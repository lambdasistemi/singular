#!/usr/bin/env bash
# Alice's open-datum story through the packaged `singular` commands (#299),
# under each read backend (#324).
#
# usage: demo1_cli_journey.sh SINGULAR DEVNET BLUEPRINT WORKDIR [BACKEND]
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
#
# BACKEND is `node` or `indexer`. Without it the journey runs under the
# node backend and then again, on a fresh development node in
# WORKDIR-indexer, under the indexer backend. There every process runs
# with `--backend indexer`, each successful one must report the address
# reads the in-process index answered (a line the node backend never
# prints, shown absent on a node-backend control), and a wallet whose
# only output is in the genesis ledger state is refused by name.
set -euo pipefail

[ "$#" -eq 4 ] || [ "$#" -eq 5 ] || {
  echo "usage: $0 SINGULAR DEVNET BLUEPRINT WORKDIR [BACKEND]" >&2
  exit 2
}
singular="$1"
devnet="$2"
blueprint="$3"
work="$4"
backend="${5:-}"
case "$backend" in
  "" | node | indexer) ;;
  *)
    echo "usage: BACKEND is node or indexer, not $backend" >&2
    exit 2
    ;;
esac
rm -rf "$work"
mkdir -p "$work"
receipts="$work/receipts"
mkdir -p "$receipts"
reg="$work/registry"

fail() {
  echo "journey: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "journey: SETUP: $*" >&2
  exit 3
}
say() { echo "journey: $*"; }

# Under the indexer backend every process, the create race's included,
# names it; `node_singular` is the same executable at its default.
node_singular="$singular"
if [ "$backend" = indexer ]; then
  printf '#!/usr/bin/env bash\nexec %q "$@" --backend indexer\n' "$singular" >"$work/singular"
  chmod +x "$work/singular"
  singular="$work/singular"
fi

# served ERR: the process whose standard error is ERR read through the
# index: it names at least one address read the index answered, and at
# most one node address read (a write's wallet coverage check).
served() {
  grep -Eq '^node: indexer backend: [1-9][0-9]* address reads answered by the index, [01] by the node$' "$1"
}

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/alice.skey"
hexkey >"$work/bob.skey"
hexkey >"$work/carol.skey" # never funded

export TMPDIR="$work"

# ------------------------------------------------------------------
# 0. coverage (indexer backend): a genesis-only wallet is refused
# ------------------------------------------------------------------
# On a development node nobody has paid from yet, the genesis key holds
# its one output in the ledger's initial state, carried by no block. The
# node backend reads it (a preview seeds from it, naming the refusal a
# create from that one-output wallet meets, and such a create is refused
# before it writes anything); the indexer backend, following blocks from
# the origin, refuses the wallet by name and submits nothing, rather than
# reading it as empty.
if [ "$backend" = indexer ]; then
  "$devnet" >"$work/bare.out" 2>"$work/bare.err" &
  bare_pid=$!
  trap 'kill "$bare_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
  bare=""
  for _ in $(seq 1 900); do
    bare="$(head -n1 "$work/bare.out" 2>/dev/null || true)"
    [ -n "$bare" ] && [ -S "$bare" ] && break
    kill -0 "$bare_pid" 2>/dev/null || break
    sleep 1
  done
  [ -n "$bare" ] && [ -S "$bare" ] || setup_fail "the unfunded development node never printed a usable socket"
  # The genesis UTxO key of the development network (cardano-node-clients'
  # genesisSignKey): its 32 seed bytes are the raw signing key.
  printf '%s' e2e-genesis-utxo-key-seed-000001 | od -An -tx1 | tr -d ' \n' >"$work/genesis.skey"
  genesis=(--wallet-skey "$work/genesis.skey")
  bare_node=(--node-socket "$bare" --network-magic 42)
  status=0
  "$node_singular" registry create --preview --registry "$work/genesis-node" --blueprint "$blueprint" \
    "${bare_node[@]}" "${genesis[@]}" >"$receipts/genesis-node.json" 2>"$receipts/genesis-node.err" || status=$?
  [ "$status" -eq 0 ] && [ "$(jq -r .outcome "$receipts/genesis-node.json")" = success ] \
    || fail "the node backend did not preview the genesis key's output (exit $status): $(jq -r .reason "$receipts/genesis-node.json" 2>/dev/null)"
  ! served "$receipts/genesis-node.err" || fail "a node-backend process reported reads the index answered"
  # That output is the wallet's only one, so the preview names the refusal a
  # create would meet, and a create is refused before it writes anything.
  jq -e '.seed as $s | .createRefusal | type == "string" and contains($s) and contains("only ada-only output")' \
    "$receipts/genesis-node.json" >/dev/null \
    || fail "the preview of a one-output wallet does not report the refusal its create meets: $(jq -c .createRefusal "$receipts/genesis-node.json")"
  status=0
  "$node_singular" registry create --seed "$(jq -r .seed "$receipts/genesis-node.json")" --registry "$work/genesis-create" \
    --blueprint "$blueprint" "${bare_node[@]}" "${genesis[@]}" >"$receipts/genesis-create.json" 2>"$receipts/genesis-create.err" || status=$?
  [ "$(jq -r .outcome "$receipts/genesis-create.json")" = client-refusal ] && [ "$status" -ne 0 ] \
    || fail "a create from the one-output wallet: outcome $(jq -r .outcome "$receipts/genesis-create.json") (exit $status), expected client-refusal"
  jq -e --arg s "$(jq -r .seed "$receipts/genesis-node.json")" '.reason | contains($s) and contains("only ada-only output")' \
    "$receipts/genesis-create.json" >/dev/null || fail "the create's refusal does not name the missing funding: $(jq -r .reason "$receipts/genesis-create.json")"
  [ -z "$(find "$work/genesis-create" -mindepth 1 ! -name .lock 2>/dev/null)" ] \
    || fail "the refused create wrote more than its lock: $(find "$work/genesis-create" -mindepth 1 ! -name .lock)"
  status=0
  "$singular" registry create --preview --registry "$work/genesis-indexer" --blueprint "$blueprint" \
    "${bare_node[@]}" "${genesis[@]}" >"$receipts/genesis-indexer.json" 2>"$receipts/genesis-indexer.err" || status=$?
  [ "$(jq -r .outcome "$receipts/genesis-indexer.json")" = node-unavailable ] && [ "$status" -eq 12 ] \
    || fail "the genesis-only wallet under the indexer backend: outcome $(jq -r .outcome "$receipts/genesis-indexer.json") (exit $status), expected node-unavailable"
  jq -e --arg seed "$(jq -r .seed "$receipts/genesis-node.json")" \
    '.reason | contains("(coverage-incomplete)") and contains("genesis") and contains($seed)' \
    "$receipts/genesis-indexer.json" >/dev/null \
    || fail "the genesis-only wallet was not refused by the coverage diagnostic naming its output: $(jq -r .reason "$receipts/genesis-indexer.json")"
  [ ! -e "$work/genesis-indexer" ] || fail "the refused preview created its target"
  kill "$bare_pid" 2>/dev/null || true
  pkill -f "cardano-node run --config $work/" 2>/dev/null || true
  for _ in $(seq 1 300); do
    pgrep -f "cardano-node run --config $work/" >/dev/null || break
    sleep 0.1
  done
  wait "$bare_pid" 2>/dev/null || true
  say "a genesis-only wallet: previewed by the node backend (its create refused for want of a second output), refused by the indexer backend as coverage-incomplete"
fi

# ------------------------------------------------------------------
# One persistent development node
# ------------------------------------------------------------------
"$devnet" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" \
  --fund-outputs 4 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
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
# and its exit status must be that class's. Under the indexer backend a
# successful process must also have read through the index.
run() {
  local name="$1" class="$2"
  shift 3
  local status=0
  "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  local got
  got="$(jq -r '.outcome' "$receipts/$name.json" 2>/dev/null || echo none)"
  if [ "$got" != "$class" ] || [ "$status" -ne "$(exit_of "$class")" ]; then
    cat "$receipts/$name.json" >&2 || true
    tail -20 "$receipts/$name.err" >&2 || true
    fail "$name: outcome $got (exit $status), expected $class"
  fi
  if [ "$backend" = indexer ] && [ "$class" = success ] && ! served "$receipts/$name.err"; then
    tail -20 "$receipts/$name.err" >&2 || true
    fail "$name: no address read was answered by the index"
  fi
  say "$name: $class"
}
journal_lines() { if [ -f "$1/journal.jsonl" ]; then wc -l <"$1/journal.jsonl"; else echo 0; fi; }
# refused NAME CLASS -- ARGS: a refusal against the actual target; its
# journal must not move.
refused() {
  local name="$1" class="$2"
  shift 3
  local before
  before="$(journal_lines "$reg")"
  run "$name" "$class" -- "$@"
  [ "$(journal_lines "$reg")" = "$before" ] \
    || fail "$name: the target's journal moved; a refusal submitted something"
}
field() { jq -r "$2" "$receipts/$1.json"; }
# prepared_points DIR: the view point of each prepared line of DIR's
# journal, one JSON object each; a line missing any of the four fields
# fails the journey.
prepared_points() {
  jq -c 'select(.journalEvent == "prepared")
      | if (.journalNetwork == 42) and (.journalEra | type == "string" and length > 0)
          and (.journalChainPoint // "" | test("^[0-9]+\\.[0-9a-f]{64}$"))
        then {slot: (.journalChainPoint | split(".")[0] | tonumber)}
        else error("prepared \(.journalTxId) lacks its view point: network \(.journalNetwork), era \(.journalEra), point \(.journalChainPoint)")
        end' "$1/journal.jsonl" || fail "$1: a write did not journal its view point"
}

# envelope FILE CONTROLLER KEY [REGISTRY_NAME] [ACTIVE]: an envelope with
# a nested payload, naming this registry unless told otherwise.
envelope() {
  local file="$1" controller="$2" key="$3" name="${4:-$token}" active="${5:-$active}"
  jq -n --arg s "$state" --arg t "$name" --arg a "$active" --arg k "$key" --arg c "$controller" '
      {constructor:0, fields:[
        {constructor:0, fields:[{int:1},{constructor:0,fields:[{bytes:$s},{bytes:$t}]},
          {bytes:$a},{bytes:$k},{bytes:$c},{int:2000000}]},
        {map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}]}' >"$file"
}

# ------------------------------------------------------------------
# The command surface
# ------------------------------------------------------------------
"$singular" --help >"$work/help.txt"
for c in create insert update terminate inspect; do
  grep -q "singular registry $c" "$work/help.txt" || fail "help does not name registry $c"
done
status=0
"$singular" registry inspect --key 00 "${common[@]}" "${node[@]}" "${alice[@]}" >/dev/null 2>&1 || status=$?
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
alice_addr="$(field preview .wallet)"
bob_addr="$(field bob-preview .wallet)"

# The same preview for a public address alone: no key, no write, and the
# identity it names is the one the key-holding preview named.
run preview-public success -- registry create --preview --registry "$work/public-preview" \
  --blueprint "$blueprint" "${node[@]}" --wallet-address "$alice_addr"
[ ! -e "$work/public-preview" ] || fail "a public preview created its target"
jq -e --slurpfile k "$receipts/preview.json" '.seed == $k[0].seed and .pins == $k[0].pins and .walletKeyHash == $k[0].walletKeyHash' \
  "$receipts/preview-public.json" >/dev/null || fail "the public preview names another identity than the key preview"
status=0
"$singular" registry create --preview --registry "$work/public-preview" --blueprint "$blueprint" \
  "${node[@]}" --wallet-address "$alice_addr" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "a preview accepted a signing key beside a public address (exit $status)"

run create-seed-not-owned client-refusal -- registry create --seed "$seed" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
[ ! -e "$reg/registry.json" ] || fail "a refused create saved a registry"

run create success -- registry create --seed "$seed" "${common[@]}" "${node[@]}" "${alice[@]}"
state="$(field create .pins.pinState)"
token="$(field create .token)"
active="$(field create .pins.pinActive)"
alicekey="$(field create .walletKeyHash)"
[ "$(field create .seed)" = "$seed" ] || fail "create booted from another seed"
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"]' \
  "$receipts/create.json" >/dev/null || fail "create did not publish the six references"
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

# A preview builds and measures what the insert would submit, for the public
# address alone, and leaves the registry directory byte-for-byte as it was.
tree_hash() { (cd "$reg" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1); }
preview_ok() {
  jq -e --arg s "$2" '
    .preview == true
    and .[$s].fee > 0
    and .[$s].fee != 2000000
    and (.[$s].purposes | length) == 1
    and .[$s].purposes[0].memory != 14000000
    and .[$s].collateral.total == ((.[$s].fee * 150 + 99) / 100 | floor)
    and .[$s].collateral.return != null
    and .[$s].collateral.exposure == .[$s].collateral.total
    and .outlay.total == (.outlay.fee + .outlay.lockedBond + .outlay.foldFeeBound)
    and .outlay.withinAllowance == true
  ' "$receipts/$1.json" >/dev/null || fail "$1: the preview does not state measured bodies"
}
tree_before="$(tree_hash)"
run insert-preview success -- registry insert --preview --key "$key" --envelope "$work/alice.json" \
  "${common[@]}" "${node[@]}" --wallet-address "$alice_addr"
preview_ok insert-preview booking
[ "$(tree_hash)" = "$tree_before" ] || fail "a preview changed the registry directory"
jq -e '.fold.feeBound > .booking.fee' "$receipts/insert-preview.json" >/dev/null \
  || fail "the fold bound does not exceed a booking fee"
status=0
"$singular" registry insert --preview --key "$key" --envelope "$work/alice.json" "${common[@]}" \
  "${node[@]}" --wallet-address "$alice_addr" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "an insert preview accepted a signing key (exit $status)"
refused insert-preview-not-controller client-refusal -- registry insert --preview --key 6b657942 \
  --envelope "$work/alice-by-bob.json" "${common[@]}" "${node[@]}" --wallet-address "$bob_addr"
# An allowance below the measured outlay stops the insert before it signs or
# sends anything.
refused insert-over-allowance client-refusal -- registry insert --key "$key" \
  --envelope "$work/alice.json" --max-outlay 1000000 "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.outlay.withinAllowance == false and .outlay.allowance == 1000000' \
  "$receipts/insert-over-allowance.json" >/dev/null || fail "the refusal does not state the outlay and the allowance"

run insert success -- registry insert --key "$key" --envelope "$work/alice.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
run inspect-1 success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-1 .leaf)" = active ] || fail "inspect after insert is not active"
[ "$(field inspect-1 .root)" = "$(field insert .root)" ] || fail "inspect root differs from insert"
jq -e --slurpfile e "$work/alice.json" '.applicationOutput.envelope == $e[0]' \
  "$receipts/inspect-1.json" >/dev/null || fail "the holding's envelope is not the one inserted"
# The index-read report is the indexer backend's own: the same inspect at
# the node backend reads the same leaf and reports no read the index
# answered.
if [ "$backend" = indexer ]; then
  status=0
  "$node_singular" registry inspect --key "$key" "${common[@]}" "${node[@]}" \
    >"$receipts/inspect-1-node.json" 2>"$receipts/inspect-1-node.err" || status=$?
  [ "$status" -eq 0 ] && [ "$(field inspect-1-node .leaf)" = active ] \
    || fail "inspect-1 at the node backend did not read the active leaf (exit $status)"
  ! served "$receipts/inspect-1-node.err" \
    || fail "a node-backend inspect reported reads the index answered"
  say "the node backend reads the same leaf and reports no index read"
fi

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
jq -n '{constructor:3, fields:[{bytes:"626f62"},{int:123456789012345678901234567890}]}' >"$work/payload.json"
refused update-not-controller client-refusal -- registry update --key "$key" \
  --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${bob[@]}"
tree_before="$(tree_hash)"
run update-preview success -- registry update --preview --key "$key" --payload "$work/payload.json" \
  "${common[@]}" "${node[@]}" --wallet-address "$alice_addr"
preview_ok update-preview update
[ "$(tree_hash)" = "$tree_before" ] || fail "an update preview changed the registry directory"
refused update-preview-not-controller client-refusal -- registry update --preview --key "$key" \
  --payload "$work/payload.json" "${common[@]}" "${node[@]}" --wallet-address "$bob_addr"
run update success -- registry update --key "$key" --payload "$work/payload.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
run inspect-2 success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-2 .leaf)" = active ] || fail "inspect after update is not active"
[ "$(field inspect-2 .root)" = "$(field bob-insert .root)" ] || fail "the update moved the root"
jq -e --slurpfile p "$work/payload.json" '.applicationOutput.payload == $p[0]' \
  "$receipts/inspect-2.json" >/dev/null || fail "the holding does not carry the new payload"

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
jq '.confApplication = "open.open"' "$work/registry.json.aside" >"$reg/registry.json"
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
# shellcheck disable=SC2016 # $$ and $1 belong to the holder's own shell
flock --fcntl "$reg/.lock" bash -c 'echo $$ > "$1/lock.pid"; touch "$1/lock.held"; exec sleep 120' _ "$work" &
holder=$!
for _ in $(seq 1 100); do
  [ -e "$work/lock.held" ] && break
  sleep 0.1
done
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
tree_before="$(tree_hash)"
run terminate-preview success -- registry terminate --preview --key "$key" \
  "${common[@]}" "${node[@]}" --wallet-address "$alice_addr"
preview_ok terminate-preview booking
[ "$(tree_hash)" = "$tree_before" ] || fail "a terminate preview changed the registry directory"
# The process is held by the marked harness point right after the node's
# acceptance of its fold is journalled, and killed there.
before="$(journal_lines "$reg")"
rm -f "$work/fold.go" "$work/fold.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/fold.go" SINGULAR_HARNESS_HOLD_STEP=fold \
  "$singular" registry terminate --key "$key" "${common[@]}" "${node[@]}" "${alice[@]}" \
  >"$receipts/terminate-killed.json" 2>&1 &
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
fold_tx="$(tail -n 1 "$reg/journal.jsonl" | jq -r .journalTxId)"
# The next ordinary write — bob's update of his own key — reconciles the
# killed fold from chain evidence and proceeds. While the fold is not yet
# on chain it is refused before submitting anything, naming the fold and
# its case; it is then run again.
for _ in $(seq 1 60); do
  before="$(journal_lines "$reg")"
  status=0
  "$singular" registry update --key "$bkey" --payload "$work/payload.json" \
    "${common[@]}" "${node[@]}" "${bob[@]}" \
    >"$receipts/write-after-kill.json" 2>"$receipts/write-after-kill.err" || status=$?
  got="$(jq -r .outcome "$receipts/write-after-kill.json")"
  [ "$got/$status" = success/0 ] && break
  [ "$got/$status" = partial/15 ] || fail "write-after-kill: outcome $got (exit $status)"
  [ "$(journal_lines "$reg")" = "$before" ] || fail "write-after-kill: a refused write moved the journal"
  [ "$(field write-after-kill .unresolved.tx)" = "$fold_tx" ] \
    || fail "write-after-kill: the refusal does not name the killed fold"
  [ "$(field write-after-kill .unresolved.case)" = acknowledged ] \
    || fail "write-after-kill: the refusal does not name the fold's case acknowledged"
  sleep 2
done
[ "$(field write-after-kill .outcome)" = success ] || fail "the write after the kill never reconciled the fold"
jq -e --arg t "$fold_tx" '.reconciled.observed | index($t)' "$receipts/write-after-kill.json" >/dev/null \
  || fail "the write after the kill did not observe the killed fold"
say "write-after-kill: success, reconciling the killed fold"
# Alice's key reads Terminal: the killed terminate's fold is on chain.
run inspect-3 success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-3 .leaf)" = terminal ] || fail "the killed fold did not leave the key terminal"
jq -e '.applicationOutput.absent' "$receipts/inspect-3.json" >/dev/null || fail "the holding is still live"
# The fold was applied to the mirror exactly once and observed exactly
# once, across every receipt, and never sent again.
jq -s -e --arg t "$fold_tx" '[.[0].reconciled.applied[], .[1].mirrorAdvanced[]] == [$t]' \
  "$receipts/write-after-kill.json" "$receipts/inspect-3.json" >/dev/null \
  || fail "the mirror was not advanced exactly once by the journalled fold"
[ "$(jq -s --arg t "$fold_tx" '[.[] | select(.journalTxId == $t and .journalEvent == "observed")] | length' "$reg/journal.jsonl")" = 1 ] \
  || fail "the killed fold was not observed exactly once"
[ "$(jq -s --arg t "$fold_tx" '[.[] | select(.journalTxId == $t and .journalEvent == "prepared")] | length' "$reg/journal.jsonl")" = 1 ] \
  || fail "the killed fold was prepared more than once"
say "the next write reconciled the killed fold from the chain once; inspect reads it terminal"

# ------------------------------------------------------------------
# 6. terminate bob normally; a write works again
# ------------------------------------------------------------------
run bob-terminate success -- registry terminate --key "$bkey" "${common[@]}" "${node[@]}" "${bob[@]}"
run inspect-4 success -- registry inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-4 .leaf)" = terminal ] || fail "bob's key is not terminal"

# Every write so far journalled, at prepared, the point of the view its
# body was built from: this network, an era, a slot and a block hash — a
# point no later than the one inspect-4 read afterwards.
read_slot="$(field inspect-4 .chainPoint | cut -d. -f1)"
prepared_points "$reg" | jq -e -s --argjson s "$read_slot" \
  'length > 0 and all(.slot <= $s)' >/dev/null \
  || fail "a write's journalled view point is missing or later than inspect-4's ($read_slot)"
say "every write journalled its build view's point, no later than slot $read_slot"

# ------------------------------------------------------------------
# 7. create races and interruptions, on their own targets
# ------------------------------------------------------------------
# Two creates race for one target: bob's, on his own live seed, is held
# after its pre-lock checks while alice's completes; under the lock it must
# re-check the target and refuse RegistryExists (demo1_cli_create_race.sh).
race="${DEMO1_CREATE_RACE:-$(dirname "$0")/demo1_cli_create_race.sh}"
status=0
bash "$race" "$singular" "$blueprint" "$sock" "$work/alice.skey" "$work/bob.skey" "$work/race" || status=$?
case "$status" in
  0) ;;
  3) setup_fail "the create race never reached its target check" ;;
  *) fail "the create race control does not hold (exit $status)" ;;
esac
say "create race: the late create was refused RegistryExists; the first registry stands"

# A create killed after its first accepted submission: a new create is
# refused, and inspect reads the incomplete create from its journal.
inter="$work/interrupted"
run preview-inter success -- registry create --preview --registry "$inter" \
  --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
seed_i="$(field preview-inter .seed)"
rm -f "$work/create.go" "$work/create.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/create.go" SINGULAR_HARNESS_HOLD_STEP=boot \
  "$singular" registry create --seed "$seed_i" --registry "$inter" --blueprint "$blueprint" \
  "${node[@]}" "${alice[@]}" >"$receipts/create-killed.json" 2>&1 &
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
  jq -e --arg t "$first_tx" '.observed | index($t)' "$receipts/inspect-interrupted.json" >/dev/null && break
  sleep 2
done
jq -e '.incompleteCreate.seed' "$receipts/inspect-interrupted.json" >/dev/null \
  || fail "inspect did not read the incomplete create's identity"
[ "$(field inspect-interrupted .leaf)" = null ] || fail "an incomplete create printed a leaf"
jq -e --arg t "$first_tx" 'select(.journalTxId == $t and .journalEvent == "observed")' \
  "$inter/journal.jsonl" >/dev/null || fail "the killed create's accepted submission was never observed"
say "an interrupted create is refused a second boot and read back from its journal"

# ------------------------------------------------------------------
# 8. the node lost after an accepted submission (last: the node dies)
# ------------------------------------------------------------------
jq -n '{int: 42}' >"$work/payload-2.json"
before="$(journal_lines "$reg")"
rm -f "$work/update.go" "$work/update.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/update.go" SINGULAR_HARNESS_HOLD_STEP=update \
  "$singular" registry update --key 6b657943 --payload "$work/payload-2.json" --confirm-timeout 30 \
  "${common[@]}" "${node[@]}" "${alice[@]}" >"$receipts/update-node-lost.json" 2>"$receipts/update-node-lost.err" &
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
for _ in $(seq 1 100); do
  [ -S "$sock" ] || break
  pgrep -f "cardano-node run --config $work/" >/dev/null || break
  sleep 0.1
done
released_at=$(date +%s)
touch "$work/update.go"
status=0
wait "$victim" || status=$?
waited=$(($(date +%s) - released_at))
# The bound holds with the node gone: the command ends within its
# --confirm-timeout (plus teardown), attributing the submitted update —
# partial when the wait fails, timeout when it outlives the bound.
[ "$waited" -le 90 ] || fail "node lost after submit: the command waited ${waited}s past a 30s bound"
outcome="$(jq -r .outcome "$receipts/update-node-lost.json")"
case "$outcome/$status" in
  partial/15 | timeout/13) ;;
  *) fail "node lost after submit: outcome $outcome (exit $status), expected partial or timeout" ;;
esac
jq -e --arg t "$lost_tx" '.reason | contains($t)' "$receipts/update-node-lost.json" >/dev/null \
  || fail "the partial receipt does not name the submitted transaction"
[ "$(tail -n 1 "$reg/journal.jsonl" | jq -r .journalEvent)" = unconfirmed ] \
  || fail "the journal does not keep the submitted update unresolved"
say "node lost after an accepted submission: $outcome after ${waited}s, naming $lost_tx, journal unresolved"

jq -r '.journalEvent' "$reg/journal.jsonl" | sort | uniq -c

# Every journal the journey's writes left, wherever they wrote: each
# prepared line names its view point.
mapfile -t journals < <(find "$work" -name journal.jsonl | sort)
[ "${#journals[@]}" -ge 2 ] || fail "found ${#journals[@]} journals; the extent is not the journey's"
written=0
for j in "${journals[@]}"; do
  n="$(prepared_points "$(dirname "$j")" | wc -l)"
  written=$((written + n))
done
[ "$written" -gt 0 ] || fail "no prepared line in ${#journals[@]} journals"
say "$written prepared submissions in ${#journals[@]} journals each name their view point"
say "JOURNEY-OK (${backend:-node} backend)"

# Without a named backend the same journey runs again under the indexer
# backend, on its own development node; this pass's node is gone.
if [ -z "$backend" ]; then
  trap - EXIT
  exec bash "$0" "$node_singular" "$devnet" "$blueprint" "$work-indexer" indexer
fi
