#!/usr/bin/env bash
# The Demo 1 journey through the packaged `singular` commands (#299).
#
# usage: demo1_cli_journey.sh SINGULAR DEVNET BLUEPRINT WORKDIR
#
# SINGULAR and DEVNET are executables (the archive's own builds when
# demo1-cli-check runs this); BLUEPRINT is the archive's
# onchain/plutus.json. One development node is started ONCE and every
# registry command is a separate process against it:
#
#   create -> insert -> inspect -> terminate -> inspect
#
# Each process leaves one receipt. The assertions read those receipts
# and the ledger reads they carry: the same registry, network, wallet and
# key throughout; the seed reserved through the preparatory publications
# and consumed by the boot; the keyed +1 and -1; the wallet's active
# holding 0 -> 1 -> 0; the ledger root equal to the locally proven one.
# Refusal controls run at the boundary they belong to and assert the
# outcome class the command reports, never an exit status alone, and a
# refusal must leave the journal exactly as it was: nothing submitted.
#
# Client, node, timeout and setup failures are never read as ledger
# evidence: every assertion names the receipt field it reads.
set -euo pipefail

[ "$#" -eq 4 ] || { echo "usage: $0 SINGULAR DEVNET BLUEPRINT WORKDIR" >&2; exit 2; }
singular="$1"; devnet="$2"; blueprint="$3"; work="$4"
mkdir -p "$work"
receipts="$work/receipts"; mkdir -p "$receipts"
reg="$work/registry"

fail() { echo "demo1-cli: FAIL: $*" >&2; exit 1; }
say() { echo "demo1-cli: $*"; }

# A generated development wallet, as hex text, and a second one that
# never funds anything: the wrong-wallet control.
hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey > "$work/wallet.skey"
hexkey > "$work/other.skey"

# ONE persistent development node for the whole journey. Its chain lives
# under this run's own TMPDIR, kept short: a unix socket path is short.
export TMPDIR="$work"
"$devnet" --fund-skey "$work/wallet.skey" --fund-outputs 4 --fund-lovelace 2000000000 \
    > "$work/devnet.out" 2> "$work/devnet.err" &
devnet_pid=$!
trap 'kill "$devnet_pid" 2>/dev/null || true' EXIT
sock=""
for _ in $(seq 1 600); do
    sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
    [ -n "$sock" ] && [ -S "$sock" ] && break
    kill -0 "$devnet_pid" 2>/dev/null || break
    sleep 1
done
if [ -z "$sock" ] || [ ! -S "$sock" ]; then
    tail -40 "$work/devnet.err" >&2 || true
    fail "setup: the development node never printed a usable socket"
fi
say "one development node at $sock"

node=(--node-socket "$sock" --network-magic 42)
common=(--registry "$reg" --blueprint "$blueprint")
wallet=(--wallet-skey "$work/wallet.skey")

# run NAME EXPECTED-EXIT -- ARGS: one singular process, its stdout kept as
# the receipt NAME.json, its exit status compared with the expected one.
run() {
    local name="$1" expected="$2"; shift 3
    local status=0
    "$singular" "$@" > "$receipts/$name.json" 2> "$receipts/$name.err" || status=$?
    if [ "$status" -ne "$expected" ]; then
        cat "$receipts/$name.err" >&2 || true
        cat "$receipts/$name.json" >&2 || true
        fail "$name: exit $status, expected $expected"
    fi
}
# The outcome class a refusal receipt names.
class_of() { jq -r '.outcome.class' "$receipts/$1.json"; }
expect_class() {
    local got; got="$(class_of "$1")"
    [ "$got" = "$2" ] || fail "$1: outcome class $got, expected $2"
}
# The journal of the registry directory a process actually used.
journal_lines() { if [ -f "$1/journal.jsonl" ]; then wc -l < "$1/journal.jsonl"; else echo 0; fi; }
exit_of() {
    case "$1" in
        client-refusal) echo 10 ;; node-unavailable) echo 12 ;; timeout) echo 13 ;;
        stale-state) echo 14 ;; partial) echo 15 ;; *) fail "no exit for class $1" ;;
    esac
}
# refused NAME DIR CLASS -- ARGS: one process against the registry in DIR
# must end in CLASS and leave DIR's journal exactly as it was.
refused() {
    local name="$1" dir="$2" class="$3"; shift 4
    local before; before="$(journal_lines "$dir")"
    run "$name" "$(exit_of "$class")" -- "$@"
    expect_class "$name" "$class"
    [ "$(journal_lines "$dir")" = "$before" ] \
        || fail "$name: the journal of $dir moved; a refusal submitted something"
}
# A copy of the registry with one saved value altered by a jq program.
altered_copy() {
    local name="$1" file="$2" program="$3" copy="$work/registry-$1"
    rm -rf "$copy"; cp -r "$reg" "$copy"
    jq "$program" "$reg/$file" > "$copy/$file"
    echo "$copy"
}

# ------------------------------------------------------------------
# The command surface
# ------------------------------------------------------------------
"$singular" --help > "$work/help.txt"
for c in create insert terminate inspect; do
    grep -q "singular registry $c" "$work/help.txt" || fail "help does not name registry $c"
done
if "$singular" registry delete > /dev/null 2>&1; then fail "an unsupported command ran"; fi
status=0; "$singular" registry inspect --key 00 "${common[@]}" "${node[@]}" "${wallet[@]}" \
    > /dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "inspect accepted a signing key (exit $status)"
say "help names the four commands; delete and a signing key on inspect are refused"

# ------------------------------------------------------------------
# 1. create — preview, controls, then the one boot
# ------------------------------------------------------------------
run preview 0 -- registry create --preview "${common[@]}" "${node[@]}" "${wallet[@]}"
[ ! -e "$reg" ] || fail "preview wrote the registry directory"
seed="$(jq -r '.wallet.seedCandidates[0]' "$receipts/preview.json")"
[ "$seed" != null ] && [ -n "$seed" ] || fail "preview offered no seed"

run create-other-wallet 10 -- registry create --seed "$seed" "${common[@]}" "${node[@]}" \
    --wallet-skey "$work/other.skey"
expect_class create-other-wallet client-refusal
jq -e '.outcome.detail | test("seed")' "$receipts/create-other-wallet.json" > /dev/null \
    || fail "create with another wallet was not refused on the seed"
[ ! -e "$reg/registry.json" ] || fail "a refused create saved a registry"

run create 0 -- registry create --seed "$seed" "${common[@]}" "${node[@]}" "${wallet[@]}"
token="$(jq -r '.registry.token' "$receipts/create.json")"
say "process 1: create booted registry $token from seed $seed"
jq -e --arg seed "$seed" '
    def txid: type == "string" and test("^[0-9a-f]{64}$");
    .outcome.class == "success"
    and .registry.seed == $seed
    and (.submitted | map(.step)) == ["publish-state", "boot", "publish-references"]
    and all(.submitted[]; (.txid | txid) and .confirmed == true)
    and all(.submitted[] | select(.step != "boot"); (.inputs | index($seed)) == null)
    and ([.submitted[] | select(.step == "boot") | .inputs | index($seed)] | .[0] != null)
    and .ledger.seedInWallet == false
    and (.ledger.stateOutput.token == .registry.token)
    and (.ledger.chainPoint.slot | type == "number")
' "$receipts/create.json" > /dev/null || fail "create: seed reservation, boot or readback not observed"

refused create-again "$reg" client-refusal -- \
    registry create --seed "$seed" "${common[@]}" "${node[@]}" "${wallet[@]}"
say "a second create over the saved registry is refused and submits nothing"

# A node that is not there halts a write and a read by name.
refused insert-no-node "$reg" node-unavailable -- registry insert --key 00 "${common[@]}" \
    --node-socket "$work/no-such-node.socket" --network-magic 42 "${wallet[@]}"
refused inspect-no-node "$reg" node-unavailable -- registry inspect --key 00 "${common[@]}" \
    --node-socket "$work/no-such-node.socket" --network-magic 42
say "an unavailable node halts insert and inspect as node-unavailable"

# ------------------------------------------------------------------
# 2. insert
# ------------------------------------------------------------------
key="$(printf 'demo1-%s' "$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')" | od -An -tx1 | tr -d ' \n')"
run insert 0 -- registry insert --key "$key" "${common[@]}" "${node[@]}" "${wallet[@]}"
say "process 2: insert folded key $key"
jq -e --arg key "$key" '
    def txid: type == "string" and test("^[0-9a-f]{64}$");
    .outcome.class == "success" and .key == $key
    and (.submitted | map(.step)) == ["book", "fold"]
    and all(.submitted[]; (.txid | txid) and .confirmed == true)
    and .effects.mint == [{"policy": .registry.pins.pinActive, "name": $key, "quantity": 1}]
    and .effects.destination.holdsKey == true
    and .effects.destination.lovelace >= .effects.deposit
    and .before.localProof.leaf == "unknown" and .after.localProof.leaf == "active"
    and .before.ledger.stateOutput.root == .before.localProof.root
    and .after.ledger.stateOutput.root == .after.localProof.root
    and .before.ledger.stateOutput.root != .after.ledger.stateOutput.root
    and .before.ledger.stateOutput.config == .after.ledger.stateOutput.config
    and .before.ledger.custody == .after.ledger.custody
    and .before.ledger.activeAtWallet == 0 and .after.ledger.activeAtWallet == 1
' "$receipts/insert.json" > /dev/null || fail "insert: the Active transition was not observed"

# Keep this registry as it stood after the insert: the stale control.
cp -r "$reg" "$work/registry-after-insert"

refused insert-again "$reg" client-refusal -- \
    registry insert --key "$key" "${common[@]}" "${node[@]}" "${wallet[@]}"
refused insert-other-wallet "$reg" client-refusal -- \
    registry insert --key 00 "${common[@]}" "${node[@]}" --wallet-skey "$work/other.skey"
say "a duplicate insert and another wallet are refused before submission"

# Every saved value a write relies on, altered one at a time in its own
# copy: each copy's own journal must stay as it was.
other_seed="$(jq -r '.wallet.seedCandidates[1]' "$receipts/preview.json")"
while IFS='|' read -r name file program class; do
    copy="$(altered_copy "$name" "$file" "$program")"
    refused "insert-$name" "$copy" "$class" -- registry insert --key 00 --registry "$copy" \
        --blueprint "$blueprint" "${node[@]}" "${wallet[@]}"
done <<EOF
pin|registry.json|.confPins.pinTerminal = ("00" * 28)|client-refusal
token|registry.json|.confDeployment.depCageToken = ("00" * 32)|client-refusal
seed|registry.json|.confDeployment.depSeedOutRef = "$other_seed"|client-refusal
reference|registry.json|.confDeployment.depReferenceScripts[0].refOutRef = ("00" * 32 + "#0")|client-refusal
network|registry.json|.confNetworkMagic = 43|client-refusal
root|state.json|.localRoot = ("00" * 32)|stale-state
proof|registry.mirror.json|.mirrorTries[0].mtMpf = []|stale-state
EOF
jq -e '.outcome.detail | test("terminal")' "$receipts/insert-pin.json" > /dev/null \
    || fail "a tampered terminal pin was not refused by name"
say "altered pin, token, seed, reference, network, root and proof are each refused before submission"

# ------------------------------------------------------------------
# 3. inspect — confirmed Active, no signing key
# ------------------------------------------------------------------
run inspect-active 0 -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
say "process 3: inspect read the key back"
jq -e --arg key "$key" '
    .outcome.class == "success" and .key == $key
    and .status == "active"
    and .localProof.leaf == "active"
    and .localProof.root == .ledger.stateOutput.root
    and .ledger.activeAtWallet == 1 and .ledger.terminalAtWallet == 0
    and (.read.chainPoint.slot | type == "number")
    and (.read.mechanism | type == "string" and length > 0)
' "$receipts/inspect-active.json" > /dev/null || fail "inspect did not confirm Active"

for name in proof root token; do
    copy="$work/registry-$name"
    class=stale-state; [ "$name" = token ] && class=client-refusal
    refused "inspect-$name" "$copy" "$class" -- registry inspect --key "$key" \
        --registry "$copy" --blueprint "$blueprint" "${node[@]}"
done
refused inspect-other-network "$reg" client-refusal -- registry inspect --key "$key" \
    "${common[@]}" --node-socket "$sock" --network-magic 43
# Another key reads back as what it is: bound to nothing, held by no one.
run inspect-other-key 0 -- registry inspect --key 00 "${common[@]}" "${node[@]}"
jq -e '.status == "unknown" and .localProof.leaf == "unknown" and .ledger.activeAtWallet == 0' \
    "$receipts/inspect-other-key.json" > /dev/null || fail "another key did not read back unknown"
say "inspect refuses an altered proof, root and token and another network; another key reads unknown"

# ------------------------------------------------------------------
# 4. terminate
# ------------------------------------------------------------------
run terminate 0 -- registry terminate --key "$key" "${common[@]}" "${node[@]}" "${wallet[@]}"
say "process 4: terminate folded key $key"
jq -e --arg key "$key" '
    def txid: type == "string" and test("^[0-9a-f]{64}$");
    .outcome.class == "success" and .key == $key
    and (.submitted | map(.step)) == ["book", "fold"]
    and all(.submitted[]; (.txid | txid) and .confirmed == true)
    and .effects.mint == [{"policy": .registry.pins.pinActive, "name": $key, "quantity": -1}]
    and .effects.terminalMint == []
    and .effects.ownerReturn.lovelace >= .effects.deposit
    and .effects.destinationOutput == "held: #304"
    and .before.localProof.leaf == "active" and .after.localProof.leaf == "terminal"
    and .after.ledger.stateOutput.root == .after.localProof.root
    and .before.ledger.stateOutput.config == .after.ledger.stateOutput.config
    and .before.ledger.custody == .after.ledger.custody
    and .before.ledger.activeAtWallet == 1 and .after.ledger.activeAtWallet == 0
' "$receipts/terminate.json" > /dev/null || fail "terminate: the Terminal transition was not observed"

refused terminate-again "$reg" client-refusal -- \
    registry terminate --key "$key" "${common[@]}" "${node[@]}" "${wallet[@]}"
refused terminate-unknown "$reg" client-refusal -- \
    registry terminate --key 00 "${common[@]}" "${node[@]}" "${wallet[@]}"
refused terminate-stale "$work/registry-after-insert" stale-state -- registry terminate \
    --key "$key" --registry "$work/registry-after-insert" --blueprint "$blueprint" \
    "${node[@]}" "${wallet[@]}"
say "repeated, unknown and stale terminations are refused before submission"

# ------------------------------------------------------------------
# 5. inspect — confirmed Terminal
# ------------------------------------------------------------------
run inspect-terminal 0 -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
say "process 5: inspect read the key back"
jq -e --arg key "$key" '
    .outcome.class == "success" and .status == "terminal"
    and .localProof.leaf == "terminal"
    and .localProof.root == .ledger.stateOutput.root
    and .ledger.activeAtWallet == 0
' "$receipts/inspect-terminal.json" > /dev/null || fail "inspect did not confirm Terminal"
refused inspect-stale "$work/registry-after-insert" stale-state -- registry inspect \
    --key "$key" --registry "$work/registry-after-insert" --blueprint "$blueprint" "${node[@]}"

# ------------------------------------------------------------------
# Continuity across the five processes, and its own control
# ------------------------------------------------------------------
continuity='
    [.[] | .registry | {token, seed, networkMagic, wallet, pins}] | unique | length == 1
'
jq -s -e "$continuity" "$receipts"/{create,insert,inspect-active,terminate,inspect-terminal}.json \
    > /dev/null || fail "the five processes did not share one registry identity"
jq -s -e --arg key "$key" 'all(.[]; .key == $key)' \
    "$receipts"/{insert,inspect-active,terminate,inspect-terminal}.json > /dev/null \
    || fail "the entry processes did not share one key"
jq '.registry.token = ("00" * 32)' "$receipts/insert.json" > "$work/insert-altered.json"
if jq -s -e "$continuity" "$receipts/create.json" "$work/insert-altered.json" > /dev/null; then
    fail "control: an altered receipt passed the continuity check"
fi

# ------------------------------------------------------------------
# An interrupted write: the process stops right after its first
# submission, which is kept; the next write refuses to go on from it.
# ------------------------------------------------------------------
second="$(printf 'demo1-late' | od -An -tx1 | tr -d ' \n')"
before="$(journal_lines "$reg")"
run insert-timeout "$(exit_of timeout)" -- registry insert --key "$second" --confirm-timeout 0 \
    "${common[@]}" "${node[@]}" "${wallet[@]}"
expect_class insert-timeout timeout
pending="$(jq -r '.submitted[0].txid' "$receipts/insert-timeout.json")"
jq -e '(.submitted | length) == 1 and .submitted[0].step == "book"
       and .submitted[0].confirmed == false
       and (.submitted[0].txid | test("^[0-9a-f]{64}$"))' \
    "$receipts/insert-timeout.json" > /dev/null || fail "the stopped insert did not report its one submission"
[ "$(journal_lines "$reg")" = "$((before + 1))" ] || fail "the stopped insert did not journal exactly one submission"
tail -n1 "$reg/journal.jsonl" | jq -e --arg t "$pending" '.journalTxId == $t and .journalEvent == "submitted"' \
    > /dev/null || fail "the journal does not keep the stopped submission"
refused insert-after-timeout "$reg" partial -- \
    registry insert --key "$second" "${common[@]}" "${node[@]}" "${wallet[@]}"
refused terminate-after-timeout "$reg" partial -- \
    registry terminate --key "$key" "${common[@]}" "${node[@]}" "${wallet[@]}"
jq -e --arg t "$pending" '.outcome.detail | contains($t)' "$receipts/insert-after-timeout.json" \
    > /dev/null || fail "the refusal does not name the unconfirmed submission"
say "a stopped insert keeps its submission; later writes refuse to continue past it"

say "PASS: five processes, one node, one registry $token, key $key Active then Terminal"
