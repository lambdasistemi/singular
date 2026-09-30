#!/usr/bin/env bash
# Alice's open-datum story through the packaged `singular` commands (#299).
#
# usage: demo1_cli_journey.sh SINGULAR DEVNET BLUEPRINT WORKDIR
#
# SINGULAR and DEVNET are executables; BLUEPRINT is the registry
# partition's plutus.json. ONE development node is started once, funding
# two generated wallets (alice, bob), and every registry command is a
# separate process against it:
#
#   create -> insert -> inspect -> update -> inspect -> terminate -> inspect
#
# Each process leaves one JSON receipt. Assertions read those receipts,
# the target directory's own journal and files, and nothing else. A
# refusal control names the outcome class it expects and requires the
# target's journal to be exactly as it was: nothing submitted. Setup
# failures (no node, no socket) are reported as setup, never as a result.
set -euo pipefail

[ "$#" -eq 4 ] || { echo "usage: $0 SINGULAR DEVNET BLUEPRINT WORKDIR" >&2; exit 2; }
singular="$1"; devnet="$2"; blueprint="$3"; work="$4"
rm -rf "$work"; mkdir -p "$work"
receipts="$work/receipts"; mkdir -p "$receipts"
reg="$work/registry"

fail() { echo "journey: FAIL: $*" >&2; exit 1; }
setup_fail() { echo "journey: SETUP: $*" >&2; exit 3; }
say() { echo "journey: $*"; }

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey > "$work/alice.skey"
hexkey > "$work/bob.skey"
hexkey > "$work/carol.skey"   # never funded

# ------------------------------------------------------------------
# One persistent development node
# ------------------------------------------------------------------
export TMPDIR="$work"
"$devnet" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" \
    --fund-outputs 4 --fund-lovelace 2000000000 \
    > "$work/devnet.out" 2> "$work/devnet.err" &
devnet_pid=$!
# The node is the devnet runner's child: reap both, so no node of this
# run outlives it holding the development network's ports.
trap 'kill "$devnet_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
sock=""
for _ in $(seq 1 900); do
    sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
    [ -n "$sock" ] && [ -S "$sock" ] && break
    kill -0 "$devnet_pid" 2>/dev/null || break
    sleep 1
done
if [ -z "$sock" ] || [ ! -S "$sock" ]; then
    tail -40 "$work/devnet.err" >&2 || true
    setup_fail "the development node never printed a usable socket"
fi
say "one development node at $sock"

node=(--node-socket "$sock" --network-magic 42)
common=(--registry "$reg" --blueprint "$blueprint")
alice=(--wallet-skey "$work/alice.skey")
bob=(--wallet-skey "$work/bob.skey")

exit_of() {
    case "$1" in
        success) echo 0 ;; client-refusal) echo 10 ;; ledger-refusal) echo 11 ;;
        node-unavailable) echo 12 ;; timeout) echo 13 ;; stale-state) echo 14 ;;
        partial) echo 15 ;; concurrent-writer) echo 16 ;; proof-missing) echo 17 ;;
        proof-inconsistent) echo 18 ;; *) fail "no exit status for class $1" ;;
    esac
}
# run NAME CLASS -- ARGS: one singular process; its receipt must name CLASS
# and its exit status must be that class's.
run() {
    local name="$1" class="$2"; shift 3
    local status=0
    "$singular" "$@" > "$receipts/$name.json" 2> "$receipts/$name.err" || status=$?
    local got; got="$(jq -r '.outcome' "$receipts/$name.json" 2>/dev/null || echo none)"
    if [ "$got" != "$class" ] || [ "$status" -ne "$(exit_of "$class")" ]; then
        cat "$receipts/$name.json" >&2 || true
        tail -20 "$receipts/$name.err" >&2 || true
        fail "$name: outcome $got (exit $status), expected $class"
    fi
    say "$name: $class"
}
journal_lines() { if [ -f "$1/journal.jsonl" ]; then wc -l < "$1/journal.jsonl"; else echo 0; fi; }
# refused NAME CLASS -- ARGS: a refusal against the actual target; its
# journal must not move.
refused() {
    local name="$1" class="$2"; shift 3
    local before; before="$(journal_lines "$reg")"
    run "$name" "$class" -- "$@"
    [ "$(journal_lines "$reg")" = "$before" ] \
        || fail "$name: the target's journal moved; a refusal submitted something"
}
field() { jq -r "$2" "$receipts/$1.json"; }

# envelope FILE CONTROLLER KEY [REGISTRY_NAME] [ACTIVE]: an envelope with
# a nested payload, naming this registry unless told otherwise.
envelope() {
    local file="$1" controller="$2" key="$3" name="${4:-$token}" active="${5:-$active}"
    jq -n --arg s "$state" --arg t "$name" --arg a "$active" --arg k "$key" --arg c "$controller" '
      {constructor:0, fields:[
        {constructor:0, fields:[{int:1},{constructor:0,fields:[{bytes:$s},{bytes:$t}]},
          {bytes:$a},{bytes:$k},{bytes:$c},{int:2000000}]},
        {map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}]}' > "$file"
}

# ------------------------------------------------------------------
# The command surface
# ------------------------------------------------------------------
"$singular" --help > "$work/help.txt"
for c in create insert update terminate inspect; do
    grep -q "singular registry $c" "$work/help.txt" || fail "help does not name registry $c"
done
status=0
"$singular" registry inspect --key 00 "${common[@]}" "${node[@]}" "${alice[@]}" > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "inspect accepted a signing key (exit $status)"
say "help names the five commands; a signing key on inspect is refused"

# ------------------------------------------------------------------
# 1. create
# ------------------------------------------------------------------
run preview success -- registry create --preview "${common[@]}" "${node[@]}" "${alice[@]}"
[ ! -e "$reg" ] || fail "preview created the target $reg"
seed="$(field preview .seed)"
run bob-preview success -- registry create --preview --registry "$work/bob-preview" \
    --blueprint "$blueprint" "${node[@]}" "${bob[@]}"
[ ! -e "$work/bob-preview" ] || fail "bob's preview created its target"
bobkey="$(field bob-preview .walletKeyHash)"

run create-seed-not-owned client-refusal -- registry create --seed "$seed" \
    "${common[@]}" "${node[@]}" "${bob[@]}"
[ ! -e "$reg/registry.json" ] || fail "a refused create saved a registry"

run create success -- registry create --seed "$seed" "${common[@]}" "${node[@]}" "${alice[@]}"
state="$(field create .pins.pinState)"; token="$(field create .token)"
active="$(field create .pins.pinActive)"; alicekey="$(field create .walletKeyHash)"
[ "$(field create .seed)" = "$seed" ] || fail "create booted from another seed"
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"]' \
    "$receipts/create.json" > /dev/null || fail "create did not publish the six references"
refused create-again client-refusal -- registry create --seed "$seed" "${common[@]}" "${node[@]}" "${alice[@]}"
say "registry $token booted from $seed"

# ------------------------------------------------------------------
# 2. insert (alice), with its refusals
# ------------------------------------------------------------------
key=6b657941
envelope "$work/alice.json" "$alicekey" "$key"
envelope "$work/alice-other-key.json" "$alicekey" 6b657958
envelope "$work/alice-other-registry.json" "$alicekey" "$key" 00
envelope "$work/alice-by-bob.json" "$alicekey" 6b657942
refused insert-envelope-key-mismatch client-refusal -- registry insert --key "$key" \
    --envelope "$work/alice-other-key.json" "${common[@]}" "${node[@]}" "${alice[@]}"
refused insert-other-registry client-refusal -- registry insert --key "$key" \
    --envelope "$work/alice-other-registry.json" "${common[@]}" "${node[@]}" "${alice[@]}"
refused insert-not-controller client-refusal -- registry insert --key 6b657942 \
    --envelope "$work/alice-by-bob.json" "${common[@]}" "${node[@]}" "${bob[@]}"

run insert success -- registry insert --key "$key" --envelope "$work/alice.json" \
    "${common[@]}" "${node[@]}" "${alice[@]}"
run inspect-1 success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-1 .leaf)" = active ] || fail "inspect after insert is not active"
[ "$(field inspect-1 .root)" = "$(field insert .root)" ] || fail "inspect root differs from insert"
jq -e --slurpfile e "$work/alice.json" '.applicationOutput.envelope == $e[0]' \
    "$receipts/inspect-1.json" > /dev/null || fail "the holding's envelope is not the one inserted"

# bob, a wallet that did not create the registry, inserts his own key.
bkey=6b657942
envelope "$work/bob.json" "$bobkey" "$bkey"
run bob-insert success -- registry insert --key "$bkey" --envelope "$work/bob.json" \
    "${common[@]}" "${node[@]}" "${bob[@]}"
run inspect-bob success -- registry inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-bob .leaf)" = active ] || fail "bob's key is not active"

# ------------------------------------------------------------------
# 3. update (alice), with its refusals
# ------------------------------------------------------------------
jq -n '{constructor:3, fields:[{bytes:"626f62"},{int:123456789012345678901234567890}]}' > "$work/payload.json"
refused update-not-controller client-refusal -- registry update --key "$key" \
    --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${bob[@]}"
root_before="$(field inspect-1 .root)"
run update success -- registry update --key "$key" --payload "$work/payload.json" \
    "${common[@]}" "${node[@]}" "${alice[@]}"
run inspect-2 success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-2 .leaf)" = active ] || fail "inspect after update is not active"
[ "$(field inspect-2 .root)" = "$(field bob-insert .root)" ] || fail "the update moved the root"
jq -e --slurpfile p "$work/payload.json" '.applicationOutput.payload == $p[0]' \
    "$receipts/inspect-2.json" > /dev/null || fail "the holding does not carry the new payload"

# ------------------------------------------------------------------
# 4. process boundaries on the actual target
# ------------------------------------------------------------------
# Missing proof material: the mirror moved aside, inspect prints no leaf.
mv "$reg/registry.mirror.json" "$work/mirror.aside"
run inspect-no-mirror proof-missing -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-no-mirror .leaf)" = null ] || fail "a leaf was printed without proof material"
mv "$work/mirror.aside" "$reg/registry.mirror.json"
# A changed application selector.
cp "$reg/registry.json" "$work/registry.json.aside"
jq '.confApplication = "open.open"' "$work/registry.json.aside" > "$reg/registry.json"
refused insert-selector-changed client-refusal -- registry insert --key 6b657943 \
    --envelope "$work/alice.json" "${common[@]}" "${node[@]}" "${alice[@]}"
cp "$work/registry.json.aside" "$reg/registry.json"
# No node at all.
run inspect-no-node node-unavailable -- registry inspect --key "$key" "${common[@]}" \
    --node-socket "$work/absent.sock" --network-magic 42
[ "$(field inspect-no-node .leaf)" = null ] || fail "a leaf was printed with no node"
# A concurrent writer on the same target. An OS lock holder takes the
# target's actual lock (an fcntl open-file-description lock, which conflicts
# with the command's own fcntl lock) and is verified to hold it; the
# command is then refused without reading or submitting anything.
envelope "$work/alice-c.json" "$alicekey" 6b657943
rm -f "$work/lock.held" "$work/lock.pid"
# The holding process is the exec'd sleep itself, so killing it releases
# the lock (the open-file description dies with its last holder).
flock --fcntl "$reg/.lock" bash -c 'echo $ > "$1/lock.pid"; touch "$1/lock.held"; exec sleep 120' _ "$work" &
holder=$!
for _ in $(seq 1 100); do [ -e "$work/lock.held" ] && break; sleep 0.1; done
[ -e "$work/lock.held" ] || setup_fail "the lock holder never acquired $reg/.lock"
if flock --fcntl --nonblock "$reg/.lock" true; then
    setup_fail "the lock holder does not hold $reg/.lock"
fi
refused concurrent-writer concurrent-writer -- registry insert --key 6b657943 \
    --envelope "$work/alice-c.json" "${common[@]}" "${node[@]}" "${alice[@]}"
kill "$(cat "$work/lock.pid")" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
flock --fcntl --nonblock "$reg/.lock" true || setup_fail "the lock holder did not release $reg/.lock"
run insert-after-release success -- registry insert --key 6b657943 \
    --envelope "$work/alice-c.json" "${common[@]}" "${node[@]}" "${alice[@]}"

# ------------------------------------------------------------------
# 5. terminate, killed after the node accepted its fold
# ------------------------------------------------------------------
refused terminate-not-controller client-refusal -- registry terminate --key "$key" \
    "${common[@]}" "${node[@]}" "${bob[@]}"
# The process is held by the marked harness point right after the node's
# acceptance of its fold is journalled, and killed there.
before="$(journal_lines "$reg")"
rm -f "$work/fold.go" "$work/fold.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/fold.go" SINGULAR_HARNESS_HOLD_STEP=fold \
    "$singular" registry terminate --key "$key" "${common[@]}" "${node[@]}" "${alice[@]}" \
    > "$receipts/terminate-killed.json" 2>&1 &
victim=$!
for _ in $(seq 1 1200); do
    [ -e "$work/fold.go.waiting" ] && break
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.1
done
[ -e "$work/fold.go.waiting" ] || setup_fail "the terminate never reached its accepted fold"
kill -9 "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
[ "$(tail -n 1 "$reg/journal.jsonl" | jq -r '.journalStep + "/" + .journalEvent')" = fold/submitted ] \
    || fail "the killed process did not stop at its accepted fold"
say "terminate killed after the node accepted its fold"
# A write now refuses: the fold is unresolved.
refused write-while-unresolved partial -- registry update --key "$bkey" \
    --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${bob[@]}"
# Inspecting an unrelated key never observes alice's fold.
sleep 5
run inspect-unrelated partial -- registry inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-unrelated .leaf)" = null ] || fail "a leaf was printed while unresolved"
jq -e '.observed == []' "$receipts/inspect-unrelated.json" > /dev/null \
    || fail "inspecting another key observed the killed fold"
# The relevant readback: alice's key, once the fold is on chain.
for i in $(seq 1 60); do
    status=0
    "$singular" registry inspect --key "$key" "${common[@]}" "${node[@]}" \
        > "$receipts/inspect-3.json" 2> "$receipts/inspect-3.err" || status=$?
    [ "$(jq -r .outcome "$receipts/inspect-3.json")" = success ] && break
    sleep 2
done
[ "$(field inspect-3 .outcome)" = success ] || fail "inspect never resolved the killed fold"
[ "$(field inspect-3 .leaf)" = terminal ] || fail "the killed fold did not leave the key terminal"
jq -e '.applicationOutput.absent' "$receipts/inspect-3.json" > /dev/null || fail "the holding is still live"
# The fold was advanced into the mirror exactly once, by whichever inspect
# first saw it included (root-authenticated), and observed only by the
# inspect of its own key.
fold_tx="$(jq -r '.observed[0]' "$receipts/inspect-3.json")"
[ -n "$fold_tx" ] && [ "$fold_tx" != null ] || fail "the relevant inspect observed nothing"
jq -s -e --arg t "$fold_tx" '[.[].mirrorAdvanced[]] == [$t]' \
    "$receipts/inspect-unrelated.json" "$receipts/inspect-3.json" > /dev/null \
    || fail "the mirror was not advanced exactly once by the journalled fold"
say "inspect resolved the killed fold from the chain: terminal, holding released"

# ------------------------------------------------------------------
# 6. terminate bob normally; a write works again
# ------------------------------------------------------------------
run bob-terminate success -- registry terminate --key "$bkey" "${common[@]}" "${node[@]}" "${bob[@]}"
run inspect-4 success -- registry inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-4 .leaf)" = terminal ] || fail "bob's key is not terminal"

# ------------------------------------------------------------------
# 7. create races and interruptions, on their own targets
# ------------------------------------------------------------------
# A create held after its pre-lock check while another create completes
# on the same target: once it takes the lock it must re-check and refuse.
raced="$work/raced"
run preview-raced success -- registry create --preview --registry "$raced" \
    --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
seed_r="$(field preview-raced .seed)"
SINGULAR_HARNESS_HOLD_BEFORE_LOCK="$work/go" "$singular" registry create --seed "$seed_r" \
    --registry "$raced" --blueprint "$blueprint" "${node[@]}" "${alice[@]}" \
    > "$receipts/create-raced-late.json" 2> "$receipts/create-raced-late.err" &
late=$!
for _ in $(seq 1 300); do [ -e "$work/go.waiting" ] && break; sleep 0.1; done
[ -e "$work/go.waiting" ] || setup_fail "the held create never reached its hold point"
run create-raced-first success -- registry create --seed "$seed_r" --registry "$raced" \
    --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
raced_token="$(jq -r '.confDeployment.depCageToken' "$raced/registry.json")"
raced_lines="$(journal_lines "$raced")"
touch "$work/go"
status=0; wait "$late" || status=$?
[ "$(jq -r .outcome "$receipts/create-raced-late.json")" = client-refusal ] && [ "$status" -eq 10 ] \
    || fail "the held create was not refused after the other create finished (exit $status)"
[ "$(journal_lines "$raced")" = "$raced_lines" ] || fail "the held create submitted something"
[ "$(jq -r '.confDeployment.depCageToken' "$raced/registry.json")" = "$raced_token" ] \
    || fail "the held create replaced the first registry"
say "create-raced-late: client-refusal after the lock; the first registry stands"

# A create killed after its first accepted submission: a new create is
# refused, and inspect reads the incomplete create from its journal.
inter="$work/interrupted"
run preview-inter success -- registry create --preview --registry "$inter" \
    --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
seed_i="$(field preview-inter .seed)"
rm -f "$work/create.go" "$work/create.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/create.go" SINGULAR_HARNESS_HOLD_STEP=boot \
    "$singular" registry create --seed "$seed_i" --registry "$inter" --blueprint "$blueprint" \
    "${node[@]}" "${alice[@]}" > "$receipts/create-killed.json" 2>&1 &
victim=$!
for _ in $(seq 1 1200); do
    [ -e "$work/create.go.waiting" ] && break
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.1
done
[ -e "$work/create.go.waiting" ] || setup_fail "the create never reached an accepted submission"
kill -9 "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true
[ ! -e "$inter/registry.json" ] || setup_fail "the create finished before it was killed"
first_tx="$(jq -r 'select(.journalEvent == "submitted") | .journalTxId' "$inter/journal.jsonl" | head -n1)"
inter_lines="$(journal_lines "$inter")"
run create-after-kill client-refusal -- registry create --seed "$seed_i" --registry "$inter" \
    --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
[ "$(journal_lines "$inter")" = "$inter_lines" ] || fail "a create after the kill submitted something"
for _ in $(seq 1 60); do
    run inspect-interrupted partial -- registry inspect --key 00 --registry "$inter" \
        --blueprint "$blueprint" "${node[@]}"
    jq -e --arg t "$first_tx" '.observed | index($t)' "$receipts/inspect-interrupted.json" > /dev/null && break
    sleep 2
done
jq -e '.incompleteCreate.seed' "$receipts/inspect-interrupted.json" > /dev/null \
    || fail "inspect did not read the incomplete create's identity"
[ "$(field inspect-interrupted .leaf)" = null ] || fail "an incomplete create printed a leaf"
jq -e --arg t "$first_tx" 'select(.journalTxId == $t and .journalEvent == "observed")' \
    "$inter/journal.jsonl" > /dev/null || fail "the killed create's accepted submission was never observed"
say "an interrupted create is refused a second boot and read back from its journal"

# ------------------------------------------------------------------
# 8. the node lost after an accepted submission (last: the node dies)
# ------------------------------------------------------------------
jq -n '{int: 42}' > "$work/payload-2.json"
before="$(journal_lines "$reg")"
rm -f "$work/update.go" "$work/update.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/update.go" SINGULAR_HARNESS_HOLD_STEP=update \
    "$singular" registry update --key 6b657943 --payload "$work/payload-2.json" --confirm-timeout 30 \
    "${common[@]}" "${node[@]}" "${alice[@]}" > "$receipts/update-node-lost.json" 2> "$receipts/update-node-lost.err" &
victim=$!
for _ in $(seq 1 1200); do
    [ -e "$work/update.go.waiting" ] && break
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.1
done
[ -e "$work/update.go.waiting" ] || setup_fail "the update never reached an accepted submission"
lost_tx="$(tail -n +"$((before + 1))" "$reg/journal.jsonl" | jq -r 'select(.journalEvent == "submitted") | .journalTxId' | head -n1)"
kill "$devnet_pid" 2>/dev/null || true
pkill -f "cardano-node run --config $work/" 2>/dev/null || true
for _ in $(seq 1 100); do [ -S "$sock" ] || break; pgrep -f "cardano-node run --config $work/" > /dev/null || break; sleep 0.1; done
released_at=$(date +%s)
touch "$work/update.go"
status=0; wait "$victim" || status=$?
waited=$(( $(date +%s) - released_at ))
# The bound holds with the node gone: the command ends within its
# --confirm-timeout (plus teardown), attributing the submitted update —
# partial when the wait fails, timeout when it outlives the bound.
[ "$waited" -le 90 ] || fail "node lost after submit: the command waited ${waited}s past a 30s bound"
outcome="$(jq -r .outcome "$receipts/update-node-lost.json")"
case "$outcome/$status" in
    partial/15 | timeout/13) ;;
    *) fail "node lost after submit: outcome $outcome (exit $status), expected partial or timeout" ;;
esac
jq -e --arg t "$lost_tx" '.reason | contains($t)' "$receipts/update-node-lost.json" > /dev/null \
    || fail "the partial receipt does not name the submitted transaction"
[ "$(tail -n 1 "$reg/journal.jsonl" | jq -r .journalEvent)" = unconfirmed ] \
    || fail "the journal does not keep the submitted update unresolved"
say "node lost after an accepted submission: $outcome after ${waited}s, naming $lost_tx, journal unresolved"

jq -r '.journalEvent' "$reg/journal.jsonl" | sort | uniq -c
say "JOURNEY-OK"
