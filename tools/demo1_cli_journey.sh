#!/usr/bin/env bash
# Alice's open-datum story through the packaged `singular` and `open-datum`
# commands (#299), through the sole Koios provider. The node/indexer
# comparison is retired with the node backend (A023); every registry and
# recovery control remains in the explicitly selected test-build carrier.
#
# usage: demo1_cli_journey.sh SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR [ordinary|test-harness]
#
# SINGULAR, OPEN_DATUM and DEVNET are executables; BLUEPRINT is the registry
# partition's plutus.json. ONE development node is started once, funding
# two generated wallets (alice, bob), and every registry command is a
# separate process against it:
#
#   create -> insert -> fold -> inspect -> update -> inspect
#          -> terminate -> fold -> inspect -> reject -> insert -> fold
#          -> reclaim -> insert -> fold
#
# An insert or a terminate books and leaves its request pending; `open-datum
# fold` folds it, signed by a wallet other than the booking's. The combined
# `--fold` form is run where a control needs the fold to follow its own
# booking in one process. The journey also books a request and lets its
# processing deadline pass: the late fold is refused by the client, by name,
# before anything is signed. That request is then rejected once its retract
# window has closed, refused by name while it is still open, and a new request
# is folded afterwards. Another pending insertion is reclaimed by its owner
# inside its retract window: its whole return is bound to the consumed request
# and checked against independent reads before and after. Early attempts and
# another wallet are refused; after reclaim a new request folds.
#
# Each process leaves one JSON receipt. Assertions read those receipts,
# the target directory's own journal and files, and nothing else. A
# refusal control names the outcome class it expects and requires the
# target's journal to be exactly as it was: nothing submitted. Setup
# failures (no node, no socket) are reported as setup, never as a result.
#
# The genesis-only wallet remains an explicit coverage refusal control.
#
# The sections up to 7e and section 8 are harness controls of the key-file path:
# their wallets hold key files so that a writer which signs and sends can be
# watched, killed and recovered. The guide's flow is section 7f: Alice and Bob,
# with wallets made by `singular wallet create`, run the run page's sixteen
# steps on a registry of their own, each write staged in a bundle (exit 19),
# signed with `singular wallet sign --vault` and sent with `singular submit`.
set -euo pipefail

[ "$#" -ge 5 ] && [ "$#" -le 6 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR [ordinary|test-harness]" >&2
  exit 2
}
singular="$1"
open_datum="$2"
devnet="$3"
blueprint="$4"
work="$5"
mode="${6:-ordinary}"
case "$mode" in
  ordinary | test-harness) ;;
  *)
    echo "journey: unknown build mode $mode" >&2
    exit 2
    ;;
esac
rm -rf "$work"
mkdir -p "$work"
receipts="$work/receipts"
mkdir -p "$receipts"
# These launcher identities accompany the receipts. The release verifier
# separately binds the compiled ordinary bytes and actual component flags.
jq -n --arg mode "$mode" --arg singular "$singular" --arg openDatum "$open_datum" \
  --arg singularSha256 "$(sha256sum "$singular" | cut -d' ' -f1)" \
  --arg openDatumSha256 "$(sha256sum "$open_datum" | cut -d' ' -f1)" \
  '{mode:$mode, singular:$singular, openDatum:$openDatum,
    singularSha256:$singularSha256, openDatumSha256:$openDatumSha256}' >"$work/build-identity.json"
reg="$work/registry"
# shellcheck source=tools/managed_state.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/managed_state.sh"
: >"$work/trie-command-invocations"
: >"$work/trace-command-invocations"

fail() {
  echo "journey: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "journey: SETUP: $*" >&2
  exit 3
}
say() { echo "journey: $*"; }

# Stop the node before touching the tree. The caller still reads receipts
# and harness markers in $work, so the directory stays; the node chain is
# what fills the disk. DEMO1_KEEP_SCRATCH=1 keeps the chain and names $work.
# shellcheck disable=SC2329 # the EXIT traps below invoke this
release_work() {
  local code=$?
  local _wait
  trap - EXIT
  # A controller may fail before reaching its marker: retain its diagnostics
  # and stop/join only the process this journey still owns.
  if [ -n "${victim:-}" ]; then
    kill -9 "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    victim=""
  fi
  if [ -n "${holder:-}" ]; then
    kill -9 "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    holder=""
  fi
  [ -n "${bare_pid:-}" ] && kill "$bare_pid" 2>/dev/null || true
  [ -n "${devnet_pid:-}" ] && kill "$devnet_pid" 2>/dev/null || true
  if [ -n "${work:-}" ]; then
    if command -v pkill >/dev/null 2>&1; then
      pkill -f "cardano-node run --config $work/" >/dev/null 2>&1 || true
    fi
    for _wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
      if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -f "cardano-node run --config $work/" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
      echo "kept scratch: $work" >&2
    else
      chmod -R u+rwx "$work" 2>/dev/null || true
      rm -rf "$work/cardano-e2e" || true
      if [ -e "$work/cardano-e2e" ]; then
        echo "scratch remains: $work/cardano-e2e" >&2
        code=1
      fi
    fi
  fi
  exit "$code"
}

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/alice.skey"
hexkey >"$work/bob.skey"
hexkey >"$work/carol.skey" # never funded
hexkey >"$work/dave.skey"  # funded small, for the underfunded create
hexkey >"$work/erin.skey"  # fragmented outputs below the largest remaining need, total covers the run
hexkey >"$work/frank.skey" # same size, one output short of the whole run
hexkey >"$work/grace.skey" # one 200 tADA output, state carrier reused after Alice

# The key-file wallets above are the harness's: the controls that watch the
# key-file path itself (the writer's journal phases, a process held and killed
# after its submission, lock holders, races, key relocation) need a writer that
# signs and sends. The story's Alice and Bob (section 7f) make their wallets
# with `singular wallet create`, each in a directory of their own that stands
# for their own machine, name their passphrase through an inherited descriptor,
# and are funded by the address `singular wallet address` prints: no key file
# of theirs exists.
story="$work/story"
mkdir -p "$story/alice" "$story/bob" "$story/bundles"
alice_pass="alice's demo passphrase"
bob_pass="bob's demo passphrase"
for who in alice bob; do
  pass_var="${who}_pass"
  "$singular" wallet create --vault "$story/$who/$who.vault" --network-magic 42 --passphrase-fd 3 \
    3<<<"${!pass_var}" >"$story/$who/create.out" 2>"$story/$who/create.err" \
    || setup_fail "singular wallet create failed for $who: $(tail -n 3 "$story/$who/create.err" | tr '\n' ' ')"
done
vault_alice_addr="$("$singular" wallet address --vault "$story/alice/alice.vault" --network-magic 42 --passphrase-fd 3 3<<<"$alice_pass")"
vault_bob_addr="$("$singular" wallet address --vault "$story/bob/bob.vault" --network-magic 42 --passphrase-fd 3 3<<<"$bob_pass")"
case "$vault_alice_addr$vault_bob_addr" in
  addr_test1*addr_test1*) ;;
  *) setup_fail "singular wallet address printed no test-network addresses: $vault_alice_addr $vault_bob_addr" ;;
esac
[ "$vault_alice_addr" != "$vault_bob_addr" ] || setup_fail "Alice and Bob made the same wallet"

export TMPDIR="$work"

# ------------------------------------------------------------------
# 0. coverage: a genesis-only wallet is refused on the Koios path
# ------------------------------------------------------------------
say "harness control of the key-file path: the sections up to the story (7f) run wallets that hold key files, to watch what a writer that signs and sends leaves behind; they are not the guide's flow"
# These actual initial allocations have no transaction carried by a full
# block. The private actor leaves them untouched for this control; the
# node/genesis/epoch/slot/time parameters are the normal fixture's.
"$devnet" --genesis-only --evidence-dir "$work/genesis-source" >"$work/bare.out" 2>"$work/bare.err" &
bare_pid=$!
trap release_work EXIT
bare_provider=""
bare_time=""
bare_magic=""
for _ in $(seq 1 900); do
  settings="$(head -n1 "$work/bare.out" 2>/dev/null || true)"
  bare_provider="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
  bare_time="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
  bare_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
  [ -n "$bare_provider" ] && [ "$bare_magic" = 42 ] && [ -r "$bare_time/time-manifest.json" ] && break
  kill -0 "$bare_pid" 2>/dev/null || break
  sleep 1
done
[ -n "$bare_provider" ] && [ "$bare_magic" = 42 ] && [ -r "$bare_time/time-manifest.json" ] \
  || setup_fail "the genesis-only source never printed usable provider/time settings"
printf '%s' e2e-genesis-utxo-key-seed-000001 | od -An -tx1 | tr -d ' \n' >"$work/genesis.skey"
status=0
"$open_datum" create --process-time 120000 --retract-time 30000 --preview --state-dir "$work/genesis-indexer" --blueprint "$blueprint" \
  --koios-url "$bare_provider" --network-time "$bare_time" --network-magic "$bare_magic" \
  --wallet-skey "$work/genesis.skey" >"$receipts/genesis-indexer.json" 2>"$receipts/genesis-indexer.err" || status=$?
[ "$(jq -r .outcome "$receipts/genesis-indexer.json")" = node-unavailable ] && [ "$status" -eq 12 ] \
  || fail "the genesis-only wallet: outcome $(jq -r .outcome "$receipts/genesis-indexer.json") (exit $status), expected node-unavailable/12"
jq -e '.reason | contains("(coverage-incomplete)") and contains("genesis")' \
  "$receipts/genesis-indexer.json" >/dev/null \
  || fail "the genesis-only wallet was not refused by the named coverage diagnostic"
jq -s -e --slurpfile receipt "$receipts/genesis-indexer.json" '
  [.[] | select(.kind == "http-ledger-exchange") | .source.unindexedGenesisReferences? // [] | .[]] | unique
  | length > 0 and all(. as $ref | $receipt[0].reason | contains($ref))' \
  "$work/genesis-source/independent-facade-sources.jsonl" >/dev/null \
  || fail "the coverage diagnostic does not name the actual queried genesis allocation"
[ ! -e "$work/genesis-indexer" ] || fail "the refused preview created its target"
kill "$bare_pid" 2>/dev/null || true
pkill -f "cardano-node run --config $work/" 2>/dev/null || true
for _ in $(seq 1 300); do
  pgrep -f "cardano-node run --config $work/" >/dev/null || break
  sleep 0.1
done
wait "$bare_pid" 2>/dev/null || true
say "a genesis-only wallet: coverage-incomplete/12, nothing written"

# ------------------------------------------------------------------
# One persistent development node
# ------------------------------------------------------------------
"$devnet" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" \
  --fund-outputs 6 --fund-lovelace 2000000000 \
  --fund "$work/dave.skey:1:5000000" --fund "$work/dave.skey:24:4000000" \
  --fund "$work/erin.skey:5:30000000" --fund "$work/frank.skey:4:30000000" \
  --fund "$work/grace.skey:1:200000000" \
  --fund-address "$vault_alice_addr:6:2000000000" --fund-address "$vault_bob_addr:6:2000000000" \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
# The per-wallet funding group is parsed before any node starts: a
# malformed one is refused by name, so no second node appears for it.
bad_fund="$work/bad-fund.out"
bad_status=0
"$devnet" --fund "$work/dave.skey:two:4000000" >"$bad_fund" 2>&1 || bad_status=$?
[ "$bad_status" -ne 0 ] || fail "the devnet accepted a malformed funding group"
grep -q '^devnet: --fund expects FILE:N:LOVELACE' "$bad_fund" \
  || fail "the malformed funding group was not refused by name: $(head -n 1 "$bad_fund")"
say "the devnet refuses a malformed per-wallet funding group by name"
# A wallet made elsewhere is funded from its public address alone
# (--fund-address ADDRESS:N:LOVELACE); the same parse-first rule holds: a
# group that is not three parts, a spelling that is no address and an address
# of the main network are each refused by name before any node starts.
# Bounded: a harness that took one would start a node and wait for ever.
refuses_fund_address() {
  local group="$1" expected="$2" out="$work/bad-fund-address.out" code=0
  timeout 60 "$devnet" --fund-address "$group" >"$out" 2>&1 || code=$?
  [ "$code" -ne 0 ] && [ "$code" -ne 124 ] \
    || fail "the devnet did not refuse the funding group $group (exit $code)"
  grep -q "^devnet: --fund-address $expected" "$out" \
    || fail "the funding group $group was not refused by name: $(head -n 1 "$out")"
}
refuses_fund_address 'addr_test1vq6aahffs2sreuu70h8q8jpen98lmmpwc6cy788j6s8xrgc64xuck:two:4000000' 'expects ADDRESS:N:LOVELACE'
refuses_fund_address 'not-an-address:1:4000000' '"not-an-address" is not a bech32 address'
refuses_fund_address 'addr1vy6aahffs2sreuu70h8q8jpen98lmmpwc6cy788j6s8xrgcpajqhn:1:4000000' '"addr1vy6aahffs2sreuu70h8q8jpen98lmmpwc6cy788j6s8xrgcpajqhn" is a mainnet address'
say "the devnet refuses a malformed funding address by name"
# The node is the devnet runner's child: reap both, so no node of this
# run outlives it holding the development network's ports.
trap release_work EXIT
sock=""
provider_url=""
time_directory=""
network_magic=""
for _ in $(seq 1 900); do
  settings="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  sock="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
  provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
  time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
  network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
  [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_directory/time-manifest.json" ] && break
  kill -0 "$devnet_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -S "$sock" ] || [ ! -r "$time_directory/time-manifest.json" ]; then
  tail -40 "$work/devnet.err" >&2 || true
  setup_fail "the private devnet never printed usable provider/time and independent probe settings"
fi
say "one private development source at $provider_url"

node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
common=(--state-dir "$reg" --blueprint "$blueprint")
alice=(--wallet-skey "$work/alice.skey")
bob=(--wallet-skey "$work/bob.skey")

exit_of() {
  case "$1" in
    success) echo 0 ;; client-refusal) echo 10 ;; ledger-refusal) echo 11 ;;
    node-unavailable) echo 12 ;; timeout) echo 13 ;; stale-state) echo 14 ;;
    partial) echo 15 ;; concurrent-writer) echo 16 ;; proof-missing) echo 17 ;;
    proof-inconsistent) echo 18 ;; waiting-for-signatures) echo 19 ;;
    *) fail "no exit status for class $1" ;;
  esac
}
# trace_disagreements RECEIPT TRACE [KEY]: every way the command's typed
# events, as the JSON lines its file sink wrote, contradict its receipt; empty
# when every event that carries a receipt-bound fact agrees with it. The same
# rules as the in-process comparison (offchain/test/Singular/CLI/CommandRunSpec.hs):
# one end naming the receipt's command and outcome, last; every key an event
# or its scope carries is one of the receipt's settled keys, or KEY (base16, the key the
# command line named) when the receipt names none; every request is one the
# receipt names (a booking names its output 0), with that request's key, edge
# and deadline; every edge action is one the command performs, on an edge it
# books or one its receipt names; a key's leaf and holding, the registry's pending
# count and root, the outputs, amounts, root and token are the receipt's;
# every transaction event is one of the receipt's submissions, or the read-back
# of a reference the command found already published, each submission signed
# and submitted, observed exactly when the receipt says so, with verdicts
# matching the case the journal records; a refusal's kind fits the outcome,
# and a refusal receipt's stream reports exactly one refusal (any other at
# most one).
trace_disagreements() {
  local receipt="$1" trace="$2" key="${3:-}"
  jq -s -c --slurpfile r "$receipt" --arg invoked "$key" '
    # A staged run (outcome waiting-for-signatures) states its own facts under
    # expected, because nothing has landed: the narration is compared with that
    # statement, and its transactions are the bundle'"'"'s, staged and never sent.
    $r[0] as $r0
    | ($r0 | if .outcome == "waiting-for-signatures" then . + .expected else . end) as $r
    | [$r0.bundle.transactions[]? | {step, tx: .identity}] as $staged
    | . as $ev
    | ([$r | if .command == "fold" then (.settled // [])[].key else .key end] | map(select(. != null))) as $rk
    | ((if ($rk | length) > 0 then $rk elif $invoked == "" then [] else [$invoked] end)) as $receiptKeys
    | ([$r | if .command == "fold" then (.settled // [])[].edge else .edge end] | map(select(. != null))) as $receiptEdges
    | ([$r | .. | objects | select(has("request"))
        | {request, key, edge, deadline: (.foldDeadline.posixMs // .processingEnds // .deadline.posixMs)}]
       + [$r | .. | objects | select(has("pendingRequest")) | {request: .pendingRequest}]
       + [$r | select(.booking != null) | {request: (((.booking | if type == "object" then .txId else . end) // "") + "#0"), key}]) as $facts
    | (($facts | length == 0) and ($r.outcome != "success")) as $bare_refusal
    | [$r.submissions[]? | {step, tx, case, observed}] as $subs
    | (if ($staged | length) > 0 then [] else
       [$r.references[]? | {step: ("publish-" + .role), tx: (.output | split("#")[0])}
        | select(.tx as $t | $subs | map(.tx) | index($t) | not)] end) as $reused
    | (first($ev[] | select(.event == "root") | .before) // $r.root) as $before
    | def keys_of: (if .event == "key" or .event == "folded" or .event == "updated" then .key else empty end),
        (.scope[]? | .key? // empty);
      def requests_of: (if .event == "request" or .event == "booked" or .event == "reclaimed" then .request else empty end),
        (if .event == "rejected" then .requests[] else empty end),
        (.scope[]? | .request? // empty);
      def edges_of: (if .event == "edge-started" then {edge, on} else empty end),
        (.scope[]? | select(has("edge")) | {edge, on}),
        (if .event == "folded" then {edge: "fold", on: .edge} else empty end);
      def in_role($c; $res):
        ($c == "create" and .edge == "boot")
        or ($c == "insert" and (.edge | IN("book", "fold")) and .on == "insertActive")
        or ($c == "terminate" and (.edge | IN("book", "fold")) and .on == "updateTerminal")
        or ($c == "update" and .edge == "update")
        or ($c == "fold" and .edge == "fold" and ((.on | IN($res[])) or ($res | length) == 0))
        or ($c == "reject" and .edge == "reject")
        or ($c == "reclaim" and .edge == "reclaim" and ((.on | IN($res[])) or ($res | length) == 0));
      def fits($v; $c):
        if $v == "accepted" then ($c | IN("acknowledged", "timeout", "included", "rolled-back", "excluded"))
        elif $v == "ledger-refused" or $v == "wrong-network" then $c == "rejected"
        elif $v == "provider-failed" or $v == "threw" then $c == "unknown"
        elif $v == "confirmed" then ($c | IN("included", "rolled-back", "excluded"))
        else $c == "timeout" end;
      def refusal_fits($k; $o):
        if $k == "ledger" then $o == "ledger-refusal"
        elif $k == "transport" then ($o | IN("partial", "node-unavailable", "timeout"))
        elif $k == "evaluation" then ($o | IN("client-refusal", "partial"))
        else ($o | IN("client-refusal", "partial", "concurrent-writer", "stale-state")) end;
      [ (map(select(.event == "command-ended")) as $ends
         | if ($ends | length) == 1 and ($ends[0].command == $r.command) and ($ends[0].outcome == $r.outcome)
              and ($ev | last | .event) == "command-ended"
           then empty else "the stream does not end once with the command and outcome of the receipt" end),
        ($ev[] | keys_of | select(. as $k | $receiptKeys | index($k) | not) | "key \(.)"),
        ($ev[] | requests_of | select(. as $q | $facts | map(.request) | index($q) | not) | select($bare_refusal | not) | "request \(.) not named by the receipt"),
        ($ev[] | select(.event == "request") as $e
         | $facts[] | select(.request == $e.request)
         | (select(.key != null and .key != $e.key) | "request \($e.request) key \($e.key)"),
           (select(.edge != null and .edge != $e.edge) | "request \($e.request) edge \($e.edge)"),
           (select(.deadline != null and $e.deadlineMs != null and .deadline != $e.deadlineMs)
            | "request \($e.request) deadline \($e.deadlineMs)")),
        ($ev[] | select(.event == "booked" and .deadlineMs != null) as $e
         | $facts[] | select(.request == $e.request and .deadline != null and .deadline != $e.deadlineMs)
         | "booked \($e.request) deadline \($e.deadlineMs)"),
        ($ev[] | edges_of | select(in_role($r.command; $receiptEdges) | not) | "edge \(.) outside the command role"),
        ($ev[] | select(.event == "key" and $r.leaf != null and .leaf != $r.leaf) | "leaf \(.leaf)"),
        ($ev[] | select(.event == "key" and $r.applicationOutput != null and .holding != $r.applicationOutput.output)
         | "holding \(.holding)"),
        ($ev[] | select(.event == "registry" and .pending != null and $r.pendingRequests != null
                        and .pending != ($r.pendingRequests | length)) | "pending \(.pending)"),
        ($ev[] | select(.event == "registry" and $before != null and .root != $before) | "registry root \(.root)"),
        ($ev[] | select(.tx != null) | . as $e | {step, tx} as $t
         | select(($subs | map({step, tx}) | index($t) | not) and ($staged | index($t) | not))
         | select(($e.event == "tx-observed" and ($reused | index($t))) | not)
         | "transaction \($t) not among the submissions of the receipt"),
        ($staged[] as $t
         | select(([$ev[] | select(.event == "tx-staged" and .step == $t.step and .tx == $t.tx)] | length) != 1)
         | "staged transaction \($t) has not exactly one staged event"),
        (if ($staged | length) > 0 then
           (if ([$ev[] | select(.event == "tx-built")] | length) != ($staged | length)
            then "built events against \($staged | length) staged transactions" else empty end),
           ($ev[] | select(.event | IN("tx-signed", "tx-submitted", "tx-confirmed", "tx-observed"))
            | "a staged run narrates \(.event)")
         else empty end),
        ($reused[] as $t
         | select(([$ev[] | select(.event == "tx-observed" and .step == $t.step and .tx == $t.tx)] | length) != 1)
         | "reference \($t) not read back once"),
        ($subs[] as $s
         | (select(([$ev[] | select(.event == "tx-signed" and .step == $s.step and .tx == $s.tx)] | length) == 0
              or ([$ev[] | select(.event == "tx-submitted" and .step == $s.step and .tx == $s.tx)] | length) == 0)
            | "submission \($s.tx) has no signing and submission event"),
           (select(($s.observed == true) != ([$ev[] | select(.event == "tx-observed" and .step == $s.step and .tx == $s.tx)] | length > 0))
            | "submission \($s.tx) observed \($s.observed) against its events"),
           ($ev[] | select((.event == "tx-submitted" or .event == "tx-confirmed") and .tx == $s.tx)
            | select(fits(.verdict; $s.case) | not) | "submission \($s.tx) met \($s.case) but its events say \(.verdict)")),
        ($ev[] | select(.event == "root") | select(.after != $r.root) | "root \(.after)"),
        ($ev[] | select(.event == "created") | select(.token != $r.token) | "token \(.token)"),
        ($ev[] | select(.event == "created") | select((.state | split("#")[0]) != $r.boot) | "created state \(.state)"),
        ($ev[] | select(.event == "rejected") | select((.requests | sort) != ([$r.rejected[]?.request] | sort))
         | "rejected \(.requests)"),
        ($ev[] | select(.event == "reclaimed") | select(.returned != $r.returned.lovelace) | "reclaimed \(.returned)"),
        ($ev[] | select(.event == "updated") | select(.output != $r.liveOutput) | "updated output \(.output)"),
        ($ev[] | select(.event == "folded")
         | select(.output as $o
            | ([$r.settled[]? | .settlement.liveOutput // .settlement.released] | index($o) | not))
         | "folded output \(.output)"),
        ($ev[] | select(.event == "refused") | select(refusal_fits(.kind; $r.outcome) | not)
         | "refusal \(.kind) under outcome \($r.outcome)"),
        (([$ev[] | select(.event == "refused")] | length) as $n
        | if ($r.outcome | IN("client-refusal", "ledger-refusal")) then
            (if $n != 1 then "refusal events \($n) under outcome \($r.outcome)" else empty end)
          elif $n > 1 then "refusal events \($n) under outcome \($r.outcome)" else empty end),
        (if $r.outcome == "ledger-refusal" and ([$ev[] | select(.event == "refused" and .kind == "ledger")] | length) == 0
         then "ledger refusal with no ledger rejection event" else empty end)
      ]' "$trace"
}
# trace_agrees RECEIPT TRACE [KEY]: every line is one JSON object and the
# stream has no disagreement with the receipt.
trace_agrees() {
  local receipt="$1" trace="$2" key="${3:-}"
  [ -s "$trace" ] || return 1
  jq -R -e 'fromjson | type == "object"' "$trace" >/dev/null || return 1
  [ "$(trace_disagreements "$receipt" "$trace" "$key")" = "[]" ]
}
# run NAME CLASS -- ARGS: one registry process; its receipt must name CLASS
# and its exit status must be that class's. ARGS starting with `registry`
# (reject, reclaim) run through `singular registry`; a bare verb
# (create, insert, update, terminate, fold, inspect) runs through
# `open-datum`. Each process uses the Koios path
# and narrates how on stderr, its typed events also written as JSON lines to
# a file; standard output carries the receipt alone.
run() {
  local name="$1" class="$2"
  shift 3
  local status=0
  local bin="$open_datum"
  [ "${1:-}" = registry ] && bin="$singular"
  local trace="$receipts/$name.trace.jsonl"
  local narrated=(--trace how --trace-to stderr --trace-to "file:$trace")
  local SINGULAR_LOG="$receipts/$name.phases.jsonl"
  export SINGULAR_LOG
  : >"$receipts/$name.trie.jsonl"
  if [ "$mode" = ordinary ] || [[ " $* " == *" --preview "* ]]; then
    # Keep the release's existing all-harness-variables-unset preview controls.
    env -u SINGULAR_HARNESS_TRIE_TRACE "$bin" "$@" "${narrated[@]}" \
      >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  else
    SINGULAR_LOG="$receipts/$name.phases.jsonl" SINGULAR_HARNESS_TRIE_TRACE="$receipts/$name.trie.jsonl" \
      "$bin" "$@" "${narrated[@]}" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  fi
  printf '%s\n' "$name" >>"$work/trie-command-invocations"
  local got
  got="$(jq -r '.outcome' "$receipts/$name.json" 2>/dev/null || echo none)"
  if [ "$got" != "$class" ] || [ "$status" -ne "$(exit_of "$class")" ]; then
    cat "$receipts/$name.json" >&2 || true
    tail -20 "$receipts/$name.err" >&2 || true
    fail "$name: outcome $got (exit $status), expected $class"
  fi
  jq -s -e 'length == 1' "$receipts/$name.json" >/dev/null \
    || fail "$name: standard output holds more than the receipt"
  [ -s "$receipts/$name.err" ] || fail "$name: --trace how --trace-to stderr narrated nothing"
  local key="" prev=""
  for a in "$@"; do
    [ "$prev" = --key ] && key="$(printf %s "$a" | od -An -tx1 | tr -d " \n")"
    prev="$a"
  done
  trace_agrees "$receipts/$name.json" "$trace" "$key" || {
    trace_disagreements "$receipts/$name.json" "$trace" "$key" >&2 || true
    fail "$name: the typed events of its narration disagree with its receipt"
  }
  printf '%s\n' "$name" >>"$work/trace-command-invocations"
  if [ "$class" = success ] && jq -e 'any(.submissions[]?; .step == "fold")' "$receipts/$name.json" >/dev/null; then
    [ -s "$receipts/$name.phases.jsonl" ] || setup_fail "$name: the fold produced no phase log"
    local build_ms
    build_ms="$(jq -s '[.[] | select(.phase == "build" and .step == "fold") | .duration_ms] | max // empty' "$receipts/$name.phases.jsonl")"
    [ -n "$build_ms" ] || setup_fail "$name: the fold phase log has no build duration"
    jq -n -e --argjson build "$build_ms" --argjson window "$(field create .processTime)" \
      '$build * 3 < $window - 30000' >/dev/null \
      || fail "$name: the processing window leaves less than three times the measured fold build beyond the CLI margin"
    say "$name: fold build ${build_ms} ms, processing window $(field create .processTime) ms"
  fi
  say "$name: $class"
}
journal_lines() { journal_lines_root "$1"; }
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

# A successful stored-registry command has actually selected a trie. An
# inspect's public leaf must be the leaf proven at its printed root/key,
# and a committed fold's root the root the capability accepted. The file
# is created by this harness before the process starts: presence is not
# evidence; these assertions require content from executed operations.
trie_bound() {
  local receipt="$1" trace="$2"
  jq -s -e --slurpfile r "$receipt" '
    $r[0] as $r
    | [.[] | select(.operation == "select" or .operation == "create")]
      as $selected
    | ($selected | length > 0)
      and ($selected | all(
        (.identity.policy | test("^[0-9a-f]{56}$"))
        and (.identity.name | test("^[0-9a-f]+$"))
        and (.output | test("^[0-9a-f]{64}#[0-9]+$"))
        and (.root | test("^[0-9a-f]{64}$"))))
      and (if $r.command == "inspect" then
        any(.[]; .operation == "leafAt" and .key == $r.key
          and .root == $r.root and .leaf == $r.leaf)
      elif $r.fold? != null then
        any(.[]; .operation == "select" and .root == $r.root
          and .output == ($r.fold + "#0"))
        and any(.[]; .operation == "speculateEdges" and .rootAfter == $r.root
          and .proofCount > 0 and (.proofs | type == "string"))
      elif $r.root? != null then any($selected[]; .root == $r.root)
      else true end)' "$trace" >/dev/null
}

trie_extent() {
  local file command name
  : >"$work/trie-command-extent.jsonl"
  while IFS= read -r name; do
    file="$receipts/$name.json"
    if jq -e '.outcome == "success" and .preview != true' "$file" >/dev/null; then
      command="$(jq -r .command "$file")"
      case "$command" in
        insert | update | terminate | fold | reject | reclaim | inspect)
          trie_bound "$file" "${file%.json}.trie.jsonl" \
            || fail "$(basename "$file"): actual command lacks trie evidence bound to its receipt"
          jq -c --slurpfile trace "${file%.json}.trie.jsonl" \
            '{command, key, root, operations: ($trace | map(.operation)), executions: ($trace | length)}' \
            "$file" >>"$work/trie-command-extent.jsonl"
          ;;
      esac
    fi
  done <"$work/trie-command-invocations"
  jq -s -e 'length > 1 and all(.executions > 0)
      and (map(.command) | unique == ["fold","insert","inspect","reclaim","reject","terminate","update"])' \
    "$work/trie-command-extent.jsonl" >/dev/null \
    || fail "the executed trie command extent is empty or omits a stored-registry command"
}
# local_files: what a booking must leave alone in the actor's directory —
# no identity file and no retired trie files are ever written there.
local_files() {
  [ -z "$(managed_find "$reg" registry.mirror.json)" ] && [ -z "$(managed_find "$reg" state.json)" ] \
    || fail "a command created retired trie files"
  [ -z "$(managed_find "$reg" registry.json)" ] \
    || fail "a command wrote a registry.json"
  echo "no identity file"
}
# booked NAME: a booking-only receipt names its pending request (the
# booking's own output 0), the requester, and the deadline by which it must be
# folded, as a POSIX time and, when the node converts it, a slot; it states no fold and no root.
booked() {
  jq -e '(.request | test("^[0-9a-f]{64}#0$")) and .request == (.booking + "#0")
      and (.requester | test("^[0-9a-f]{56}$"))
      and (.foldDeadline.posixMs | type == "number")
      and ((.foldDeadline.slot | type == "number") or (.foldDeadline.slot == null and .foldDeadline.slotUnavailable == "beyond the node\u0027s conversion horizon"))
      and (has("fold") | not) and (has("root") | not)' "$receipts/$1.json" >/dev/null \
    || fail "$1: the booking's receipt does not name its pending request, requester and fold deadline, or it claims a fold"
}
# booking_only NAME JOURNAL BEFORE FILES: since journal line BEFORE the command
# left exactly the booking's four phases and the mirror and state it started with.
booking_only() {
  local name="$1" journal="$2" before="$3" files="$4"
  [ "$(local_files)" = "$files" ] || fail "$name: a booking altered identity or created retired trie files"
  [ "$((($(journal_count "$journal")) - before))" -eq 4 ] \
    || fail "$name: the booking left $((($(journal_count "$journal")) - before)) journal lines, expected its four phases"
  tail -n +"$((before + 1))" "$journal" \
    | jq -s -e '(map(.journalEvent) == ["prepared", "submitted", "confirmed", "observed"]) and (map(.journalStep) | unique == ["book"]) and (map(.journalTxId) | unique | length == 1)' >/dev/null \
    || fail "$name: the journal lines the booking left are not one booking's prepared, submitted, confirmed and observed"
}
# journal_count FILE: lines in a journal that may not exist yet.
journal_count() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }
# The body is built in one actual acquisition. Latest Koios reads are
# Unbound; a latest observed tip is separate from snapshot binding.
prepared_scopes() {
  jq -c 'select(.journalEvent == "prepared")
      | . as $j | .journalSession as $s
      | if (.journalNetwork == 42) and (.journalEra | type == "string" and length > 0)
          and (.journalChainPoint == null)
          and ($s.session | type == "string" and length > 0)
          and ($s.networkMagic == 42) and ($s.binding == {kind:"Unbound"})
          and ($s.facts | type == "array" and length > 0)
          and ($s.facts | all(.session == $s.session and .networkMagic == 42
            and .binding == $s.binding and .verdict == "Unverified"
            and .reason == "NoVerifierConfigured" and .witnessPresent == false))
          and ($s.rawSources | type == "array" and length > 0)
          and ($s.rawSources | all(.session == $s.session))
          and ([$s.rawSources[] | select(.kind == "acquire")] | length == 1)
        then {session:$s.session, binding:$s.binding, facts:($s.facts|length), sources:($s.rawSources|length)}
        else error("prepared \($j.journalTxId) lacks its actual Unbound acquisition/fact/source extent")
        end' "$1/journal.jsonl" || fail "$1: a write did not journal its actual acquisition"
}

# hexof TEXT: the hex of the key bytes, for the expected envelope.
hexof() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

# A minimal CBOR reader, for the saved signed transactions the journal keeps:
# the outputs of a transaction (address hex, lovelace, other assets, inline datum),
# read apart from any receipt. Byte strings are hex strings, maps are lists of
# [key, value] pairs, a tag is {tag, value}.
cat >"$work/cbor.jq" <<'JQ'
def nibble: if . >= 97 then . - 87 else . - 48 end;
def tobytes: explode | map(nibble) | [range(0; length; 2) as $i | .[$i] * 16 + .[$i + 1]];
def hexdig: if . < 10 then . + 48 else . + 87 end;
def bytehex: map([(. / 16 | floor), (. % 16)] | map(hexdig)) | flatten | implode;
def be($b; $p; $n): reduce range($p; $p + $n) as $i (0; . * 256 + $b[$i]);
def head($b; $p):
  $b[$p] as $h | ($h / 32 | floor) as $mt | ($h % 32) as $ai
  | (if $ai < 24 then [$ai, $p + 1]
     elif $ai == 24 then [$b[$p + 1], $p + 2]
     elif $ai == 25 then [be($b; $p + 1; 2), $p + 3]
     elif $ai == 26 then [be($b; $p + 1; 4), $p + 5]
     elif $ai == 27 then [be($b; $p + 1; 8), $p + 9]
     else [null, $p + 1] end) as [$arg, $q]
  | {mt: $mt, ai: $ai, arg: $arg, q: $q};
def dec($b; $p):
  head($b; $p) as {mt: $mt, ai: $ai, arg: $arg, q: $q}
  | if $mt == 0 then [$arg, $q]
    elif $mt == 1 then [-1 - $arg, $q]
    elif $mt == 2 then [($b[$q:$q + $arg] | bytehex), $q + $arg]
    elif $mt == 3 then [($b[$q:$q + $arg] | implode), $q + $arg]
    elif $mt == 4 or $mt == 5 then
      (if $mt == 5 then 2 else 1 end) as $w
      | (if $ai == 31 then null else $arg * $w end) as $count
      | {p: $q, v: [], n: 0}
      | until(
          (if $count == null then $b[.p] == 255 else .n >= $count end);
          dec($b; .p) as [$c, $r] | {p: $r, v: (.v + [$c]), n: (.n + 1)})
      | (if $count == null then .p + 1 else .p end) as $e
      | .v as $items
      | [(if $mt == 5 then [range(0; $items | length; 2) as $i | [$items[$i], $items[$i + 1]]] else $items end), $e]
    elif $mt == 6 then dec($b; $q) as [$v, $r] | [{tag: $arg, value: $v}, $r]
    else [(if $ai == 20 then false elif $ai == 21 then true else null end), $q]
    end;
def decode: tobytes as $b | dec($b; 0) | .[0];
def mapget($k): map(select(.[0] == $k)) | (.[0] // [null, null])[1];
def datum_value: if type == "object" and .tag == 24 then (.value | decode) else . end;
def out_of:
  if (.[0] | type) == "string" then {address: .[0], v: .[1], datum: null}
  else {address: mapget(0), v: mapget(1),
        datum: (mapget(2) | if . == null then null elif .[0] == 1 then (.[1] | datum_value) else null end)}
  end
  | .coin = (if (.v | type) == "array" then .v[0] else .v end)
  | .assets = [(if (.v | type) == "array" then .v[1][]? else empty end) | .[0] as $p | .[1][] | {policy: $p, name: .[0], quantity: .[1]}]
  | del(.v);
def tx_outputs: decode | .[0] | mapget(1) | map(out_of);
def tx_inputs: decode | .[0] | mapget(0) | (if type == "object" then .value else . end) | map(.[0] + "#" + (.[1] | tostring));
# the hex of a signed transaction's body alone: the bytes whose hash is its id
def body_span: tobytes as $b | (if $b[0] == 132 then dec($b; 1) else error("not a four-element transaction") end) as [$v, $q] | $b[1:$q] | bytehex;
JQ
# tx_outputs_of TXID: the outputs of the signed transaction the managed journal saved.
tx_outputs_of() { jq -R -c "$(cat "$work/cbor.jq") tx_outputs" "$(managed_body "$reg" "$1")"; }
# tx_inputs_of TXID: the spent inputs of the signed transaction the managed journal saved, one TXID#index per line.
tx_inputs_of() { jq -R -r "$(cat "$work/cbor.jq") tx_inputs | .[]" "$(managed_body "$reg" "$1")"; }

# payload FILE: the nested payload every insert of this journey carries.
payload() {
  jq -n '{map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}' >"$1"
}

# holds_envelope RECEIPT PATH CONTROLLER KEY PAYLOAD_FILE: the envelope at PATH
# of the receipt is the datum an insert must book, assembled here from the
# registry's own pins and saved token, the key's bytes, the caller's payment
# key hash, the 2 000 000 lovelace minimum and the payload file, not from
# anything the command printed.
holds_envelope() {
  jq -e --arg s "$state" --arg t "$token" --arg a "$active" --arg k "$(hexof "$4")" \
    --arg c "$3" --slurpfile p "$5" "$2 == {constructor:0, fields:[
      {constructor:0, fields:[{int:1},{constructor:0,fields:[{bytes:\$s},{bytes:\$t}]},
        {bytes:\$a},{bytes:\$k},{bytes:\$c},{int:2000000}]}, \$p[0]]}" \
    "$receipts/$1.json" >/dev/null
}

# ------------------------------------------------------------------
# The command surface
# ------------------------------------------------------------------
"$singular" --help >"$work/help.txt"
"$open_datum" --help >"$work/help-open-datum.txt"
for c in create fold reclaim reject inspect; do
  grep -q "singular registry $c" "$work/help.txt" || fail "help does not name registry $c"
done
for c in create insert update terminate fold inspect; do
  grep -q "open-datum $c" "$work/help-open-datum.txt" || fail "open-datum help does not name $c"
done
status=0
"$open_datum" inspect --key-hex 00 "${common[@]}" "${node[@]}" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "inspect accepted a signing key (exit $status)"
say "both helps name the eight commands; a signing key on inspect is refused"

# ------------------------------------------------------------------
# 1. create
# ------------------------------------------------------------------
run preview success -- create --process-time 120000 --retract-time 30000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
[ ! -e "$reg" ] || fail "preview created the target $reg"
seed="$(field preview .seed)"
run bob-preview success -- create --process-time 120000 --retract-time 30000 --preview --state-dir "$work/bob-preview" \
  --blueprint "$blueprint" "${node[@]}" "${bob[@]}"
[ ! -e "$work/bob-preview" ] || fail "bob's preview created its target"
bobkey="$(field bob-preview .walletKeyHash)"
alice_addr="$(field preview .wallet)"
bob_addr="$(field bob-preview .wallet)"

# The same preview for a public address alone: no key, no write, and the
# identity it names is the one the key-holding preview named.
run preview-public success -- create --process-time 120000 --retract-time 30000 --preview --state-dir "$work/public-preview" \
  --blueprint "$blueprint" "${node[@]}" --wallet-address "$alice_addr"
[ ! -e "$work/public-preview" ] || fail "a public preview created its target"
jq -e --slurpfile k "$receipts/preview.json" '.seed == $k[0].seed and .pins == $k[0].pins and .walletKeyHash == $k[0].walletKeyHash' \
  "$receipts/preview-public.json" >/dev/null || fail "the public preview names another identity than the key preview"
for preview_receipt in preview bob-preview preview-public; do
  jq -e '.sessionEvidence as $s
    | $s.binding == {kind:"Unbound"}
      and ($s.facts | type == "array" and length > 0)
      and ($s.facts | all(.session == $s.session and .binding == $s.binding
        and .verdict == "Unverified"))' "$receipts/$preview_receipt.json" >/dev/null \
    || fail "$preview_receipt lacks its Unbound session and Unverified facts"
done
status=0
"$open_datum" create --process-time 120000 --retract-time 30000 --preview --state-dir "$work/public-preview" --blueprint "$blueprint" \
  "${node[@]}" --wallet-address "$alice_addr" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "a preview accepted a signing key beside a public address (exit $status)"

run create-seed-not-owned client-refusal -- create --process-time 120000 --retract-time 30000 --seed "$seed" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
[ ! -e "$reg/registry.json" ] || fail "a refused create saved a registry"

# Leave room for the unchanged 30-second CLI margin and the assertion
# requiring three measured fold builds, including the traced second actor.
# The retract window must also stay open across the selection scenario the
# late request's section runs between the refused late fold and the early
# reject: a booking and a fold of a fresh request happen there (#518).
process_time=120000
retract_time=60000
run create success -- create --process-time "$process_time" --retract-time "$retract_time" --seed "$seed" "${common[@]}" "${node[@]}" "${alice[@]}"
state="$(field create .pins.pinState)"
token="$(field create .token)"
active="$(field create .pins.pinActive)"
alicekey="$(field create .walletKeyHash)"
[ "$(field create .seed)" = "$seed" ] || fail "create booted from another seed"
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"]' \
  "$receipts/create.json" >/dev/null || fail "create did not publish the six references"
refused create-again client-refusal -- create --process-time 120000 --retract-time 30000 --seed "$seed" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e --argjson p "$process_time" --argjson r "$retract_time" \
  '.processTime == $p and .retractTime == $r' "$receipts/create.json" >/dev/null \
  || fail "create did not report the chosen processing and retract windows"
say "registry $token booted from $seed"

# A registry is its state token: create prints it and keeps no identity file,
# and an actor whose directory is empty runs a command on the token alone.
state_token="$(field create .stateToken)"
[ "$state_token" = "$state.$token" ] || fail "create did not print the state token $state.$token"
# Managed partitions for this journey's main-registry writers, derived from
# the token and wallet identities the receipts name; the commands create them.
alice_journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
bob_main_journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
[ ! -e "$reg/registry.json" ] || fail "create wrote a registry.json"
empty_actor="$work/empty-actor"
mkdir -p "$empty_actor"
[ -z "$(ls -A "$empty_actor")" ] || setup_fail "the second actor's directory is not empty at start"
run empty-actor-inspect success -- inspect --key keyEmpty --state-token "$state_token" \
  --state-dir "$empty_actor" --blueprint "$blueprint" "${node[@]}"
[ "$(field empty-actor-inspect .leaf)" = unknown ] \
  || fail "an actor starting from an empty directory did not read the registry from its state token"
say "an actor with an empty directory read the registry from its state token alone"
# Every later command names the registry by its token; the directory is only
# the actor's journal.
common+=(--state-token "$state_token")

# ------------------------------------------------------------------
# 1c. the registry page right after create, from the receipt's command
# ------------------------------------------------------------------
# The create receipt prints the working describe command; run it as printed,
# with only the program name resolving to this archive's singular, and print
# the page text to the journey log. The read leaves the actor's state
# directory exactly as it was. The page steps run only where the archive
# layout is present; in test-harness mode without it the journey says so
# once below and runs none of them.
# require_archive_layout BLUEPRINT MODE: 0 iff version.txt sits beside the
# blueprint. It never exits: in ordinary mode it names the missing file and
# returns 1, and the caller fails the journey by that same name; in
# test-harness mode the caller skips the page steps and says so once instead.
require_archive_layout() {
  local blueprint="$1" mode="$2"
  if [ -f "$(dirname "$blueprint")/version.txt" ]; then
    return 0
  fi
  if [ "$mode" = ordinary ]; then
    echo "the archive's blueprint has no version.txt beside it" >&2
  fi
  return 1
}
page_steps_run=0
if require_archive_layout "$blueprint" "$mode"; then
  page_steps_run=1
  describe_cmd="$(jq -r .describeCommand "$receipts/create.json")"
  [ "$describe_cmd" != "null" ] && [ -n "$describe_cmd" ] || fail "create printed no describe command"
  mkdir -p "$work/archive-bin"
  ln -sf "$singular" "$work/archive-bin/singular"
  describe_tree_before="$(cd "$reg" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  path_before="$PATH"
  PATH="$work/archive-bin:$PATH"
  describe_status=0
  eval "$describe_cmd" >"$receipts/describe-after-create.txt" 2>"$receipts/describe-after-create.err" || describe_status=$?
  PATH="$path_before"
  [ "$describe_status" -eq 0 ] || fail "the printed describe command failed after create: $(tail -n 3 "$receipts/describe-after-create.txt" "$receipts/describe-after-create.err" | tr '\n' ' ')"
  [ -s "$receipts/describe-after-create.txt" ] || fail "the page after create is empty"
  cat "$receipts/describe-after-create.txt"
  path_before="$PATH"
  PATH="$work/archive-bin:$PATH"
  describe_status=0
  eval "$describe_cmd --json" >"$receipts/describe-after-create.json" 2>"$receipts/describe-after-create.err" || describe_status=$?
  PATH="$path_before"
  [ "$describe_status" -eq 0 ] || fail "the printed describe command failed as JSON after create"
  jq -e '.command == "describe" and .outcome == "success"' "$receipts/describe-after-create.json" >/dev/null \
    || fail "the page after create is no success page"
  describe_tree_after="$(cd "$reg" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  [ "$describe_tree_after" = "$describe_tree_before" ] || fail "a page read changed the actor's state directory"
  say "the registry page reads after create from the receipt's command"
elif [ "$mode" = test-harness ]; then
  say "the page steps belong to the archive journey; skipped in this mode"
else
  # Ordinary without the layout never skips: the function named the missing
  # file above, and the same name fails the journey here.
  fail "the archive's blueprint has no version.txt beside it"
fi

# This registry's own folds, in journey order: every fold command of the
# journey runs on its token, so the page's counts are read from their
# receipts at run time below. The test-harness path's killed terminate fold
# never printed a receipt; its settled edge enters from the journal where it
# was accepted.
main_folds=(empty-actor-insert bob-default-fold fold bob-fold insert-after-release terminate-ordinary bob-terminate-fold fold-selection fold-after-insert fold-after-reclaim)
# page_agrees PAGE INSPECT LASTFOLD ACTIVE TERMINAL FOLDS: the page's six
# facts equal the readback the caller passes: root and pending list from the
# inspect receipt, the last fold (empty expects none), the key counts and the
# folds since create. Callers read every value from receipts at run time.
page_agrees() {
  local page="$1" inspect="$2" lastfold="$3" active="$4" terminal="$5" folds="$6"
  jq -e --slurpfile inspect "$inspect" --arg lastfold "$lastfold" \
    --argjson active "$active" --argjson terminal "$terminal" --argjson folds "$folds" '
      .command == "describe" and .outcome == "success"
      and .state.root == $inspect[0].root
      and .state.pendingRequests == $inspect[0].pendingRequests
      and (if $lastfold == "" then .state.lastFold == null else .state.lastFold == $lastfold end)
      and .state.activeKeys == $active
      and .state.terminalKeys == $terminal
      and .state.foldsSinceCreate == $folds' "$page" >/dev/null
}
# main_fold_settled: the settled key and edge of every fold receipt of this
# registry so far, in journey order, read from the receipts at run time.
main_fold_settled() {
  local f
  for f in "${main_folds[@]}"; do
    if [ -e "$receipts/$f.json" ]; then
      jq -c '.settled[]? | {key, edge}' "$receipts/$f.json"
    fi
  done
}
# main_fold_count: how many of this registry's fold receipts exist so far.
main_fold_count() {
  local f n=0
  for f in "${main_folds[@]}"; do
    if [ -e "$receipts/$f.json" ]; then
      n=$((n + 1))
    fi
  done
  printf '%s' "$n"
}
# page_tamper_demo PAGE INSPECT LASTFOLD ACTIVE TERMINAL FOLDS: a page with a
# planted difference in any one compared fact disagrees with the same
# readback, shown for each of the six facts in turn.
page_tamper_demo() {
  local page="$1"
  shift
  local altered
  for altered in \
    '.state.root = "00"' \
    '.state.pendingRequests = [{}]' \
    '.state.lastFold = "00"' \
    '.state.activeKeys += 1' \
    '.state.terminalKeys += 1' \
    '.state.foldsSinceCreate += 1'; do
    jq "$altered" "$page" >"$work/page-tampered.json"
    if page_agrees "$work/page-tampered.json" "$@"; then
      fail "a page altered by $altered still agreed with the readback"
    fi
  done
}
# No fold ran on this registry yet: the settled history so far is empty, so
# the counts, the folds since create and the last fold are read from the
# receipts at run time, not stated.
if [ "$page_steps_run" = 1 ]; then
  after_create_counts="$(main_fold_settled | jq -s -c '{active: ([.[] | select(.edge == "insertActive")] | length), terminal: ([.[] | select(.edge == "updateTerminal")] | length)}')"
  after_create_active="$(jq -r .active <<<"$after_create_counts")"
  after_create_terminal="$(jq -r .terminal <<<"$after_create_counts")"
  after_create_folds="$(main_fold_count)"
  page_agrees "$receipts/describe-after-create.json" "$receipts/empty-actor-inspect.json" "" "$after_create_active" "$after_create_terminal" "$after_create_folds" \
    || fail "the page after create differs from the empty-actor readback"
  say "the page after create agrees with the empty-actor readback: $after_create_active active, $after_create_terminal terminal, $after_create_folds folds"
  page_tamper_demo "$receipts/describe-after-create.json" "$receipts/empty-actor-inspect.json" "" "$after_create_active" "$after_create_terminal" "$after_create_folds"
  say "a planted difference in any compared fact fails the page comparison"
fi

# This registry exercises absent flags and never books a timed request.
# The rest of the journey keeps its explicit development-network windows.
# Bob's early preview named a chained seed with no carrier; Alice has since
# published the carrier, so that pin is stale. Re-preview Bob with the carrier
# (largest output, as today) and boot from the fresh pin.
run bob-preview2 success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$work/bob-preview2" --blueprint "$blueprint" "${node[@]}" "${bob[@]}"
[ ! -e "$work/bob-preview2" ] || fail "bob's second preview created its target"
run create-defaults success -- create --seed "$(field bob-preview2 .seed)" \
  --state-dir "$work/default-registry" --blueprint "$blueprint" "${node[@]}" "${bob[@]}"
run inspect-defaults success -- inspect --key default-window-key \
  --state-dir "$work/default-registry" --blueprint "$blueprint" \
  --state-token "$(field create-defaults .stateToken)" "${node[@]}"
for name in create-defaults inspect-defaults; do
  jq -e '.processTime == 600000 and .retractTime == 300000' "$receipts/$name.json" >/dev/null \
    || fail "$name: the default registry did not read back ten-minute processing and five-minute retract windows"
done
say "default registry windows read back from create and inspect, without waiting them out"
# The state script is the same for every registry of a release: Bob's create
# found Alice's live carrier of it by hash and booted from it, publishing none.
jq -e --slurpfile a "$receipts/create.json" '
    [.references[] | select(.role == "state") | .output]
      == [$a[0].references[] | select(.role == "state") | .output]
    and (.transactions | index($a[0].references[] | select(.role == "state") | .output | split("#")[0]) | not)' \
  "$receipts/create-defaults.json" >/dev/null \
  || fail "a second create published the state script again instead of booting from the live carrier"
say "a second create booted from the state reference found by hash, publishing none"

# Bob writes from an empty directory of his own, on the token alone: he books
# and folds an insertion, and a third empty directory reads it back.
bob_actor="$work/bob-actor"
mkdir -p "$bob_actor"
[ -z "$(ls -A "$bob_actor")" ] || setup_fail "bob's directory is not empty at start"
payload "$work/payload-empty.json"
run empty-actor-insert success -- insert --fold --key keyEmpty --payload "$work/payload-empty.json" \
  --state-dir "$bob_actor" --blueprint "$blueprint" --state-token "$state_token" "${node[@]}" "${bob[@]}"
[ ! -e "$bob_actor/registry.json" ] || fail "a command wrote a registry.json in bob's directory"
reader="$work/empty-reader"
mkdir -p "$reader"
# Files in an actor's directory are never an input: another registry's
# identity file there changes nothing.
printf '{"confDeployment":{"depCageToken":"00"}}\n' >"$reader/registry.json"
run empty-reader-inspect success -- inspect --key keyEmpty --state-token "$state_token" \
  --state-dir "$reader" --blueprint "$blueprint" "${node[@]}"
[ "$(field empty-reader-inspect .leaf)" = active ] \
  || fail "an insertion booked and folded from an empty directory is not active for another empty reader"
say "bob booked and folded from an empty directory on the state token; another empty directory reads it"

# ------------------------------------------------------------------
# 1b. fresh bob on the managed default path: no directory argument (485)
# ------------------------------------------------------------------
# Bob is new: an isolated HOME with no state, and no --state-dir anywhere
# in this leg. His inspect, booking, fold and readback resolve the managed
# default root under that HOME alone. The harness asserts on the
# CLI-managed root but never precreates a partition; explicit --state-dir
# roots elsewhere test the override and isolation scopes, not this leg.
bob_home="$work/bob-home"
bob_copy="$work/bob-copy.skey"
rm -rf "$bob_home"
mkdir -p "$bob_home"
cp "$work/bob.skey" "$bob_copy"
# The expected CLI-managed root, with an explicitly cleared XDG so an
# inherited XDG_STATE_HOME cannot override the intended HOME unexpectedly.
bob_root="$(managed_default_root "$bob_home" "")"
# bob_env_on/bob_env_off: scope bob's isolated HOME (and XDG clearing) around
# ordinary commands without a subshell, so later uses of HOME and singular
# stay intact. Loss at a subshell end would hide the spent environment;
# explicit restore keeps the spent state visible.
bob_env_on() {
  bob_home_old="$HOME"
  bob_xdg_old="${XDG_STATE_HOME-unset}"
  unset XDG_STATE_HOME
  export HOME="$bob_home"
}
bob_env_off() {
  export HOME="$bob_home_old"
  if [ "$bob_xdg_old" = unset ]; then unset XDG_STATE_HOME; else export XDG_STATE_HOME="$bob_xdg_old"; fi
}
# bob_run NAME CLASS -- ARGS: run() with bob's isolated HOME and no XDG.
bob_run() {
  bob_env_on
  run "$@"
  bob_env_off
}
bob_key=defaultBob
payload "$work/payload-bob-default.json"
# 1. Inspect with no prior state succeeds and creates nothing.
bob_run bob-default-inspect success -- inspect --key keyEmpty \
  --blueprint "$blueprint" --state-token "$state_token" "${node[@]}"
[ "$(field bob-default-inspect .leaf)" = active ] \
  || fail "fresh bob's default-path inspect did not read the active key"
[ -z "$(find "$bob_home" -mindepth 1)" ] \
  || fail "a stateless inspect created state under bob's HOME"
# The access detector, shown able to fire on this leg's paths: a deliberate
# open under the creator's root is reported.
[ -f "$alice_journal" ] \
  || setup_fail "the creator's managed journal is not where the booking left it"
strace -f -qq -e trace=%file -o "$work/bob-detector.strace" cat "$alice_journal" >/dev/null 2>&1 || true
grep -qF "$reg/" "$work/bob-detector.strace" \
  || fail "control: a deliberate open under the creator's root was not detected"
# 2. Bob books with his key, traced: the booking must never open the
# creator's directory or another actor's root.
bob_traced="$work/traced-singular-bob"
printf '#!/usr/bin/env bash\nexec strace -f -qq -e trace=%%file -o "%s" "%s" "$@"\n' \
  "$work/bob-book.strace" "$open_datum" >"$bob_traced"
chmod +x "$bob_traced"
bob_open_datum_old="$open_datum"
open_datum="$bob_traced"
bob_env_on
run bob-default-insert success -- insert --key "$bob_key" \
  --payload "$work/payload-bob-default.json" --blueprint "$blueprint" \
  --state-token "$state_token" "${node[@]}" --wallet-skey "$work/bob.skey"
bob_env_off
open_datum="$bob_open_datum_old"
[ "$(field bob-default-insert .requester)" = "$bobkey" ] \
  || fail "fresh bob's default-path booking names another requester"
holds_envelope bob-default-insert .envelope "$bobkey" "$bob_key" "$work/payload-bob-default.json" \
  || fail "fresh bob's booking carries another controller"
[ -s "$work/bob-book.strace" ] \
  || setup_fail "fresh bob's default-path booking left no trace of its file accesses"
for root in "$reg/" "$bob_actor/" "$reader/"; do
  ! grep -qF "$root" "$work/bob-book.strace" \
    || fail "fresh bob's booking accessed another actor's directory: $(grep -F "$root" "$work/bob-book.strace" | head -n 3)"
done
bob_journal="$(managed_journal "$bob_root" "$state_token" "$bobkey")"
[ -f "$bob_journal" ] \
  || fail "fresh bob's booking left no journal under the managed default root"
mapfile -t bob_journals < <(managed_find "$bob_root" journal.jsonl)
[ "${#bob_journals[@]}" -eq 1 ] \
  || fail "fresh bob's root holds more than his one journal"
# 2b. Bob folds with the COPIED key: key-file relocation reuses the same
# journal and partition, and the fold consumes exactly his booking.
printf '#!/usr/bin/env bash\nexec strace -f -qq -e trace=%%file -o "%s" "%s" "$@"\n' \
  "$work/bob-fold.strace" "$open_datum" >"$bob_traced"
open_datum="$bob_traced"
bob_env_on
run bob-default-fold success -- fold --request "$(field bob-default-insert .request)" \
  --blueprint "$blueprint" --state-token "$state_token" "${node[@]}" \
  --wallet-skey "$bob_copy"
bob_env_off
open_datum="$bob_open_datum_old"
[ "$(field bob-default-fold .folder)" = "$bobkey" ] \
  || fail "the copied key folded into another wallet's partition"
jq -e --slurpfile b "$receipts/bob-default-insert.json" '
    (.settled | length == 1)
    and .settled[0].request == $b[0].request and .foldDeadline.posixMs == $b[0].foldDeadline.posixMs
    and .folder == $b[0].requester and .settled[0].edge == "insertActive"
    and (.fold | test("^[0-9a-f]{64}$"))' "$receipts/bob-default-fold.json" >/dev/null \
  || fail "fresh bob's fold does not consume his booking's request and deadline with his own key"
bob_part="$(dirname "$bob_journal")"
jq -R -e --slurpfile receipt "$receipts/bob-default-fold.json" \
  "$(cat "$work/cbor.jq") decode | .[0] | mapget(3) == \$receipt[0].validUntilSlot" \
  "$bob_part/submissions/$(field bob-default-fold .fold).cbor.hex" >/dev/null \
  || fail "fresh bob's saved signed body's upper slot differs from the receipt and actual selection"
jq -s -ce --arg tx "$(field bob-default-fold .fold)" '
    [.[] | select(.journalEvent == "prepared" and .journalTxId == $tx)
      | .journalSession.rawSources[] | select(.kind == "raw-time")] | unique
    | if length == 1 then .[0] else error("fold has no unique raw time source") end' \
  "$bob_journal" >"$receipts/bob-default-fold.time-source.json" \
  || fail "fresh bob's fold has no exact pinned time source in his journal"
[ -s "$work/bob-fold.strace" ] \
  || setup_fail "fresh bob's default-path fold left no trace of its file accesses"
for root in "$reg/" "$bob_actor/" "$reader/"; do
  ! grep -qF "$root" "$work/bob-fold.strace" \
    || fail "fresh bob's fold accessed another actor's directory: $(grep -F "$root" "$work/bob-fold.strace" | head -n 3)"
done
mapfile -t bob_journals_after < <(managed_find "$bob_root" journal.jsonl)
[ "${#bob_journals_after[@]}" -eq 1 ] \
  || fail "the copied key created another journal instead of reusing bob's"
# 3. Readback binds the fold: same request consumed, delivered and observed.
bob_run bob-default-readback success -- inspect --key "$bob_key" \
  --blueprint "$blueprint" --state-token "$state_token" "${node[@]}"
jq -e --slurpfile b "$receipts/bob-default-insert.json" --slurpfile f "$receipts/bob-default-fold.json" '
    .leaf == "active" and .applicationOutput.envelope == $b[0].envelope
    and .root == $f[0].root
    and .applicationOutput.output == $f[0].settled[0].settlement.liveOutput' \
  "$receipts/bob-default-readback.json" >/dev/null \
  || fail "fresh bob's default-path readback is not his folded booking, delivered and observed"
jq -s -e --arg t "$(field bob-default-fold .fold)" \
  '[.[] | select(.journalTxId == $t and .journalEvent == "observed")] | length == 1' \
  "$bob_journal" >/dev/null \
  || fail "fresh bob's fold was never journalled observed in his partition"
# 4. Negative control: the identical fold through a wrapper that opens the
# creator's journal first must trip the same isolation predicate, while the
# refused rerun journals nothing.
printf '#!/usr/bin/env bash\nexec strace -f -qq -e trace=%%file -o "%s" bash -c '\''cat "%s" >/dev/null 2>&1; exec "%s" "$@"'\'' open-datum "$@"\n' \
  "$work/bob-evil.strace" "$alice_journal" "$open_datum" >"$work/traced-singular-bob-evil"
chmod +x "$work/traced-singular-bob-evil"
evil_before="$(wc -l <"$bob_journal" | tr -d ' ')"
bob_env_on
"$work/traced-singular-bob-evil" fold --request "$(field bob-default-insert .request)" \
  --blueprint "$blueprint" --state-token "$state_token" "${node[@]}" \
  --wallet-skey "$bob_copy" >"$receipts/bob-default-evil.json" 2>"$receipts/bob-default-evil.err" || true
bob_env_off
grep -qF "$reg/" "$work/bob-evil.strace" \
  || fail "negative control did not fire: a creator-journal open by bob's process went undetected"
[ "$(wc -l <"$bob_journal" | tr -d ' ')" = "$evil_before" ] \
  || fail "the negative rerun moved fresh bob's journal"
say "fresh bob inspected, booked, folded and read back with no directory argument under the managed default root; the negative control fires"

# ------------------------------------------------------------------
# 2. insert (alice), with its refusals
# ------------------------------------------------------------------
key=keyA
payload "$work/payload-insert.json"
echo '{"not":"a datum"}' >"$work/payload-bad.json"
# ------------------------------------------------------------------
# 7. two actors (#419, #437): bob folds alice's insertion on the state token
# ------------------------------------------------------------------
# This independent control runs here, before the deadline/reclaim waits
# below, so the deliberate-open control fails fast at the access check
# without replaying them. Numbering keeps its journey position.
# Alice books an insertion from her own registry directory. Bob folds it
# from an empty directory of his own: no trie, no journal, nothing of her
# booking and no file of hers; he names the registry by the state token
# alone, the trie is rebuilt from chain history and the envelope is read
# from the request on the chain. Alice's directory is unreadable while bob
# runs, and every file access of bob's process is traced: one under
# alice's directory fails the run.
two="$work/two-actors"
two_alice="$two/alice"
two_bob="$two/bob"
mkdir -p "$two"
trap release_work EXIT
run two-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$two_alice" --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
run two-create success -- create --process-time 120000 --retract-time 30000 \
  --seed "$(field two-preview .seed)" --state-dir "$two_alice" --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
two_token="$(field two-create .stateToken)"
two_key=keyT
run two-insert success -- insert --key "$two_key" --payload "$work/payload-insert.json" \
  --state-dir "$two_alice" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}" "${alice[@]}"
[ "$(field two-insert .requester)" = "$alicekey" ] || fail "the two-actor booking's requester is not alice's key"
mkdir -p "$two_bob"
[ -z "$(ls -A "$two_bob")" ] || setup_fail "bob's two-actor directory is not empty at start"
# touches_alice TRACE: the traced process named a path under alice's directory.
touches_alice() { grep -qF "$two_alice" "$1"; }
# The detector, shown able to fire: a deliberate open under alice's
# directory, traced the same way, is reported. Alice's journal is her own
# in-flight file; it exists because she booked.
two_alice_journal="$(managed_journal "$two_alice" "$two_token" "$alicekey")"
[ -f "$two_alice_journal" ] \
  || setup_fail "alice's managed journal is not where her booking left it"
strace -f -qq -e trace=%file -o "$two/control.strace" cat "$two_alice_journal" >/dev/null 2>&1 || true
touches_alice "$two/control.strace" || fail "control: a deliberate open under alice's directory was not detected"
say "two actors: the access detector reports a deliberate open under alice's directory"
traced="$work/traced-singular"
printf '#!/usr/bin/env bash\nexec strace -f -qq -e trace=%%file -o "%s" "%s" "$@"\n' "$two/bob-fold.strace" "$open_datum" >"$traced"
# DEMO1_TWO_ACTOR_DELIBERATE_OPEN=1 is the run's own failing control: bob's
# traced process opens alice's journal before it folds, so the whole
# journey must fail at the access check below.
if [ "${DEMO1_TWO_ACTOR_DELIBERATE_OPEN:-}" = 1 ]; then
  printf '#!/usr/bin/env bash\nexec strace -f -qq -e trace=%%file -o "%s" bash -c '"'"'cat "%s" >/dev/null 2>&1; exec "%s" "$@"'"'"' open-datum "$@"\n' \
    "$two/bob-fold.strace" "$two_alice_journal" "$open_datum" >"$traced"
  say "two actors: the deliberate open control is on; bob's process opens alice's journal"
fi
chmod +x "$traced"
real_open_datum="$open_datum"
chmod 000 "$two_alice"
! ls "$two_alice" >/dev/null 2>&1 || fail "alice's directory is readable to the run"
open_datum="$traced"
run two-fold success -- fold --state-dir "$two_bob" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}" "${bob[@]}"
open_datum="$real_open_datum"
chmod u+rwx "$two_alice"
[ -s "$two/bob-fold.strace" ] || setup_fail "bob's fold left no trace of its file accesses"
! touches_alice "$two/bob-fold.strace" || fail "bob's fold accessed alice's directory: $(grep -F "$two_alice" "$two/bob-fold.strace" | head -n 3)"
jq -e --slurpfile b "$receipts/two-insert.json" --arg k "$(hexof "$two_key")" --arg bob "$bobkey" '
    (.settled | length == 1)
    and .settled[0].request == $b[0].request and .folder == $bob and .settled[0].edge == "insertActive"
    and .settled[0].key == $k and .settled[0].settlement.envelope == $b[0].envelope
    and (.settled[0].settlement.liveOutput | test("#"))' \
  "$receipts/two-fold.json" >/dev/null \
  || fail "bob's fold does not deliver alice's envelope at her key"
run two-inspect success -- inspect --key "$two_key" --state-dir "$two_bob" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}"
jq -e --slurpfile b "$receipts/two-insert.json" --slurpfile f "$receipts/two-fold.json" '
    .leaf == "active" and .applicationOutput.envelope == $b[0].envelope
    and .root == $f[0].root' "$receipts/two-inspect.json" >/dev/null \
  || fail "the key bob folded is not active under alice's envelope at her destination"
say "two actors: bob folded alice's insertion from the state token alone; her envelope sits at her destination"

# ------------------------------------------------------------------
# 7a. two actors book at once and one fold settles both (#518)
# ------------------------------------------------------------------
# Alice books first and Bob second, but the settled list keeps ledger input
# order: pending requests are sorted by output reference, so the receipt
# names the two bookings in ascending request order, which this leg asserts
# by set and order rather than by booking position. Each entry is bound to
# its own booking by request reference; each key reads back under its own
# booker's envelope at its own delivered output; the two live outputs sit
# at the one application destination. Every assertion below is shown able to
# fail on an edited copy of the receipt.
two_both_started="$(date +%s)"
two_key_a=keyU
two_key_b=keyV
run two-both-insert-alice success -- insert --key "$two_key_a" --payload "$work/payload-insert.json" \
  --state-dir "$two_alice" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}" "${alice[@]}"
[ "$(field two-both-insert-alice .requester)" = "$alicekey" ] \
  || fail "the joint booking's requester is not alice's key"
run two-both-insert-bob success -- insert --key "$two_key_b" --payload "$work/payload-insert.json" \
  --state-dir "$two_bob" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}" "${bob[@]}"
[ "$(field two-both-insert-bob .requester)" = "$bobkey" ] \
  || fail "the joint booking's requester is not bob's key"
booked two-both-insert-alice
booked two-both-insert-bob
run two-both-fold success -- fold --state-dir "$two_bob" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}" "${bob[@]}"
[ "$(field two-both-fold .folder)" = "$bobkey" ] \
  || fail "the joint fold was not folded with bob's key"
two_both_settled() {
  jq -e --slurpfile a "$receipts/two-both-insert-alice.json" --slurpfile b "$receipts/two-both-insert-bob.json" \
    --arg ka "$(hexof "$two_key_a")" --arg kb "$(hexof "$two_key_b")" --arg alice "$alicekey" --arg bob "$bobkey" '
      (.settled | length == 2)
      and ([.settled[].request] == ([$a[0].request, $b[0].request] | sort))
      and ((.settled | map(select(.request == $a[0].request)) | .[0]) as $ea
        | $ea.key == $ka and $ea.edge == "insertActive" and $ea.owner == $alice
        and $ea.settlement.envelope == $a[0].envelope
        and $ea.deadline.posixMs == $a[0].foldDeadline.posixMs
        and ($ea.settlement.liveOutput | test("^[0-9a-f]{64}#[0-9]+$")))
      and ((.settled | map(select(.request == $b[0].request)) | .[0]) as $eb
        | $eb.key == $kb and $eb.edge == "insertActive" and $eb.owner == $bob
        and $eb.settlement.envelope == $b[0].envelope
        and $eb.deadline.posixMs == $b[0].foldDeadline.posixMs
        and ($eb.settlement.liveOutput | test("^[0-9a-f]{64}#[0-9]+$")))
      and $a[0].requester == $alice and $b[0].requester == $bob
      and .settled[0].settlement.liveOutput != .settled[1].settlement.liveOutput
      and (.excluded | length == 0)
      and .capacity.bound == 9
      and (.capacity.provenance | startswith("an estimate, not a measurement"))
      and (.fold | test("^[0-9a-f]{64}$"))
      and .foldDeadline.posixMs == ([.settled[].deadline.posixMs] | min)' "$1" >/dev/null
}
two_both_settled "$receipts/two-both-fold.json" \
  || fail "the joint fold did not settle both bookings in ledger order: $(jq -c .settled "$receipts/two-both-fold.json")"
two_both_tamper() { # NAME JQ-EDIT FILTER
  jq "$2" "$receipts/two-both-fold.json" >"$receipts/two-both-tampered-$1.json"
  if "$3" "$receipts/two-both-tampered-$1.json"; then
    fail "the two-request fold receipt edited in $1 still passed its assertion"
  fi
}
two_both_tamper settled-empty '.settled = []' two_both_settled
two_both_tamper one-dropped '.settled |= .[0:1]' two_both_settled
two_both_tamper order-swapped '.settled |= reverse' two_both_settled
# shellcheck disable=SC2016 # Single quotes preserve the jq program's variable.
two_both_tamper owners-swapped '.settled[0].owner as $o | .settled[0].owner = .settled[1].owner | .settled[1].owner = $o' two_both_settled
# shellcheck disable=SC2016 # Single quotes preserve the jq program's variable.
two_both_tamper envelope-swapped '.settled[0].settlement.envelope as $e | .settled[0].settlement.envelope = .settled[1].settlement.envelope | .settled[1].settlement.envelope = $e' two_both_settled
two_both_tamper capacity-bound '.capacity.bound = 1' two_both_settled
# Each payout reaches its owner: each key reads active under its own booker's
# envelope at its own delivered output, and the swapped readbacks fail.
two_both_payout_alice() {
  jq -e --slurpfile a "$receipts/two-both-insert-alice.json" --slurpfile f "$receipts/two-both-fold.json" '
    .leaf == "active" and .applicationOutput.envelope == $a[0].envelope
    and .applicationOutput.output == ($f[0].settled[] | select(.request == $a[0].request) | .settlement.liveOutput)
    and .root == $f[0].root' "$1" >/dev/null
}
two_both_payout_bob() {
  jq -e --slurpfile b "$receipts/two-both-insert-bob.json" --slurpfile f "$receipts/two-both-fold.json" '
    .leaf == "active" and .applicationOutput.envelope == $b[0].envelope
    and .applicationOutput.output == ($f[0].settled[] | select(.request == $b[0].request) | .settlement.liveOutput)
    and .root == $f[0].root' "$1" >/dev/null
}
run two-both-inspect-alice success -- inspect --key "$two_key_a" --state-dir "$two_alice" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}"
two_both_payout_alice "$receipts/two-both-inspect-alice.json" \
  || fail "alice's key does not read her envelope at her delivered output"
run two-both-inspect-bob success -- inspect --key "$two_key_b" --state-dir "$two_bob" --blueprint "$blueprint" --state-token "$two_token" "${node[@]}"
two_both_payout_bob "$receipts/two-both-inspect-bob.json" \
  || fail "bob's key does not read his envelope at his delivered output"
if two_both_payout_bob "$receipts/two-both-inspect-alice.json"; then
  fail "alice's readback passed under bob's envelope and output"
fi
if two_both_payout_alice "$receipts/two-both-inspect-bob.json"; then
  fail "bob's readback passed under alice's envelope and output"
fi
# Both payouts sit at the one application destination: the fold's saved body
# carries both live outputs at the same address, read apart from the receipt.
two_both_tx="$(field two-both-fold .fold)"
two_both_body="$(managed_body "$two_bob" "$two_both_tx")" \
  || fail "the joint fold's saved body is not under bob's directory"
two_both_outs="$(jq -R -c "$(cat "$work/cbor.jq") tx_outputs" "$two_both_body")" \
  || fail "the joint fold's saved body could not be read"
two_both_addr() { # LIVEOUTPUT OUTSJSON: the address the fold body gives the output
  jq -r --argjson i "${1##*#}" '.[$i].address // empty' <<<"$2"
}
two_both_out_a="$(field two-both-fold .settled[0].settlement.liveOutput)"
two_both_out_b="$(field two-both-fold .settled[1].settlement.liveOutput)"
two_both_addr_a="$(two_both_addr "$two_both_out_a" "$two_both_outs")"
two_both_addr_b="$(two_both_addr "$two_both_out_b" "$two_both_outs")"
[ -n "$two_both_addr_a" ] && [ "$two_both_addr_a" = "$two_both_addr_b" ] \
  || fail "the two payouts sit at different addresses: $two_both_addr_a vs $two_both_addr_b"
two_both_idx_b="${two_both_out_b##*#}"
if [ "$(two_both_addr "$two_both_out_b" "$(jq --argjson i "$two_both_idx_b" '.[$i].address += "00"' <<<"$two_both_outs")")" = "$two_both_addr_a" ]; then
  fail "a body read with one payout address changed still agreed"
fi
# Both payouts are live on the chain.
for two_both_out in "$two_both_out_a" "$two_both_out_b"; do
  "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$two_both_out" >"$work/two-both-probe.json"
  jq -e --arg o "$two_both_out" 'any(.live[]; . == $o)' "$work/two-both-probe.json" >/dev/null \
    || fail "the joint payout $two_both_out is not live on the chain"
done
say "two actors booked at once and one fold settled both, each payout to its owner, in $(($(date +%s) - two_both_started))s"

# ------------------------------------------------------------------
# 7b. an underfunded create refuses before boot (J)
# ------------------------------------------------------------------
# Dave's wallet holds one 5 ada output beside twenty-four 4 ada outputs:
# 101 ada in all, below the whole run's lowest total need, with a 5 ada
# ada-only output usable as collateral. A state carrier of this release is already
# live and reused, so his create would publish no state script; the seed
# and the largest output beside it cannot fund the boot, and the refusal
# comes before anything is submitted: no journal, no pending identity,
# and his seed stays an unspent output.
two_dave="$work/underfunded-actor"
dave=(--wallet-skey "$work/dave.skey")
run dave-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$two_dave" --blueprint "$blueprint" "${node[@]}" "${dave[@]}"
dave_seed="$(field dave-preview .seed)"
run dave-create client-refusal -- create --process-time 120000 --retract-time 30000 \
  --seed "$dave_seed" --state-dir "$two_dave" --blueprint "$blueprint" "${node[@]}" "${dave[@]}"
jq -e '.reason | startswith("publication-unfunded")' "$receipts/dave-create.json" >/dev/null \
  || fail "dave's underfunded create was refused for another reason: $(jq -r .reason "$receipts/dave-create.json")"
say "an underfunded create refuses before boot: $(jq -r .reason "$receipts/dave-create.json")"
[ -z "$(managed_find "$two_dave" journal.jsonl)" ] || fail "the refused create wrote a journal"
[ -z "$(managed_find "$two_dave" registry.pending.json)" ] || fail "the refused create wrote a pending identity"
probe_out="$work/dave-seed-probe.json"
"$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$dave_seed" >"$probe_out"
jq -e --arg s "$dave_seed" 'any(.live[]; . == $s)' "$probe_out" >/dev/null \
  || fail "dave's seed was spent by the refused create"
say "the refused create left dave's seed unspent"

# ------------------------------------------------------------------
# 7c. a fragmented wallet completes (Erin) and one short is refused (Frank)
# ------------------------------------------------------------------
# Erin holds five 30 tADA ada-only outputs and nothing else: the seed stays
# withheld from the publications, so four outputs fund them. Each output is
# strictly below the largest remaining single publication need (the
# application, needs 46966310 as the journey prints; state 11557 bytes is
# already live and reused, so no state publication remains), but the four
# permitted outputs cover the whole run (run need 109950687 as the refusals
# print; the seed is withheld from the publications). Her preview reports no
# refusal and her create completes;
# every reference is live carrying its script; at least one publication spent
# two or more inputs (read from her journal, never typed); Bob reads the
# registry from the token alone.
# Frank holds four 30 tADA outputs (seed withheld, so three fund them): the run's
# lowest total need 109950687 exceeds his total, short by less than one 30 tADA
# output. His preview and his create give one
# verdict, naming totals from the refusal itself, never typed; nothing is
# submitted and every wallet output stays live.
two_erin="$work/erin-actor"
erin=(--wallet-skey "$work/erin.skey")
run erin-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$two_erin" --blueprint "$blueprint" "${node[@]}" "${erin[@]}"
jq -e '.createRefusal == null' "$receipts/erin-preview.json" >/dev/null \
  || fail "erin's preview refuses a fundable wallet: $(jq -r .createRefusal "$receipts/erin-preview.json")"
erin_seed="$(field erin-preview .seed)"
run erin-create success -- create --process-time 120000 --retract-time 30000 \
  --seed "$erin_seed" --state-dir "$two_erin" --blueprint "$blueprint" "${node[@]}" "${erin[@]}"
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"]' \
  "$receipts/erin-create.json" >/dev/null || fail "erin's create did not publish the six references"
erin_token="$(field erin-create .stateToken)"
for ref_out in $(jq -r '.references[] | .output' "$receipts/erin-create.json"); do
  probe_one="$work/erin-ref-probe.json"
  "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ref_out" >"$probe_one"
  jq -e --arg r "$ref_out" 'any(.live[]; . == $r)' "$probe_one" >/dev/null \
    || fail "erin's reference $ref_out is not live"
done
say "erin's fragmented wallet completed; every reference is live"
erin_key="$(field erin-create .walletKeyHash)"
erin_journal="$(managed_journal "$two_erin" "$erin_token" "$erin_key")"
[ -f "$erin_journal" ] || fail "erin's create left no journal"
max_pub_inputs="$(jq -s '[.[] | select(.journalEvent == "prepared" and (.journalStep | startswith("publish-"))) | (.journalInputs // [] | length)] | max // 0' "$erin_journal")"
[ -n "$max_pub_inputs" ] || fail "erin's journal names no publication inputs"
[ "$max_pub_inputs" -ge 2 ] || fail "erin's publications all spent one input (max $max_pub_inputs)"
say "erin's create spent $max_pub_inputs inputs in one publication"
bob_erin="$work/bob-erin"
mkdir -p "$bob_erin"
run bob-erin-inspect success -- inspect --key keyEmpty --state-token "$erin_token" \
  --state-dir "$bob_erin" --blueprint "$blueprint" "${node[@]}"
[ "$(field bob-erin-inspect .leaf)" = unknown ] \
  || fail "bob did not read erin's registry from the token alone"
say "bob read erin's registry from the state token alone"

two_frank="$work/frank-actor"
frank=(--wallet-skey "$work/frank.skey")
run frank-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$two_frank" --blueprint "$blueprint" "${node[@]}" "${frank[@]}"
jq -e '(.createRefusal // "") | startswith("publication-unfunded")' "$receipts/frank-preview.json" >/dev/null \
  || fail "frank's preview does not refuse funding: $(jq -r .createRefusal "$receipts/frank-preview.json")"
frank_seed="$(field frank-preview .seed)"
frank_refusal="$(field frank-preview .createRefusal)"
frank_addr="$(field frank-preview .wallet)"
run frank-pub-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$two_frank" --blueprint "$blueprint" "${node[@]}" --wallet-address "$frank_addr"
[ "$(field frank-pub-preview .createRefusal)" = "$frank_refusal" ] \
  || fail "frank's public preview differs from his key preview: $(field frank-pub-preview .createRefusal) vs $frank_refusal"
say "frank's key and public previews agree"
run frank-create client-refusal -- create --process-time 120000 --retract-time 30000 \
  --seed "$frank_seed" --state-dir "$two_frank" --blueprint "$blueprint" "${node[@]}" "${frank[@]}"
[ "$(field frank-create .reason)" = "$frank_refusal" ] \
  || fail "frank's create refusal differs from his preview: $(field frank-create .reason) vs $frank_refusal"
# From the refusal's own numbers, never typed: the shortfall is positive and
# less than one 30 tADA output.
read -r frank_needed frank_held <<<"$(printf '%s' "$frank_refusal" | grep -oE '[0-9]+' | head -n 2 | tr '\n' ' ')"
[ -n "${frank_needed:-}" ] && [ -n "${frank_held:-}" ] \
  || fail "frank's refusal carries no numbers: $frank_refusal"
[ "$frank_needed" -gt "$frank_held" ] \
  || fail "frank's needed $frank_needed does not exceed held $frank_held"
[ "$((frank_needed - frank_held))" -le 30000000 ] \
  || fail "frank's shortfall exceeds one 30 tADA output: needed $frank_needed held $frank_held"
say "frank refused with one verdict: needed $frank_needed held $frank_held"
[ -z "$(managed_find "$two_frank" journal.jsonl)" ] || fail "the refused frank create wrote a journal"
[ -z "$(managed_find "$two_frank" registry.pending.json)" ] || fail "the refused frank create wrote a pending identity"
frank_probe="$work/frank-seed-probe.json"
"$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$frank_seed" >"$frank_probe"
jq -e --arg s "$frank_seed" 'any(.live[]; . == $s)' "$frank_probe" >/dev/null \
  || fail "frank's seed was spent by the refused create"
run frank-preview2 success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$two_frank" --blueprint "$blueprint" "${node[@]}" "${frank[@]}"
[ "$(field frank-preview2 .createRefusal)" = "$frank_refusal" ] \
  || fail "frank's wallet changed under the refused create"
say "the refused frank create left every wallet output unchanged"

# ------------------------------------------------------------------
# 7d. a one-output wallet with the state carrier reused (Grace)
# ------------------------------------------------------------------
# Grace holds one 200 tADA ada-only output and nothing else. Alice's create
# already published this release's state script, so Grace's create publishes
# none: the seed is her sole output (the largest, as today, so identities of
# creates from wallets with a live carrier do not change) and the boot is
# paid from it. Her preview reports no refusal and her create completes;
# every reference is live; Bob reads the registry from the token alone.
# Fails on base: the preview reports the NoFundingBesideSeed refusal and the
# create is refused before anything is submitted.
two_grace="$work/grace-actor"
grace=(--wallet-skey "$work/grace.skey")
run grace-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$two_grace" --blueprint "$blueprint" "${node[@]}" "${grace[@]}"
jq -e '.createRefusal == null' "$receipts/grace-preview.json" >/dev/null \
  || fail "grace's preview refuses a fundable one-output wallet: $(jq -r .createRefusal "$receipts/grace-preview.json")"
jq -e '.seedFrom == "output"' "$receipts/grace-preview.json" >/dev/null \
  || fail "grace's reused-carrier preview does not name an output seed: $(jq -r .seedFrom "$receipts/grace-preview.json")"
grace_seed="$(field grace-preview .seed)"
grace_token_preview="$(field grace-preview .stateToken)"
# The seed is her funded output, read from the chain at run time: live
# before the create (her wallet holds one output, funded 1x200 tADA).
grace_seed_probe="$work/grace-seed-probe.json"
"$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$grace_seed" >"$grace_seed_probe"
jq -e --arg s "$grace_seed" 'any(.live[]; . == $s)' "$grace_seed_probe" >/dev/null \
  || fail "grace's previewed seed $grace_seed is not live before her create"
# The story is the command with no seed flag: it boots from her sole output.
run grace-create success -- create --process-time 120000 --retract-time 30000 \
  --state-dir "$two_grace" --blueprint "$blueprint" "${node[@]}" "${grace[@]}"
[ "$(field grace-create .stateToken)" = "$grace_token_preview" ] \
  || fail "grace's create made another token: $(field grace-create .stateToken) vs $grace_token_preview"
[ "$(field grace-create .seed)" = "$grace_seed" ] \
  || fail "grace's create booted from another seed: $(field grace-create .seed) vs $grace_seed"
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"]' \
  "$receipts/grace-create.json" >/dev/null || fail "grace's create did not publish the six references"
grace_token="$(field grace-create .stateToken)"
for ref_out in $(jq -r '.references[] | .output' "$receipts/grace-create.json"); do
  probe_one="$work/grace-ref-probe.json"
  "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ref_out" >"$probe_one"
  jq -e --arg r "$ref_out" 'any(.live[]; . == $r)' "$probe_one" >/dev/null \
    || fail "grace's reference $ref_out is not live"
done
say "grace's one-output wallet with a reused carrier completed; every reference is live"
grace_key="$(field grace-create .walletKeyHash)"
grace_journal="$(managed_journal "$two_grace" "$grace_token" "$grace_key")"
[ -f "$grace_journal" ] || fail "grace's create left no journal"
bob_grace="$work/bob-grace"
mkdir -p "$bob_grace"
run bob-grace-inspect success -- inspect --key keyEmpty --state-token "$grace_token" \
  --state-dir "$bob_grace" --blueprint "$blueprint" "${node[@]}"
[ "$(field bob-grace-inspect .leaf)" = unknown ] \
  || fail "bob did not read grace's registry from the token alone"
say "bob read grace's registry from the state token alone"

# stderr_of NAME ARGS...: a command line the parser refuses before anything
# is read: exit 2 and a message on stderr, never a receipt.
stderr_of() {
  local name="$1" status=0 bin="$open_datum"
  shift
  [ "${1:-}" = registry ] && bin="$singular"
  "$bin" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  [ "$status" -eq 2 ] || fail "$name: exit $status, expected 2"
  [ ! -s "$receipts/$name.json" ] || fail "$name: a refused command line printed a receipt"
  say "$name: refused at parse"
}
before_inserts="$(journal_lines "$reg")"
stderr_of insert-bad-key insert --key-hex zz --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- '--key-hex is not base16' "$receipts/insert-bad-key.err" || fail "insert-bad-key: the refusal does not name the key"
stderr_of insert-deposit-below-minimum insert --key "$key" --deposit 1999999 \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- 'below the minimum of 2000000 lovelace' "$receipts/insert-deposit-below-minimum.err" \
  || fail "insert-deposit-below-minimum: the refusal does not name the minimum"
stderr_of insert-deposit-not-integer insert --key "$key" --deposit lots \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- 'not a whole number of lovelace' "$receipts/insert-deposit-not-integer.err" \
  || fail "insert-deposit-not-integer: the refusal does not name the deposit"
removed="--""envelope" # spelled apart: no line of the tree names the removed flag
stderr_of insert-removed-flag insert --key "$key" "$removed" "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- "$removed is not a flag singular reads" "$receipts/insert-removed-flag.err" \
  || fail "insert-removed-flag: the removed flag is still read"
for control in "--trace loud" "--trace-to stdout" "--trace-to file:" "--trace-format xml"; do
  read -r flag value <<<"$control"
  stderr_of "insert-trace-${flag#--}-unknown" insert --key "$key" --payload "$work/payload-insert.json" \
    "${common[@]}" "${node[@]}" "${alice[@]}" "$flag" "$value"
  grep -q -- "$flag is " "$receipts/insert-trace-${flag#--}-unknown.err" \
    || fail "insert $control: the refusal does not name the tracing control"
  ! grep -q -- "is not a flag singular reads" "$receipts/insert-trace-${flag#--}-unknown.err" \
    || fail "insert $control: the tracing control is not read"
done
stderr_of insert-without-token insert --key "$key" --payload "$work/payload-insert.json" \
  --state-dir "$reg" --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
grep -q -- '--state-token' "$receipts/insert-without-token.err" \
  || fail "insert-without-token: the refusal does not name the state token"
refused insert-payload-not-data client-refusal -- insert --key "$key" \
  --payload "$work/payload-bad.json" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.reason | contains("not Plutus data")' "$receipts/insert-payload-not-data.json" >/dev/null \
  || fail "insert-payload-not-data: the refusal does not name the payload"
# Narration cannot change a command: with standard error closed, the same
# refusal, narrated to standard error, ends in bounded time with the same
# receipt and exit status.
closed_status=0
timeout 120 "$open_datum" insert --key "$key" --payload "$work/payload-bad.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}" --trace how --trace-to stderr \
  >"$receipts/insert-closed-stderr.json" 2>&- || closed_status=$?
[ "$closed_status" -eq "$(exit_of client-refusal)" ] \
  || fail "insert with standard error closed: exit $closed_status, expected the client refusal's"
cmp -s <(jq -S . "$receipts/insert-payload-not-data.json") \
  <(jq -S . "$receipts/insert-closed-stderr.json") \
  || fail "insert with standard error closed: another receipt than with it open"
unminted="$state.$(printf '%064d' 0)"
refused insert-unknown-registry client-refusal -- insert --key "$key" \
  --payload "$work/payload-insert.json" --state-dir "$work/no-such-registry" --blueprint "$blueprint" \
  --state-token "$unminted" "${node[@]}" "${alice[@]}"
jq -e '.reason | startswith("state-token-not-found")' "$receipts/insert-unknown-registry.json" >/dev/null \
  || fail "insert-unknown-registry: the refusal is not state-token-not-found"
[ -z "$(managed_find "$work/no-such-registry" journal.jsonl)" ] || fail "insert-unknown-registry: a refused insert journalled"
[ "$(journal_lines "$reg")" = "$before_inserts" ] || fail "an insert refusal moved the target's journal"

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
run insert-preview success -- insert --preview --key "$key" --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" --wallet-address "$alice_addr"
preview_ok insert-preview booking
[ "$(tree_hash)" = "$tree_before" ] || fail "a preview changed the registry directory"
jq -e '.fold.feeBound > .booking.fee' "$receipts/insert-preview.json" >/dev/null \
  || fail "the fold bound does not exceed a booking fee"
status=0
"$open_datum" insert --preview --key "$key" --payload "$work/payload-insert.json" "${common[@]}" \
  "${node[@]}" --wallet-address "$alice_addr" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "an insert preview accepted a signing key (exit $status)"
# An allowance below the measured outlay stops the insert before it signs or
# sends anything.
refused insert-over-allowance client-refusal -- insert --key "$key" \
  --payload "$work/payload-insert.json" --max-outlay 1000000 "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.outlay.withinAllowance == false and .outlay.allowance == 1000000' \
  "$receipts/insert-over-allowance.json" >/dev/null || fail "the refusal does not state the outlay and the allowance"

[ ! -e "$reg/preimages" ] || fail "a refused booking left an envelope in the registry directory"

# The booking alone: alice's insert leaves its request pending, the mirror,
# the public root as it was, and names the deadline.
before="$(journal_lines "$reg")"
insert_journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
insert_before="$(journal_count "$insert_journal")"
files_before="$(local_files)"
run insert success -- insert --key "$key" --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert
booking_only insert "$insert_journal" "$insert_before" "$files_before"
[ "$(field insert .requester)" = "$alicekey" ] || fail "the booking's requester is not alice's key"
# The request carries the envelope the fold will deliver: the booking keeps
# nothing of it in the registry directory.
[ ! -e "$reg/preimages" ] || fail "the booking kept an envelope in the registry directory"
run inspect-pending success -- inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-pending .leaf)" = unknown ] || fail "inspect after a booking alone does not read the key unknown to the registry"
jq -e --argjson p "$process_time" --argjson r "$retract_time" --slurpfile b "$receipts/insert.json" '
  .processTime == $p and .retractTime == $r
  and ([.pendingRequests[] | select(.request == $b[0].request)] | length == 1)
  and ([.pendingRequests[] | select(.request == $b[0].request)][0].submittedAt + .processTime == $b[0].foldDeadline.posixMs)
' "$receipts/inspect-pending.json" >/dev/null \
  || fail "inspect did not read the chosen windows, or the booking deadline differs from its live submission time plus the processing window"
say "chosen registry windows read back; booking deadline is submission time plus the processing window"

# A-001: an unconverted processing deadline cannot prove opening and is
# refused before the window, naming when it opens.
refused reclaim-early client-refusal -- registry reclaim --request "$(field insert .request)" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e --slurpfile b "$receipts/insert.json" '
    .request == $b[0].request and (.reason | contains("before the window") and contains("retract window opens at") and contains($b[0].foldDeadline.posixMs | tostring))' \
  "$receipts/reclaim-early.json" >/dev/null || fail "the early reclaim did not name when the window opens"
refused reclaim-not-owner client-refusal -- registry reclaim --request "$(field insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e '.reason | contains("retract-owner") and contains("not the request\u0027s owner")' \
  "$receipts/reclaim-not-owner.json" >/dev/null || fail "another wallet's reclaim did not name the ownership refusal"

# The fold is bob's: another wallet folds alice's request, and the receipt
# names the same deadline and request. Its body's upper bound is the lesser
# of that deadline and the observed ledger horizon minus one.
run fold success -- fold --request "$(field insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
fold_ok() {
  local fold_part
  fold_part="$(managed_partition "$reg" "$state_token" "$(field "$1" .folder)")"
  jq -e --slurpfile b "$receipts/$2.json" '
      (.settled | length == 1)
      and .settled[0].request == $b[0].request and .foldDeadline.posixMs == $b[0].foldDeadline.posixMs
      and .folder != $b[0].requester and .settled[0].edge == "'"$3"'"
      and (.fold | test("^[0-9a-f]{64}$"))
      and (.validUntilSlot | type == "number")
      and (if .foldDeadline.slot != null then .validUntilSlot <= .foldDeadline.slot else true end)
      and (.hostClockMs + 30000 < .foldDeadline.posixMs)
      and (.remainingMs | type == "number" and . > 30000)' "$receipts/$1.json" >/dev/null \
    || fail "$1: the fold does not name the booking's request and deadline, or was signed by the booker"
  # Read the exact genesis bytes consumed by this body's prepared session,
  # rather than the facade's later current publication or the emitted horizon.
  jq -s -ce --arg tx "$(field "$1" .fold)" '
      [.[] | select(.journalEvent == "prepared" and .journalTxId == $tx)
        | .journalSession.rawSources[] | select(.kind == "raw-time")] | unique
      | if length == 1 then .[0] else error("fold has no unique raw time source") end' \
    "$fold_part/journal.jsonl" >"$receipts/$1.time-source.json" \
    || fail "$1: the prepared body has no exact pinned time source"
  jq -j "$(cat "$work/cbor.jq") .genesisHex | tobytes | implode" \
    "$receipts/$1.time-source.json" >"$receipts/$1.genesis.json"
  [ "$(sha256sum "$receipts/$1.genesis.json" | cut -d' ' -f1)" = "$(jq -r .genesisSha256 "$receipts/$1.time-source.json")" ] \
    || fail "$1: the consumed genesis bytes do not match their recorded hash"
  jq -s -e --arg tx "$(field "$1" .fold)" --slurpfile phases "$receipts/$1.phases.jsonl" '
      [$phases[] | select(.phase == "validityUpper")] as $selected
      | [.[] | select(.journalEvent == "prepared" and .journalTxId == $tx)] as $prepared
      | ($selected | length) == 1 and ($prepared | length) == 1
      and any($prepared[0].journalSession.facts[];
        .query == "Latest block observation" and .value.slot == $selected[0].tip)' \
    "$fold_part/journal.jsonl" >/dev/null \
    || fail "$1: the selected build tip is absent from the prepared body's actual observations"
  jq -s -e --slurpfile receipt "$receipts/$1.json" --slurpfile genesis "$receipts/$1.genesis.json" '
      [.[] | select(.phase == "validityUpper")] as $selected
      | ($selected | length) == 1
      and ($selected[0] as $s | $receipt[0] as $r | $genesis[0] as $g
        | ([$s.tip, $s.horizon, $s.effectiveLower, $s.windowUpper, $s.upper, $s.minimumSlots] | all(type == "number"))
        and $g.networkMagic == 42 and $g.securityParam > 0
        and $g.activeSlotsCoeff > 0 and $g.activeSlotsCoeff <= 1
        and $g.epochLength > 0 and $g.slotLength > 0
        and $s.horizon == (((($s.tip + ((3 * $g.securityParam / $g.activeSlotsCoeff) | ceil)) / $g.epochLength) | ceil) * $g.epochLength)
        and $s.windowUpper == $r.foldDeadline.slot
        and $s.upper == ([$s.windowUpper, ($s.horizon - 1)] | min)
        and $s.upper == $r.validUntilSlot
        and $s.effectiveLower == ([($s.lower // 0), ($s.tip + 1)] | max)
        and $s.minimumSlots == ((10 / $g.slotLength) | ceil)
        and ($s.upper - $s.effectiveLower) >= $s.minimumSlots)' \
    "$receipts/$1.phases.jsonl" >/dev/null \
    || fail "$1: the actual selection does not cap the deadline at the observed horizon with the required usable interval"
  jq -R -e --slurpfile receipt "$receipts/$1.json" \
    "$(cat "$work/cbor.jq") decode | .[0] | mapget(3) == \$receipt[0].validUntilSlot" \
    "$fold_part/submissions/$(field "$1" .fold).cbor.hex" >/dev/null \
    || fail "$1: the saved signed body's upper slot differs from the receipt and actual selection"
}
fold_ok fold insert insertActive
[ "$(field fold .folder)" = "$bobkey" ] || fail "alice's request was not folded with bob's key"
jq -e --slurpfile e "$receipts/insert.json" --arg k "$(hexof "$key")" '.settled[0].key == $k
  and .settled[0].settlement.envelope == $e[0].envelope
  and (.settled[0].settlement.liveOutput | test("#"))' \
  "$receipts/fold.json" >/dev/null || fail "the fold does not deliver alice's envelope at her key"
run inspect-1 success -- inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-1 .leaf)" = active ] || fail "inspect after insert is not active"
[ "$(field inspect-1 .root)" = "$(field fold .root)" ] || fail "inspect root differs from the fold's"
[ "$(field inspect-1 .root)" != "$(field inspect-pending .root)" ] || fail "the fold did not move the root"
holds_envelope inspect-1 .applicationOutput.envelope "$alicekey" "$key" "$work/payload-insert.json" \
  || fail "the holding's envelope is not the one the registry, the key, the caller and the payload make"
jq -e --slurpfile i "$receipts/insert.json" '.applicationOutput.envelope == $i[0].envelope' \
  "$receipts/inspect-1.json" >/dev/null || fail "the holding's envelope is not the one the insert receipt reports"
holds_envelope insert .envelope "$alicekey" "$key" "$work/payload-insert.json" \
  || fail "the insert receipt's envelope is not the one the sources make"
holds_envelope insert-preview .envelope "$alicekey" "$key" "$work/payload-insert.json" \
  || fail "the insert preview's envelope is not the one the sources make"
# bob, a wallet that did not create the registry, inserts his own key.
bkey=keyB
before="$(journal_lines "$reg")"
bob_insert_journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
bob_insert_before="$(journal_count "$bob_insert_journal")"
files_before="$(local_files)"
run bob-insert success -- insert --key "$bkey" --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
holds_envelope bob-insert .envelope "$bobkey" "$bkey" "$work/payload-insert.json" \
  || fail "bob's insert did not book his own key hash as controller"
booked bob-insert
booking_only bob-insert "$bob_insert_journal" "$bob_insert_before" "$files_before"
[ "$(field bob-insert .requester)" = "$bobkey" ] || fail "the booking's requester is not bob's key"
[ ! -e "$reg/preimages" ] || fail "bob's booking kept an envelope in the registry directory"
# A funding output the folder's wallet does not hold is refused by name too.
refused fold-bad-funding client-refusal -- fold --fund-input "$(printf '%064d' 0)#0" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.reason | contains("cannot fund the fold")' "$receipts/fold-bad-funding.json" >/dev/null \
  || fail "the fold with a stranger's funding output does not say so: $(field fold-bad-funding .reason)"
# Alice folds bob's insertion: the request is named by nothing but being the
# one pending.
run bob-fold success -- fold "${common[@]}" "${node[@]}" "${alice[@]}"
fold_ok bob-fold bob-insert insertActive
[ "$(field bob-fold .folder)" = "$alicekey" ] || fail "bob's request was not folded with alice's key"
run inspect-bob success -- inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-bob .leaf)" = active ] || fail "bob's key is not active"

# ------------------------------------------------------------------
# 3. update (alice), with its refusals
# ------------------------------------------------------------------
jq -n '{constructor:3, fields:[{bytes:"626f62"},{int:123456789012345678901234567890}]}' >"$work/payload.json"
refused update-not-controller client-refusal -- update --key "$key" \
  --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${bob[@]}"
tree_before="$(tree_hash)"
run update-preview success -- update --preview --key "$key" --payload "$work/payload.json" \
  "${common[@]}" "${node[@]}" --wallet-address "$alice_addr"
preview_ok update-preview update
[ "$(tree_hash)" = "$tree_before" ] || fail "an update preview changed the registry directory"
refused update-preview-not-controller client-refusal -- update --preview --key "$key" \
  --payload "$work/payload.json" "${common[@]}" "${node[@]}" --wallet-address "$bob_addr"
run update success -- update --key "$key" --payload "$work/payload.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
run inspect-2 success -- inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-2 .leaf)" = active ] || fail "inspect after update is not active"
[ "$(field inspect-2 .root)" = "$(field bob-fold .root)" ] || fail "the update moved the root"
jq -e --slurpfile p "$work/payload.json" '.applicationOutput.payload == $p[0]' \
  "$receipts/inspect-2.json" >/dev/null || fail "the holding does not carry the new payload"

# ------------------------------------------------------------------
# 4. process boundaries on the actual target
# ------------------------------------------------------------------
# Retired local trie files cannot influence this acquired public read.
printf 'corrupt mirror\n' >"$reg/registry.mirror.json"
printf 'corrupt saved root\n' >"$reg/state.json"
run inspect-retired-files success -- inspect --key "$key" "${common[@]}" "${node[@]}" \
  --wallet-address "$alice_addr"
jq -e --slurpfile before "$receipts/inspect-2.json" \
  '.leaf == $before[0].leaf and .root == $before[0].root' "$receipts/inspect-retired-files.json" >/dev/null \
  || fail "corrupt retired files changed the proven read"
[ "$(cat "$reg/registry.mirror.json")" = 'corrupt mirror' ] || fail "the retired mirror was rewritten"
[ "$(cat "$reg/state.json")" = 'corrupt saved root' ] || fail "the retired saved root was rewritten"
rm "$reg/registry.mirror.json" "$reg/state.json"
# A state token of another release: its policy is not this release's state
# script, refused by name before the provider is asked anything.
foreign="$(printf '%s' "$state" | tr 0123456789abcdef 123456789abcdef0).$token"
refused insert-foreign-release client-refusal -- insert --key keyC \
  --payload "$work/payload-insert.json" --state-dir "$reg" --blueprint "$blueprint" \
  --state-token "$foreign" "${node[@]}" "${alice[@]}"
jq -e '.reason | startswith("state-token-foreign-release")' "$receipts/insert-foreign-release.json" >/dev/null \
  || fail "insert-foreign-release: the refusal is not state-token-foreign-release"
# No node at all.
run inspect-no-node node-unavailable -- inspect --key "$key" "${common[@]}" \
  --koios-url http://127.0.0.1:1 --network-time "$time_directory" --network-magic "$network_magic"
[ "$(field inspect-no-node .leaf)" = null ] || fail "a leaf was printed with no node"
# A concurrent writer on the same target. An OS lock holder takes the
# target's actual lock (an fcntl open-file-description lock, which conflicts
# with the command's own fcntl lock) and is verified to hold it; the
# command is then refused without reading or submitting anything.
rm -f "$work/lock.held" "$work/lock.pid"
# The holding process is the exec'd sleep itself, so killing it releases
# the lock (the open-file description dies with its last holder).
alice_lock="$(managed_lock "$reg" "$state_token" "$alicekey")"
# shellcheck disable=SC2016 # $$ and $1 belong to the holder's own shell
flock --fcntl "$alice_lock" bash -c 'echo $$ > "$1/lock.pid"; touch "$1/lock.held"; exec sleep 120' _ "$work" &
holder=$!
for _ in $(seq 1 100); do
  [ -e "$work/lock.held" ] && break
  sleep 0.1
done
[ -e "$work/lock.held" ] || setup_fail "the lock holder never acquired $alice_lock"
if flock --fcntl --nonblock "$alice_lock" true; then
  setup_fail "the lock holder does not hold $alice_lock"
fi
refused concurrent-writer concurrent-writer -- insert --key keyC \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
kill "$(cat "$work/lock.pid")" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
holder=""
flock --fcntl --nonblock "$alice_lock" true || setup_fail "the lock holder did not release $alice_lock"
# The combined form: --fold books and then folds in the one process, by the
# routine `open-datum fold` runs, and prints both transactions.
run insert-after-release success -- insert --fold --key keyC \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '(.booking | test("^[0-9a-f]{64}$")) and (.fold | test("^[0-9a-f]{64}$")) and .booking != .fold
    and (.settled | length == 1)
    and (.settled[0].settlement.liveOutput | test("#")) and has("root")' "$receipts/insert-after-release.json" >/dev/null \
  || fail "the combined insert does not name its booking, its fold and the output it delivered"

# ------------------------------------------------------------------
# 5. terminate, killed after the node accepted its fold
# ------------------------------------------------------------------
refused terminate-not-controller client-refusal -- terminate --key "$key" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
tree_before="$(tree_hash)"
run terminate-preview success -- terminate --preview --key "$key" \
  "${common[@]}" "${node[@]}" --wallet-address "$alice_addr"
preview_ok terminate-preview booking
[ "$(tree_hash)" = "$tree_before" ] || fail "a terminate preview changed the registry directory"
# The recovery leg needs a node and a held writer at the same time: this
# controller owns the writer, its release marker and its joined cleanup.
if [ "$mode" = test-harness ]; then
  # The process is held by the marked harness point right after the node's
  # acceptance of its fold is journalled, and killed there.
  rm -f "$work/fold.go" "$work/fold.go.waiting"
  SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/fold.go" SINGULAR_HARNESS_HOLD_STEP=fold \
    "$open_datum" terminate --fold --key "$key" "${common[@]}" "${node[@]}" "${alice[@]}" \
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
  victim=""
  [ "$(tail -n 1 "$alice_journal" | jq -r '.journalStep + "/" + .journalEvent')" = fold/submitted ] \
    || fail "the killed process did not stop at its accepted fold"
  say "terminate killed after the node accepted its fold"
  fold_tx="$(tail -n 1 "$alice_journal" | jq -r .journalTxId)"
  # Recovery belongs to the owning wallet: only alice's public-address inspect
  # reconciles her journal, where the killed fold is journalled. Bob's later
  # write never touches her journal; it proceeds independently. While the fold
  # is not yet on chain the inspect is refused before reading anything new,
  # naming the fold and its case; it is then run again.
  first_recovery=""
  for _ in $(seq 1 60); do
    status=0
    "$open_datum" inspect --key "$key" "${common[@]}" "${node[@]}" \
      --wallet-address "$alice_addr" \
      >"$receipts/recover-alice-inspect.json" 2>"$receipts/recover-alice-inspect.err" || status=$?
    got="$(jq -r .outcome "$receipts/recover-alice-inspect.json")"
    [ -n "$first_recovery" ] || first_recovery="$got/$status"
    [ "$got/$status" = success/0 ] && break
    [ "$got/$status" = partial/15 ] || fail "recover-alice-inspect: outcome $got (exit $status)"
    [ "$(field recover-alice-inspect .unresolved.tx)" = "$fold_tx" ] \
      || fail "recover-alice-inspect: the refusal does not name the killed fold"
    [ "$(field recover-alice-inspect .unresolved.case)" = acknowledged ] \
      || fail "recover-alice-inspect: the refusal does not name the fold's case acknowledged"
    sleep 2
  done
  [ "$(field recover-alice-inspect .outcome)" = success ] \
    || fail "alice's inspect never recovered the killed fold"
  [ "$first_recovery" = success/0 ] \
    || [ "$first_recovery" = partial/15 ] \
    || fail "alice's first recovery attempt was neither partial nor success: $first_recovery"
  say "recover-alice-inspect: success, reconciling alice's killed fold in her own journal (first attempt $first_recovery)"
else
  run terminate-ordinary success -- terminate --fold --key "$key" \
    "${common[@]}" "${node[@]}" "${alice[@]}"
  fold_tx="$(field terminate-ordinary .fold)"
fi
# Bob's subsequent write proceeds independently on chain state that includes
# the fold. It must neither touch alice's journal nor claim her fold.
alice_kept="$(journal_count "$alice_journal")"
run bob-independent-update success -- update --key "$bkey" --payload "$work/payload.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
[ "$(journal_count "$alice_journal")" = "$alice_kept" ] \
  || fail "bob's write touched alice's journal"
[ "$(jq -r --arg t "$fold_tx" '.reconciled.observed // [] | index($t)' "$receipts/bob-independent-update.json")" = null ] \
  || fail "bob's write claimed alice's fold as its own recovery"
# Alice's key reads Terminal: the killed terminate's fold is on chain.
run inspect-3 success -- inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-3 .leaf)" = terminal ] || fail "the killed fold did not leave the key terminal"
jq -e '.applicationOutput.absent' "$receipts/inspect-3.json" >/dev/null || fail "the holding is still live"
# Public replay serves the included fold; alice's journal observes it exactly
# once and prepared it exactly once: no duplicate submission, no cross-wallet
# reconciliation.
[ "$(jq -s --arg t "$fold_tx" '[.[] | select(.journalTxId == $t and .journalEvent == "observed")] | length' "$alice_journal")" = 1 ] \
  || fail "the killed fold was not observed exactly once in its owning journal"
[ "$(jq -s --arg t "$fold_tx" '[.[] | select(.journalTxId == $t and .journalEvent == "prepared")] | length' "$alice_journal")" = 1 ] \
  || fail "the killed fold was prepared more than once"
if [ "$mode" = test-harness ]; then
  say "alice's inspect recovered the killed fold from the chain once; inspect reads it terminal"
else
  say "alice's inspect reads the confirmed fold terminal"
fi

# ------------------------------------------------------------------
# 6. terminate bob normally; a write works again
# ------------------------------------------------------------------
before="$(journal_lines "$reg")"
bob_term_journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
bob_term_before="$(journal_count "$bob_term_journal")"
files_before="$(local_files)"
run bob-terminate success -- terminate --key "$bkey" "${common[@]}" "${node[@]}" "${bob[@]}"
booked bob-terminate
booking_only bob-terminate "$bob_term_journal" "$bob_term_before" "$files_before"
jq -e '(.released | test("^[0-9a-f]{64}#[0-9]+$")) and (.deposit | type == "number" and . > 0)' \
  "$receipts/bob-terminate.json" >/dev/null \
  || fail "the termination booking does not name the live output its fold will release"
run inspect-bob-booked success -- inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-bob-booked .leaf)" = active ] || fail "bob's key is not still active after a termination booking alone"
# Alice folds bob's termination, naming the request.
run bob-terminate-fold success -- fold --request "$(field bob-terminate .request)" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
fold_ok bob-terminate-fold bob-terminate updateTerminal
[ "$(field bob-terminate-fold .folder)" = "$alicekey" ] || fail "bob's termination was not folded with alice's key"
[ "$(field bob-terminate-fold .settled[0].settlement.released)" = "$(field bob-terminate .released)" ] \
  || fail "the fold released another output than the booking named"
run inspect-4 success -- inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-4 .leaf)" = terminal ] || fail "bob's key is not terminal"

# Every prepared body names the actual acquisition and its consumed facts.
# Inspect separately reports the latest tip it observed, without a snapshot promise.
mapfile -t scopes_journals < <(managed_find "$reg" journal.jsonl)
for scopes_journal in "${scopes_journals[@]}"; do
  prepared_scopes "$(dirname "$scopes_journal")" | jq -e -s 'length > 0' >/dev/null \
    || fail "a write lacks its Unbound acquisition"
done
jq -e '(.observedTip | test("^[0-9]+\\.[0-9a-f]{64}$"))
  and (.sessionEvidence.binding == {kind:"Unbound"})' "$receipts/inspect-4.json" >/dev/null \
  || fail "inspect-4 lacks its actual latest observation and Unbound binding"
say "every write names its actual Unbound acquisition; inspect reports its separate latest observation"

# ------------------------------------------------------------------
# 7. create races and interruptions, on their own targets
# ------------------------------------------------------------------
# A race and interrupted boot require a concurrently held test process.
# The test carrier owns, releases/kills and joins it; release evidence runs
# the connected ordinary create separately and makes no crash-window claim.
if [ "$mode" = test-harness ]; then
  # Two creates race for one seed: the same wallet's second boot is held
  # after its pre-lock checks while the first completes; under the lock it
  # must re-check the target and refuse RegistryExists (demo1_cli_create_race.sh).
  race="${DEMO1_CREATE_RACE:-$(dirname "$0")/demo1_cli_create_race.sh}"
  status=0
  bash "$race" "$singular" "$open_datum" "$blueprint" "$provider_url" "$time_directory" "$network_magic" "$work/alice.skey" "$work/alice.skey" "$work/race" || status=$?
  case "$status" in
    0) ;;
    3) setup_fail "the create race never reached its target check" ;;
    *) fail "the create race control does not hold (exit $status)" ;;
  esac
  say "create race: the late create was refused RegistryExists; the first registry stands"

  # A create killed after its first accepted submission: a new create is
  # refused, and inspect reads the incomplete create from its journal.
  inter="$work/interrupted"
  run preview-inter success -- create --process-time 120000 --retract-time 30000 --preview --state-dir "$inter" \
    --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
  seed_i="$(field preview-inter .seed)"
  rm -f "$work/create.go" "$work/create.go.waiting"
  SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/create.go" SINGULAR_HARNESS_HOLD_STEP=boot \
    "$open_datum" create --process-time 120000 --retract-time 30000 --seed "$seed_i" --state-dir "$inter" --blueprint "$blueprint" \
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
  victim=""
  inter_token="$(field preview-inter .stateToken)"
  inter_journal="$(managed_journal "$inter" "$inter_token" "$alicekey")"
  inter_pending="$(managed_pending "$inter" "$inter_token" "$alicekey")"
  [ -f "$inter_pending" ] || setup_fail "the killed create left no managed pending identity"
  first_tx="$(jq -r 'select(.journalEvent == "submitted") | .journalTxId' "$inter_journal")"
  first_tx="${first_tx%%$'\n'*}"
  inter_lines="$(journal_lines "$inter")"
  run create-after-kill client-refusal -- create --process-time 120000 --retract-time 30000 --seed "$seed_i" --state-dir "$inter" \
    --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
  [ "$(journal_lines "$inter")" = "$inter_lines" ] || fail "a create after the kill submitted something"
  for _ in $(seq 1 60); do
    run inspect-interrupted partial -- inspect --key-hex 00 --state-dir "$inter" \
      --blueprint "$blueprint" --state-token "$inter_token" "${node[@]}" \
      --wallet-address "$alice_addr"
    jq -e --arg t "$first_tx" '.observed | index($t)' "$receipts/inspect-interrupted.json" >/dev/null && break
    sleep 2
  done
  jq -e '.incompleteCreate.seed' "$receipts/inspect-interrupted.json" >/dev/null \
    || fail "inspect did not read the incomplete create's identity"
  [ "$(jq -er .incompleteCreate.seed "$receipts/inspect-interrupted.json")" = "$seed_i" ] \
    || fail "the interrupted pending identity names another seed"
  [ "$(jq -er .incompleteCreate.stateToken "$receipts/inspect-interrupted.json")" = "$inter_token" ] \
    || fail "the interrupted pending identity names another token"
  [ "$(field inspect-interrupted .leaf)" = null ] || fail "an incomplete create printed a leaf"
  jq -e --arg t "$first_tx" 'select(.journalTxId == $t and .journalEvent == "observed")' \
    "$inter_journal" >/dev/null || fail "the killed create's accepted submission was never observed"
  # Registries cannot leak into each other: under partitioned state an inspect
  # under another token reads that registry alone and never sees the
  # interrupted partition. The interrupted pending identity stays intact.
  inter_kept="$(journal_count "$inter_journal")"
  run inspect-interrupted-other-token success -- inspect --key-hex 00 --state-dir "$inter" \
    --blueprint "$blueprint" --state-token "$state_token" "${node[@]}" \
    --wallet-address "$alice_addr"
  [ "$(field inspect-interrupted-other-token .leaf)" = unknown ] \
    || fail "another token's readback showed a leaf for an absent key"
  [ -f "$inter_pending" ] \
    || fail "another token's read disturbed the interrupted pending identity"
  [ "$(journal_count "$inter_journal")" = "$inter_kept" ] \
    || fail "another token's read moved the interrupted journal"
  say "an interrupted create is refused a second boot and read back from its journal"

fi

# A request nobody folds: alice books one more insertion and leaves it. The
# registry's fold takes every pending request, so this is the journey's last
# booking; the late fold below is its control.
before="$(journal_lines "$reg")"
late_journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
late_before="$(journal_count "$late_journal")"
files_before="$(local_files)"
run late-insert success -- insert --key keyD --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked late-insert
booking_only late-insert "$late_journal" "$late_before" "$files_before"

# A fold near its request's deadline. Within the margin a fold needs to be
# included, the client refuses it up front, by name, before it builds anything:
# nothing is signed, submitted or journalled. (The fold the guard admits is judged
# again from its built body, `postBuildDecision`, which a unit witness proves;
# on a development network that second check cannot be reached end to end,
# because near a window's end the library's own fallback times lie past the
# node's horizon and no fold is built there, #370.)
deadline_ms="$(field late-insert .foldDeadline.posixMs)"
margin_ms=30000
near_remaining_ms=$((margin_ms * 2 / 3))
wait_ms=$((deadline_ms - near_remaining_ms - $(date +%s%3N)))
[ "$wait_ms" -gt -10000 ] || setup_fail "the late request has less than 10 s of margin left: the near fold would meet the passed deadline instead"
if [ "$wait_ms" -gt 0 ]; then
  say "waiting $((wait_ms / 1000 + 1)) s until $((near_remaining_ms / 1000)) s of the late request's window remain"
  sleep $((wait_ms / 1000 + 1))
fi
refused fold-near client-refusal -- fold --request "$(field late-insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
fold_near_refused() {
  jq -e --slurpfile l "$receipts/late-insert.json" --argjson m "$margin_ms" '
    (.reason | capture("deadline, (?<dl>[0-9]+) ms, is before the probe bound (?<pb>[0-9]+) ms") // null) as $c
    | ($c != null)
    and ((($c.pb | tonumber) - $m < ($c.dl | tonumber)) and (($c.dl | tonumber) < ($c.pb | tonumber)))
    and (.reason | contains("is excluded: not-phase1 (model-refusal)") and contains($l[0].foldDeadline.posixMs | tostring))
    and .pendingRequest == $l[0].request
    and (.submissions | length == 0)' "$1" >/dev/null
}
fold_near_refused "$receipts/fold-near.json" \
  || fail "the fold near the deadline was not refused up front, by name, with nothing submitted: $(field fold-near .reason)"
fold_near_tamper() {
  jq "$2" "$receipts/fold-near.json" >"$receipts/fold-near-tampered-$1.json"
  if fold_near_refused "$receipts/fold-near-tampered-$1.json"; then
    fail "the near-fold receipt edited in $1 still passed its assertion"
  fi
}
fold_near_tamper expired-beyond-probe '.reason |= sub("processing deadline, [0-9]+ ms"; "processing deadline, 99999999999999 ms")'
say "a fold near the deadline: refused up front by the guard, naming it, nothing signed or submitted"

# ------------------------------------------------------------------
# 7b. a fold that comes too late
# ------------------------------------------------------------------
# The request booked above is folded by no one until its processing deadline
# has passed. A fold of it is then refused by the client, quickly and by
# name, before anything is signed: the reason names the deadline the booking
# stated.
deadline_ms="$(field late-insert .foldDeadline.posixMs)"
wait_ms=$((deadline_ms + 3000 - $(date +%s%3N)))
if [ "$wait_ms" -gt 0 ]; then
  say "waiting $((wait_ms / 1000 + 1)) s for the late request's processing deadline to pass"
  sleep $((wait_ms / 1000 + 1))
fi
started="$(date +%s)"
refused fold-late client-refusal -- fold --request "$(field late-insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
took=$(($(date +%s) - started))
fold_late_refused() {
  jq -e --slurpfile l "$receipts/late-insert.json" --argjson m "$margin_ms" '
    (.reason | capture("deadline, (?<dl>[0-9]+) ms, is before the probe bound (?<pb>[0-9]+) ms") // null) as $c
    | ($c != null)
    and ((($c.pb | tonumber) - $m >= ($c.dl | tonumber)))
    and (.reason | contains("is excluded: not-phase1 (model-refusal)") and contains("processing deadline") and contains($l[0].foldDeadline.posixMs | tostring))
    and .pendingRequest == $l[0].request' "$1" >/dev/null
}
fold_late_refused "$receipts/fold-late.json" \
  || fail "the late fold does not name the deadline and the request it left pending: $(field fold-late .reason)"
fold_late_tamper() {
  jq "$2" "$receipts/fold-late.json" >"$receipts/fold-late-tampered-$1.json"
  if fold_late_refused "$receipts/fold-late-tampered-$1.json"; then
    fail "the late-fold receipt edited in $1 still passed its assertion"
  fi
}
fold_late_tamper open-at-judgment '.reason |= sub("probe bound [0-9]+ ms"; "probe bound 1 ms")'
[ "$took" -le 30 ] || fail "the late fold took ${took}s to be refused; a client refusal reads one view and stops"

# The fold takes the selection (#518): the late request above is past its
# processing deadline and still pending. A fresh eligible insertion is
# booked beside it, and `registry fold` names no request: the fold settles
# the fresh one and leaves the late one out, named with its reason and its
# source. The earlier top-level single-request fields are gone; the settled
# list carries the facts, and the capacity bound of 9 states its provenance. Each new assertion is shown able to fail
# on a copy of the receipt altered so its property is false.
eligible_files="$(local_files)"
eligible_journal_before="$(journal_count "$alice_journal")"
run eligible-insert success -- insert --key keyH --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked eligible-insert
booking_only eligible-insert "$alice_journal" "$eligible_journal_before" "$eligible_files"
run fold-selection success -- registry fold "${common[@]}" "${node[@]}" "${bob[@]}"
fold_selection_settled() {
  jq -e --slurpfile e "$receipts/eligible-insert.json" --arg k "$(hexof keyH)" --arg owner "$alicekey" '
      (.settled | length == 1)
      and .settled[0].request == $e[0].request
      and .settled[0].key == $k and .settled[0].edge == "insertActive"
      and .settled[0].owner == $owner
      and (.settled[0].settlement.liveOutput | test("^[0-9a-f]{64}#[0-9]+$"))
      and (.settled[0].settlement.datumHash | type == "string" and length > 0)
      and .settled[0].deadline.posixMs == $e[0].foldDeadline.posixMs
      and (.settled[0].deadline.slot == $e[0].foldDeadline.slot)' "$1" >/dev/null
}
fold_selection_excluded() {
  jq -e --slurpfile l "$receipts/late-insert.json" '
      (.excluded | length == 1)
      and .excluded[0].request == $l[0].request
      and .excluded[0].reason == "not-phase1"
      and .excluded[0].source == "model-refusal"
      and (.excluded[0].detail | type == "string" and length > 0)' "$1" >/dev/null
}
fold_selection_earlier() {
  jq -e --slurpfile e "$receipts/eligible-insert.json" --arg k "$(hexof keyH)" --arg owner "$alicekey" '
      .capacity.bound == 9
      and (.capacity.provenance | startswith("an estimate, not a measurement"))
      and ([has("request"), has("key"), has("edge"), has("liveOutput"), has("envelope"), has("released"), has("deposit"), has("datumHash"), has("datumCbor")] | any | not)
      and (.fold | test("^[0-9a-f]{64}$"))
      and (.settled | length == 1)
      and .settled[0].request == $e[0].request
      and .settled[0].key == $k and .settled[0].edge == "insertActive"
      and .settled[0].owner == $owner
      and (.settled[0].settlement.liveOutput | test("^[0-9a-f]{64}#[0-9]+$"))
      and (.settled[0].settlement.datumHash | type == "string" and length > 0)
      and .settled[0].deadline.posixMs == $e[0].foldDeadline.posixMs' "$1" >/dev/null
}
fold_selection_settled "$receipts/fold-selection.json" \
  || fail "the fold's settled list is not exactly the fresh request: $(jq -c .settled "$receipts/fold-selection.json")"
fold_selection_excluded "$receipts/fold-selection.json" \
  || fail "the fold did not leave the late request out and named: $(jq -c .excluded "$receipts/fold-selection.json")"
fold_selection_earlier "$receipts/fold-selection.json" \
  || fail "the fold still prints an earlier single-request field, or its settled list does not carry the request: $(jq -c '{settled, excluded, capacity}' "$receipts/fold-selection.json")"
fold_selection_tamper() { # NAME JQ-EDIT FILTER
  jq "$2" "$receipts/fold-selection.json" >"$receipts/fold-selection-tampered-$1.json"
  if "$3" "$receipts/fold-selection-tampered-$1.json"; then
    fail "the fold-selection receipt edited in $1 still passed its assertion"
  fi
}
fold_selection_tamper settled-empty '.settled = []' fold_selection_settled
fold_selection_tamper reason-changed '.excluded[0].reason = "capacity"' fold_selection_excluded
fold_selection_tamper excluded-empty '.excluded = []' fold_selection_excluded
fold_selection_tamper earlier-request '.request = .excluded[0].request' fold_selection_earlier
fold_selection_tamper capacity-bound '.capacity.bound = 1' fold_selection_earlier
run inspect-eligible success -- inspect --key keyH "${common[@]}" "${node[@]}"
[ "$(field inspect-eligible .leaf)" = active ] \
  || fail "the fold's settled key did not read active: $(field inspect-eligible .leaf)"
jq -e --slurpfile l "$receipts/late-insert.json" '
    (.pendingRequests | length == 1) and .pendingRequests[0].request == $l[0].request' \
  "$receipts/inspect-eligible.json" >/dev/null \
  || fail "the late request is not the one request the registry still holds pending: $(jq -c .pendingRequests "$receipts/inspect-eligible.json")"
say "the fold settled the eligible request and left the late one out, named; the late one is still the only pending request"

# The same request is past its processing deadline but still inside its
# retract window, where its owner may take it back: a reject, which takes
# every pending request, is refused by the client before anything is signed,
# naming the request and when its retract window closes.
retract_ms="$(field inspect-pending .retractTime)"
retract_ends=$((deadline_ms + retract_ms))
[ "$(($(date +%s%3N) + 5000))" -lt "$retract_ends" ] \
  || setup_fail "the late request's retract window is nearly over: the early reject would meet the open reject"
refused reject-early client-refusal -- registry reject "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e --slurpfile l "$receipts/late-insert.json" --argjson e "$retract_ends" '
    (.reason | contains($l[0].request) and contains("retract window") and contains($e | tostring))
    and (.pendingRequests | length == 1)
    and .pendingRequests[0].request == $l[0].request
    and .pendingRequests[0].retractEnds == $e
    and .pendingRequests[0].processingEnds == $l[0].foldDeadline.posixMs
    and (.tipSlot | type == "number")
    and (.pendingRequests[0].unplaced | type == "boolean")
    and (.pendingRequests[0].retractEndsSlot == null or (.pendingRequests[0].retractEndsSlot | type == "number"))' \
  "$receipts/reject-early.json" >/dev/null \
  || fail "the early reject does not name the request and when its retract window closes: $(field reject-early .reason)"
run inspect-late success -- inspect --key keyD "${common[@]}" "${node[@]}"
[ "$(field inspect-late .leaf)" = unknown ] || fail "the refused late fold moved the registry"
say "a fold after the deadline: refused in ${took}s, naming the deadline; its request stays pending"

# ------------------------------------------------------------------
# 7c. reject: the request nobody folded or took back is cleared
# ------------------------------------------------------------------
# Past both windows the request can only be rejected, and while it stays
# pending the registry's fold, which takes every pending request, is
# blocked. Bob rejects it with his own wallet: the whole refund goes to the
# owner in the output designated for it, the receipt names what was locked,
# what the folder kept and what went to whom, and the root does not move.
wait_ms=$((retract_ends + 3000 - $(date +%s%3N)))
if [ "$wait_ms" -gt 0 ]; then
  say "waiting $((wait_ms / 1000 + 1)) s for the late request's retract window to close"
  sleep $((wait_ms / 1000 + 1))
fi
root_before="$(field inspect-late .root)"
before="$(journal_lines "$reg")"
reject_before="$(journal_count "$bob_main_journal")"
files_before="$(local_files)"
refused reclaim-closed client-refusal -- registry reclaim --request "$(field late-insert .request)" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.reason | contains("closed") and contains("registry reject")' \
  "$receipts/reclaim-closed.json" >/dev/null || fail "a reclaim after its window did not name its closure and reject"
# A funding output the rejecting wallet does not hold is refused by name, before
# anything is signed.
refused reject-bad-funding client-refusal -- registry reject --fund-input "$(printf '%064d' 0)#0" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e '.reason | contains("cannot fund the reject")' "$receipts/reject-bad-funding.json" >/dev/null \
  || fail "the reject with a stranger's funding output does not say so: $(field reject-bad-funding .reason)"
# What the node holds before the reject: the pending request and what it actually locks.
run inspect-before-reject success -- inspect --key keyD "${common[@]}" "${node[@]}"
run reject success -- registry reject "${common[@]}" "${node[@]}" "${bob[@]}"
[ "$(local_files)" = "$files_before" ] || fail "a reject altered identity or created retired trie files"
[ "$((($(journal_lines "$reg")) - before))" -eq 4 ] \
  || fail "the reject left $((($(journal_lines "$reg")) - before)) journal lines, expected its four phases"
tail -n +"$((reject_before + 1))" "$bob_main_journal" \
  | jq -s -e --arg t "$(field reject .reject)" '(map(.journalEvent) == ["prepared", "submitted", "confirmed", "observed"]) and (map(.journalStep) | unique == ["reject"]) and (map(.journalTxId) | unique == [$t])' >/dev/null \
  || fail "the journal lines the reject left are not one reject's prepared, submitted, confirmed and observed"
jq -e --slurpfile l "$receipts/late-insert.json" --arg bob "$bobkey" --arg owner "$alicekey" --arg addr "$alice_addr" --arg k "$(hexof keyD)" '
    (.reject | test("^[0-9a-f]{64}$")) and .rejector == $bob
    and (.rejected | length == 1)
    and (.rejected[0] as $r
      | $r.request == $l[0].request and $r.owner == $owner and $r.key == $k
      and $r.returned.recipient == $addr)
    and .root == "'"$root_before"'"' "$receipts/reject.json" >/dev/null \
  || fail "the reject receipt does not name the request, its owner and key, and the owner's address: $(jq -c .rejected "$receipts/reject.json")"
# The receipt's money is bound to what the chain and the signed transactions say,
# read apart from the receipt and from the reject command:
#  - each saved signed body is bound to its claim: the transaction id the receipt
#    claims is the hash of that body's own bytes, and the file's bytes hash to
#    the journal's saved-body hash;
#  - the request's locked value as the node held it before the reject, and the
#    designated refund output as the node holds it afterwards (output reference,
#    address and amount), read by `open-datum inspect` from the node;
#  - the tip, and the designated output's index and address, from the reject's
#    own signed body (state datum and outputs).
# A receipt that differs in any of them turns the journey red, and each binding is
# shown able to fail.
# What the node holds after the reject: the outputs at the owner's address.
run inspect-refund success -- inspect --key keyD --outputs-at "$alice_addr" "${common[@]}" "${node[@]}"
reject_tx="$(field reject .reject)"
booking_tx="$(field late-insert .booking)"
for t in "$reject_tx" "$booking_tx"; do
  case "$t" in
    "$reject_tx") j="$bob_main_journal" ;;
    *) j="$alice_journal" ;;
  esac
  [ "$(jq -s --arg t "$t" '[.[] | select(.journalTxId == $t and .journalEvent == "confirmed")] | length' "$j")" = 1 ] \
    || fail "the journal does not show $t confirmed"
done
# body_bound TXID FILE JOURNAL: zero only when FILE's body hashes to TXID
# and its bytes to JOURNAL's saved-body hash. The journal is bound
# explicitly: deriving it from the candidate file turns a tampered body
# outside any partition into a missing-evidence setup error instead of the
# claimed mismatch.
body_bound() {
  local id file="$2" journal="$3" computed saved
  [ -r "$journal" ] || return 1
  computed="$(jq -R -r "$(cat "$work/cbor.jq") body_span" "$file" | tr -d '\n' | tr a-f A-F | basenc --base16 -d | b2sum -l 256 | cut -d' ' -f1)" || return 1
  saved="$(tr -d '\n' <"$file" | tr a-f A-F | basenc --base16 -d | b2sum -l 256 | cut -d' ' -f1)" || return 1
  id="$(jq -r --arg t "$1" 'select(.journalTxId == $t and .journalEvent == "prepared") | .journalBodyHash' "$journal")"
  [ "$computed" = "$1" ] && [ -n "$id" ] && [ "$saved" = "$id" ]
}
for t in "$reject_tx" "$booking_tx"; do
  case "$t" in
    "$reject_tx") j="$bob_main_journal" ;;
    *) j="$alice_journal" ;;
  esac
  body_bound "$t" "$(managed_body "$reg" "$t")" "$j" || fail "the saved body of $t is not the transaction it is claimed to be"
done
flip() { # one hex digit changed
  local c="${1:0:1}"
  [ "$c" = 0 ] && c=1 || c=0
  printf '%s%s' "$c" "${1:1}"
}
body_bound "$(flip "$reject_tx")" "$(managed_body "$reg" "$reject_tx")" "$bob_main_journal" \
  && fail "a body passed for a transaction id that is not its own"
# the same bytes with their last digit changed no longer match the journal's hash
# (the id, a hash of the body alone, still does)
body="$(cat "$(managed_body "$reg" "$reject_tx")")"
if [ "${body: -1}" = 0 ]; then last=1; else last=0; fi
printf "%s%s" "${body%?}" "$last" >"$work/body-tampered.hex"
cmp_status=0
cmp -s "$work/body-tampered.hex" "$(managed_body "$reg" "$reject_tx")" \
  || cmp_status=$?
case "$cmp_status" in
  0) setup_fail "the tampered body equals the saved one" ;;
  1) ;;
  *) setup_fail "the tampered body comparison could not run" ;;
esac
body_bound "$reject_tx" "$work/body-tampered.hex" "$bob_main_journal" \
  && fail "a body with changed bytes passed the journal's saved-body hash"
booking_outs="$(tx_outputs_of "$booking_tx")" || fail "the booking's saved body could not be read"
reject_outs="$(tx_outputs_of "$reject_tx")" || fail "the reject's saved body could not be read"
# What the node held before the reject, and holds after it
node_pending="$(jq -c --arg r "$(field late-insert .request)" '[.pendingRequests[] | select(.request == $r)]' "$receipts/inspect-before-reject.json")"
node_refunds="$(jq -c '.outputsAt.outputs' "$receipts/inspect-refund.json")"
[ "$(jq 'length' <<<"$node_pending")" = 1 ] || fail "the node did not show the late request pending before the reject: $node_pending"
# reject_bound RECEIPT NODE_PENDING NODE_REFUNDS: every binding; zero only when all hold.
reject_bound() {
  jq -e --argjson bo "$booking_outs" --argjson ro "$reject_outs" --argjson np "$2" --argjson nr "$3" \
    --arg owner "$alicekey" --arg tx "$reject_tx" '
      $bo[0] as $req | $ro[0].datum.value[0].value[1] as $tip | .rejected[0] as $r
      | ($req.coin | type == "number") and ($tip | type == "number")
      and $r.locked.lovelace == $req.coin
      and $r.locked.assets == [$req.assets[] | {policy, name, quantity}]
      and ($np | length == 1) and $r.locked == $np[0].locked and $r.request == $np[0].request
      and $r.tip == $tip
      and $r.returned.index >= 1 and $ro[$r.returned.index] != null
      and $r.returned.output == ($tx + "#" + ($r.returned.index | tostring))
      and $ro[$r.returned.index].address == ("60" + $owner)
      and $ro[$r.returned.index].coin == $r.returned.lovelace
      and ([$nr[] | select(.output == $r.returned.output and .locked.lovelace == $r.returned.lovelace)] | length == 1)
      and $r.returned.lovelace == ($req.coin - $tip)
      and $r.topUp == ([$r.returned.lovelace - ($req.coin - $tip), 0] | max)
      and $r.owner == $owner' "$1" >/dev/null
}
reject_bound "$receipts/reject.json" "$node_pending" "$node_refunds" \
  || fail "the reject receipt's money differs from the chain and the signed transactions: receipt $(jq -c '.rejected[0] | {locked, tip, returned, topUp}' "$receipts/reject.json"); node before $node_pending; node after $node_refunds; reject outputs $(jq -c 'map({address, coin})' <<<"$reject_outs") tip $(jq -c '.[0].datum.value[0].value[1]' <<<"$reject_outs")"
# Each binding can fail: a receipt edited in any one money field, or a node read
# that differs from it, is refused.
tamper() { # NAME JQ-EDIT
  jq "$2" "$receipts/reject.json" >"$receipts/reject-tampered-$1.json"
  if reject_bound "$receipts/reject-tampered-$1.json" "$node_pending" "$node_refunds"; then
    fail "a reject receipt edited in $1 still passed the independent bindings"
  fi
}
tamper locked '.rejected[0].locked.lovelace += 1'
tamper locked-assets '.rejected[0].locked.assets = []'
tamper tip '.rejected[0].tip += 1'
tamper returned '.rejected[0].returned.lovelace += 1'
tamper top-up '.rejected[0].topUp += 1'
# shellcheck disable=SC2016 # Single quotes preserve the jq program's variable.
tamper index '.rejected[0].returned as $x | .rejected[0].returned.index = ($x.index + 1) | .rejected[0].returned.output = (($x.output | sub("#[0-9]+$"; "")) + "#" + (($x.index + 1) | tostring))'
tamper index-only '.rejected[0].returned.index += 1'
tamper output '.rejected[0].returned.output |= sub("#[0-9]+$"; "#9")'
tamper owner '.rejected[0].owner = "'"$bobkey"'"'
# a node read that disagrees with the receipt fails it just as well
if reject_bound "$receipts/reject.json" "$(jq -c '.[0].locked.lovelace += 1' <<<"$node_pending")" "$node_refunds"; then
  fail "a node read of another locked value still passed the bindings"
fi
if reject_bound "$receipts/reject.json" "$node_pending" "$(jq -c --arg o "$(field reject .rejected[0].returned.output)" 'map(if .output == $o then .locked.lovelace += 1 else . end)' <<<"$node_refunds")"; then
  fail "a node read of another refund amount still passed the bindings"
fi
if reject_bound "$receipts/reject.json" "$node_pending" "$(jq -c --arg o "$(field reject .rejected[0].returned.output)" 'map(if .output == $o then .output |= sub("#[0-9]+$"; "#9") else . end)' <<<"$node_refunds")"; then
  fail "a node read of another output reference still passed the bindings"
fi
say "the reject receipt's money equals the signed transactions' (locked, tip, designated output), and each edit of it fails"
# The refund stays at the owner's address and the root has not moved.
run inspect-rejected success -- inspect --key keyD "${common[@]}" "${node[@]}"
[ "$(field inspect-rejected .root)" = "$root_before" ] || fail "the reject moved the registry's root"
[ "$(field inspect-rejected .leaf)" = unknown ] || fail "the rejected request's key is not unknown"
refused fold-after-reject client-refusal -- fold "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e '.reason | contains("nothing is pending")' "$receipts/fold-after-reject.json" >/dev/null \
  || fail "after the reject something is still pending: $(field fold-after-reject .reason)"
refused reject-nothing client-refusal -- registry reject "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e '.reason | contains("nothing is pending")' "$receipts/reject-nothing.json" >/dev/null \
  || fail "a reject with nothing pending does not say so: $(field reject-nothing .reason)"
# Cleared, the registry folds again: a new request is booked and folded.
run insert-after-reject success -- insert --key keyE --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert-after-reject
run fold-after-insert success -- fold --request "$(field insert-after-reject .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
fold_ok fold-after-insert insert-after-reject insertActive
run inspect-after-reject success -- inspect --key keyE "${common[@]}" "${node[@]}"
[ "$(field inspect-after-reject .leaf)" = active ] || fail "the fold after the reject did not make its key active"
say "a reject past both windows: refunded to the owner, root unmoved, and a new request folds"

# ------------------------------------------------------------------
# 7d. reclaim: the owner takes a pending insertion back in its window
# ------------------------------------------------------------------
run insert-to-reclaim success -- insert --key keyF --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert-to-reclaim
run inspect-before-reclaim success -- inspect --key keyF "${common[@]}" "${node[@]}"
root_before="$(field inspect-before-reclaim .root)"
files_before="$(local_files)"
before="$(journal_lines "$reg")"
reclaim_before="$(journal_count "$alice_journal")"
deadline_ms="$(field insert-to-reclaim .foldDeadline.posixMs)"
wait_ms=$((deadline_ms + 1 - $(date +%s%3N)))
if [ "$wait_ms" -gt 0 ]; then
  say "waiting $wait_ms ms to attempt the owner's reclaim; the command judges the window from its own view"
  sleep "$((wait_ms / 1000)).$(printf '%03d' "$((wait_ms % 1000))")"
fi
refused fold-before-reclaim client-refusal -- fold --request "$(field insert-to-reclaim .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e --slurpfile l "$receipts/insert-to-reclaim.json" '
    (.reason | contains("is excluded: not-phase1 (model-refusal)") and contains("processing deadline") and contains($l[0].foldDeadline.posixMs | tostring))
    and .pendingRequest == $l[0].request' \
  "$receipts/fold-before-reclaim.json" >/dev/null || fail "the fold before reclaim was not refused for its deadline"
# A build failure, an unconverted window or a ledger refusal fails this success
# assertion. None can stand in for a reclaim or for a named refusal control.
run reclaim success -- registry reclaim --request "$(field insert-to-reclaim .request)" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
[ "$(local_files)" = "$files_before" ] || fail "the reclaim altered identity or created retired trie files"
tail -n +"$((reclaim_before + 1))" "$alice_journal" \
  | jq -s -e --arg t "$(field reclaim .retract)" '
      map(.journalEvent) == ["prepared", "submitted", "confirmed", "observed"]
      and (map(.journalStep) | unique == ["reclaim"])
      and (map(.journalTxId) | unique == [$t])' >/dev/null \
  || fail "reclaim did not leave exactly its four journal phases"
run inspect-after-reclaim success -- inspect --key keyF --outputs-at "$alice_addr" "${common[@]}" "${node[@]}"
retract_tx="$(field reclaim .retract)"
booking_tx="$(field insert-to-reclaim .booking)"
body_bound "$retract_tx" "$(managed_body "$reg" "$retract_tx")" "$alice_journal" || fail "the retract body is not the transaction claimed"
body_bound "$booking_tx" "$(managed_body "$reg" "$booking_tx")" "$alice_journal" || fail "the reclaimed booking body is not the transaction claimed"
retract_outs="$(tx_outputs_of "$retract_tx")"
booking_outs="$(tx_outputs_of "$booking_tx")"
node_pending="$(jq -c --arg r "$(field insert-to-reclaim .request)" '[.pendingRequests[] | select(.request == $r)]' "$receipts/inspect-before-reclaim.json")"
node_returns="$(jq -c '.outputsAt.outputs' "$receipts/inspect-after-reclaim.json")"
reclaim_bound() {
  jq -e --argjson bo "$booking_outs" --argjson ro "$retract_outs" --argjson np "$2" --argjson nr "$3" \
    --arg owner "$alicekey" --arg addr "$alice_addr" --arg tx "$retract_tx" --arg booking "$booking_tx" '
      . as $r | $bo[0] as $req | $ro[0] as $return
      | ($np | length == 1) and $r.request == $np[0].request and $r.locked == $np[0].locked
      and $r.locked.lovelace == $req.coin and $r.locked.assets == $req.assets
      and $r.retract == $tx and $r.owner == $owner
      and $r.returned.index == 0 and $r.returned.output == ($tx + "#0")
      and $r.returned.recipient == $addr and $return.address == ("60" + $owner)
      and $r.returned.lovelace == $return.coin and $return.coin >= $req.coin
      and $r.returned.value == {lovelace:$return.coin, assets:$return.assets}
      and $r.returned.request == $r.request and $return.datum.value == [$booking, 0]
      and ([$nr[] | select(.output == $r.returned.output and .locked == $r.returned.value)] | length == 1)
      and $r.topUp == ($return.coin - $req.coin)
      and .processingEndsSlot <= .tipSlot
      and (.retractEndsSlot == null or .tipSlot < .retractEndsSlot)' "$1" >/dev/null
}
reclaim_bound "$receipts/reclaim.json" "$node_pending" "$node_returns" \
  || fail "the reclaim receipt differs from its signed body or the independent before/after node reads"
for edit in '.locked.lovelace += 1' '.locked.assets += [{policy:"00",name:"00",quantity:1}]' '.returned.lovelace += 1' '.returned.index += 1' '.returned.output |= sub("#0$"; "#9")' '.returned.request |= sub("#0$"; "#9")' '.returned.recipient = "another address"' '.topUp += 1'; do
  jq "$edit" "$receipts/reclaim.json" >"$receipts/reclaim-tampered.json"
  if reclaim_bound "$receipts/reclaim-tampered.json" "$node_pending" "$node_returns"; then
    fail "a reclaim receipt edited by $edit passed the independent bindings"
  fi
done
if reclaim_bound "$receipts/reclaim.json" "$(jq -c '.[0].locked.lovelace += 1' <<<"$node_pending")" "$node_returns"; then
  fail "another locked value read by the node passed the reclaim bindings"
fi
if reclaim_bound "$receipts/reclaim.json" "$node_pending" "$(jq -c --arg o "$retract_tx#0" 'map(if .output == $o then .locked.lovelace += 1 else . end)' <<<"$node_returns")"; then
  fail "another return amount read by the node passed the reclaim bindings"
fi
[ "$(field inspect-after-reclaim .root)" = "$root_before" ] || fail "the reclaim moved the root"
[ "$(field inspect-after-reclaim .leaf)" = unknown ] || fail "the reclaimed key became registered"
refused reclaim-not-pending client-refusal -- registry reclaim --request "$(field insert-to-reclaim .request)" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.reason | contains("not pending")' "$receipts/reclaim-not-pending.json" >/dev/null || fail "a consumed request was not refused as not pending"
run insert-after-reclaim success -- insert --key keyG --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert-after-reclaim
run fold-after-reclaim success -- fold --request "$(field insert-after-reclaim .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
fold_ok fold-after-reclaim insert-after-reclaim insertActive
run inspect-after-reclaim-fold success -- inspect --key keyG "${common[@]}" "${node[@]}"
[ "$(field inspect-after-reclaim-fold .leaf)" = active ] || fail "a new request did not fold after reclaim"
say "the owner's reclaim: whole bound return checked independently, root unchanged, and a new request folds"

# ------------------------------------------------------------------
# 7e. the registry page after the lifecycle agrees with the readback
# ------------------------------------------------------------------
# The receipt's describe command reads the page again as JSON; its six facts
# equal the final inspect receipt and this registry's own fold receipts,
# every value read at run time, never typed. The read leaves the actor's
# state directory exactly as it was. This runs only where the page steps ran
# after create; elsewhere it is skipped silently (the skip line above is the
# record).
if [ "$page_steps_run" = 1 ]; then
  describe_tree_before="$(cd "$reg" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  path_before="$PATH"
  PATH="$work/archive-bin:$PATH"
  describe_status=0
  eval "$describe_cmd --json" >"$receipts/describe-final.json" 2>"$receipts/describe-final.err" || describe_status=$?
  PATH="$path_before"
  [ "$describe_status" -eq 0 ] || fail "the printed describe command failed after the lifecycle: $(tail -n 3 "$receipts/describe-final.json" "$receipts/describe-final.err" | tr '\n' ' ')"
  describe_tree_after="$(cd "$reg" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  [ "$describe_tree_after" = "$describe_tree_before" ] || fail "a page read changed the actor's state directory"
  # Every named fold receipt names a real fold transaction.
  for f in "${main_folds[@]}"; do
    if [ -e "$receipts/$f.json" ]; then
      jq -e '.fold | test("^[0-9a-f]{64}$")' "$receipts/$f.json" >/dev/null \
        || fail "the fold receipt $f names no fold transaction"
    fi
  done
  # The test-harness path's killed terminate fold never printed a receipt; its
  # settled edge enters from the journal line where it was accepted.
  killed_folds=0
  if [ "$mode" = test-harness ]; then
    jq -e --arg t "$fold_tx" 'select(.journalTxId == $t and .journalEvent == "submitted" and .journalStep == "fold")' "$alice_journal" >/dev/null \
      || fail "the killed fold left no submitted journal line"
    killed_folds=1
  fi
  final_counts="$({
    main_fold_settled
    if [ "$killed_folds" = 1 ]; then jq -n --arg k "$(hexof "$key")" '{key: $k, edge: "updateTerminal"}'; fi
  } | jq -s -c 'reduce .[] as $s ({}; .[$s.key] = $s.edge) | {active: ([to_entries[] | select(.value == "insertActive")] | length), terminal: ([to_entries[] | select(.value == "updateTerminal")] | length)}')"
  final_active="$(jq -r .active <<<"$final_counts")"
  final_terminal="$(jq -r .terminal <<<"$final_counts")"
  # The reject spends the live state output and recreates it with the same
  # root, so the lineage counts it as a fold since create; the reclaim spends
  # no state output. Both facts are read from this run's saved bodies: the
  # state outputs are create's and each fold's own output zero, a layout both
  # pages prove on this run through their live state outputs.
  create_out="$(jq -r .state.createTransaction "$receipts/describe-after-create.json")#0"
  [ "$create_out" != "null#0" ] || fail "the after-create page names no create transaction"
  state_outputs=("$create_out")
  for f in "${main_folds[@]}"; do
    if [ -e "$receipts/$f.json" ]; then
      state_outputs+=("$(field "$f" .fold)#0")
    fi
  done
  reject_tx="$(field reject .reject)"
  [ "$reject_tx" != "null" ] && [ -n "$reject_tx" ] || fail "the reject receipt names no transaction"
  reject_folds=0
  for out in "${state_outputs[@]}"; do
    if tx_inputs_of "$reject_tx" | grep -qxF "$out"; then
      reject_folds=1
      break
    fi
  done
  [ "$reject_folds" = 1 ] || fail "the reject spent no state output of this registry"
  final_folds=$(($(main_fold_count) + killed_folds + reject_folds))
  [ "$final_folds" -gt 1 ] || fail "the fold history holds $final_folds folds; the comparison needs more than one"
  last_fold="$(field fold-after-reclaim .fold)"
  [ "$last_fold" != "null" ] && [ -n "$last_fold" ] || fail "the last fold receipt names no fold transaction"
  page_agrees "$receipts/describe-final.json" "$receipts/inspect-after-reclaim-fold.json" "$last_fold" "$final_active" "$final_terminal" "$final_folds" \
    || fail "the page after the lifecycle differs from the inspect and fold receipts"
  [ "$(jq -r .state.root "$receipts/describe-final.json")" = "$(field fold-after-reclaim .root)" ] \
    || fail "the page root differs from the last fold's root"
  say "the page after the lifecycle agrees with the readback: $final_active active, $final_terminal terminal, $final_folds folds, last $last_fold"
  page_tamper_demo "$receipts/describe-final.json" "$receipts/inspect-after-reclaim-fold.json" "$last_fold" "$final_active" "$final_terminal" "$final_folds"
  say "a planted difference in any final fact fails the page comparison"
fi

# Local journal roots/edges are not trie reconstruction material. Copies of
# the settled registry with those records omitted or altered prove the same key.
boot_tx="$(jq -sr '[.[] | select(.journalEvent == "prepared" and .journalStep == "boot")] | first | .journalTxId' "$alice_journal")"
# Tampering follows the create journal's relative path: the copy preserves
# the managed layout, so the same relative partition is rewritten in it.
create_rel="$(realpath --relative-to="$reg" "$alice_journal")"
for fault in missing-create missing-change broken-before wrong-after undecodable-edge; do
  copy="$work/coverage-$fault"
  cp -a "$reg" "$copy"
  case "$fault" in
    missing-create)
      jq -c --arg tx "$boot_tx" 'select(.journalTxId != $tx)' "$alice_journal" >"$copy/$create_rel"
      ;;
    missing-change)
      jq -c 'select(.journalEdge == null)' "$alice_journal" >"$copy/$create_rel"
      ;;
    broken-before)
      jq -c 'if .journalEvent == "prepared" then .journalRootBefore = "not-hex" else . end' "$alice_journal" >"$copy/$create_rel"
      ;;
    wrong-after)
      jq -c 'if .journalEvent == "prepared" then .journalRootAfter = "not-hex" else . end' "$alice_journal" >"$copy/$create_rel"
      ;;
    undecodable-edge)
      jq -c 'if .journalEvent == "prepared" then .journalEdge = 99 else . end' "$alice_journal" >"$copy/$create_rel"
      ;;
  esac
  run "trie-local-$fault" success -- inspect --key keyG --state-dir "$copy" \
    --blueprint "$blueprint" --state-token "$state_token" "${node[@]}" \
    --wallet-address "$alice_addr"
  jq -e --slurpfile correct "$receipts/inspect-after-reclaim-fold.json" \
    '.leaf == $correct[0].leaf and .root == $correct[0].root' "$receipts/trie-local-$fault.json" >/dev/null \
    || fail "altered local journal trie records changed the public read: $fault"
done
say "public history replay serves the same key despite omitted or altered local trie records"

# A real successful read with the harness entirely absent still returns the
# same key/leaf/root. It is separate from the instrumented extent, and preserves
# the release's existing proof that ordinary processes run without hooks.
status=0
env -u SINGULAR_HARNESS_TRIE_TRACE "$open_datum" inspect --key keyG \
  "${common[@]}" "${node[@]}" >"$receipts/trie-plain-inspect.json" 2>"$receipts/trie-plain-inspect.err" || status=$?
[ "$status" -eq 0 ] || fail "the ordinary untraced inspect did not succeed"
jq -e --slurpfile correct "$receipts/inspect-after-reclaim-fold.json" \
  '.outcome == "success" and .key == $correct[0].key and .leaf == $correct[0].leaf and .root == $correct[0].root' \
  "$receipts/trie-plain-inspect.json" >/dev/null || fail "the ordinary untraced inspect changed the actual proven read"

# Pre-migration sidecar callers are retired. A compiled subject mutation,
# rather than an old mirror binary against a sidecar-free registry, supplies
# the lineage source refusal control in the owner evidence bundle.

# ------------------------------------------------------------------
# 7f. the story, with wallets made by `singular wallet create` (#642)
# ------------------------------------------------------------------
# Alice and Bob run the run page's sixteen steps, in page order, on a registry
# of their own, with wallets they made with `singular wallet create` and the
# devnet funded by address: no key file of either exists, and no `cardano-cli`
# ran. Every write of theirs names an address and a new bundle file where the
# key-file legs above name a key file. It builds its whole run as one bundle,
# signs and sends nothing and exits 19; `singular wallet sign --vault` signs
# the bundle and `singular submit` sends it. A write's own fields (the request,
# the envelope, the fold, the root) are `expected` until its transactions are
# found on chain: only after `singular submit` reports every transaction of the
# bundle on chain does the leg read them as facts, as the landed view of the
# receipt, and each step then checks what its key-file counterpart above checks
# (the booking's request and deadline, the fold's settled request and margin,
# the readback of the key, the root) against reads of the chain.
say "the story: Alice and Bob keep no signing key on disk. Every write of theirs names the wallet's address and a new bundle file: the command builds its whole run as that one bundle, signs nothing, sends nothing and exits with status 19, the outcome waiting-for-signatures. The wallet's owner then signs the bundle from the vault with singular wallet sign and sends it with singular submit."
s_reg="$story/reg"
scommon=(--state-dir "$s_reg" --blueprint "$blueprint")
s_window_process=120000
s_window_retract=60000
payload "$story/payload.json"
jq -n '{constructor:3, fields:[{bytes:"626f62"},{int:123456789012345678901234567890}]}' >"$story/payload-update.json"

# story_who WHO FIELD: a story wallet's passphrase or address.
story_who() {
  case "$1/$2" in
    alice/pass) printf '%s' "$alice_pass" ;;
    bob/pass) printf '%s' "$bob_pass" ;;
    alice/addr) printf '%s' "$vault_alice_addr" ;;
    bob/addr) printf '%s' "$vault_bob_addr" ;;
    *) fail "no story wallet $1/$2" ;;
  esac
}
# story_stage NAME WHO -- ARGS: one write of WHO's in the external flow. The
# receipt is NAME-staged: exit 19, the bundle file written, WHO's address its
# only signer, the write's own fields under `expected`, no submission.
story_stage() {
  local name="$1" who="$2" bundle="$story/bundles/$1.bundle" addr
  shift 3
  addr="$(story_who "$who" addr)"
  run "$name-staged" waiting-for-signatures -- "$@" --wallet-address "$addr" --bundle "$bundle"
  [ -s "$bundle" ] || fail "$name: the staged run wrote no bundle file"
  jq -e --arg a "$addr" --arg w "$bundle" '
      .bundle.signers == [$a] and .bundle.written == $w
      and (.bundle.transactions | length > 0)
      and (.expected | type == "object") and (has("submissions") | not)' \
    "$receipts/$name-staged.json" >/dev/null \
    || fail "$name: the staged receipt does not name the bundle, its only signer and its own fields under expected"
}
# story_settle NAME WHO: WHO signs the bundle with the vault (one witness per
# transaction, the passphrase through an inherited descriptor) and sends it;
# the submission must find every transaction of the bundle on chain. The
# receipt NAME is then the landed view: the staged `expected` fields, stated
# as facts, beside the chain points `singular submit` read.
story_settle() {
  local name="$1" who="$2" bundle="$story/bundles/$1.bundle" witnesses="$story/witnesses/$1" n status=0
  n="$(jq '.bundle.transactions | length' "$receipts/$name-staged.json")"
  "$singular" wallet sign --vault "$story/$who/$who.vault" --passphrase-fd 3 --out "$witnesses" "$bundle" \
    3<<<"$(story_who "$who" pass)" >"$receipts/$name.signed" 2>"$receipts/$name.sign.err" \
    || fail "$name: $who's wallet sign failed: $(tail -n 3 "$receipts/$name.sign.err" | tr '\n' ' ')"
  [ "$(wc -l <"$receipts/$name.signed")" -eq "$n" ] && [ "$(find "$witnesses" -name '*.witness' | wc -l)" -eq "$n" ] \
    || fail "$name: the signing step did not write one witness per transaction ($n)"
  "$singular" submit --witnesses "$witnesses" "${node[@]}" --receipt "$receipts/$name.submitted.json" "$bundle" \
    >"$receipts/$name.submit.out" 2>"$receipts/$name.submit.err" || status=$?
  [ "$status" -eq 0 ] || fail "$name: singular submit exited $status: $(tail -n 3 "$receipts/$name.submit.err" | tr '\n' ' ')"
  jq -e --slurpfile s "$receipts/$name-staged.json" '
      .command == "submit" and .outcome == "success"
      and .bundleHash == $s[0].bundle.hash
      and ([.submissions[].identity] == [$s[0].bundle.transactions[].identity])
      and all(.submissions[]; (.chainPoint.slot | type == "number") and .how == "sent")' \
    "$receipts/$name.submitted.json" >/dev/null \
    || fail "$name: the submission did not find every transaction of the bundle on chain, in the bundle's order"
  jq --slurpfile u "$receipts/$name.submitted.json" \
    '{command, outcome: "success",
      landed: {bundle: .bundle.hash, transactions: [$u[0].submissions[] | {identity, chainPoint, confirmations}]}}
     + .expected' "$receipts/$name-staged.json" >"$receipts/$name.json"
  say "$name: $who signed the bundle with the vault and sent it; $n transaction(s) on chain"
}
# story_envelope_ok NAME CONTROLLER KEY PAYLOAD_FILE: the landed envelope is the
# datum the story registry, the key, the controller and the payload make.
story_envelope_ok() {
  jq -e --arg s "$s_state" --arg t "$s_token" --arg a "$s_active" --arg k "$(hexof "$3")" \
    --arg c "$2" --slurpfile p "$4" '.envelope == {constructor:0, fields:[
      {constructor:0, fields:[{int:1},{constructor:0,fields:[{bytes:$s},{bytes:$t}]},
        {bytes:$a},{bytes:$k},{bytes:$c},{int:2000000}]}, $p[0]]}' \
    "$receipts/$1.json" >/dev/null
}
# story_fold_ok NAME BOOKING EDGE: the landed fold settles the booking's one
# request on the edge, with a wallet other than the booker's, before the
# deadline and with the margin the key-file fold above keeps.
story_fold_ok() {
  jq -e --slurpfile b "$receipts/$2.json" '
      (.settled | length == 1)
      and .settled[0].request == $b[0].request and .foldDeadline.posixMs == $b[0].foldDeadline.posixMs
      and .folder != $b[0].requester and .settled[0].edge == "'"$3"'"
      and (.fold | test("^[0-9a-f]{64}$"))
      and .landed.transactions[0].identity == .fold
      and (.validUntilSlot | type == "number")
      and (if .foldDeadline.slot != null then .validUntilSlot <= .foldDeadline.slot else true end)
      and (.hostClockMs + 30000 < .foldDeadline.posixMs)
      and (.remainingMs | type == "number" and . > 30000)' "$receipts/$1.json" >/dev/null \
    || fail "$1: the fold does not name the booking's request and deadline, or the booker folded, or it left no margin"
}
# story_wait_until MS WHAT: sleep until the epoch millisecond MS plus 3 s.
story_wait_until() {
  local wait_ms=$(($1 + 3000 - $(date +%s%3N)))
  if [ "$wait_ms" -gt 0 ]; then
    say "waiting $((wait_ms / 1000 + 1)) s for $2"
    sleep $((wait_ms / 1000 + 1))
  fi
}

say "story 1. Preview the identity a seed gives, from Alice's address alone, then create the registry on it."
# 1. Preview the identity a seed gives (the address alone), then create.
run story-preview success -- create --preview --process-time "$s_window_process" --retract-time "$s_window_retract" \
  "${scommon[@]}" "${node[@]}" --wallet-address "$vault_alice_addr"
run story-bob-preview success -- create --preview --process-time "$s_window_process" --retract-time "$s_window_retract" \
  --state-dir "$story/bob-preview" --blueprint "$blueprint" "${node[@]}" --wallet-address "$vault_bob_addr"
[ ! -e "$s_reg" ] && [ ! -e "$story/bob-preview" ] || fail "a story preview created its target"
s_alicekey="$(field story-preview .walletKeyHash)"
s_bobkey="$(field story-bob-preview .walletKeyHash)"
[ "$(field story-preview .wallet)" = "$vault_alice_addr" ] || fail "the story preview names another wallet than Alice's vault address"
story_stage story-create alice -- create --seed "$(field story-preview .seed)" \
  --process-time "$s_window_process" --retract-time "$s_window_retract" "${scommon[@]}" "${node[@]}"
# The state script is the same for every registry of a release: Alice's story
# create found the live carrier of it by hash and published none.
jq -e --slurpfile m "$receipts/create.json" '
    [.expected.references[] | select(.role == "state") | .output]
      == [$m[0].references[] | select(.role == "state") | .output]
    and (.bundle.transactions | map(.step) | index("publish-state") | not)
    and (.expected.references | map(.role) | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"])
    and .expected.processTime == '"$s_window_process"' and .expected.retractTime == '"$s_window_retract"'
    and .expected.walletKeyHash == "'"$s_alicekey"'" and .expected.wallet == "'"$vault_alice_addr"'"' \
  "$receipts/story-create-staged.json" >/dev/null \
  || fail "the staged story create does not boot from the live state carrier with six references and Alice's windows"
# Nothing was sent: the registry is not on chain yet.
run story-create-absent client-refusal -- inspect --key alice "${scommon[@]}" \
  --state-token "$(field story-create-staged .expected.stateToken)" "${node[@]}"
story_settle story-create alice
s_state_token="$(field story-create .stateToken)"
s_state="$(field story-create .pins.pinState)"
s_token="$(field story-create .token)"
s_active="$(field story-create .pins.pinActive)"
[ "$s_state_token" = "$s_state.$s_token" ] || fail "the story create did not print the state token $s_state.$s_token"
scommon+=(--state-token "$s_state_token")
# A landed bundle sends nothing the second time: its transactions are found.
status=0
"$singular" submit --witnesses "$story/witnesses/story-create" "${node[@]}" --receipt "$receipts/story-create.again.json" \
  "$story/bundles/story-create.bundle" >/dev/null 2>"$receipts/story-create.again.err" || status=$?
[ "$status" -eq 0 ] || fail "submitting the landed create bundle again failed"
jq -e 'all(.submissions[]; .how == "found")' "$receipts/story-create.again.json" >/dev/null \
  || fail "submitting the landed create bundle again sent a transaction instead of finding it"
say "story create: $s_state_token; submitting its landed bundle again finds every transaction and sends none"

say "story 2. Read the registry page with the command the create receipt printed."
# 2. The registry page, with the command the create receipt printed.
if [ "$page_steps_run" = 1 ]; then
  s_describe_cmd="$(field story-create .describeCommand)"
  [ "$s_describe_cmd" != "null" ] && [ -n "$s_describe_cmd" ] || fail "the story create printed no describe command"
  path_before="$PATH"
  PATH="$work/archive-bin:$PATH"
  describe_status=0
  eval "$s_describe_cmd --json" >"$receipts/story-describe-after-create.json" 2>"$receipts/story-describe-after-create.err" || describe_status=$?
  PATH="$path_before"
  [ "$describe_status" -eq 0 ] || fail "the story's printed describe command failed: $(tail -n 3 "$receipts/story-describe-after-create.err" | tr '\n' ' ')"
  run story-inspect-empty success -- inspect --key alice "${scommon[@]}" "${node[@]}"
  [ "$(field story-inspect-empty .leaf)" = unknown ] || fail "the story registry holds a key before any insertion"
  page_agrees "$receipts/story-describe-after-create.json" "$receipts/story-inspect-empty.json" "" 0 0 0 \
    || fail "the story's page after create differs from its readback"
  say "the story's registry page reads after create from the receipt's command"
fi

say "story 3. Book an insertion of a key with its first payload; Alice's wallet is its controller."
# 3. Alice books an insertion; the request stays pending.
story_stage story-insert alice -- insert --key alice --payload "$story/payload.json" "${scommon[@]}" "${node[@]}"
# While the bundle waits for its signatures, Alice's next write stops before it
# builds anything: the same outcome and status, no second bundle, nothing
# journalled of its own.
s_alice_journal="$(managed_journal "$s_reg" "$s_state_token" "$s_alicekey")"
s_nonlanded() { jq -s '[.[] | select(.journalEvent != "landed")] | length' "$1"; }
s_journal_before="$(s_nonlanded "$s_alice_journal")"
run story-insert-while-waiting waiting-for-signatures -- insert --key aliceTwo --payload "$story/payload.json" \
  "${scommon[@]}" "${node[@]}" --wallet-address "$vault_alice_addr" --bundle "$story/bundles/story-insert-while-waiting.bundle"
[ ! -e "$story/bundles/story-insert-while-waiting.bundle" ] && [ "$(s_nonlanded "$s_alice_journal")" = "$s_journal_before" ] \
  || fail "a write stopped by a waiting bundle wrote a bundle or journalled something"
# Bob cannot sign Alice's bundle: his vault's address is not among its signers.
status=0
"$singular" wallet sign --vault "$story/bob/bob.vault" --passphrase-fd 3 --out "$story/witnesses/stranger" \
  "$story/bundles/story-insert.bundle" 3<<<"$bob_pass" >"$receipts/story-stranger.out" 2>"$receipts/story-stranger.err" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$receipts/story-stranger.out" ] && [ -z "$(find "$story/witnesses/stranger" -name '*.witness' 2>/dev/null)" ] \
  || fail "Bob's vault signed Alice's bundle (exit $status)"
say "Bob's vault is refused Alice's bundle: its address is not among the signers"
story_settle story-insert alice
booked story-insert
[ "$(field story-insert .requester)" = "$s_alicekey" ] || fail "the story booking's requester is not Alice's key"
story_envelope_ok story-insert "$s_alicekey" alice "$story/payload.json" \
  || fail "the story booking's envelope is not the one the registry, the key, Alice and the payload make"
run story-inspect-pending success -- inspect --key alice "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-pending .leaf)" = unknown ] || fail "inspect after a landed booking alone does not read the key unknown"
jq -e --argjson p "$s_window_process" --argjson r "$s_window_retract" --slurpfile b "$receipts/story-insert.json" '
  .processTime == $p and .retractTime == $r
  and ([.pendingRequests[] | select(.request == $b[0].request)] | length == 1)
  and ([.pendingRequests[] | select(.request == $b[0].request)][0].submittedAt + .processTime == $b[0].foldDeadline.posixMs)' \
  "$receipts/story-inspect-pending.json" >/dev/null \
  || fail "inspect did not read the story's windows, or the booking deadline differs from its live submission time plus the processing window"

say "story 4. Fold it, before that deadline. Any wallet may fold: here, Bob's."
# 4. Bob folds it before that deadline, with his own wallet.
story_stage story-fold bob -- fold "${scommon[@]}" "${node[@]}"
story_settle story-fold bob
story_fold_ok story-fold story-insert insertActive
[ "$(field story-fold .folder)" = "$s_bobkey" ] || fail "Alice's story request was not folded with Bob's key"
jq -e --slurpfile e "$receipts/story-insert.json" --arg k "$(hexof alice)" '.settled[0].key == $k
  and .settled[0].settlement.envelope == $e[0].envelope
  and (.settled[0].settlement.liveOutput | test("#"))' "$receipts/story-fold.json" >/dev/null \
  || fail "the story fold does not deliver Alice's envelope at her key"

say "story 5. Read it back: no signing key, nothing submitted."
# 5. Read it back: no signing key, nothing submitted.
run story-inspect-1 success -- inspect --key alice "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-1 .leaf)" = active ] || fail "inspect after the story insert is not active"
[ "$(field story-inspect-1 .root)" = "$(field story-fold .root)" ] || fail "inspect root differs from the story fold's"
[ "$(field story-inspect-1 .root)" != "$(field story-inspect-pending .root)" ] || fail "the story fold did not move the root"
jq -e --slurpfile i "$receipts/story-insert.json" '.applicationOutput.envelope == $i[0].envelope' \
  "$receipts/story-inspect-1.json" >/dev/null \
  || fail "the story holding's envelope is not the one the insert receipt reports"

say "story 6. Replace the payload."
# 6. Alice replaces the payload.
story_stage story-update alice -- update --key alice --payload "$story/payload-update.json" "${scommon[@]}" "${node[@]}"
jq -e --arg root "$(field story-inspect-1 .root)" '.expected.root == $root' "$receipts/story-update-staged.json" >/dev/null \
  || fail "the staged story update does not leave the root where it is"
story_settle story-update alice

say "story 7. Read it back."
# 7. Read it back.
run story-inspect-2 success -- inspect --key alice "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-2 .leaf)" = active ] || fail "inspect after the story update is not active"
[ "$(field story-inspect-2 .root)" = "$(field story-fold .root)" ] || fail "the story update moved the root"
jq -e --slurpfile p "$story/payload-update.json" '.applicationOutput.payload == $p[0]' \
  "$receipts/story-inspect-2.json" >/dev/null || fail "the story holding does not carry the new payload"

say "story 8. Book the termination of the key."
# 8. Alice books the termination of the key.
story_stage story-terminate alice -- terminate --key alice "${scommon[@]}" "${node[@]}"
story_settle story-terminate alice
booked story-terminate
jq -e '(.released | test("^[0-9a-f]{64}#[0-9]+$")) and (.deposit | type == "number" and . > 0)' \
  "$receipts/story-terminate.json" >/dev/null \
  || fail "the story termination booking does not name the live output its fold will release"
run story-inspect-booked success -- inspect --key alice "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-booked .leaf)" = active ] || fail "the story key is not still active after a termination booking alone"

say "story 9. Fold it: the fold burns the token and releases the deposit."
# 9. Bob folds it: the fold burns the token and releases the deposit.
story_stage story-terminate-fold bob -- fold --request "$(field story-terminate .request)" "${scommon[@]}" "${node[@]}"
story_settle story-terminate-fold bob
story_fold_ok story-terminate-fold story-terminate updateTerminal
[ "$(field story-terminate-fold .settled[0].settlement.released)" = "$(field story-terminate .released)" ] \
  || fail "the story fold released another output than the booking named"

say "story 10. Read it back."
# 10. Read it back.
run story-inspect-3 success -- inspect --key alice "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-3 .leaf)" = terminal ] || fail "the story key is not terminal"
jq -e '.applicationOutput.absent' "$receipts/story-inspect-3.json" >/dev/null || fail "the story holding is still live"
[ "$(field story-inspect-3 .root)" = "$(field story-terminate-fold .root)" ] || fail "inspect root differs from the termination fold's"

say "story 11. A request nobody folded or took back stays pending past both its windows and blocks the registry's fold. Reject it; any wallet may: here, Bob's."
# 11. A request nobody folded or took back stays pending past both its windows
# and blocks the registry's fold: Alice books one and nobody folds it. Bob's
# reject is refused while a window is open (no bundle is written), then he
# rejects it.
story_stage story-late alice -- insert --key late --payload "$story/payload.json" "${scommon[@]}" "${node[@]}"
story_settle story-late alice
booked story-late
s_late_deadline="$(field story-late .foldDeadline.posixMs)"
s_late_retract_ends=$((s_late_deadline + s_window_retract))
[ "$(($(date +%s%3N) + 5000))" -lt "$s_late_retract_ends" ] || setup_fail "the story's late request has no open window left for the early reject"
run story-reject-early client-refusal -- registry reject "${scommon[@]}" "${node[@]}" \
  --wallet-address "$vault_bob_addr" --bundle "$story/bundles/story-reject-early.bundle"
[ ! -e "$story/bundles/story-reject-early.bundle" ] || fail "a refused reject wrote a bundle"
jq -e --slurpfile l "$receipts/story-late.json" '.reason | contains($l[0].request) and contains("window")' \
  "$receipts/story-reject-early.json" >/dev/null || fail "the early story reject does not name the request and its open window"
story_wait_until "$s_late_retract_ends" "the late request's retract window to close"
run story-inspect-late success -- inspect --key late "${scommon[@]}" "${node[@]}"
s_root_before_reject="$(field story-inspect-late .root)"
story_stage story-reject bob -- registry reject "${scommon[@]}" "${node[@]}"
jq -e --slurpfile l "$receipts/story-late.json" --arg owner "$s_alicekey" --arg addr "$vault_alice_addr" --arg bob "$s_bobkey" --arg root "$s_root_before_reject" '
    (.expected.reject | test("^[0-9a-f]{64}$")) and .expected.rejector == $bob and .expected.root == $root
    and (.expected.rejected | length == 1)
    and .expected.rejected[0].request == $l[0].request and .expected.rejected[0].owner == $owner
    and .expected.rejected[0].returned.recipient == $addr' "$receipts/story-reject-staged.json" >/dev/null \
  || fail "the staged story reject does not return the late request to its owner's address with the root unmoved"
story_settle story-reject bob
run story-inspect-rejected success -- inspect --key late "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-rejected .root)" = "$s_root_before_reject" ] || fail "the story reject moved the root"
[ "$(jq '.pendingRequests | length' "$receipts/story-inspect-rejected.json")" = 0 ] \
  || fail "the story reject left a request pending"
jq -e --arg r "$(field story-reject .reject)" '
    [.submissions[] | select(.identity == $r) | .outputs[] | select(.unspent)] | length > 0' \
  "$receipts/story-reject.submitted.json" >/dev/null || fail "the story reject's outputs are not on chain"

say "story 12. The registry takes requests again: book a new insertion."
# 12. The registry takes requests again: Bob books an insertion of his own.
story_stage story-bob-insert bob -- insert --key bob --payload "$story/payload.json" "${scommon[@]}" "${node[@]}"
story_settle story-bob-insert bob
booked story-bob-insert
[ "$(field story-bob-insert .requester)" = "$s_bobkey" ] || fail "the booking's requester is not Bob's key"
story_envelope_ok story-bob-insert "$s_bobkey" bob "$story/payload.json" \
  || fail "Bob's story insert did not book his own key hash as controller"

say "story 13. Fold it."
# 13. Alice folds it.
story_stage story-bob-fold alice -- fold "${scommon[@]}" "${node[@]}"
story_settle story-bob-fold alice
story_fold_ok story-bob-fold story-bob-insert insertActive
[ "$(field story-bob-fold .folder)" = "$s_alicekey" ] || fail "Bob's story request was not folded with Alice's key"
run story-inspect-bob success -- inspect --key bob "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-bob .leaf)" = active ] || fail "Bob's story key is not active"

say "story 14. Book a different insertion and keep its request reference from the receipt. Let its processing deadline pass, then reclaim during its retract window."
# 14. Alice books a different insertion, keeps its request reference from the
# receipt, lets its processing deadline pass and reclaims it in the retract
# window.
story_stage story-carol alice -- insert --key carol --payload "$story/payload.json" "${scommon[@]}" "${node[@]}"
story_settle story-carol alice
booked story-carol
s_carol_deadline="$(field story-carol .foldDeadline.posixMs)"
story_wait_until "$s_carol_deadline" "the carol request's processing deadline to pass"
run story-inspect-before-reclaim success -- inspect --key carol "${scommon[@]}" "${node[@]}"
story_stage story-reclaim alice -- registry reclaim --request "$(field story-carol .request)" "${scommon[@]}" "${node[@]}"
jq -e --slurpfile c "$receipts/story-carol.json" --arg owner "$s_alicekey" --arg addr "$vault_alice_addr" --arg root "$(field story-inspect-before-reclaim .root)" '
    .expected.request == $c[0].request and .expected.owner == $owner
    and .expected.returned.recipient == $addr and .expected.root == $root' \
  "$receipts/story-reclaim-staged.json" >/dev/null \
  || fail "the staged story reclaim does not return the request to its owner's address with the root unmoved"
story_settle story-reclaim alice
run story-inspect-reclaimed success -- inspect --key carol "${scommon[@]}" "${node[@]}"
[ "$(jq '.pendingRequests | length' "$receipts/story-inspect-reclaimed.json")" = 0 ] \
  || fail "the story reclaim left a request pending"
[ "$(field story-inspect-reclaimed .leaf)" = unknown ] || fail "the reclaimed story key is known to the registry"
[ "$(field story-inspect-reclaimed .root)" = "$(field story-inspect-before-reclaim .root)" ] || fail "the story reclaim moved the root"

say "story 15. The reclaimed request no longer blocks the next insertion."
# 15. The reclaimed request no longer blocks the next insertion.
story_stage story-dave alice -- insert --key dave --payload "$story/payload.json" "${scommon[@]}" "${node[@]}"
story_settle story-dave alice
booked story-dave

say "story 16. Fold it with Bob's wallet."
# 16. Bob folds it.
story_stage story-dave-fold bob -- fold "${scommon[@]}" "${node[@]}"
story_settle story-dave-fold bob
story_fold_ok story-dave-fold story-dave insertActive
run story-inspect-dave success -- inspect --key dave "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-dave .leaf)" = active ] || fail "the story key dave is not active"
[ "$(field story-inspect-dave .root)" = "$(field story-dave-fold .root)" ] || fail "inspect root differs from the last story fold's"

# The combined forms: one bundle holds the booking and the fold, signed once.
story_stage story-insert-fold alice -- insert --fold --key erin --payload "$story/payload.json" "${scommon[@]}" "${node[@]}"
jq -e '(.bundle.transactions | map(.step) == ["book", "fold"])
    and (.expected.booking | test("^[0-9a-f]{64}$")) and (.expected.fold | test("^[0-9a-f]{64}$"))
    and .expected.booking != .expected.fold and (.expected.settled | length == 1)' \
  "$receipts/story-insert-fold-staged.json" >/dev/null \
  || fail "the staged story insert --fold does not hold exactly its booking and its fold"
story_settle story-insert-fold alice
run story-inspect-erin success -- inspect --key erin "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-erin .leaf)" = active ] || fail "insert --fold left the key erin not active"
story_stage story-terminate-fold-erin alice -- terminate --fold --key erin "${scommon[@]}" "${node[@]}"
jq -e '(.bundle.transactions | map(.step) == ["book", "fold"]) and (.expected.settled | length == 1)
    and .expected.settled[0].edge == "updateTerminal"' "$receipts/story-terminate-fold-erin-staged.json" >/dev/null \
  || fail "the staged story terminate --fold does not hold exactly its booking and its fold"
story_settle story-terminate-fold-erin alice
run story-inspect-erin-terminal success -- inspect --key erin "${scommon[@]}" "${node[@]}"
[ "$(field story-inspect-erin-terminal .leaf)" = terminal ] || fail "terminate --fold left the key erin not terminal"
[ "$(jq '.pendingRequests | length' "$receipts/story-inspect-erin-terminal.json")" = 0 ] \
  || fail "the story ends with a request still pending"

# Alice and Bob made no key file: the story directory holds the two vaults and
# no signing key outside them.
[ -z "$(find "$story" -name '*.skey')" ] && [ "$(find "$story" -name '*.vault' | wc -l)" -eq 2 ] \
  || fail "the story directory holds a key file, or other than the two vaults"
say "the story: Alice and Bob ran the page's sixteen steps and the combined forms with wallets made by singular wallet create; every write exited 19, was signed from a vault and sent by singular submit"

# ------------------------------------------------------------------
# 8. the node lost after an accepted submission (last: the node dies)
# ------------------------------------------------------------------
say "harness control of the key-file path: the node-lost control below runs a key-file wallet; it is not the guide's flow"
# A held update and a dying node are concurrent only for this recovery
# assertion. The controller joins the update before leaving this block.
if [ "$mode" = test-harness ]; then
  jq -n '{int: 42}' >"$work/payload-2.json"
  before="$(journal_lines "$reg")"
  update_before="$(journal_count "$alice_journal")"
  rm -f "$work/update.go" "$work/update.go.waiting"
  SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/update.go" SINGULAR_HARNESS_HOLD_STEP=update \
    "$open_datum" update --key keyC --payload "$work/payload-2.json" --confirm-timeout 30 \
    "${common[@]}" "${node[@]}" "${alice[@]}" >"$receipts/update-node-lost.json" 2>"$receipts/update-node-lost.err" &
  victim=$!
  for _ in $(seq 1 1200); do
    [ -e "$work/update.go.waiting" ] && break
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.1
  done
  [ -e "$work/update.go.waiting" ] || setup_fail "the update never reached an accepted submission"
  lost_tx="$(tail -n +"$((update_before + 1))" "$alice_journal" | jq -r 'select(.journalEvent == "submitted") | .journalTxId')"
  lost_tx="${lost_tx%%$'\n'*}"
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
  victim=""
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
  [ "$(tail -n 1 "$alice_journal" | jq -r .journalEvent)" = unconfirmed ] \
    || fail "the journal does not keep the submitted update unresolved"
  say "node lost after an accepted submission: $outcome after ${waited}s, naming $lost_tx, journal unresolved"

fi

mapfile -t census_journals < <(managed_find "$reg" journal.jsonl)
for census in "${census_journals[@]}"; do jq -r '.journalEvent' "$census"; done | sort | uniq -c

# Every journal the journey's writes left, wherever they wrote: each
# prepared line names its actual Unbound acquisition.
mapfile -t journals < <(find "$work" -name journal.jsonl | sort)
[ "${#journals[@]}" -ge 2 ] || fail "found ${#journals[@]} journals; the extent is not the journey's"
written=0
for j in "${journals[@]}"; do
  n="$(prepared_scopes "$(dirname "$j")" | wc -l)"
  written=$((written + n))
done
[ "$written" -gt 0 ] || fail "no prepared line in ${#journals[@]} journals"
say "$written prepared submissions in ${#journals[@]} journals each name their actual Unbound acquisition"
if [ "$mode" = test-harness ]; then
  trie_extent
  say "test build: all eight stored-registry commands have nonempty capability evidence from actual executions"
fi
# Every traced command's events agreed with its receipt (checked as it ran).
# The extent: all eight commands succeeded under narration, with mechanics.
while IFS= read -r name; do
  jq -c --slurpfile trace "$receipts/$name.trace.jsonl" \
    '{command, outcome, how: ($trace | map(select(.level == "how")) | length)}' "$receipts/$name.json"
done <"$work/trace-command-invocations" >"$work/trace-command-extent.jsonl"
jq -s -e '[.[] | select(.outcome == "success" and .how > 0) | .command] | unique
    == ["create","fold","insert","inspect","reclaim","reject","terminate","update"]' \
  "$work/trace-command-extent.jsonl" >/dev/null \
  || fail "the narrated command extent omits a command, or narrates it without mechanics"
# The agreement can fail: one fold's stream, altered in any one fact it
# carries, disagrees with that fold's receipt.
fold_trace="$receipts/fold.trace.jsonl"
for altered in \
  'if .event == "command-ended" then .outcome = "partial" else . end' \
  'if .key then .key = "00" else . end' \
  '.scope |= map(if .request then .request = ("0" * 64 + "#9") else . end)' \
  'if .event == "tx-confirmed" then .verdict = "timed-out" else . end' \
  'select(.event != "tx-observed")' \
  'if .event == "root" then .after = "00" else . end' \
  'if .tx then .tx |= (if startswith("0") then "1" else "0" end) + .[1:] else . end' \
  '.scope |= map(if .edge then .on = "deleteActive" else . end)' \
  'if .event == "folded" then .output = "00#0" else . end' \
  'if .event == "registry" then .root = "00" else . end' \
  'if .event == "request" then .deadlineMs += 1 else . end'; do
  jq -c "$altered" "$fold_trace" >"$work/altered.trace.jsonl"
  ! trace_agrees "$receipts/fold.json" "$work/altered.trace.jsonl" \
    || fail "the trace agreement accepts a stream altered by: $altered"
done
trace_agrees "$receipts/fold.json" "$fold_trace" || fail "the fold's own stream no longer agrees"
# and one inspect's stream, altered in its key's leaf or holding or the
# registry's pending count, disagrees with that inspect's receipt.
inspect_trace="$receipts/inspect-1.trace.jsonl"
for altered in \
  'if .event == "key" then .leaf = "altered" else . end' \
  'if .event == "key" then .holding = "00#0" else . end' \
  'if .event == "registry" then .pending += 1 else . end'; do
  jq -c "$altered" "$inspect_trace" >"$work/altered.trace.jsonl"
  ! trace_agrees "$receipts/inspect-1.json" "$work/altered.trace.jsonl" \
    || fail "the trace agreement accepts an inspect stream altered by: $altered"
done
trace_agrees "$receipts/inspect-1.json" "$inspect_trace" || fail "the inspect's own stream no longer agrees"
# and a refusal's stream, refused before anything was built, disagrees with
# its receipt once its one refusal event is removed or repeated.
refusal_trace="$receipts/insert-payload-not-data.trace.jsonl"
refusal_key="$(printf %s "$key" | od -An -tx1 | tr -d " \n")"
trace_agrees "$receipts/insert-payload-not-data.json" "$refusal_trace" "$refusal_key" \
  || fail "the early refusal's own stream does not agree"
for altered in 'select(.event != "refused")' 'if .event == "refused" then (., .) else . end'; do
  jq -c "$altered" "$refusal_trace" >"$work/altered.trace.jsonl"
  ! trace_agrees "$receipts/insert-payload-not-data.json" "$work/altered.trace.jsonl" "$refusal_key" \
    || fail "the trace agreement accepts a refusal stream altered by: $altered"
done
say "every narrated command's typed events agree with its receipt; altered streams do not"
say "JOURNEY-OK (Koios path; $mode build evidence)"
