#!/usr/bin/env bash
# Alice's open-datum story through the packaged `singular` commands (#299),
# through the sole Koios provider. The node/indexer comparison is retired
# with the node backend (A023); every registry and recovery control remains.
#
# usage: demo1_cli_journey.sh SINGULAR DEVNET BLUEPRINT WORKDIR
#
# SINGULAR and DEVNET are executables; BLUEPRINT is the registry
# partition's plutus.json. ONE development node is started once, funding
# two generated wallets (alice, bob), and every registry command is a
# separate process against it:
#
#   create -> insert -> fold -> inspect -> update -> inspect
#          -> terminate -> fold -> inspect -> reject -> insert -> fold
#          -> reclaim -> insert -> fold
#
# An insert or a terminate books and leaves its request pending; `registry
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
set -euo pipefail

[ "$#" -eq 4 ] || {
  echo "usage: $0 SINGULAR DEVNET BLUEPRINT WORKDIR" >&2
  exit 2
}
singular="$1"
devnet="$2"
blueprint="$3"
work="$4"
rm -rf "$work"
mkdir -p "$work"
receipts="$work/receipts"
mkdir -p "$receipts"
reg="$work/registry"
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

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/alice.skey"
hexkey >"$work/bob.skey"
hexkey >"$work/carol.skey" # never funded

export TMPDIR="$work"

# ------------------------------------------------------------------
# 0. coverage: a genesis-only wallet is refused on the Koios path
# ------------------------------------------------------------------
# These actual initial allocations have no transaction carried by a full
# block. The private actor leaves them untouched for this control; the
# node/genesis/epoch/slot/time parameters are the normal fixture's.
"$devnet" --genesis-only --evidence-dir "$work/genesis-source" >"$work/bare.out" 2>"$work/bare.err" &
bare_pid=$!
trap 'kill "$bare_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
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
"$singular" registry create --process-time 90000 --retract-time 30000 --preview --registry "$work/genesis-indexer" --blueprint "$blueprint" \
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
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
# The node is the devnet runner's child: reap both, so no node of this
# run outlives it holding the development network's ports.
trap 'kill "$devnet_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
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
# trace_disagreements RECEIPT TRACE [KEY]: every way the command's typed
# events, as the JSON lines its file sink wrote, contradict its receipt; empty
# when every event that carries a receipt-bound fact agrees with it. The same
# rules as the in-process comparison (offchain/test/Singular/CLI/CommandRunSpec.hs):
# one end naming the receipt's command and outcome, last; every key an event
# or its scope carries is the receipt's key, or KEY (base16, the key the
# command line named) when the receipt names none; every request is one the
# receipt names (a booking names its output 0), with that request's key, edge
# and deadline; every edge action is one the command performs, on the edge it
# books or its receipt names; a key's leaf and holding, the registry's pending
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
    $r[0] as $r
    | . as $ev
    | ($r.key // (if $invoked == "" then null else $invoked end)) as $key
    | ([$r | .. | objects | select(has("request"))
        | {request, key, edge, deadline: (.foldDeadline.posixMs // .processingEnds)}]
       + [$r | .. | objects | select(has("pendingRequest")) | {request: .pendingRequest}]
       + [$r | select(.booking != null) | {request: (((.booking | if type == "object" then .txId else . end) // "") + "#0"), key}]) as $facts
    | (($facts | length == 0) and ($r.outcome != "success")) as $bare_refusal
    | [$r.submissions[]? | {step, tx, case, observed}] as $subs
    | [$r.references[]? | {step: ("publish-" + .role), tx: (.output | split("#")[0])}
       | select(.tx as $t | $subs | map(.tx) | index($t) | not)] as $reused
    | (first($ev[] | select(.event == "root") | .before) // $r.root) as $before
    | def keys_of: (if .event == "key" or .event == "folded" or .event == "updated" then .key else empty end),
        (.scope[]? | .key? // empty);
      def requests_of: (if .event == "request" or .event == "booked" or .event == "reclaimed" then .request else empty end),
        (if .event == "rejected" then .requests[] else empty end),
        (.scope[]? | .request? // empty);
      def edges_of: (if .event == "edge-started" then {edge, on} else empty end),
        (.scope[]? | select(has("edge")) | {edge, on}),
        (if .event == "folded" then {edge: "fold", on: .edge} else empty end);
      def in_role($c; $re):
        ($c == "create" and .edge == "boot")
        or ($c == "insert" and (.edge | IN("book", "fold")) and .on == "insertActive")
        or ($c == "terminate" and (.edge | IN("book", "fold")) and .on == "updateTerminal")
        or ($c == "update" and .edge == "update")
        or ($c == "fold" and .edge == "fold" and (.on == $re or $re == null))
        or ($c == "reject" and .edge == "reject")
        or ($c == "reclaim" and .edge == "reclaim" and (.on == $re or $re == null));
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
        ($ev[] | keys_of | select(. != $key) | "key \(.)"),
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
        ($ev[] | edges_of | select(in_role($r.command; $r.edge) | not) | "edge \(.) outside the command role"),
        ($ev[] | select(.event == "key" and $r.leaf != null and .leaf != $r.leaf) | "leaf \(.leaf)"),
        ($ev[] | select(.event == "key" and $r.applicationOutput != null and .holding != $r.applicationOutput.output)
         | "holding \(.holding)"),
        ($ev[] | select(.event == "registry" and .pending != null and $r.pendingRequests != null
                        and .pending != ($r.pendingRequests | length)) | "pending \(.pending)"),
        ($ev[] | select(.event == "registry" and $before != null and .root != $before) | "registry root \(.root)"),
        ($ev[] | select(.tx != null) | . as $e | {step, tx} as $t
         | select($subs | map({step, tx}) | index($t) | not)
         | select(($e.event == "tx-observed" and ($reused | index($t))) | not)
         | "transaction \($t) not among the submissions of the receipt"),
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
        ($ev[] | select(.event == "folded") | select(.output != ($r.liveOutput // $r.released)) | "folded output \(.output)"),
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
# run NAME CLASS -- ARGS: one singular process; its receipt must name CLASS
# and its exit status must be that class's. Each process uses the Koios path
# and narrates how on stderr, its typed events also written as JSON lines to
# a file; standard output carries the receipt alone.
run() {
  local name="$1" class="$2"
  shift 3
  local status=0
  local trace="$receipts/$name.trace.jsonl"
  local narrated=(--trace how --trace-to stderr --trace-to "file:$trace")
  local SINGULAR_LOG="$receipts/$name.phases.jsonl"
  export SINGULAR_LOG
  : >"$receipts/$name.trie.jsonl"
  if [[ " $* " == *" --preview "* ]]; then
    # Keep the release's existing all-harness-variables-unset preview controls.
    env -u SINGULAR_HARNESS_TRIE_TRACE "$singular" "$@" "${narrated[@]}" \
      >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  else
    SINGULAR_LOG="$receipts/$name.phases.jsonl" SINGULAR_HARNESS_TRIE_TRACE="$receipts/$name.trie.jsonl" \
      "$singular" "$@" "${narrated[@]}" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
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
  [ ! -e "$reg/registry.mirror.json" ] && [ ! -e "$reg/state.json" ] || fail "a command created retired trie files"
  [ ! -e "$reg/registry.json" ] || fail "a command wrote a registry.json"
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
# booking_only NAME: since journal line BEFORE the command left exactly the
# booking's four phases and the mirror and state it started with.
booking_only() {
  local name="$1" before="$2" files="$3"
  [ "$(local_files)" = "$files" ] || fail "$name: a booking altered identity or created retired trie files"
  [ "$((($(journal_lines "$reg")) - before))" -eq 4 ] \
    || fail "$name: the booking left $((($(journal_lines "$reg")) - before)) journal lines, expected its four phases"
  tail -n +"$((before + 1))" "$reg/journal.jsonl" \
    | jq -s -e '(map(.journalEvent) == ["prepared", "submitted", "confirmed", "observed"]) and (map(.journalStep) | unique == ["book"]) and (map(.journalTxId) | unique | length == 1)' >/dev/null \
    || fail "$name: the journal lines the booking left are not one booking's prepared, submitted, confirmed and observed"
}
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
# the hex of a signed transaction's body alone: the bytes whose hash is its id
def body_span: tobytes as $b | (if $b[0] == 132 then dec($b; 1) else error("not a four-element transaction") end) as [$v, $q] | $b[1:$q] | bytehex;
JQ
# tx_outputs_of TXID: the outputs of the signed transaction the registry directory's journal saved.
tx_outputs_of() { jq -R -c "$(cat "$work/cbor.jq") tx_outputs" "$reg/submissions/$1.cbor.hex"; }

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
for c in create insert update terminate fold reclaim reject inspect; do
  grep -q "singular registry $c" "$work/help.txt" || fail "help does not name registry $c"
done
status=0
"$singular" registry inspect --key-hex 00 "${common[@]}" "${node[@]}" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "inspect accepted a signing key (exit $status)"
say "help names the eight commands; a signing key on inspect is refused"

# ------------------------------------------------------------------
# 1. create
# ------------------------------------------------------------------
run preview success -- registry create --process-time 90000 --retract-time 30000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
[ ! -e "$reg" ] || fail "preview created the target $reg"
seed="$(field preview .seed)"
run bob-preview success -- registry create --process-time 90000 --retract-time 30000 --preview --registry "$work/bob-preview" \
  --blueprint "$blueprint" "${node[@]}" "${bob[@]}"
[ ! -e "$work/bob-preview" ] || fail "bob's preview created its target"
bobkey="$(field bob-preview .walletKeyHash)"
alice_addr="$(field preview .wallet)"
bob_addr="$(field bob-preview .wallet)"

# The same preview for a public address alone: no key, no write, and the
# identity it names is the one the key-holding preview named.
run preview-public success -- registry create --process-time 90000 --retract-time 30000 --preview --registry "$work/public-preview" \
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
"$singular" registry create --process-time 90000 --retract-time 30000 --preview --registry "$work/public-preview" --blueprint "$blueprint" \
  "${node[@]}" --wallet-address "$alice_addr" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "a preview accepted a signing key beside a public address (exit $status)"

run create-seed-not-owned client-refusal -- registry create --process-time 90000 --retract-time 30000 --seed "$seed" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
[ ! -e "$reg/registry.json" ] || fail "a refused create saved a registry"

process_time=90000
retract_time=30000
run create success -- registry create --process-time "$process_time" --retract-time "$retract_time" --seed "$seed" "${common[@]}" "${node[@]}" "${alice[@]}"
state="$(field create .pins.pinState)"
token="$(field create .token)"
active="$(field create .pins.pinActive)"
alicekey="$(field create .walletKeyHash)"
[ "$(field create .seed)" = "$seed" ] || fail "create booted from another seed"
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"]' \
  "$receipts/create.json" >/dev/null || fail "create did not publish the six references"
refused create-again client-refusal -- registry create --process-time 90000 --retract-time 30000 --seed "$seed" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e --argjson p "$process_time" --argjson r "$retract_time" \
  '.processTime == $p and .retractTime == $r' "$receipts/create.json" >/dev/null \
  || fail "create did not report the chosen processing and retract windows"
say "registry $token booted from $seed"

# A registry is its state token: create prints it and keeps no identity file,
# and an actor whose directory is empty runs a command on the token alone.
state_token="$(field create .stateToken)"
[ "$state_token" = "$state.$token" ] || fail "create did not print the state token $state.$token"
[ ! -e "$reg/registry.json" ] || fail "create wrote a registry.json"
empty_actor="$work/empty-actor"
mkdir -p "$empty_actor"
[ -z "$(ls -A "$empty_actor")" ] || setup_fail "the second actor's directory is not empty at start"
run empty-actor-inspect success -- registry inspect --key keyEmpty --state-token "$state_token" \
  --registry "$empty_actor" --blueprint "$blueprint" "${node[@]}"
[ "$(field empty-actor-inspect .leaf)" = unknown ] \
  || fail "an actor starting from an empty directory did not read the registry from its state token"
say "an actor with an empty directory read the registry from its state token alone"
# Every later command names the registry by its token; the directory is only
# the actor's journal.
common+=(--state-token "$state_token")

# This registry exercises absent flags and never books a timed request.
# The rest of the journey keeps its explicit development-network windows.
run create-defaults success -- registry create --seed "$(field bob-preview .seed)" \
  --registry "$work/default-registry" --blueprint "$blueprint" "${node[@]}" "${bob[@]}"
run inspect-defaults success -- registry inspect --key default-window-key \
  --registry "$work/default-registry" --blueprint "$blueprint" \
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
run empty-actor-insert success -- registry insert --fold --key keyEmpty --payload "$work/payload-empty.json" \
  --registry "$bob_actor" --blueprint "$blueprint" --state-token "$state_token" "${node[@]}" "${bob[@]}"
[ ! -e "$bob_actor/registry.json" ] || fail "a command wrote a registry.json in bob's directory"
reader="$work/empty-reader"
mkdir -p "$reader"
# Files in an actor's directory are never an input: another registry's
# identity file there changes nothing.
printf '{"confDeployment":{"depCageToken":"00"}}\n' >"$reader/registry.json"
run empty-reader-inspect success -- registry inspect --key keyEmpty --state-token "$state_token" \
  --registry "$reader" --blueprint "$blueprint" "${node[@]}"
[ "$(field empty-reader-inspect .leaf)" = active ] \
  || fail "an insertion booked and folded from an empty directory is not active for another empty reader"
say "bob booked and folded from an empty directory on the state token; another empty directory reads it"

# ------------------------------------------------------------------
# 2. insert (alice), with its refusals
# ------------------------------------------------------------------
key=keyA
payload "$work/payload-insert.json"
echo '{"not":"a datum"}' >"$work/payload-bad.json"
# stderr_of NAME ARGS...: a command line the parser refuses before anything
# is read: exit 2 and a message on stderr, never a receipt.
stderr_of() {
  local name="$1" status=0
  shift
  "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  [ "$status" -eq 2 ] || fail "$name: exit $status, expected 2"
  [ ! -s "$receipts/$name.json" ] || fail "$name: a refused command line printed a receipt"
  say "$name: refused at parse"
}
before_inserts="$(journal_lines "$reg")"
stderr_of insert-bad-key registry insert --key-hex zz --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- '--key-hex is not base16' "$receipts/insert-bad-key.err" || fail "insert-bad-key: the refusal does not name the key"
stderr_of insert-deposit-below-minimum registry insert --key "$key" --deposit 1999999 \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- 'below the minimum of 2000000 lovelace' "$receipts/insert-deposit-below-minimum.err" \
  || fail "insert-deposit-below-minimum: the refusal does not name the minimum"
stderr_of insert-deposit-not-integer registry insert --key "$key" --deposit lots \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- 'not a whole number of lovelace' "$receipts/insert-deposit-not-integer.err" \
  || fail "insert-deposit-not-integer: the refusal does not name the deposit"
removed="--""envelope" # spelled apart: no line of the tree names the removed flag
stderr_of insert-removed-flag registry insert --key "$key" "$removed" "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
grep -q -- "$removed is not a flag singular reads" "$receipts/insert-removed-flag.err" \
  || fail "insert-removed-flag: the removed flag is still read"
for control in "--trace loud" "--trace-to stdout" "--trace-to file:" "--trace-format xml"; do
  read -r flag value <<<"$control"
  stderr_of "insert-trace-${flag#--}-unknown" registry insert --key "$key" --payload "$work/payload-insert.json" \
    "${common[@]}" "${node[@]}" "${alice[@]}" "$flag" "$value"
  grep -q -- "$flag is " "$receipts/insert-trace-${flag#--}-unknown.err" \
    || fail "insert $control: the refusal does not name the tracing control"
  ! grep -q -- "is not a flag singular reads" "$receipts/insert-trace-${flag#--}-unknown.err" \
    || fail "insert $control: the tracing control is not read"
done
stderr_of insert-without-token registry insert --key "$key" --payload "$work/payload-insert.json" \
  --registry "$reg" --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
grep -q -- '--state-token' "$receipts/insert-without-token.err" \
  || fail "insert-without-token: the refusal does not name the state token"
refused insert-payload-not-data client-refusal -- registry insert --key "$key" \
  --payload "$work/payload-bad.json" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.reason | contains("not Plutus data")' "$receipts/insert-payload-not-data.json" >/dev/null \
  || fail "insert-payload-not-data: the refusal does not name the payload"
# Narration cannot change a command: with standard error closed, the same
# refusal, narrated to standard error, ends in bounded time with the same
# receipt and exit status.
closed_status=0
timeout 120 "$singular" registry insert --key "$key" --payload "$work/payload-bad.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}" --trace how --trace-to stderr \
  >"$receipts/insert-closed-stderr.json" 2>&- || closed_status=$?
[ "$closed_status" -eq "$(exit_of client-refusal)" ] \
  || fail "insert with standard error closed: exit $closed_status, expected the client refusal's"
cmp -s <(jq -S . "$receipts/insert-payload-not-data.json") \
  <(jq -S . "$receipts/insert-closed-stderr.json") \
  || fail "insert with standard error closed: another receipt than with it open"
unminted="$state.$(printf '%064d' 0)"
refused insert-unknown-registry client-refusal -- registry insert --key "$key" \
  --payload "$work/payload-insert.json" --registry "$work/no-such-registry" --blueprint "$blueprint" \
  --state-token "$unminted" "${node[@]}" "${alice[@]}"
jq -e '.reason | startswith("state-token-not-found")' "$receipts/insert-unknown-registry.json" >/dev/null \
  || fail "insert-unknown-registry: the refusal is not state-token-not-found"
[ ! -e "$work/no-such-registry/journal.jsonl" ] || fail "insert-unknown-registry: a refused insert journalled"
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
run insert-preview success -- registry insert --preview --key "$key" --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" --wallet-address "$alice_addr"
preview_ok insert-preview booking
[ "$(tree_hash)" = "$tree_before" ] || fail "a preview changed the registry directory"
jq -e '.fold.feeBound > .booking.fee' "$receipts/insert-preview.json" >/dev/null \
  || fail "the fold bound does not exceed a booking fee"
status=0
"$singular" registry insert --preview --key "$key" --payload "$work/payload-insert.json" "${common[@]}" \
  "${node[@]}" --wallet-address "$alice_addr" "${alice[@]}" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "an insert preview accepted a signing key (exit $status)"
# An allowance below the measured outlay stops the insert before it signs or
# sends anything.
refused insert-over-allowance client-refusal -- registry insert --key "$key" \
  --payload "$work/payload-insert.json" --max-outlay 1000000 "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.outlay.withinAllowance == false and .outlay.allowance == 1000000' \
  "$receipts/insert-over-allowance.json" >/dev/null || fail "the refusal does not state the outlay and the allowance"

[ ! -e "$reg/preimages" ] || fail "a refused booking left an envelope in the registry directory"

# The booking alone: alice's insert leaves its request pending, the mirror,
# the public root as it was, and names the deadline.
before="$(journal_lines "$reg")"
files_before="$(local_files)"
run insert success -- registry insert --key "$key" --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert
booking_only insert "$before" "$files_before"
[ "$(field insert .requester)" = "$alicekey" ] || fail "the booking's requester is not alice's key"
# The request carries the envelope the fold will deliver: the booking keeps
# nothing of it in the registry directory.
[ ! -e "$reg/preimages" ] || fail "the booking kept an envelope in the registry directory"
run inspect-pending success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
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
run fold success -- registry fold --request "$(field insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
fold_ok() {
  jq -e --slurpfile b "$receipts/$2.json" '
      .request == $b[0].request and .foldDeadline.posixMs == $b[0].foldDeadline.posixMs
      and .folder != $b[0].requester and .edge == "'"$3"'"
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
    "$reg/journal.jsonl" >"$receipts/$1.time-source.json" \
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
    "$reg/journal.jsonl" >/dev/null \
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
    "$reg/submissions/$(field "$1" .fold).cbor.hex" >/dev/null \
    || fail "$1: the saved signed body's upper slot differs from the receipt and actual selection"
}
fold_ok fold insert insertActive
[ "$(field fold .folder)" = "$bobkey" ] || fail "alice's request was not folded with bob's key"
jq -e --slurpfile e "$receipts/insert.json" --arg k "$(hexof "$key")" '.key == $k and .envelope == $e[0].envelope and (.liveOutput | test("#"))' \
  "$receipts/fold.json" >/dev/null || fail "the fold does not deliver alice's envelope at her key"
run inspect-1 success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
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
files_before="$(local_files)"
run bob-insert success -- registry insert --key "$bkey" --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
holds_envelope bob-insert .envelope "$bobkey" "$bkey" "$work/payload-insert.json" \
  || fail "bob's insert did not book his own key hash as controller"
booked bob-insert
booking_only bob-insert "$before" "$files_before"
[ "$(field bob-insert .requester)" = "$bobkey" ] || fail "the booking's requester is not bob's key"
[ ! -e "$reg/preimages" ] || fail "bob's booking kept an envelope in the registry directory"
# A funding output the folder's wallet does not hold is refused by name too.
refused fold-bad-funding client-refusal -- registry fold --fund-input "$(printf '%064d' 0)#0" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.reason | contains("cannot fund the fold")' "$receipts/fold-bad-funding.json" >/dev/null \
  || fail "the fold with a stranger's funding output does not say so: $(field fold-bad-funding .reason)"
# Alice folds bob's insertion: the request is named by nothing but being the
# one pending.
run bob-fold success -- registry fold "${common[@]}" "${node[@]}" "${alice[@]}"
fold_ok bob-fold bob-insert insertActive
[ "$(field bob-fold .folder)" = "$alicekey" ] || fail "bob's request was not folded with alice's key"
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
[ "$(field inspect-2 .root)" = "$(field bob-fold .root)" ] || fail "the update moved the root"
jq -e --slurpfile p "$work/payload.json" '.applicationOutput.payload == $p[0]' \
  "$receipts/inspect-2.json" >/dev/null || fail "the holding does not carry the new payload"

# ------------------------------------------------------------------
# 4. process boundaries on the actual target
# ------------------------------------------------------------------
# Retired local trie files cannot influence this acquired public read.
printf 'corrupt mirror\n' >"$reg/registry.mirror.json"
printf 'corrupt saved root\n' >"$reg/state.json"
run inspect-retired-files success -- registry inspect --key "$key" "${common[@]}" "${node[@]}"
jq -e --slurpfile before "$receipts/inspect-2.json" \
  '.leaf == $before[0].leaf and .root == $before[0].root' "$receipts/inspect-retired-files.json" >/dev/null \
  || fail "corrupt retired files changed the proven read"
[ "$(cat "$reg/registry.mirror.json")" = 'corrupt mirror' ] || fail "the retired mirror was rewritten"
[ "$(cat "$reg/state.json")" = 'corrupt saved root' ] || fail "the retired saved root was rewritten"
rm "$reg/registry.mirror.json" "$reg/state.json"
# A state token of another release: its policy is not this release's state
# script, refused by name before the provider is asked anything.
foreign="$(printf '%s' "$state" | tr 0123456789abcdef 123456789abcdef0).$token"
refused insert-foreign-release client-refusal -- registry insert --key keyC \
  --payload "$work/payload-insert.json" --registry "$reg" --blueprint "$blueprint" \
  --state-token "$foreign" "${node[@]}" "${alice[@]}"
jq -e '.reason | startswith("state-token-foreign-release")' "$receipts/insert-foreign-release.json" >/dev/null \
  || fail "insert-foreign-release: the refusal is not state-token-foreign-release"
# No node at all.
run inspect-no-node node-unavailable -- registry inspect --key "$key" "${common[@]}" \
  --koios-url http://127.0.0.1:1 --network-time "$time_directory" --network-magic "$network_magic"
[ "$(field inspect-no-node .leaf)" = null ] || fail "a leaf was printed with no node"
# A concurrent writer on the same target. An OS lock holder takes the
# target's actual lock (an fcntl open-file-description lock, which conflicts
# with the command's own fcntl lock) and is verified to hold it; the
# command is then refused without reading or submitting anything.
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
refused concurrent-writer concurrent-writer -- registry insert --key keyC \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
kill "$(cat "$work/lock.pid")" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
flock --fcntl --nonblock "$reg/.lock" true || setup_fail "the lock holder did not release $reg/.lock"
# The combined form: --fold books and then folds in the one process, by the
# routine `registry fold` runs, and prints both transactions.
run insert-after-release success -- registry insert --fold --key keyC \
  --payload "$work/payload-insert.json" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '(.booking | test("^[0-9a-f]{64}$")) and (.fold | test("^[0-9a-f]{64}$")) and .booking != .fold
    and (.liveOutput | test("#")) and has("root")' "$receipts/insert-after-release.json" >/dev/null \
  || fail "the combined insert does not name its booking, its fold and the output it delivered"

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
  "$singular" registry terminate --fold --key "$key" "${common[@]}" "${node[@]}" "${alice[@]}" \
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
# Public replay serves the included fold; journal observation is appended
# exactly once across the reconciling command and subsequent inspect.
[ "$(jq -s --arg t "$fold_tx" '[.[] | select(.journalTxId == $t and .journalEvent == "observed")] | length' "$reg/journal.jsonl")" = 1 ] \
  || fail "the killed fold was not observed exactly once"
[ "$(jq -s --arg t "$fold_tx" '[.[] | select(.journalTxId == $t and .journalEvent == "prepared")] | length' "$reg/journal.jsonl")" = 1 ] \
  || fail "the killed fold was prepared more than once"
say "the next write reconciled the killed fold from the chain once; inspect reads it terminal"

# ------------------------------------------------------------------
# 6. terminate bob normally; a write works again
# ------------------------------------------------------------------
before="$(journal_lines "$reg")"
files_before="$(local_files)"
run bob-terminate success -- registry terminate --key "$bkey" "${common[@]}" "${node[@]}" "${bob[@]}"
booked bob-terminate
booking_only bob-terminate "$before" "$files_before"
jq -e '(.released | test("^[0-9a-f]{64}#[0-9]+$")) and (.deposit | type == "number" and . > 0)' \
  "$receipts/bob-terminate.json" >/dev/null \
  || fail "the termination booking does not name the live output its fold will release"
run inspect-bob-booked success -- registry inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-bob-booked .leaf)" = active ] || fail "bob's key is not still active after a termination booking alone"
# Alice folds bob's termination, naming the request.
run bob-terminate-fold success -- registry fold --request "$(field bob-terminate .request)" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
fold_ok bob-terminate-fold bob-terminate updateTerminal
[ "$(field bob-terminate-fold .folder)" = "$alicekey" ] || fail "bob's termination was not folded with alice's key"
[ "$(field bob-terminate-fold .released)" = "$(field bob-terminate .released)" ] \
  || fail "the fold released another output than the booking named"
run inspect-4 success -- registry inspect --key "$bkey" "${common[@]}" "${node[@]}"
[ "$(field inspect-4 .leaf)" = terminal ] || fail "bob's key is not terminal"

# Every prepared body names the actual acquisition and its consumed facts.
# Inspect separately reports the latest tip it observed, without a snapshot promise.
prepared_scopes "$reg" | jq -e -s 'length > 0' >/dev/null \
  || fail "a write lacks its Unbound acquisition"
jq -e '(.observedTip | test("^[0-9]+\\.[0-9a-f]{64}$"))
  and (.sessionEvidence.binding == {kind:"Unbound"})' "$receipts/inspect-4.json" >/dev/null \
  || fail "inspect-4 lacks its actual latest observation and Unbound binding"
say "every write names its actual Unbound acquisition; inspect reports its separate latest observation"

# ------------------------------------------------------------------
# 7. create races and interruptions, on their own targets
# ------------------------------------------------------------------
# Two creates race for one target: bob's, on his own live seed, is held
# after its pre-lock checks while alice's completes; under the lock it must
# re-check the target and refuse RegistryExists (demo1_cli_create_race.sh).
race="${DEMO1_CREATE_RACE:-$(dirname "$0")/demo1_cli_create_race.sh}"
status=0
bash "$race" "$singular" "$blueprint" "$provider_url" "$time_directory" "$network_magic" "$work/alice.skey" "$work/bob.skey" "$work/race" || status=$?
case "$status" in
  0) ;;
  3) setup_fail "the create race never reached its target check" ;;
  *) fail "the create race control does not hold (exit $status)" ;;
esac
say "create race: the late create was refused RegistryExists; the first registry stands"

# A create killed after its first accepted submission: a new create is
# refused, and inspect reads the incomplete create from its journal.
inter="$work/interrupted"
run preview-inter success -- registry create --process-time 90000 --retract-time 30000 --preview --registry "$inter" \
  --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
seed_i="$(field preview-inter .seed)"
rm -f "$work/create.go" "$work/create.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/create.go" SINGULAR_HARNESS_HOLD_STEP=boot \
  "$singular" registry create --process-time 90000 --retract-time 30000 --seed "$seed_i" --registry "$inter" --blueprint "$blueprint" \
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
[ -e "$inter/registry.pending.json" ] || setup_fail "the create finished before it was killed"
inter_token="$(field preview-inter .stateToken)"
first_tx="$(jq -r 'select(.journalEvent == "submitted") | .journalTxId' "$inter/journal.jsonl")"
first_tx="${first_tx%%$'\n'*}"
inter_lines="$(journal_lines "$inter")"
run create-after-kill client-refusal -- registry create --process-time 90000 --retract-time 30000 --seed "$seed_i" --registry "$inter" \
  --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
[ "$(journal_lines "$inter")" = "$inter_lines" ] || fail "a create after the kill submitted something"
for _ in $(seq 1 60); do
  run inspect-interrupted partial -- registry inspect --key-hex 00 --registry "$inter" \
    --blueprint "$blueprint" --state-token "$inter_token" "${node[@]}"
  jq -e --arg t "$first_tx" '.observed | index($t)' "$receipts/inspect-interrupted.json" >/dev/null && break
  sleep 2
done
jq -e '.incompleteCreate.seed' "$receipts/inspect-interrupted.json" >/dev/null \
  || fail "inspect did not read the incomplete create's identity"
[ "$(field inspect-interrupted .leaf)" = null ] || fail "an incomplete create printed a leaf"
jq -e --arg t "$first_tx" 'select(.journalTxId == $t and .journalEvent == "observed")' \
  "$inter/journal.jsonl" >/dev/null || fail "the killed create's accepted submission was never observed"
run inspect-interrupted-other-token client-refusal -- registry inspect --key-hex 00 --registry "$inter" \
  --blueprint "$blueprint" --state-token "$state_token" "${node[@]}"
jq -e '.reason | startswith("state-token mismatch")' "$receipts/inspect-interrupted-other-token.json" >/dev/null \
  || fail "an interrupted create was read under another registry's token"
say "an interrupted create is refused a second boot and read back from its journal"

# A request nobody folds: alice books one more insertion and leaves it. The
# registry's fold takes every pending request, so this is the journey's last
# booking; the late fold below is its control.
before="$(journal_lines "$reg")"
files_before="$(local_files)"
run late-insert success -- registry insert --key keyD --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked late-insert
booking_only late-insert "$before" "$files_before"

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
refused fold-near client-refusal -- registry fold --request "$(field late-insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e --slurpfile l "$receipts/late-insert.json" --argjson m "$margin_ms" '
    (.reason | contains("within the") and contains("no fold is built") and (contains("could not be built") | not))
    and .foldDeadline.posixMs == $l[0].foldDeadline.posixMs and .pendingRequest == $l[0].request
    and (.remainingMs > 0 and .remainingMs <= $m) and (.hostClockMs + $m >= .foldDeadline.posixMs)
    and (.submissions | length == 0)' \
  "$receipts/fold-near.json" >/dev/null \
  || fail "the fold near the deadline was not refused up front, by name, with nothing submitted: $(field fold-near .reason)"
say "a fold near the deadline: refused up front by the guard, naming it, nothing signed or submitted"

# ------------------------------------------------------------------
# 7b. a fold that comes too late
# ------------------------------------------------------------------
# The request booked above is folded by no one until its processing deadline
# has passed. A fold of it is then refused by the client, quickly and by
# name, before anything is signed: the reason names the deadline and the
# receipt states it as the booking did.
deadline_ms="$(field late-insert .foldDeadline.posixMs)"
wait_ms=$((deadline_ms + 3000 - $(date +%s%3N)))
if [ "$wait_ms" -gt 0 ]; then
  say "waiting $((wait_ms / 1000 + 1)) s for the late request's processing deadline to pass"
  sleep $((wait_ms / 1000 + 1))
fi
started="$(date +%s)"
refused fold-late client-refusal -- registry fold --request "$(field late-insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
took=$(($(date +%s) - started))
jq -e --slurpfile l "$receipts/late-insert.json" '
    (.reason | contains("processing deadline") and contains("has passed"))
    and .foldDeadline.posixMs == $l[0].foldDeadline.posixMs and .pendingRequest == $l[0].request' \
  "$receipts/fold-late.json" >/dev/null \
  || fail "the late fold does not name the deadline and the request it left pending: $(field fold-late .reason)"
[ "$took" -le 30 ] || fail "the late fold took ${took}s to be refused; a client refusal reads one view and stops"
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
run inspect-late success -- registry inspect --key keyD "${common[@]}" "${node[@]}"
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
run inspect-before-reject success -- registry inspect --key keyD "${common[@]}" "${node[@]}"
run reject success -- registry reject "${common[@]}" "${node[@]}" "${bob[@]}"
[ "$(local_files)" = "$files_before" ] || fail "a reject altered identity or created retired trie files"
[ "$((($(journal_lines "$reg")) - before))" -eq 4 ] \
  || fail "the reject left $((($(journal_lines "$reg")) - before)) journal lines, expected its four phases"
tail -n +"$((before + 1))" "$reg/journal.jsonl" \
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
#    address and amount), read by `registry inspect` from the node;
#  - the tip, and the designated output's index and address, from the reject's
#    own signed body (state datum and outputs).
# A receipt that differs in any of them turns the journey red, and each binding is
# shown able to fail.
# What the node holds after the reject: the outputs at the owner's address.
run inspect-refund success -- registry inspect --key keyD --outputs-at "$alice_addr" "${common[@]}" "${node[@]}"
reject_tx="$(field reject .reject)"
booking_tx="$(field late-insert .booking)"
for t in "$reject_tx" "$booking_tx"; do
  [ "$(jq -s --arg t "$t" '[.[] | select(.journalTxId == $t and .journalEvent == "confirmed")] | length' "$reg/journal.jsonl")" = 1 ] \
    || fail "the journal does not show $t confirmed"
done
# body_bound TXID FILE: zero only when FILE's body hashes to TXID and its bytes to the journal's hash.
body_bound() {
  local id file="$2" computed saved
  computed="$(jq -R -r "$(cat "$work/cbor.jq") body_span" "$file" | tr -d '\n' | tr a-f A-F | basenc --base16 -d | b2sum -l 256 | cut -d' ' -f1)" || return 1
  saved="$(tr -d '\n' <"$file" | tr a-f A-F | basenc --base16 -d | b2sum -l 256 | cut -d' ' -f1)" || return 1
  id="$(jq -r --arg t "$1" 'select(.journalTxId == $t and .journalEvent == "prepared") | .journalBodyHash' "$reg/journal.jsonl")"
  [ "$computed" = "$1" ] && [ -n "$id" ] && [ "$saved" = "$id" ]
}
for t in "$reject_tx" "$booking_tx"; do
  body_bound "$t" "$reg/submissions/$t.cbor.hex" || fail "the saved body of $t is not the transaction it is claimed to be"
done
flip() { # one hex digit changed
  local c="${1:0:1}"
  [ "$c" = 0 ] && c=1 || c=0
  printf '%s%s' "$c" "${1:1}"
}
body_bound "$(flip "$reject_tx")" "$reg/submissions/$reject_tx.cbor.hex" \
  && fail "a body passed for a transaction id that is not its own"
# the same bytes with their last digit changed no longer match the journal's hash
# (the id, a hash of the body alone, still does)
body="$(cat "$reg/submissions/$reject_tx.cbor.hex")"
if [ "${body: -1}" = 0 ]; then last=1; else last=0; fi
printf "%s%s" "${body%?}" "$last" >"$work/body-tampered.hex"
cmp_status=0
cmp -s "$work/body-tampered.hex" "$reg/submissions/$reject_tx.cbor.hex" \
  || cmp_status=$?
case "$cmp_status" in
  0) setup_fail "the tampered body equals the saved one" ;;
  1) ;;
  *) setup_fail "the tampered body comparison could not run" ;;
esac
body_bound "$reject_tx" "$work/body-tampered.hex" \
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
run inspect-rejected success -- registry inspect --key keyD "${common[@]}" "${node[@]}"
[ "$(field inspect-rejected .root)" = "$root_before" ] || fail "the reject moved the registry's root"
[ "$(field inspect-rejected .leaf)" = unknown ] || fail "the rejected request's key is not unknown"
refused fold-after-reject client-refusal -- registry fold "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e '.reason | contains("nothing is pending")' "$receipts/fold-after-reject.json" >/dev/null \
  || fail "after the reject something is still pending: $(field fold-after-reject .reason)"
refused reject-nothing client-refusal -- registry reject "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e '.reason | contains("nothing is pending")' "$receipts/reject-nothing.json" >/dev/null \
  || fail "a reject with nothing pending does not say so: $(field reject-nothing .reason)"
# Cleared, the registry folds again: a new request is booked and folded.
run insert-after-reject success -- registry insert --key keyE --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert-after-reject
run fold-after-insert success -- registry fold --request "$(field insert-after-reject .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
fold_ok fold-after-insert insert-after-reject insertActive
run inspect-after-reject success -- registry inspect --key keyE "${common[@]}" "${node[@]}"
[ "$(field inspect-after-reject .leaf)" = active ] || fail "the fold after the reject did not make its key active"
say "a reject past both windows: refunded to the owner, root unmoved, and a new request folds"

# ------------------------------------------------------------------
# 7d. reclaim: the owner takes a pending insertion back in its window
# ------------------------------------------------------------------
run insert-to-reclaim success -- registry insert --key keyF --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert-to-reclaim
run inspect-before-reclaim success -- registry inspect --key keyF "${common[@]}" "${node[@]}"
root_before="$(field inspect-before-reclaim .root)"
files_before="$(local_files)"
before="$(journal_lines "$reg")"
deadline_ms="$(field insert-to-reclaim .foldDeadline.posixMs)"
wait_ms=$((deadline_ms + 1 - $(date +%s%3N)))
if [ "$wait_ms" -gt 0 ]; then
  say "waiting $wait_ms ms to attempt the owner's reclaim; the command judges the window from its own view"
  sleep "$((wait_ms / 1000)).$(printf '%03d' "$((wait_ms % 1000))")"
fi
refused fold-before-reclaim client-refusal -- registry fold --request "$(field insert-to-reclaim .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e '.reason | contains("processing deadline") and contains("has passed")' \
  "$receipts/fold-before-reclaim.json" >/dev/null || fail "the fold before reclaim was not refused for its deadline"
# A build failure, an unconverted window or a ledger refusal fails this success
# assertion. None can stand in for a reclaim or for a named refusal control.
run reclaim success -- registry reclaim --request "$(field insert-to-reclaim .request)" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
[ "$(local_files)" = "$files_before" ] || fail "the reclaim altered identity or created retired trie files"
tail -n +"$((before + 1))" "$reg/journal.jsonl" \
  | jq -s -e --arg t "$(field reclaim .retract)" '
      map(.journalEvent) == ["prepared", "submitted", "confirmed", "observed"]
      and (map(.journalStep) | unique == ["reclaim"])
      and (map(.journalTxId) | unique == [$t])' >/dev/null \
  || fail "reclaim did not leave exactly its four journal phases"
run inspect-after-reclaim success -- registry inspect --key keyF --outputs-at "$alice_addr" "${common[@]}" "${node[@]}"
retract_tx="$(field reclaim .retract)"
booking_tx="$(field insert-to-reclaim .booking)"
body_bound "$retract_tx" "$reg/submissions/$retract_tx.cbor.hex" || fail "the retract body is not the transaction claimed"
body_bound "$booking_tx" "$reg/submissions/$booking_tx.cbor.hex" || fail "the reclaimed booking body is not the transaction claimed"
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
run insert-after-reclaim success -- registry insert --key keyG --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${alice[@]}"
booked insert-after-reclaim
run fold-after-reclaim success -- registry fold --request "$(field insert-after-reclaim .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
fold_ok fold-after-reclaim insert-after-reclaim insertActive
run inspect-after-reclaim-fold success -- registry inspect --key keyG "${common[@]}" "${node[@]}"
[ "$(field inspect-after-reclaim-fold .leaf)" = active ] || fail "a new request did not fold after reclaim"
say "the owner's reclaim: whole bound return checked independently, root unchanged, and a new request folds"

# Local journal roots/edges are not trie reconstruction material. Copies of
# the settled registry with those records omitted or altered prove the same key.
boot_tx="$(jq -sr '[.[] | select(.journalEvent == "prepared" and .journalStep == "boot")] | first | .journalTxId' "$reg/journal.jsonl")"
for fault in missing-create missing-change broken-before wrong-after undecodable-edge; do
  copy="$work/coverage-$fault"
  cp -a "$reg" "$copy"
  case "$fault" in
    missing-create)
      jq -c --arg tx "$boot_tx" 'select(.journalTxId != $tx)' "$reg/journal.jsonl" >"$copy/journal.jsonl"
      ;;
    missing-change)
      jq -c 'select(.journalEdge == null)' "$reg/journal.jsonl" >"$copy/journal.jsonl"
      ;;
    broken-before)
      jq -c 'if .journalEvent == "prepared" then .journalRootBefore = "not-hex" else . end' "$reg/journal.jsonl" >"$copy/journal.jsonl"
      ;;
    wrong-after)
      jq -c 'if .journalEvent == "prepared" then .journalRootAfter = "not-hex" else . end' "$reg/journal.jsonl" >"$copy/journal.jsonl"
      ;;
    undecodable-edge)
      jq -c 'if .journalEvent == "prepared" then .journalEdge = 99 else . end' "$reg/journal.jsonl" >"$copy/journal.jsonl"
      ;;
  esac
  run "trie-local-$fault" success -- registry inspect --key keyG --registry "$copy" \
    --blueprint "$blueprint" --state-token "$state_token" "${node[@]}"
  jq -e --slurpfile correct "$receipts/inspect-after-reclaim-fold.json" \
    '.leaf == $correct[0].leaf and .root == $correct[0].root' "$receipts/trie-local-$fault.json" >/dev/null \
    || fail "altered local journal trie records changed the public read: $fault"
done
say "public history replay serves the same key despite omitted or altered local trie records"

# A real successful read with the harness entirely absent still returns the
# same key/leaf/root. It is separate from the instrumented extent, and preserves
# the release's existing proof that ordinary processes run without hooks.
status=0
env -u SINGULAR_HARNESS_TRIE_TRACE "$singular" registry inspect --key keyG \
  "${common[@]}" "${node[@]}" >"$receipts/trie-plain-inspect.json" 2>"$receipts/trie-plain-inspect.err" || status=$?
[ "$status" -eq 0 ] || fail "the ordinary untraced inspect did not succeed"
jq -e --slurpfile correct "$receipts/inspect-after-reclaim-fold.json" \
  '.outcome == "success" and .key == $correct[0].key and .leaf == $correct[0].leaf and .root == $correct[0].root' \
  "$receipts/trie-plain-inspect.json" >/dev/null || fail "the ordinary untraced inspect changed the actual proven read"

# Pre-migration sidecar callers are retired. A compiled subject mutation,
# rather than an old mirror binary against a sidecar-free registry, supplies
# the lineage source refusal control in the owner evidence bundle.

# ------------------------------------------------------------------
# 7. two actors (#419): bob folds alice's insertion from the chain alone
# ------------------------------------------------------------------
# Alice books an insertion from her own registry directory. Bob folds it
# from a directory of his own holding only her registry.json: no trie, no
# journal, nothing of her booking; the trie is rebuilt from chain history
# and the envelope is read from the request on the chain. Alice's directory
# is unreadable while bob runs, and every file access of bob's process is
# traced: one under alice's directory fails the run.
two="$work/two-actors"
two_alice="$two/alice"
two_bob="$two/bob"
mkdir -p "$two"
trap 'chmod -R u+rwx "$two_alice" 2>/dev/null || true; kill "$devnet_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
run two-preview success -- registry create --process-time 90000 --retract-time 30000 --preview \
  --registry "$two_alice" --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
run two-create success -- registry create --process-time 90000 --retract-time 30000 \
  --seed "$(field two-preview .seed)" --registry "$two_alice" --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
two_key=keyT
run two-insert success -- registry insert --key "$two_key" --payload "$work/payload-insert.json" \
  --registry "$two_alice" --blueprint "$blueprint" "${node[@]}" "${alice[@]}"
[ "$(field two-insert .requester)" = "$alicekey" ] || fail "the two-actor booking's requester is not alice's key"
mkdir -p "$two_bob"
cp "$two_alice/registry.json" "$two_bob/"
[ "$(ls -A "$two_bob")" = registry.json ] || fail "bob's directory holds more than alice's registry.json"
# touches_alice TRACE: the traced process named a path under alice's directory.
touches_alice() { grep -qF "$two_alice" "$1"; }
# The detector, shown able to fire: a deliberate open under alice's
# directory, traced the same way, is reported.
strace -f -qq -e trace=%file -o "$two/control.strace" cat "$two_alice/registry.json" >/dev/null 2>&1 || true
touches_alice "$two/control.strace" || fail "control: a deliberate open under alice's directory was not detected"
say "two actors: the access detector reports a deliberate open under alice's directory"
traced="$work/traced-singular"
printf '#!/usr/bin/env bash\nexec strace -f -qq -e trace=%%file -o "%s" "%s" "$@"\n' "$two/bob-fold.strace" "$singular" >"$traced"
# DEMO1_TWO_ACTOR_DELIBERATE_OPEN=1 is the run's own failing control: bob's
# traced process opens alice's registry.json before it folds, so the whole
# journey must fail at the access check below.
if [ "${DEMO1_TWO_ACTOR_DELIBERATE_OPEN:-}" = 1 ]; then
  printf '#!/usr/bin/env bash\nexec strace -f -qq -e trace=%%file -o "%s" bash -c '"'"'cat "%s" >/dev/null 2>&1; exec "%s" "$@"'"'"' singular "$@"\n' \
    "$two/bob-fold.strace" "$two_alice/registry.json" "$singular" >"$traced"
  say "two actors: the deliberate open control is on; bob's process opens alice's registry.json"
fi
chmod +x "$traced"
real_singular="$singular"
chmod 000 "$two_alice"
! ls "$two_alice" >/dev/null 2>&1 || fail "alice's directory is readable to the run"
singular="$traced"
run two-fold success -- registry fold --registry "$two_bob" --blueprint "$blueprint" "${node[@]}" "${bob[@]}"
singular="$real_singular"
chmod u+rwx "$two_alice"
[ -s "$two/bob-fold.strace" ] || setup_fail "bob's fold left no trace of its file accesses"
! touches_alice "$two/bob-fold.strace" || fail "bob's fold accessed alice's directory: $(grep -F "$two_alice" "$two/bob-fold.strace" | head -n 3)"
jq -e --slurpfile b "$receipts/two-insert.json" --arg k "$(hexof "$two_key")" --arg bob "$bobkey" '
    .request == $b[0].request and .folder == $bob and .edge == "insertActive"
    and .key == $k and .envelope == $b[0].envelope and (.liveOutput | test("#"))' \
  "$receipts/two-fold.json" >/dev/null \
  || fail "bob's fold does not deliver alice's envelope at her key"
run two-inspect success -- registry inspect --key "$two_key" --registry "$two_bob" --blueprint "$blueprint" "${node[@]}"
jq -e --slurpfile b "$receipts/two-insert.json" --slurpfile f "$receipts/two-fold.json" '
    .leaf == "active" and .applicationOutput.envelope == $b[0].envelope
    and .root == $f[0].root' "$receipts/two-inspect.json" >/dev/null \
  || fail "the key bob folded is not active under alice's envelope at her destination"
say "two actors: bob folded alice's insertion from registry.json alone; her envelope sits at her destination"

# ------------------------------------------------------------------
# 8. the node lost after an accepted submission (last: the node dies)
# ------------------------------------------------------------------
jq -n '{int: 42}' >"$work/payload-2.json"
before="$(journal_lines "$reg")"
rm -f "$work/update.go" "$work/update.go.waiting"
SINGULAR_HARNESS_HOLD_AFTER_SUBMIT="$work/update.go" SINGULAR_HARNESS_HOLD_STEP=update \
  "$singular" registry update --key keyC --payload "$work/payload-2.json" --confirm-timeout 30 \
  "${common[@]}" "${node[@]}" "${alice[@]}" >"$receipts/update-node-lost.json" 2>"$receipts/update-node-lost.err" &
victim=$!
for _ in $(seq 1 1200); do
  [ -e "$work/update.go.waiting" ] && break
  kill -0 "$victim" 2>/dev/null || break
  sleep 0.1
done
[ -e "$work/update.go.waiting" ] || setup_fail "the update never reached an accepted submission"
lost_tx="$(tail -n +"$((before + 1))" "$reg/journal.jsonl" | jq -r 'select(.journalEvent == "submitted") | .journalTxId')"
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
trie_extent
say "all eight stored-registry commands have nonempty capability evidence from actual executions"
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
say "JOURNEY-OK (Koios path)"
