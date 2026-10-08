#!/usr/bin/env bash
# The ordinary CLI's recovery controls (#325): what `singular registry`
# does after a lost acknowledgement or an interrupted local commit, on one
# generated development node, every command a separate process.
#
# usage: cli_recovery_controls.sh SINGULAR DEVNET BLUEPRINT WORKDIR REPO-ROOT
#
#   accepting: public replay proves an included fold at the ledger root.
#   lost answer: the next command observes the included fold once, never sends
#     it again, and proceeds from the fold's recorded after-root.
#   confirmed process killed: later commands recover observation through
#     public history, with no mirror or saved-root files.
#   never sent: an expired fold is excluded; an unbounded booking remains
#     unresolved, naming its transaction and case, without resubmission.
#   rolled back: restoring the generated DevNet database makes the public
#     replay reach the restored root; rollbacks are journalled once and the
#     next write names the unresolved case, sending nothing.
#
# The harness points are SINGULAR_HARNESS_* variables, inert when unset.
# Every verdict is computed from the receipts the processes printed, the
# registry's journal, its saved bodies and its files; none is typed. The
# verdict table is WORKDIR/verdicts.md. A setup failure (no node, no
# socket, a create that does not complete) exits 3 and is never a
# verdict; any clause that does not hold exits 1.
# shellcheck disable=SC2016 # single-quoted jq programs name jq variables, never shell ones
set -euo pipefail

# 50 MiB. Receipts hold the journal fields the cross-wallet predicates read
# and one exit code per alteration. Past this cap the run stops.
receipt_cap_bytes=52428800
receipt_bytes() {
  local s=0 n
  while IFS= read -r n; do
    s=$((s + n))
  done < <(find "$1" -type f -printf '%s\n' 2>/dev/null || true)
  printf '%d' "$s"
}
enforce_receipt_cap() {
  local bytes
  bytes="$(receipt_bytes "$1")"
  if [ "$bytes" -gt "$receipt_cap_bytes" ]; then
    echo "recovery: receipt bytes $bytes exceed $receipt_cap_bytes ($1)" >&2
    return 1
  fi
}
# Fields the cross-wallet predicates and their alterations actually read.
cross_evidence_filter='
def line:
  {journalTxId,journalEvent,journalCommand,journalInputs,journalKey,journalEdge,journalRootBefore,journalRootAfter,journalStep}
  | with_entries(select(.value != null));
def lines: map(line);
def projected_loss:
  if . == null then null
  else {outcome, submissions: [(.submissions // [])[] | {step, tx, case}]}
  end;
{fold:$fold,key:$key,point:$point,reached:$reached,folder:$folder,signers:$signers,clean:$clean,exit:$exit,
 loss:($loss | projected_loss),
 booking:($booking[0] | {outcome, request, booking, requester}),
 next:($next[0] | {outcome, reconciled: {observed: .reconciled.observed}}),
 inspect:($inspect[0] | {outcome, leaf, root}),
 booked:($booked | lines), held:($held | lines), after:($after | lines),
 roots:{before:$beforeRoot,booked:$bookedRoot,held:$heldRoot,after:$afterRoot}}'
# Fixture entries for the receipt-size check. Neither starts a node.
if [ "${1:-}" = "--project-evidence" ]; then
  [ "$#" -eq 3 ] || {
    echo "usage: $0 --project-evidence FIXTURE OUT" >&2
    exit 2
  }
  fixture="$2"
  out="$3"
  jq -n \
    --arg fold "$(jq -r .fold "$fixture/meta.json")" \
    --arg key "$(jq -r .key "$fixture/meta.json")" \
    --arg point "$(jq -r .point "$fixture/meta.json")" \
    --argjson reached "$(jq .reached "$fixture/meta.json")" \
    --arg folder "$(jq -r .folder "$fixture/meta.json")" \
    --argjson signers "$(jq .signers "$fixture/meta.json")" \
    --argjson clean "$(jq .clean "$fixture/meta.json")" \
    --argjson exit "$(jq .exit "$fixture/meta.json")" \
    --argjson loss "$(cat "$fixture/loss.json")" \
    --slurpfile booking "$fixture/booking.json" \
    --slurpfile next "$fixture/next.json" \
    --slurpfile inspect "$fixture/inspect.json" \
    --slurpfile booked "$fixture/booked.jsonl" \
    --slurpfile held "$fixture/held.jsonl" \
    --slurpfile after "$fixture/after.jsonl" \
    --arg beforeRoot "$(jq -r .before "$fixture/roots.json")" \
    --arg bookedRoot "$(jq -r .booked "$fixture/roots.json")" \
    --arg heldRoot "$(jq -r .held "$fixture/roots.json")" \
    --arg afterRoot "$(jq -r .after "$fixture/roots.json")" \
    "$cross_evidence_filter" >"$out"
  exit 0
fi
if [ "${1:-}" = "--receipt-cap" ]; then
  [ "$#" -eq 2 ] || {
    echo "usage: $0 --receipt-cap RECEIPTS-DIR" >&2
    exit 2
  }
  enforce_receipt_cap "$2"
  exit
fi

[ "$#" -eq 5 ] || {
  echo "usage: $0 SINGULAR DEVNET BLUEPRINT WORKDIR REPO-ROOT" >&2
  exit 2
}
singular="$1"
devnet="$2"
blueprint="$3"
work="$4"
root="$5"
[ ! -e "$work" ] || {
  echo "recovery: $work exists; every run takes a fresh directory" >&2
  exit 2
}
mkdir -p "$work"
work="$(cd "$work" && pwd)"
receipts="$work/receipts"
snaps="$work/snapshots"
mkdir -p "$receipts" "$snaps"
export SINGULAR_HARNESS_TRIE_TRACE="$work/direct-processes.trie.jsonl"
: >"$SINGULAR_HARNESS_TRIE_TRACE"
: >"$work/trie-command-invocations"
reg="$work/registry"
# shellcheck source=tools/managed_state.sh
source "$(dirname "$0")/managed_state.sh"
# The journal under test, reassigned per phase and writer: journals live in
# managed identity partitions, never directly at the configured root.
journal="$reg/journal.jsonl"
verdicts="$work/verdicts.md"

say() { echo "recovery: $*"; }
setup_fail() {
  echo "recovery: SETUP: $*" >&2
  exit 3
}
known_parts="accepting lost-answer killed cross-wallet never-sent whole-journal rollback trie-capability"
for requested in ${CLI_RECOVERY_PARTS:-}; do
  # cross-wallet:<hold>[:lost-answer] tokens are validated against the
  # source census below, before any node starts.
  [[ "$requested" == cross-wallet:* ]] && continue
  [[ " $known_parts " == *" $requested "* ]] || setup_fail "CLI_RECOVERY_PARTS names an unknown part: $requested (known: $known_parts)"
done
# The fold-path hold census (#451 re-cut): one shared source-derived list for
# discovery and execution, read before any node starts so an unknown
# cross-wallet:<hold> token is refused before a node exists.
cross_census() {
  local source line
  for source in Session Fold; do
    while IFS= read -r line; do
      if [[ "$line" =~ harnessHoldAt[[:space:]]+\"(SINGULAR_HARNESS_HOLD_[A-Z_]+)\" ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      fi
    done <"$root/offchain/cli/src/Singular/CLI/$source.hs"
  done | sort -u
}
mapfile -t fold_census < <(cross_census)
[ "${#fold_census[@]}" -gt 0 ] || setup_fail "the fold path declares no hold points"
cross_all=()
for point in "${fold_census[@]}"; do cross_all+=("cross-wallet:$point"); done
cross_all+=("cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer")
for requested in ${CLI_RECOVERY_PARTS:-}; do
  [[ "$requested" == cross-wallet:* ]] || continue
  case_ok=1
  for token in "${cross_all[@]}"; do
    if [ "$requested" = "$token" ]; then case_ok=0; fi
  done
  [ "$case_ok" -eq 0 ] || setup_fail "CLI_RECOVERY_PARTS names an unknown cross-wallet case: $requested (census: ${cross_all[*]})"
done

printf '| control | clause | verdict |\n|---|---|---|\n' >"$verdicts"
failed=0
declare -A part_clauses=()
current_part=""
control=""
# clause TEXT CMD...: the clause holds when CMD exits 0.
clause() {
  local text="$1"
  shift
  [ -z "$current_part" ] || part_clauses[$current_part]=$((${part_clauses[$current_part]:-0} + 1))
  if "$@" >/dev/null 2>&1; then
    printf '| %s | %s | holds |\n' "$control" "$text" >>"$verdicts"
    say "$control: holds: $text"
  else
    printf '| %s | %s | **does not hold** |\n' "$control" "$text" >>"$verdicts"
    say "$control: DOES NOT HOLD: $text"
    failed=1
  fi
}

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/alice.skey"
hexkey >"$work/bob.skey"

# ------------------------------------------------------------------
# One development node
# ------------------------------------------------------------------
export TMPDIR="$work"
harness_started=$(date +%s)
# The node-backed invocation's own measured wall time (#451 re-cut): setup
# and clause checks included, collection/upload excluded. Written at every
# exit, including refusals, so a missing record is honestly absent.
# shellcheck disable=SC2329 # the EXIT trap below invokes this
finish() {
  local code=$?
  local _wait
  trap - EXIT
  kill "${devnet_pid:-}" 2>/dev/null || true
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "cardano-node run --config $work/" >/dev/null 2>&1 || true
  fi
  for _wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
    if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -f "cardano-node run --config $work/" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  printf '{"part":"%s","elapsed_seconds":%d,"exit_code":%d}\n' \
    "${CLI_RECOVERY_PARTS:-all}" "$(($(date +%s) - harness_started))" "$code" \
    >"$work/node-execution-time.json" 2>/dev/null || true
  if ! enforce_receipt_cap "$receipts"; then
    code=1
  fi
  # DEMO1_KEEP_SCRATCH=1 keeps the run, including for the cross-wallet
  # collector that reads it after this script returns.
  if [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
    echo "kept scratch: $work" >&2
  else
    chmod -R u+rwx "$work" 2>/dev/null || true
    rm -rf "$work" || true
    if [ -e "$work" ]; then
      echo "scratch remains: $work" >&2
      code=1
    fi
  fi
  exit "$code"
}
trap finish EXIT
"$devnet" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" --fund-outputs 10 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
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
# probe_ins TXIN...: the node's own answer — its tip and which of TXIN
# are unspent — read through `devnet probe`, never through the CLI.
probe_ins() {
  local a=() t
  for t in "$@"; do a+=(--tx-in "$t"); done
  "$devnet" probe --node-socket "$sock" --network-magic 42 "${a[@]}"
}
common=(--state-dir "$reg" --blueprint "$blueprint")
alice=(--wallet-skey "$work/alice.skey")
bob=(--wallet-skey "$work/bob.skey")

# say_run NAME STATUS: a command's actual answer — its receipt's outcome and
# refusal reason when the receipt parses, an explicitly named absence
# otherwise, never replacing the command's own exit or the verdict signal.
say_run() {
  local name="$1" status="$2"
  if jq -e 'type == "object" and has("outcome")' "$receipts/$name.json" >/dev/null 2>&1; then
    say "$name: $(jq -r 'if .reason then .outcome + "/" + .reason else .outcome end' "$receipts/$name.json") (exit $status)"
  else
    say "$name: no parsable receipt (exit $status); stderr: $(head -n 1 "$receipts/$name.err" 2>/dev/null || echo none)"
  fi
}
# run NAME ARGS...: one singular process; its receipt and exit status kept.
run() {
  local name="$1"
  shift
  local status=0
  : >"$receipts/$name.trie.jsonl"
  SINGULAR_HARNESS_TRIE_TRACE="$receipts/$name.trie.jsonl" \
    "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  printf '%s\n' "$name" >>"$work/trie-command-invocations"
  echo "$status" >"$receipts/$name.exit"
  say_run "$name" "$status"
}
# held NAME VAR ARGS...: one singular process with the harness hold VAR set
# to a path, killed once it waits there. Returns 0 only when it was killed
# at the hold.
held() {
  local name="$1" var="$2"
  shift 2
  local go="$work/$name.go"
  rm -f "$go" "$go.waiting"
  : >"$receipts/$name.trie.jsonl"
  printf '%s\n' "$name" >>"$work/trie-command-invocations"
  env "SINGULAR_HARNESS_TRIE_TRACE=$receipts/$name.trie.jsonl" "$var=$go" \
    "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" &
  local victim=$!
  for _ in $(seq 1 1800); do
    [ -e "$go.waiting" ] && break
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.1
  done
  if [ -e "$go.waiting" ]; then
    kill -9 "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    say "$name: killed at its hold point"
    return 0
  fi
  local status=0
  wait "$victim" || status=$?
  say "$name: never reached its hold point (exit $status)"
  # A command that failed before its hold names its actual refusal, so the
  # historical before-hold failure shape is visible, not just its exit.
  say_run "$name" "$status"
  return 1
}
# paused NAME VAR CHECK ARGS...: one singular process with the harness hold
# VAR set to a path; while it waits there CHECK runs, then it is released
# and runs to its end. Returns 0 only when it reached the hold.
paused() {
  local name="$1" var="$2" check="$3"
  shift 3
  local go="$work/$name.go"
  rm -f "$go" "$go.waiting"
  : >"$receipts/$name.trie.jsonl"
  printf '%s\n' "$name" >>"$work/trie-command-invocations"
  env "SINGULAR_HARNESS_TRIE_TRACE=$receipts/$name.trie.jsonl" "$var=$go" \
    "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" &
  local victim=$!
  for _ in $(seq 1 1800); do
    [ -e "$go.waiting" ] && break
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.1
  done
  local reached=1
  if [ -e "$go.waiting" ]; then
    "$check"
    reached=0
    touch "$go"
  fi
  local status=0
  wait "$victim" || status=$?
  echo "$status" >"$receipts/$name.exit"
  say_run "$name" "$status"
  return "$reached"
}
field() { jq -r "$2" "$receipts/$1.json"; }
outcome_is() { [ "$(field "$1" .outcome)" = "$2" ]; }
exit_is() { [ "$(cat "$receipts/$1.exit")" = "$2" ]; }

# Content bound to actual completed commands, including their recovered
# folds. Held/killed processes keep their raw operation traces alongside
# the existing hold-point evidence; no synthetic receipt is supplied.
trie_extent() {
  local name receipt trace
  : >"$work/trie-command-extent.jsonl"
  while IFS= read -r name; do
    receipt="$receipts/$name.json"
    trace="$receipts/$name.trie.jsonl"
    if jq -e '.outcome == "success" and .preview != true' "$receipt" >/dev/null 2>&1; then
      jq -s -e --slurpfile r "$receipt" '
        $r[0] as $r
        | [.[] | select(.operation == "select" or .operation == "create")] as $selected
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
            any(.[]; .operation == "accept" and .rootAfter == $r.root
              and .output == ($r.fold + "#0"))
            and any(.[]; .operation == "speculateEdges" and .rootAfter == $r.root
              and .proofCount > 0 and (.proofs | type == "string"))
          elif $r.root? != null then any($selected[]; .root == $r.root)
          else true end)' "$trace" >/dev/null || return 1
      jq -c --slurpfile trace "$trace" \
        '{command, key, root, operations: ($trace | map(.operation)), executions: ($trace | length)}' \
        "$receipt" >>"$work/trie-command-extent.jsonl"
    fi
  done <"$work/trie-command-invocations"
  jq -s -e 'length > 1 and all(.executions > 0)
    and (map(.command) | unique | length > 1)' "$work/trie-command-extent.jsonl" >/dev/null
}

# Journal/body snapshots plus a read-only acquired public-root observation.
# A POSIX lock makes inspect skip reconciliation, so this observation cannot
# supply or alter the recovery journal being tested.
cat >"$work/read-root.py" <<'PY'
import fcntl, json, os, subprocess, sys
binary, registry, blueprint, *settings = sys.argv[1:]
with open(os.path.join(registry, ".lock"), "a") as lock:
    try:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass  # a deliberately held command already prevents reconciliation
    result = subprocess.run([binary, "registry", "inspect", "--key-hex", "00",
        "--state-dir", registry, "--blueprint", blueprint, *settings], capture_output=True, text=True,
        env={k: v for k, v in os.environ.items() if k != "SINGULAR_HARNESS_TRIE_TRACE"})
    receipt = json.loads(result.stdout)
    root = receipt.get("root")
    if not isinstance(root, str) or len(root) != 64:
        raise RuntimeError(f"public root unavailable: exit={result.returncode} receipt={receipt}")
    print(root)
PY
root_now() { python3 "$work/read-root.py" "$singular" "$reg" "$blueprint" --state-token "$state_token" "${node[@]}"; }
trie_files_absent() { [ -z "$(managed_find "$reg" state.json)" ] && [ -z "$(managed_find "$reg" registry.mirror.json)" ]; }
snap() {
  if [ -f "$journal" ]; then cp "$journal" "$snaps/$1.jsonl"; else : >"$snaps/$1.jsonl"; fi
  root_now >"$snaps/$1.root"
  find "$(dirname "$journal")/submissions" -type f -exec sha256sum {} + 2>/dev/null | sort >"$snaps/$1.bodies" || true
}
journal_same() { cmp -s "$snaps/$1.jsonl" "$journal"; }
# The journal at snapshot NAME is a byte prefix of the journal now, and
# every body saved then has the same bytes now.
appended_only() {
  cmp -s -n "$(stat -c %s "$snaps/$1.jsonl")" "$snaps/$1.jsonl" "$journal" || return 1
  while read -r sum path; do
    [ "$(sha256sum <"$path" | cut -d' ' -f1)" = "$sum" ] || return 1
  done <"$snaps/$1.bodies"
}
# Lines appended since snapshot NAME, as a JSON array.
since() { tail -c +"$(($(stat -c %s "$snaps/$1.jsonl") + 1))" "$journal" | jq -s .; }
# The journal's prepared line of TX.
prepared_of() { jq -c --arg t "$1" 'select(.journalTxId == $t and .journalEvent == "prepared")' "$journal"; }
prepared_once() { [ "$(jq -s --arg t "$1" '[.[] | select(.journalTxId == $t and .journalEvent == "prepared")] | length' "$journal")" = 1 ]; }
events_of() { jq -s -c --arg t "$1" '[.[] | select(.journalTxId == $t) | .journalEvent]' "$journal"; }
event_count() {
  jq -s --arg t "$1" --arg e "$2" '[.[] | select(.journalTxId == $t and .journalEvent == $e)] | length' "$journal"
}
last_event() { jq -s -r --arg t "$1" '[.[] | select(.journalTxId == $t)] | last | .journalEvent' "$journal"; }
# The fold this snapshot's command prepared.
fold_since() { since "$1" | jq -r '[.[] | select(.journalStep == "fold" and .journalEvent == "prepared")] | last | .journalTxId'; }
# The saved body named by TX's prepared line hashes to the journalled hash.
body_bound() {
  local p body want got
  p="$(prepared_of "$1")"
  body="$(jq -r .journalBody <<<"$p")"
  want="$(jq -r .journalBodyHash <<<"$p")"
  [ -f "$body" ] || return 1
  got="$(tr -d '\n' <"$body" | tr 'a-f' 'A-F' | basenc --base16 -d | b2sum -l 256 | cut -d' ' -f1)"
  [ "$got" = "$want" ]
}
root_before_of() { prepared_of "$1" | jq -r .journalRootBefore; }
root_after_of() { prepared_of "$1" | jq -r .journalRootAfter; }
submission_case() { field "$1" "[.submissions[]? | select(.step == \"$2\") | .case] | last"; }
submission_tx() { field "$1" "[.submissions[]? | select(.step == \"$2\") | .tx] | last"; }
# Equal, and about something: an empty or null value never matches.
is_equal() { [ -n "$1" ] && [ "$1" != null ] && [ "$1" = "$2" ]; }
is_txid() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

# The payload every insert here carries; the command builds the rest of the
# envelope from the registry, the key and the signing wallet.
insert_of() { args=(registry insert --fold --key-hex "$1" --payload "$work/insert-payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"); }

# ------------------------------------------------------------------
# The registry
# Recovery needs a fold that reaches its hold point. Allow time for booking
# and building on shared runners plus the CLI's unchanged 30-second signing
# margin; the former 45-second window left only 15 seconds for that work.
# ------------------------------------------------------------------
run preview registry create --process-time 120000 --retract-time 15000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
outcome_is preview success || setup_fail "create --preview did not succeed"
run create registry create --process-time 120000 --retract-time 15000 --seed "$(field preview .seed)" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.processTime == 120000 and .retractTime == 15000' "$receipts/create.json" >/dev/null \
  || setup_fail "the recovery registry did not read back the CI recovery windows"
outcome_is create success || setup_fail "create did not succeed"
token="$(field create .token)"
# Every later command names the registry by the state token create printed.
state_token="$(field create .stateToken)"
[[ "$state_token" =~ ^[0-9a-f]{56}\.[0-9a-f]{64}$ ]] || setup_fail "create printed no state token"
common+=(--state-token "$state_token")
# The recovery writer's journal: alice's managed partition under this root.
alicekey="$(field create .walletKeyHash)"
journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
jq -n '{map:[{k:{bytes:"6e616d65"},v:{bytes:"616c696365"}}]}' >"$work/insert-payload.json"
jq -n '{int: 42}' >"$work/payload.json"
say "registry $token created"

# An absent application source is refused by the ordinary write and shared
# preview planner, before a request or transaction can be left pending.
control="absent source"
absent_before="$(find "$reg" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
for command in update terminate; do
  extra=()
  [ "$command" != update ] || extra=(--payload "$work/payload.json")
  run "$command-absent" registry "$command" --key-hex 6d697373696e672d6b6579 \
    "${extra[@]}" "${common[@]}" "${node[@]}" "${alice[@]}"
  clause "$command of an absent key is refused before signing" exit_is "$command-absent" 10
  clause "$command names the absent source holding" is_equal \
    "$(field "$command-absent" '.outcome + "/" + .reason')" \
    'client-refusal/no live output holds key 0x6d697373696e672d6b6579'
  run "$command-absent-preview" registry "$command" --preview --key-hex 6d697373696e672d6b6579 \
    "${extra[@]}" "${common[@]}" "${node[@]}" --wallet-address "$(field preview .wallet)"
  clause "$command preview names the same absent source holding" is_equal \
    "$(field "$command-absent-preview" '.outcome + "/" + .reason')" \
    'client-refusal/no live output holds key 0x6d697373696e672d6b6579'
  clause "$command preview is refused" exit_is "$command-absent-preview" 10
done
clause "absent-source write and preview refusals leave every registry file unchanged" is_equal \
  "$(find "$reg" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)" "$absent_before"

# Reuse the journey's CBOR reader for the signed bodies, rather than add
# another decoder. Only the witness projection below is recovery-specific.
copying=0
while IFS= read -r line; do
  if [ "$line" = "cat >\"\$work/cbor.jq\" <<'JQ'" ]; then
    copying=1
    continue
  fi
  if [ "$copying" = 1 ]; then
    [ "$line" = JQ ] && break
    printf '%s\n' "$line" >>"$work/cbor.jq"
  fi
done <"$root/tools/demo1_cli_journey.sh"
[ -s "$work/cbor.jq" ] || setup_fail "the journey's CBOR reader was not found"
signers_of() {
  local key
  while read -r key; do
    [[ "$key" =~ ^[0-9a-f]{64}$ ]] || return 1
    tr 'a-f' 'A-F' <<<"$key" | tr -d '\n' | basenc --base16 -d | b2sum -l 224 | cut -d' ' -f1
  done < <(jq -R -r "$(cat "$work/cbor.jq")
    decode | .[1] | mapget(0) | (if type == \"object\" then .value else . end) | .[][0]" \
    "$(prepared_of "$1" | jq -r .journalBody)")
}
run bob-preview registry create --process-time 120000 --retract-time 15000 --preview --state-dir "$work/bob-preview" --blueprint "$blueprint" \
  "${node[@]}" "${bob[@]}"
outcome_is bob-preview success || setup_fail "the folder wallet's preview did not succeed"
bobkey="$(field bob-preview .walletKeyHash)"

# ------------------------------------------------------------------

# Parts (#449): CLI_RECOVERY_PARTS names the scenarios to run, space separated;
# unset runs them all. Each part runs on this script's own node and registry,
# so separate CI jobs run separate parts in parallel. "killed" needs "accepting".
# A name that is not a part fails here, and every part that runs must judge at
# least one clause, so a selection that matches nothing can never read as a pass.
part() {
  if [ -z "${CLI_RECOVERY_PARTS:-}" ] || [[ " $CLI_RECOVERY_PARTS " == *" $1 "* ]]; then
    current_part="$1"
    part_clauses[$1]="${part_clauses[$1]:-0}"
    return 0
  fi
  return 1
}
if part accepting; then
  # accepting
  # ------------------------------------------------------------------
  control=accepting
  clause "create stores identity and no retired trie files" trie_files_absent
  snap s0
  insert_of 6b0a
  run insert-a "${args[@]}"
  book="$(submission_tx insert-a book)"
  fold="$(submission_tx insert-a fold)"
  clause "the insert succeeds" outcome_is insert-a success
  clause "its receipt names the booking's case included" is_equal "$(submission_case insert-a book)" included
  clause "its receipt names the fold's case included" is_equal "$(submission_case insert-a fold)" included
  clause "the booking was prepared, acknowledged, included and observed, once each" \
    is_equal "$(events_of "$book")" '["prepared","submitted","confirmed","observed"]'
  clause "the fold was prepared, acknowledged, included and observed, once each" \
    is_equal "$(events_of "$fold")" '["prepared","submitted","confirmed","observed"]'
  clause "the receipt's root is that root" is_equal "$(field insert-a .root)" "$(root_after_of "$fold")"
  run inspect-a registry inspect --key-hex 6b0a "${common[@]}" "${node[@]}"
  clause "inspect reads the key active at that root" \
    is_equal "$(field inspect-a '.outcome + "/" + .leaf + "/" + .root')" "success/active/$(root_after_of "$fold")"
  clause "the journal was only appended to and no body changed" appended_only s0

  # The released executable reads the same public lineage in both directories.
  # Retired files are intentionally corrupted, without changing the identity,
  # journal or provider. The original directory remains available to the story.
  control="retired trie files are unreachable"
  clean_source="$work/clean-trie-source"
  corrupt_source="$work/corrupt-trie-source"
  cp -a "$reg" "$clean_source"
  cp -a "$reg" "$corrupt_source"
  rm -f "$clean_source/registry.mirror.json" "$clean_source/state.json"
  printf 'corrupted mirror\n' >"$corrupt_source/registry.mirror.json"
  printf 'corrupted saved root\n' >"$corrupt_source/state.json"
  for source in clean corrupt; do
    source_dir="$clean_source"
    [ "$source" != corrupt ] || source_dir="$corrupt_source"
    run "inspect-$source-source" registry inspect --key-hex 6b0a \
      --state-dir "$source_dir" --blueprint "$blueprint" --state-token "$state_token" "${node[@]}"
    clause "$source directory reads the active key from public history" \
      is_equal "$(field "inspect-$source-source" '.outcome + "/" + .leaf')" success/active
  done
  clause "missing and corrupted retired files give the same root and leaf" \
    is_equal "$(field inspect-clean-source '[.outcome,.root,.leaf] | tojson')" \
    "$(field inspect-corrupt-source '[.outcome,.root,.leaf] | tojson')"
  clause "the corrupted mirror is never rewritten" \
    is_equal "$(cat "$corrupt_source/registry.mirror.json")" 'corrupted mirror'
  clause "the corrupted saved root is never rewritten" \
    is_equal "$(cat "$corrupt_source/state.json")" 'corrupted saved root'
  clause "the clean directory creates neither retired file" \
    bash -c '[ ! -e "$1/registry.mirror.json" ] && [ ! -e "$1/state.json" ]' _ "$clean_source"

  # Preview deliberately stays untraced in the release journey's ordinary
  # process control. Here its separate actual trace binds the selected root to
  # the measured receipt, and a missing checked create must refuse the same read.
  control="preview trie access"
  preview_before="$(find "$reg" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  for command in update terminate; do
    extra=()
    [ "$command" != update ] || extra=(--payload "$work/payload.json")
    name="$command-active-preview"
    run "$name" registry "$command" --preview --key-hex 6b0a \
      "${extra[@]}" "${common[@]}" "${node[@]}" --wallet-address "$(field preview .wallet)"
    clause "$command preview succeeds on the active source" outcome_is "$name" success
    clause "$command preview consumes the capability selection at its reported root" \
      jq -s -e --slurpfile r "$receipts/$name.json" --arg root "$(root_after_of "$fold")" '
      $r[0].preview == true and $r[0].stateRoot == $root
      and any(.[]; .operation == "select" and .root == $root
        and (.identity.policy | test("^[0-9a-f]{56}$"))
        and (.identity.name | test("^[0-9a-f]+$"))
        and (.output | test("^[0-9a-f]{64}#[0-9]+$")))
    ' "$receipts/$name.trie.jsonl"
  done
  preview_copy="$work/preview-incomplete"
  cp -a "$reg" "$preview_copy"
  preview_rel="$(realpath --relative-to="$reg" "$journal")"
  boot_ids="$(jq -sc '[.[] | select(.journalStep == "boot") | .journalTxId] | unique' "$journal")"
  jq -c --argjson ids "$boot_ids" 'select(.journalTxId as $id | $ids | index($id) | not)' \
    "$preview_copy/$preview_rel" >"$work/preview-incomplete-journal"
  mv "$work/preview-incomplete-journal" "$preview_copy/$preview_rel"
  preview_copy_before="$(find "$preview_copy" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  run preview-incomplete registry update --preview --key-hex 6b0a --payload "$work/payload.json" \
    --state-dir "$preview_copy" --blueprint "$blueprint" --state-token "$state_token" "${node[@]}" --wallet-address "$(field preview .wallet)"
  clause "preview succeeds without the local boot journal" exit_is preview-incomplete 0
  clause "preview without local boot records reads the same public root" is_equal \
    "$(field preview-incomplete .stateRoot)" "$(field update-active-preview .stateRoot)"
  clause "preview leaves its incomplete copy unchanged" is_equal \
    "$(find "$preview_copy" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)" "$preview_copy_before"
  clause "successful previews leave every original registry file unchanged" is_equal \
    "$(find "$reg" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)" "$preview_before"
  if [ "${SINGULAR_RECOVERY_SOURCE_ONLY:-0}" = 1 ]; then
    say "retired-files and preview controls only: exit $failed; full recovery was not executed"
    exit "$failed"
  fi

# ------------------------------------------------------------------
fi
if part lost-answer; then
  # lost answer
  # ------------------------------------------------------------------
  control="lost answer"
  snap s1
  # Held right after the fold is sent, before its answer is journalled: what
  # is on disk at that moment is what the send was preceded by.
  at_send() {
    sent_tx="$(fold_since s1)"
    sent_last="$(last_event "$sent_tx")"
    sent_bound=1
    body_bound "$sent_tx" && sent_bound=0
  }
  sent_tx="" sent_last="" sent_bound=1 reached=0
  export SINGULAR_HARNESS_DROP_ANSWER=fold SINGULAR_HARNESS_HOLD_STEP=fold
  insert_of 6b0b
  paused insert-b SINGULAR_HARNESS_HOLD_AFTER_SEND at_send "${args[@]}" || reached=1
  unset SINGULAR_HARNESS_DROP_ANSWER SINGULAR_HARNESS_HOLD_STEP
  lost="$(submission_tx insert-b fold)"
  clause "the insert was held once its fold was sent, before the answer was journalled" is_equal "$reached" 0
  clause "at that moment the fold's prepared line was its last journalled phase" is_equal "$sent_last" prepared
  clause "at that moment the fold's body was saved, bound to its prepared line by hash" is_equal "$sent_bound" 0
  clause "the held fold is the one the receipt names" is_equal "$sent_tx" "$lost"
  clause "the insert stops partial (exit 15)" exit_is insert-b 15
  clause "its receipt names the booking's case included" is_equal "$(submission_case insert-b book)" included
  clause "its receipt names the fold's case unknown" is_equal "$(submission_case insert-b fold)" unknown
  clause "the fold's last journalled phase is submit-unknown" is_equal "$(last_event "$lost")" submit-unknown
  # The next ordinary write. While the fold is not yet on chain it is
  # refused before building anything; once it is, it reconciles and proceeds.
  refusals_clean=0
  for i in $(seq 1 40); do
    snap "s1-try-$i"
    insert_of 6b0c
    run insert-c "${args[@]}"
    outcome_is insert-c partial || break
    if ! journal_same "s1-try-$i" || ! trie_files_absent "s1-try-$i" || ! trie_files_absent "s1-try-$i" \
      || [ "$(field insert-c .unresolved.tx)" != "$lost" ]; then
      refusals_clean=1
    fi
    sleep 2
  done
  clause "every write refused while the fold was unknown named it and moved nothing" is_equal "$refusals_clean" 0
  clause "the next write reconciles and succeeds" outcome_is insert-c success
  clause "it observed the lost fold" is_equal "$(field insert-c "[.reconciled.observed[]? | select(. == \"$lost\")] | length")" 1
  clause "the lost fold was prepared once, never sent again" prepared_once "$lost"
  clause "the lost fold is observed exactly once in the journal" is_equal "$(event_count "$lost" observed)" 1
  clause "the lost fold's observation was journalled by the reconciling insert" \
    is_equal "$(since s1 | jq -r --arg t "$lost" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
  clause "the fold started from the root before the lost answer" is_equal "$(root_before_of "$lost")" "$(cat "$snaps/s1.root")"
  clause "the next fold started from the lost fold's root after: one edge between" \
    is_equal "$(root_before_of "$(submission_tx insert-c fold)")" "$(root_after_of "$lost")"
  run inspect-b registry inspect --key-hex 6b0b "${common[@]}" "${node[@]}"
  clause "inspect reads the lost answer's key active" is_equal "$(field inspect-b '.outcome + "/" + .leaf')" success/active
  clause "the journal was only appended to and no body changed" appended_only s1

# ------------------------------------------------------------------
fi
if part killed; then
  # killed before the commit
  # ------------------------------------------------------------------
  control="killed before observation"
  snap s2
  reached=0
  insert_of 6b0d
  held insert-d SINGULAR_HARNESS_HOLD_BEFORE_COMMIT "${args[@]}" || reached=1
  clause "the insert was killed after its fold was confirmed, before observation" is_equal "$reached" 0
  killed_fold="$(fold_since s2)"
  clause "the fold's last journalled phase is confirmed" is_equal "$(last_event "$killed_fold")" confirmed
  snap s2-killed
  run update-a registry update --key-hex 6b0a --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"
  clause "the next write, an update of another key, reconciles and succeeds" outcome_is update-a success
  clause "the killed fold is observed exactly once, by the update" \
    is_equal "$(since s2-killed | jq -r --arg t "$killed_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" update
  clause "the killed fold was prepared once, never sent again" prepared_once "$killed_fold"
  clause "the fold started from the root before the kill" is_equal "$(root_before_of "$killed_fold")" "$(cat "$snaps/s2.root")"
  clause "the confirmed killed fold left no retired trie files" trie_files_absent
  run inspect-d registry inspect --key-hex 6b0d "${common[@]}" "${node[@]}"
  clause "inspect reads the killed insert's key active" is_equal "$(field inspect-d '.outcome + "/" + .leaf')" success/active
  clause "the journal was only appended to and no body changed" appended_only s2

  # ------------------------------------------------------------------
  # killed before the observation
  # ------------------------------------------------------------------
  control="killed before the observation"
  snap s5
  reached=0
  insert_of 6b10
  held insert-g SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED "${args[@]}" || reached=1
  clause "the insert reached the hold before observation" is_equal "$reached" 0
  written_fold="$(fold_since s5)"
  clause "the fold's last journalled phase is confirmed" is_equal "$(last_event "$written_fold")" confirmed
  snap s5-killed
  insert_of 6b11
  run insert-h "${args[@]}"
  clause "the next write reconciles and succeeds" outcome_is insert-h success
  clause "the killed fold is observed exactly once, by the insert" \
    is_equal "$(since s5-killed | jq -r --arg t "$written_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
  clause "the killed fold was prepared once, never sent again" prepared_once "$written_fold"
  clause "the next fold started from the killed fold's root after: one edge between" \
    is_equal "$(root_before_of "$(submission_tx insert-h fold)")" "$(root_after_of "$written_fold")"
  run inspect-g registry inspect --key-hex 6b10 "${common[@]}" "${node[@]}"
  clause "inspect reads the killed insert's key active" is_equal "$(field inspect-g '.outcome + "/" + .leaf')" success/active
  clause "the journal was only appended to and no body changed" appended_only s5

# ------------------------------------------------------------------
fi
cross_any=1
if [ -n "${CLI_RECOVERY_PARTS:-}" ]; then
  cross_any=0
  for token in cross-wallet "${cross_all[@]}"; do
    if [[ " $CLI_RECOVERY_PARTS " == *" $token "* ]]; then cross_any=1; fi
  done
fi
if [ "$cross_any" -eq 1 ]; then
  # another wallet's fold at every hold supported by the fold path
  # ------------------------------------------------------------------
  # The source census above supplies the cases, not a source-text verdict:
  # every selected case is reached on the node and has receipt/journal
  # predicates below. Selecting one token narrows this invocation's extent;
  # the aggregate selector (or no selection) runs every case.
  cross_wants() {
    [ -z "${CLI_RECOVERY_PARTS:-}" ] && return 0
    [[ " $CLI_RECOVERY_PARTS " == *" cross-wallet "* ]] && return 0
    [[ " $CLI_RECOVERY_PARTS " == *" $1 "* ]]
  }
  cross_index_of() {
    local i=1 token
    for token in "${cross_all[@]}"; do
      [ "$token" = "$1" ] && {
        printf '%s\n' "$i"
        return 0
      }
      i=$((i + 1))
    done
    return 1
  }
  # The ran-proof key a case's clauses count under: its own token when that
  # token was requested, else the aggregate selector every case serves.
  cross_key_for() {
    if [ -n "${CLI_RECOVERY_PARTS:-}" ] && [[ " $CLI_RECOVERY_PARTS " == *" $1 "* ]]; then
      printf '%s\n' "$1"
    else
      printf 'cross-wallet\n'
    fi
  }
  cross_cases=()
  for token in "${cross_all[@]}"; do
    if cross_wants "$token"; then cross_cases+=("$token"); fi
  done
  [ "${#cross_cases[@]}" -gt 0 ] || setup_fail "no cross-wallet case is selected"
  printf '%s\n' "${fold_census[@]}" >"$work/fold-holds.list"
  # Mutations change copies of real evidence, never the registry being reconciled.
  # Multiple mutations per clause discriminate its distinct conjuncts.
  cross_clause() {
    local text="$1" predicate="$2" mutation status mutant red mutation_no=0
    shift 2
    clause "$text" jq -e "$predicate" "$cross_evidence"
    for mutation in "$@"; do
      mutation_no=$((mutation_no + 1))
      mutant="$receipts/$cross-$cross_check-$mutation_no-tampered.json"
      red="$receipts/$cross-$cross_check-$mutation_no-red"
      jq "$mutation" "$cross_evidence" >"$mutant"
      status=0
      jq -e "$predicate" "$mutant" >"$red.out" 2>"$red.err" || status=$?
      echo "$status" >"$red.exit"
      say "$control: altered evidence for '$text' ($mutation_no): exit $status"
      # jq's false verdict is 1. A parse/setup error cannot prove rejection.
      clause "altered evidence $mutation_no is rejected: $text" is_equal "$status" 1
      clause "alteration $mutation_no changed evidence: $text" bash -c '! cmp -s "$1" "$2"' _ "$cross_evidence" "$mutant"
      rm -f "$mutant" "$red.out" "$red.err"
    done
    cross_check=$((cross_check + 1))
  }
  # The case's own starting state (#451 re-cut): each selected case's next
  # ordinary write updates a key this invocation inserted itself through the
  # real ordinary CLI — one key per case, because an update retires the key
  # it writes — so a cross-wallet-only selection judges recovery, never
  # another part's setup (the killed part owns 6b0d; these keys are its own,
  # indexed by the case's census position for stability under selection).
  cross_prereq=0
  for cross_case in "${cross_cases[@]}"; do
    point="${cross_case#cross-wallet:}"
    point="${point%%:*}"
    cross_index="$(cross_index_of "$cross_case")"
    cross="cross-$cross_index"
    credit="$(cross_key_for "$cross_case")"
    current_part="$credit"
    part_clauses[$credit]="${part_clauses[$credit]:-0}"
    printf -v key '6d%02x' "$cross_index"
    printf -v next_key '6e%02x' "$((cross_index - 1))"
    control="the part's own starting state"
    insert_of "$next_key"
    run "insert-cross-state-$((cross_index - 1))" "${args[@]}"
    clause "the case's prerequisite insert of $next_key succeeds" \
      outcome_is "insert-cross-state-$((cross_index - 1))" success
    if outcome_is "insert-cross-state-$((cross_index - 1))" success; then
      cross_prereq=$((cross_prereq + 1))
    fi
    control="another wallet's fold at ${cross_case#cross-wallet:}"
    journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
    snap "$cross-before"
    run "$cross-book" registry insert --key-hex "$key" --payload "$work/insert-payload.json" \
      "${common[@]}" "${node[@]}" "${alice[@]}"
    snap "$cross-booked"
    # Bob's folds journal to his own partition under the same root and token.
    journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
    snap "$cross-bob-before"
    reached=0
    export SINGULAR_HARNESS_HOLD_STEP=fold
    if [[ "$cross_case" == *:lost-answer ]]; then
      # Hold at the send, witness the saved prepared body, release the process
      # with its answer dropped, then let the next ordinary command reconcile.
      export SINGULAR_HARNESS_DROP_ANSWER=fold
      at_cross_send() { snap "$cross-sent"; }
      paused "$cross-fold" "$point" at_cross_send registry fold \
        --request "$(field "$cross-book" .request)" "${common[@]}" "${node[@]}" "${bob[@]}" || reached=1
      unset SINGULAR_HARNESS_DROP_ANSWER
    else
      held "$cross-fold" "$point" registry fold --request "$(field "$cross-book" .request)" \
        "${common[@]}" "${node[@]}" "${bob[@]}" || reached=1
    fi
    unset SINGULAR_HARNESS_HOLD_STEP
    # The fold's offset is measured in its own writer's journal.
    cross_fold="$(fold_since "$cross-bob-before")"
    snap "$cross-held"
    # Alice's updates journal to her partition again.
    journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
    refusals_clean=0
    for i in $(seq 1 40); do
      snap "$cross-try-$i"
      run "$cross-next" registry update --key-hex "$next_key" --payload "$work/payload.json" \
        "${common[@]}" "${node[@]}" "${alice[@]}"
      outcome_is "$cross-next" partial || break
      if ! journal_same "$cross-try-$i" || ! trie_files_absent "$cross-try-$i" || ! trie_files_absent "$cross-try-$i" \
        || [ "$(field "$cross-next" .unresolved.tx)" != "$cross_fold" ]; then refusals_clean=1; fi
      # Retain every refusal; the next run otherwise reuses the receipt name.
      cp "$receipts/$cross-next.json" "$receipts/$cross-refused-$i.json"
      # The comparison has been recorded. The copy is a full journal.
      rm -f "$snaps/$cross-try-$i.jsonl"
      sleep 2
    done
    snap "$cross-next"
    run "$cross-inspect" registry inspect --key-hex "$key" "${common[@]}" "${node[@]}"
    loss=null
    if [[ "$cross_case" == *:lost-answer ]]; then loss="$(cat "$receipts/$cross-fold.json")"; fi
    cross_evidence="$receipts/$cross-evidence.json"
    jq -n --arg fold "$cross_fold" --arg key "$key" --arg point "$point" --argjson reached "$reached" \
      --arg folder "$bobkey" --argjson signers "$(signers_of "$cross_fold" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
      --argjson clean "$refusals_clean" --argjson exit "$(cat "$receipts/$cross-next.exit")" --argjson loss "$loss" \
      --slurpfile booking "$receipts/$cross-book.json" --slurpfile next "$receipts/$cross-next.json" \
      --slurpfile inspect "$receipts/$cross-inspect.json" \
      --slurpfile booked "$snaps/$cross-booked.jsonl" --slurpfile held "$snaps/$cross-held.jsonl" \
      --slurpfile after "$snaps/$cross-next.jsonl" \
      --arg beforeRoot "$(cat "$snaps/$cross-before.root")" --arg bookedRoot "$(cat "$snaps/$cross-booked.root")" \
      --arg heldRoot "$(cat "$snaps/$cross-held.root")" --arg afterRoot "$(root_now)" \
      "$cross_evidence_filter" >"$cross_evidence"
    enforce_receipt_cap "$receipts" || exit 1
    cross_check=1
    cross_clause "the requester booked only, leaving the public root unchanged" \
      '. as $e | .booking.outcome == "success" and .booking.request == (.booking.booking + "#0")
      and ([.booked[] | select(.journalTxId == $e.booking.booking) | .journalEvent] == ["prepared","submitted","confirmed","observed"])
      and .roots.before == .roots.booked' \
      '.roots.booked += "tampered"' '.booking.outcome = "partial"' \
      '.booking.request += "tampered"' '.booked += .booked'
    cross_clause "the fold's saved signed body carries the other wallet's payment key" \
      '(.folder | test("^[0-9a-f]{56}$")) and (.booking.requester | test("^[0-9a-f]{56}$"))
      and .signers == [.folder] and .folder != .booking.requester' \
      '.signers = [.booking.requester]' '.signers = []' '.folder = .booking.requester | .signers = [.folder]'
    cross_clause "the standalone fold reached its hold and had not been observed" \
      '. as $e | .reached == 0 and (.fold | test("^[0-9a-f]{64}$"))
      and ([.held[] | select(.journalTxId == $e.fold and .journalEvent == "observed")] | length) == 0
      and ([.held[] | select(.journalTxId == $e.fold and .journalEvent == "prepared") | .journalCommand] == ["fold"])' \
      '.reached = 1' '.fold = "not-a-transaction"' \
      '. as $e | .held += [(.held[] | select(.journalTxId == $e.fold and .journalEvent == "prepared") | .journalEvent = "observed")]' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalCommand = "insert" else . end)'
    cross_clause "the fold spent the booked request on its insertion edge" \
      '. as $e | [.held[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")]
      | length == 1 and (.[0] | .journalInputs | index($e.booking.request)) != null
      and .[0].journalKey == $e.key and .[0].journalEdge == 1 and .[0].journalRootBefore == $e.roots.before
      and .[0].journalRootAfter != .[0].journalRootBefore' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalInputs = [] else . end)' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalKey += "tampered" else . end)' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalEdge = 3 else . end)' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalRootBefore += "tampered" else . end)' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalRootAfter = .journalRootBefore else . end)'
    cross_clause "the next ordinary write proceeds, and any pending refusals name the fold and move nothing" \
      '.exit == 0 and .next.outcome == "success" and .clean == 0' \
      '.next.outcome = "partial"' '.exit = 15' '.clean = 1'
    cross_clause "the public lineage reaches the confirmed fold's recorded after-root" \
      '. as $e | [.held[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")][0].journalRootAfter == .roots.after' \
      '.roots.after += "tampered"' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalRootAfter += "tampered" else . end)'
    cross_clause "the fold is confirmed and observed exactly once, by the requester's next write when needed" \
      '. as $e | .next.reconciled.observed == [.fold]
      and ([.after[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed")] | length) == 1
      and ([.after[] | select(.journalTxId == $e.fold and .journalEvent == "observed") | .journalCommand] == ["update"])
      and (if ([.held[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed")] | length) == 0
           then [.after[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed") | .journalCommand] == ["update"] else true end)' \
      '.next.reconciled.observed += [.fold]' \
      '. as $e | .after += [.after[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed")]' \
      '. as $e | .after += [.after[] | select(.journalTxId == $e.fold and .journalEvent == "observed")]'
    cross_clause "there is no second preparation or submission of the fold or its request" \
      '. as $e | ([.after[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")] | length) == 1
      and ([.after[] | select(.journalTxId == $e.fold and .journalEvent == "submitted")] | length)
        == ([.held[] | select(.journalTxId == $e.fold and .journalEvent == "submitted")] | length)
      and ([.after[] | select(.journalStep == "fold" and .journalEvent == "prepared" and (.journalInputs | index($e.booking.request)) != null)] | length) == 1' \
      '. as $e | .after += [.after[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")]' \
      '. as $e | .after += [(.after[] | select(.journalTxId == $e.fold and .journalEvent == "prepared") | .journalEvent = "submitted")]' \
      '. as $e | .after += [(.after[] | select(.journalTxId == $e.fold and .journalEvent == "prepared") | .journalTxId = "second-fold")]'
    cross_clause "the ledger and local files agree at the folded key and root" \
      '. as $e | [.held[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")][0] as $p
      | .inspect.outcome == "success" and .inspect.leaf == "active"
      and .inspect.root == $p.journalRootAfter and .roots.after == .inspect.root' \
      '.inspect.outcome = "partial"' '.inspect.leaf = "unknown"' '.inspect.root += "tampered"' '.roots.after += "tampered"'
    if [[ "$cross_case" == *:lost-answer ]]; then
      cross_clause "the dropped answer's receipt names the unknown fold" \
        '. as $e | .loss.outcome == "partial" and [.loss.submissions[] | select(.step == "fold") | [.tx,.case]] == [[$e.fold,"unknown"]]' \
        '.loss.outcome = "success"' '.loss.submissions = []' \
        '.loss.submissions |= map(if .step == "fold" then .case = "included" else . end)'
      clause "at the send the bound body and prepared phase were already saved" \
        is_equal "$(jq -sr --arg t "$cross_fold" '[.[] | select(.journalTxId == $t) | .journalEvent] | join(",")' "$snaps/$cross-sent.jsonl")" prepared
    fi
    clause "the saved signed body is bound to its prepared line" body_bound "$cross_fold"
    clause "the journal was only appended to and no saved body changed" appended_only "$cross-before"
    rm -f "$snaps/$cross"-*.jsonl
  done
  # The two runtime extents must agree for this invocation: a selected case
  # without its own prerequisite, or a prerequisite no selected case owns,
  # fails here by name. The full source census remains the acceptance
  # extent; the hosted matrix must cover every case between its parts.
  control="fold hold-point coverage"
  current_part="$(cross_key_for "${cross_cases[0]}")"
  clause "every selected case has its own prerequisite insert: extents agree" \
    is_equal "$cross_prereq" "${#cross_cases[@]}"
  clause "the prerequisite inserts left no retired trie files" trie_files_absent
  mapfile -t cross_selected_points < <(
    for token in "${cross_cases[@]}"; do
      point="${token#cross-wallet:}"
      printf '%s\n' "${point%%:*}"
    done | sort -u
  )
  jq -s --argjson declared "$(printf '%s\n' "${cross_selected_points[@]}" | jq -Rsc 'split("\n") | map(select(. != "")) | sort')" \
    '{declared:$declared,
    executed:[.[] | select(.reached == 0) | .point] | unique | sort}' "$receipts"/cross-*-evidence.json >"$receipts/fold-hold-coverage.json"
  cross=fold-holds cross_check=1 cross_evidence="$receipts/fold-hold-coverage.json"
  cross_clause "every selected fold hold point was reached" \
    '(.declared | length) > 0 and .declared == .executed' '.executed = .executed[1:]' '.declared = [] | .executed = []'

# ------------------------------------------------------------------
fi
if part never-sent; then
  # never sent
  # ------------------------------------------------------------------
  control="never sent, past its upper bound"
  snap s4
  export SINGULAR_HARNESS_DROP_SEND=fold
  insert_of 6b0f
  run insert-f "${args[@]}"
  unset SINGULAR_HARNESS_DROP_SEND
  unsent="$(submission_tx insert-f fold)"
  clause "the insert stops partial naming its fold unknown" is_equal "$(field insert-f .outcome)/$(submission_case insert-f fold)" partial/unknown
  clause "the unsent fold names a transaction" is_txid "$unsent"
  mapfile -t unsent_ins < <(prepared_of "$unsent" | jq -r '.journalInputs[]')
  # The fallback bound can be 30 seconds, so a fixed sleep does not establish
  # that this fold has expired. Read its actual exclusive bound from the saved
  # body with the same CBOR reader, and wait for the node's own tip to reach it.
  unsent_upper="$(jq -R -r "$(cat "$work/cbor.jq") decode | .[0] | mapget(3)" \
    "$(prepared_of "$unsent" | jq -r .journalBody)")"
  for i in $(seq 1 120); do
    unsent_live="$(probe_ins "${unsent_ins[@]}")"
    printf '%s\n' "$unsent_live" >"$receipts/unsent-probe-$i.json"
    if jq -e --argjson upper "$unsent_upper" '($upper | type == "number") and .tip.slot >= $upper' \
      <<<"$unsent_live" >/dev/null; then break; fi
    sleep 1
  done
  clause "the node's tip has reached the unsent fold's actual exclusive upper bound" \
    jq -e --argjson upper "$unsent_upper" '($upper | type == "number") and .tip.slot >= $upper' \
    "$receipts/unsent-probe-$i.json"
  say "$control: node tip $(jq -r .tip.slot <<<"$unsent_live"), exclusive bound $unsent_upper"
  clause "the node reports the unsent fold's inputs unspent" \
    jq -n -e --argjson p "$unsent_live" '($p.live | length) > 0 and ($p.spent == [])'
  snap s4-excluded
  run update-d registry update --key-hex 6b0d --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"
  excluded_line="$(jq -c --arg t "$unsent" 'select(.journalTxId == $t and .journalEvent == "excluded")' "$journal")"
  clause "the next write journals the unsent fold excluded" \
    is_equal "$(events_of "$unsent")" '["prepared","submit-unknown","excluded"]'
  clause "the excluded line names its latest observed tip" \
    bash -c "[[ '$(jq -r '.journalObservedTip // ""' <<<"$excluded_line")' =~ ^[0-9]+\.[0-9a-f]{64}$ ]]"
  clause "the excluded line names inputs the node reports unspent" \
    jq -n -e --argjson l "${excluded_line:-null}" --argjson p "$unsent_live" '($l.journalInputs | length) > 0 and ($l.journalInputs - $p.live == [])'
  clause "its receipt names the fold excluded" is_equal "$(field update-d ".reconciled.excluded | tojson")" "[\"$unsent\"]"
  clause "the write then succeeds" outcome_is update-d success
  clause "the unsent fold was prepared once and never sent again" prepared_once "$unsent"
  clause "the journal was only appended to and no body changed" appended_only s4

  control="never sent, without an upper bound"
  snap s6
  export SINGULAR_HARNESS_DROP_SEND=book
  insert_of 6b0f
  run insert-i "${args[@]}"
  unset SINGULAR_HARNESS_DROP_SEND
  unbooked="$(submission_tx insert-i book)"
  clause "the insert stops partial naming its booking unknown" is_equal "$(field insert-i .outcome)/$(submission_case insert-i book)" partial/unknown
  clause "the unsent booking names a transaction" is_txid "$unbooked"
  # A booking carries no validity upper bound: no tip ever settles it.
  processing_ms="$(field create .processTime)"
  sleep $((processing_ms / 1000 + 1))
  snap s6-refused
  run update-e registry update --key-hex 6b0d --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"
  clause "the next write stops partial (exit 15)" exit_is update-e 15
  clause "it names the unsent booking" is_equal "$(field update-e .unresolved.tx)" "$unbooked"
  clause "it names the case unknown" is_equal "$(field update-e .unresolved.case)" unknown
  clause "its reason names the transaction" bash -c "jq -e --arg t '$unbooked' '.reason | contains(\$t)' '$receipts/update-e.json'"
  clause "it appended nothing to the journal" journal_same s6-refused
  clause "the unsent booking was prepared once and never acknowledged" \
    is_equal "$(events_of "$unbooked")" '["prepared","submit-unknown"]'

# ------------------------------------------------------------------
fi
if part whole-journal; then
  # the whole journal
  # ------------------------------------------------------------------
  control="every control"
  clause "every journalled transaction has exactly one prepared line" \
    jq -s -e '[group_by(.journalTxId)[] | [.[] | select(.journalEvent == "prepared")] | length] | all(. == 1)' "$journal"
  clause "the journal was only appended to and no body changed since the registry was created" appended_only s0
  # Every command read every included transaction of this registry for
  # rollback evidence — folds whose state output the next fold spent,
  # bookings whose request the fold took — and none was ever off the chain.
  clause "no transaction of this registry was ever journalled rolled back" \
    is_equal "$(jq -s '[.[] | select(.journalEvent == "rolled-back")] | length' "$journal")" 0
  jq -r '.journalEvent' "$journal" | sort | uniq -c

# ------------------------------------------------------------------
fi
if part rollback; then
  # rolled back — a generated-DevNet mechanism, not a public-chain fork
  # ------------------------------------------------------------------
  # The development node's database is copied while the node is stopped,
  # an insert is made and observed, then the node is stopped again and
  # restarted on the copy: the blocks that carried the insert are no longer
  # on its chain. The node's own reads come first — its adoption trace and
  # `devnet probe` — and only then the CLI's receipts, journal and files.
  # A second registry carries this control, so the fold the "never sent"
  # control leaves unresolved does not stand in its way.
  control="rolled back (generated DevNet: node database restored, not a public-chain fork)"
  node_dir="$work/cardano-e2e"
  nlog="$node_dir/node.log"
  # The hash and slot of the tip a node opened its database at, from the
  # OpenedDB line numbered after LINE in its log.
  opened_tip_after() {
    tail -n +"$(($1 + 1))" "$nlog" | grep -m1 'ChainDB.OpenEvent.OpenedDB' \
      | sed -nE 's/.* and tip ([0-9a-f]{64}) at slot ([0-9]+)$/{"hash":"\1","slot":\2}/p'
  }
  # Every block the node put on its chain after line LINE of its log. The
  # only block producer, it adopts every block it forges, and the adoption
  # record is written for each one (the chain-extension notice is rate
  # limited, so it is folded in but never relied on alone).
  chained_after() {
    tail -n +"$(($1 + 1))" "$nlog" | {
      { grep -F '"ns":"Forge.Loop.AdoptedBlock"' || true; } | jq -r .data.blockHash
    }
    tail -n +"$(($1 + 1))" "$nlog" | sed -nE 's/.*(Chain extended|Switched to a fork), new tip: ([0-9a-f]{64}).*/\2/p'
  }
  # Blocks the node forged and adopted after LINE: both counts, "F/A".
  # The node keeps forging while this reads its log, and each forge line is
  # followed a few milliseconds later by its adoption line (#404). So the log
  # is read once and cut after its last adoption record: a block forged after
  # that line is still being adopted, not missing from the record.
  forged_adopted_after() {
    local window forged adopted
    window="$(
      tail -n +"$(($1 + 1))" "$nlog" | awk '
      { line[NR] = $0 }
      index($0, "\"ns\":\"Forge.Loop.AdoptedBlock\"") { last = NR }
      END { for (i = 1; i <= last; i++) print line[i] }'
    )"
    forged="$(grep -c 'Forged block in slot' <<<"$window" || true)"
    adopted="$(grep -cF '"ns":"Forge.Loop.AdoptedBlock"' <<<"$window" || true)"
    echo "$forged/$adopted"
  }
  # HASH is the restored tip or a block the node chained since the restore;
  # an empty or null hash never is.
  on_restored_chain() {
    [ -n "$1" ] && [ "$1" != null ] || return 1
    local chain
    # Read whole before matching: an early-exiting grep would SIGPIPE the
    # producer, and pipefail would report a match as a failure.
    chain="$(
      jq -r .hash <<<"$restored_tip"
      chained_after "$mark"
    )"
    grep -qxF "$1" <<<"$chain"
  }
  # None of the HASHes is a block the node chained since the restore.
  not_chained_since() {
    local h chain
    chain="$(chained_after "$mark")"
    for h in "$@"; do
      [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
      if grep -qxF "$h" <<<"$chain"; then return 1; fi
    done
  }
  # The blocks the node adopted carrying TX: {"hash","slot"} per line.
  carrying() {
    grep -F '"ns":"Forge.Loop.AdoptedBlock"' "$nlog" \
      | jq -c --arg t "$1" 'select(any(.data.txIds[]; contains($t))) | {hash: .data.blockHash, slot: .data.slot}'
  }
  # carried_since LINE TX: blocks adopted after LINE that carry TX.
  carried_since() {
    tail -n +"$(($1 + 1))" "$nlog" | grep -F '"ns":"Forge.Loop.AdoptedBlock"' \
      | jq -c --arg t "$2" 'select(any(.data.txIds[]; contains($t)))' | wc -l
  }
  # Stop the node with PID and wait until it is gone or a zombie.
  stop_node() {
    kill -INT "$1" 2>/dev/null || return 1
    for _ in $(seq 1 600); do
      case "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null || echo gone)" in
        Z | gone) return 0 ;;
      esac
      sleep 0.05
    done
    return 1
  }
  start_node() {
    rm -f "$node_dir/node.sock"
    "$node_exe" "${node_args[@]}" >>"$nlog" 2>&1 </dev/null &
    node_pid=$!
    for _ in $(seq 1 600); do
      [ -S "$node_dir/node.sock" ] && return 0
      kill -0 "$node_pid" 2>/dev/null || return 1
      sleep 0.1
    done
    return 1
  }

  orig_pid="$(pgrep -f "cardano-node run --config $node_dir/node-config.json" | head -1)" \
    || setup_fail "the development node's process was not found"
  node_exe="$(readlink "/proc/$orig_pid/exe")"
  mapfile -d '' -t node_argv <"/proc/$orig_pid/cmdline"
  # The same command line, with a configuration that also writes each
  # adopted block's hash, slot and transaction ids as JSON.
  jq '.TraceOptions["Forge.Loop.AdoptedBlock"] = {detail: "DDetailed", backends: ["Stdout MachineFormat"]}' \
    "$node_dir/node-config.json" >"$node_dir/node-config.traced.json"
  node_args=()
  for a in "${node_argv[@]:1}"; do
    if [ "$a" = "$node_dir/node-config.json" ]; then node_args+=("$node_dir/node-config.traced.json"); else node_args+=("$a"); fi
  done

  reg="$work/registry-rolled-back"
  common=(--state-dir "$reg" --blueprint "$blueprint")
  run preview-rb registry create --process-time 120000 --retract-time 15000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
  outcome_is preview-rb success || setup_fail "the second create --preview did not succeed"
  run create-rb registry create --process-time 120000 --retract-time 15000 --seed "$(field preview-rb .seed)" "${common[@]}" "${node[@]}" "${alice[@]}"
  jq -e '.processTime == 120000 and .retractTime == 15000' "$receipts/create-rb.json" >/dev/null \
    || setup_fail "the rollback registry did not read back the CI recovery windows"
  outcome_is create-rb success || setup_fail "the second create did not succeed"
  state_token="$(field create-rb .stateToken)"
  [[ "$state_token" =~ ^[0-9a-f]{56}\.[0-9a-f]{64}$ ]] || setup_fail "the second create printed no state token"
  common+=(--state-token "$state_token")
  alicekey="$(field create-rb .walletKeyHash)"
  journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
  insert_of 6c00
  run insert-rb0 "${args[@]}"
  outcome_is insert-rb0 success || setup_fail "the insert before the snapshot did not succeed"

  # The snapshot: stopped, copied, restarted on the same database.
  mark="$(wc -l <"$nlog")"
  snap_mark="$mark"
  stop_node "$orig_pid" || setup_fail "the development node did not stop"
  cp -a "$node_dir/db" "$work/node-db-snapshot"
  start_node || setup_fail "the development node did not restart after the snapshot"
  snap_tip="$(opened_tip_after "$mark")"
  [ -n "$snap_tip" ] || setup_fail "the restarted node reported no tip it opened"
  forging=1
  for _ in $(seq 1 600); do
    if [ "$(tail -n +"$((mark + 1))" "$nlog" | grep -cF '"ns":"Forge.Loop.AdoptedBlock"' || true)" -gt 0 ]; then
      forging=0
      break
    fi
    sleep 0.1
  done
  [ "$forging" -eq 0 ] || setup_fail "the node did not forge again after the snapshot restart"
  say "$control: snapshot at $snap_tip"
  snap rb0

  insert_of 6c01
  run insert-rb "${args[@]}"
  rb_book="$(submission_tx insert-rb book)"
  rb_fold="$(submission_tx insert-rb fold)"
  clause "the insert after the snapshot succeeds" outcome_is insert-rb success
  clause "its booking was prepared, acknowledged, included and observed" \
    is_equal "$(events_of "$rb_book")" '["prepared","submitted","confirmed","observed"]'
  clause "its fold was prepared, acknowledged, included and observed" \
    is_equal "$(events_of "$rb_fold")" '["prepared","submitted","confirmed","observed"]'
  book_ins="$(prepared_of "$rb_book" | jq -r '.journalInputs[]')"
  fold_ins_before="$(prepared_of "$rb_fold" | jq -r --arg b "$rb_book" '.journalInputs[] | select(startswith($b + "#") | not)')"
  book_block="$(carrying "$rb_book")"
  fold_block="$(carrying "$rb_fold")"
  clause "the node adopted exactly one block carrying the booking" is_equal "$(grep -c . <<<"$book_block")" 1
  clause "the node adopted exactly one block carrying the fold" is_equal "$(grep -c . <<<"$fold_block")" 1
  clause "both blocks come after the snapshot's tip" \
    jq -n -e --argjson s "$snap_tip" --argjson b "$book_block" --argjson f "$fold_block" '$b.slot > $s.slot and $f.slot > $s.slot'
  # The probe can say both things: before the restore it reports the
  # booking's inputs spent and the fold's first output live.
  mapfile -t book_ins_a <<<"$book_ins"
  mapfile -t fold_ins_a <<<"$fold_ins_before"
  pre="$(probe_ins "${book_ins_a[@]}" "$rb_fold#0")"
  clause "before the restore the node reports the booking's inputs spent" \
    jq -n -e --argjson p "$pre" --arg f "$rb_fold#0" '($p.spent | length) > 0 and ($p.live == [$f])'
  snap rb1

  # The restore: stopped, the copy put back, restarted.
  mark="$(wc -l <"$nlog")"
  stop_node "$node_pid" || setup_fail "the development node did not stop for the restore"
  wait "$node_pid" 2>/dev/null || true
  mv "$node_dir/db" "$work/node-db-forked"
  cp -a "$work/node-db-snapshot" "$node_dir/db"
  start_node || setup_fail "the development node did not restart on the restored database"
  restored_tip="$(opened_tip_after "$mark")"
  [ -n "$restored_tip" ] || setup_fail "the restored node reported no tip it opened"
  post="$(probe_ins "${book_ins_a[@]}" "${fold_ins_a[@]}" "$rb_book#0" "$rb_fold#0")" \
    || setup_fail "the restored node answers no local state query"
  say "$control: restored at $restored_tip; node reads $(jq -c .tip <<<"$post")"
  clause "the restored node opened its database at the snapshot's tip" \
    jq -n -e --argjson s "$snap_tip" --argjson r "$restored_tip" '$s == $r'
  forged_pair() { [[ "$1" =~ ^([0-9]+)/([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; }
  clause "the node's adoption record covers every block it forged since the snapshot restart" \
    forged_pair "$(forged_adopted_after "$snap_mark")"
  clause "neither block that carried the booking or the fold is one the restored node chained since" \
    not_chained_since "$(jq -r .hash <<<"$book_block")" "$(jq -r .hash <<<"$fold_block")"
  clause "the node's tip is the restored tip or a block it chained since" \
    on_restored_chain "$(jq -r .tip.hash <<<"$post")"
  clause "the booking's inputs are unspent again" \
    jq -n -e --argjson p "$post" --arg i "$book_ins" '($i | split("\n") | map(select(. != ""))) as $w | ($w | length) > 0 and ($w - $p.live == [])'
  clause "the fold's inputs the booking did not make are unspent again" \
    jq -n -e --argjson p "$post" --arg i "$fold_ins_before" '($i | split("\n") | map(select(. != ""))) as $w | ($w | length) > 0 and ($w - $p.live == [])'
  clause "neither the booking's nor the fold's first output exists" \
    jq -n -e --argjson p "$post" --arg b "$rb_book#0" --arg f "$rb_fold#0" '($p.spent | index($b)) != null and ($p.spent | index($f)) != null'

  run inspect-rb registry inspect --key-hex 6c01 "${common[@]}" "${node[@]}"
  clause "the first inspect journals both rollbacks" \
    is_equal "$(event_count "$rb_book" rolled-back)/$(event_count "$rb_fold" rolled-back)" 1/1
  run inspect-rb registry inspect --key-hex 6c01 "${common[@]}" "${node[@]}"
  clause "a second inspect journals no second rollback" \
    jq -e '.rolledBack == []' "$receipts/inspect-rb.json"
  clause "the booking's rollback is journalled once, after its observation" \
    is_equal "$(events_of "$rb_book")" '["prepared","submitted","confirmed","observed","rolled-back"]'
  clause "and the fold rolled back after its observation" \
    is_equal "$(events_of "$rb_fold" | jq -c '.[0:5]')" '["prepared","submitted","confirmed","observed","rolled-back"]'
  # The fold's validity upper bound is seconds after it was built: when the
  # restored node has forged past it, the same command also excludes it.
  # The booking carries none and stays rolled back.
  clause "after the fold's rollback only an exclusion follows" \
    jq -n -e --argjson e "$(events_of "$rb_fold")" '$e[5:] == [] or $e[5:] == ["excluded"]'
  say "$control: the fold's latest phase is $(last_event "$rb_fold")"
  rolled_line() { jq -c --arg t "$1" 'select(.journalTxId == $t and .journalEvent == "rolled-back")' "$journal"; }
  for t in "$rb_book" "$rb_fold"; do
    clause "the rolled-back line of $t names a latest observed tip on the restored chain" \
      on_restored_chain "$(rolled_line "$t" | jq -r '.journalObservedTip // "" | split(".") | last')"
    clause "the rolled-back line of $t names spent inputs the node reports unspent" \
      jq -n -e --argjson l "$(rolled_line "$t")" --argjson p "$post" '($l.journalInputs | length) > 0 and ($l.journalInputs - $p.live == [])'
  done
  clause "inspect stops partial naming the booking's case rolled-back" \
    is_equal "$(field inspect-rb '.outcome + "/" + .unresolved.case + "/" + .unresolved.tx')" "partial/rolled-back/$rb_book"
  clause "the public replay after rollback created no retired trie files" trie_files_absent
  clause "inspect reads the ledger's root at the fold's root before" is_equal "$(field inspect-rb .root)" "$(root_before_of "$rb_fold")"
  clause "the observations stay in the journal: it was only appended to and no body changed" appended_only rb1
  clause "the booking and the fold were each prepared once" bash -c "[ '$(event_count "$rb_book" prepared)$(event_count "$rb_fold" prepared)' = 11 ]"
  clause "the fold's edge is applied zero times: observed once, rolled back once after" \
    is_equal "$(event_count "$rb_fold" observed)/$(event_count "$rb_fold" rolled-back)" 1/1
  clause "no block the node adopted since the restore carries the booking or the fold" \
    is_equal "$(carried_since "$mark" "$rb_book")$(carried_since "$mark" "$rb_fold")" 00

  snap rb2
  insert_of 6c02
  run insert-rb2 "${args[@]}"
  clause "the following write stops partial (exit 15)" exit_is insert-rb2 15
  clause "it names the case rolled-back" is_equal "$(field insert-rb2 .unresolved.case)" rolled-back
  clause "it names the rolled-back booking" is_equal "$(field insert-rb2 .unresolved.tx)" "$rb_book"
  clause "its reason names the transaction" bash -c "jq -e --arg t '$rb_book' '.reason | contains(\$t)' '$receipts/insert-rb2.json'"
  clause "it built and submitted nothing: the journal did not move" journal_same rb2
  clause "the node's blocks since the restore still carry neither transaction" \
    is_equal "$(carried_since "$mark" "$rb_book")$(carried_since "$mark" "$rb_fold")" 00
  clause "at the end too, the adoption record covers every block the node forged" \
    forged_pair "$(forged_adopted_after "$snap_mark")"
  say "$control: $(chained_after "$mark" | wc -l) block(s) chained by the restored node"
  jq -r '.journalEvent' "$journal" | sort | uniq -c

fi

if part trie-capability; then
  control="trie capability"
  clause "completed real recovery commands have nonempty trie evidence bound to their key, leaf and root" trie_extent
fi

for ran in "${!part_clauses[@]}"; do
  if [ "${part_clauses[$ran]}" -eq 0 ]; then
    say "part $ran judged no clause"
    failed=1
  fi
done
for requested in ${CLI_RECOVERY_PARTS:-}; do
  [ -n "${part_clauses[$requested]+x}" ] || {
    say "part $requested never ran"
    failed=1
  }
done
say "parts judged: $(for ran in "${!part_clauses[@]}"; do printf "%s=%s " "$ran" "${part_clauses[$ran]}"; done)"
cat "$verdicts"
if [ "$failed" -ne 0 ]; then
  say "RECOVERY-CONTROLS-FAILED"
  exit 1
fi
say "RECOVERY-CONTROLS-OK"
