#!/usr/bin/env bash
# The ordinary CLI's recovery controls (#325): what `open-datum` and
# `singular registry` do after a lost acknowledgement or an interrupted local
# commit, on one generated development node, every command a separate process.
# `create`, `insert`, `update`, `terminate`, `fold` and `inspect` of an
# open-datum registry run through `open-datum`; `reject` and `reclaim` run
# through `singular registry`, as the Demo 1 journey dispatches them.
#
# usage: cli_recovery_controls.sh SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR REPO-ROOT
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
# Blocks the node forged and adopted after line MARK of its log FILE, "F/A": F
# the blocks forged in that range, A those of them whose adoption the range
# records. The node keeps forging while this reads its log, and a block's
# adoption line follows its forge line a few milliseconds later (#404). The
# range is therefore closed at both ends, so that no block is split by an edge
# of it: it is cut after its last adoption line, a block forged after that
# being still in flight, not missing from the record; and a block forged just
# before MARK, whose adoption line alone falls in the range, is forged outside
# it and counts for neither side (#637). Each forge is paired with the adoption
# of its own slot, so an adoption never covers another block's forge.
forged_adopted_in() {
  local window adopted
  window="$(
    tail -n +"$(($2 + 1))" "$1" | awk '
      { line[NR] = $0 }
      /Adopted block forged in slot / || index($0, "\"ns\":\"Forge.Loop.AdoptedBlock\"") { last = NR }
      END { for (i = 1; i <= last; i++) print line[i] }'
  )"
  adopted="$(
    { grep -o 'Adopted block forged in slot [0-9]*' <<<"$window" || true; } | awk '{ print $6 }'
    { grep -F '"ns":"Forge.Loop.AdoptedBlock"' <<<"$window" || true; } | jq -r .data.slot
  )"
  { grep -o 'Forged block in slot [0-9]*' <<<"$window" || true; } \
    | awk -v adopted="$adopted" '
      BEGIN { n = split(adopted, slots, "\n"); for (i = 1; i <= n; i++) seen[slots[i]] = 1 }
      { forged++; if ($5 in seen) covered++ }
      END { print forged + 0 "/" covered + 0 }'
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
 reconciled:($reconciled | lines),
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
    --slurpfile reconciled "$fixture/reconciled.jsonl" \
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

[ "$#" -eq 6 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR REPO-ROOT" >&2
  exit 2
}
singular="$1"
open_datum="$2"
devnet="$3"
blueprint="$4"
work="$5"
root="$6"
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
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
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
known_parts="accepting lost-answer killed two-requests cross-wallet never-sent whole-journal rollback state-line holding-update holding-terminate termination-fold trie-capability"
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
  while IFS= read -r -d '' source; do
    while IFS= read -r line; do
      if [[ "$line" =~ harnessHoldAt[[:space:]]+\"(SINGULAR_HARNESS_HOLD_[A-Z_]+)\" ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      fi
    done <"$source"
  done < <(find "$root/offchain/cli" -type f -name '*.hs' -print0) | sort -u
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
  trap - EXIT
  # The shell owns replacement nodes; join them before the outer fixture can
  # remove its temporary node directory. Preserve an original failed result.
  if [ -n "${node_pid:-}" ]; then
    if [ -f "$node_record" ]; then
      if ! python3 "$process_control" stop "$node_record" --signal INT --seconds 30; then
        python3 "$process_control" stop "$node_record" --signal KILL --seconds 5 || { [ "$code" -ne 0 ] || code=1; }
      fi
    elif [ -n "${node_start:-}" ]; then
      if ! python3 "$process_control" stop-child "$node_record" --pid "$node_pid" --start-ticks "$node_start" --owner "$$" --signal INT --seconds 30; then
        python3 "$process_control" stop-child "$node_record" --pid "$node_pid" --start-ticks "$node_start" --owner "$$" --signal KILL --seconds 5 || { [ "$code" -ne 0 ] || code=1; }
      fi
    fi
    if [ -f "$node_record" ] && ! python3 "$process_control" assert-gone "$node_record"; then
      # Do not wait indefinitely or remove a directory under a live child.
      printf 'replacement cleanup incomplete; retained %s\n' "$work" >&2
      [ "$code" -ne 0 ] || code=1
      exit "$code"
    fi
    wait "$node_pid" 2>/dev/null || true
    printf 'replacement-joined\n' >>"$work/cleanup-order"

  fi
  if [ -n "${devnet_pid:-}" ]; then
    if [ -f "$work/devnet-process.json" ]; then
      if ! python3 "$process_control" stop "$work/devnet-process.json" --signal TERM --seconds 30; then
        python3 "$process_control" stop "$work/devnet-process.json" --signal KILL --seconds 5 || { [ "$code" -ne 0 ] || code=1; }
      fi
    elif [ -n "${devnet_start:-}" ]; then
      # The acquiring fixture child may not yet have a complete executable
      # identity; stop it by the start ticks captured at the fork, exactly
      # as cleanup does for a replacement node acquiring above.
      if ! python3 "$process_control" stop-child "$work/devnet-process.json" --pid "$devnet_pid" --start-ticks "$devnet_start" --owner "$$" --signal TERM --seconds 30; then
        python3 "$process_control" stop-child "$work/devnet-process.json" --pid "$devnet_pid" --start-ticks "$devnet_start" --owner "$$" --signal KILL --seconds 5 || { [ "$code" -ne 0 ] || code=1; }
      fi
    fi
    if [ -f "$work/devnet-process.json" ] && ! python3 "$process_control" assert-gone "$work/devnet-process.json"; then
      printf 'fixture cleanup incomplete; retained %s\n' "$work" >&2
      [ "$code" -ne 0 ] || code=1
      exit "$code"
    fi
    wait "$devnet_pid" 2>/dev/null || true
    printf 'fixture-joined\n' >>"$work/cleanup-order"
  fi
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
process_control="$(dirname "$0")/fixture_process.py"
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
restart_args=()
if [ -z "${CLI_RECOVERY_PARTS:-}" ] || [[ " ${CLI_RECOVERY_PARTS:-} " == *" rollback "* ]]; then
  restart_args=(--restart-control-dir "$work/facade-control")
fi
# Defer cancellation only across the initial fixture fork/start-tick
# acquisition, using shell builtins — the same contract as start_node
# below. Cleanup then owns this exact direct child even before the private
# devnet prints usable settings or a complete executable identity exists.
pending_cancel=0
trap 'pending_cancel=143' TERM
trap 'pending_cancel=130' INT
"$devnet" "${restart_args[@]}" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" --fund-outputs 10 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
devnet_start=""
if IFS= read -r devnet_stat <"/proc/$devnet_pid/stat"; then
  devnet_stat="${devnet_stat##*) }"
  read -r -a devnet_fields <<<"$devnet_stat"
  devnet_start="${devnet_fields[19]}"
fi
trap 'exit 143' TERM
trap 'exit 130' INT
[ "$pending_cancel" -eq 0 ] || exit "$pending_cancel"
sock=""
provider_url=""
time_directory=""
network_magic=""
for _ in $(seq 1 900); do
  settings="$(tail -n1 "$work/devnet.out" 2>/dev/null || true)"
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
python3 "$process_control" bind "$work/devnet-process.json" --pid "$devnet_pid" >/dev/null
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
# Record the exact explicit identity supplied to this invocation. Inspect's
# receipt deliberately carries no identity; its observed selection must still
# belong to the requested token, never an identity invented by this checker.
record_identity() {
  local name="$1" arg take=0
  shift
  : >"$receipts/$name.state-token"
  for arg in "$@"; do
    if [ "$take" -eq 1 ]; then
      printf '%s\n' "$arg" >>"$receipts/$name.state-token"
      take=0
    elif [ "$arg" = --state-token ]; then
      take=1
    elif [[ "$arg" == --state-token=* ]]; then
      printf '%s\n' "${arg#--state-token=}" >>"$receipts/$name.state-token"
    fi
  done
}

# run NAME ARGS...: one ordinary process; its receipt and exit status kept.
# A `registry` or `singular` first word runs through `singular` (the second
# is dropped); a bare verb
# (`create`, `insert`, `update`, `terminate`, `fold`, `inspect`) runs through
# `open-datum`, as the journey dispatches them.
run() {
  local name="$1"
  shift
  local status=0
  local bin="$open_datum"
  [ "${1:-}" = registry ] && bin="$singular"
  if [ "${1:-}" = singular ]; then
    bin="$singular"
    shift
  fi
  record_identity "$name" "$@"
  : >"$receipts/$name.trace.jsonl"
  : >"$receipts/$name.trie.jsonl"
  SINGULAR_HARNESS_TRIE_TRACE="$receipts/$name.trie.jsonl" \
    "$bin" "$@" --trace how --trace-to "file:$receipts/$name.trace.jsonl" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  printf '%s\n' "$name" >>"$work/trie-command-invocations"
  echo "$status" >"$receipts/$name.exit"
  say_run "$name" "$status"
}
# held NAME VAR ARGS...: one ordinary process with the harness hold VAR set
# to a path, killed once it waits there. Returns 0 only when it was killed
# at the hold. Dispatch as run() does.
held() {
  local name="$1" var="$2"
  shift 2
  local bin="$open_datum"
  [ "${1:-}" = registry ] && bin="$singular"
  if [ "${1:-}" = singular ]; then
    bin="$singular"
    shift
  fi
  local go="$work/$name.go"
  rm -f "$go" "$go.waiting"
  record_identity "$name" "$@"
  : >"$receipts/$name.trace.jsonl"
  : >"$receipts/$name.trie.jsonl"
  printf '%s\n' "$name" >>"$work/trie-command-invocations"
  env "SINGULAR_HARNESS_TRIE_TRACE=$receipts/$name.trie.jsonl" "$var=$go" \
    "$bin" "$@" --trace how --trace-to "file:$receipts/$name.trace.jsonl" >"$receipts/$name.json" 2>"$receipts/$name.err" &
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
# paused NAME VAR CHECK ARGS...: one ordinary process with the harness hold
# VAR set to a path; while it waits there CHECK runs, then it is released
# and runs to its end. Returns 0 only when it reached the hold.
# Dispatch as run() does.
paused() {
  local name="$1" var="$2" check="$3"
  shift 3
  local bin="$open_datum"
  [ "${1:-}" = registry ] && bin="$singular"
  if [ "${1:-}" = singular ]; then
    bin="$singular"
    shift
  fi
  local go="$work/$name.go"
  rm -f "$go" "$go.waiting"
  record_identity "$name" "$@"
  : >"$receipts/$name.trace.jsonl"
  : >"$receipts/$name.trie.jsonl"
  printf '%s\n' "$name" >>"$work/trie-command-invocations"
  env "SINGULAR_HARNESS_TRIE_TRACE=$receipts/$name.trie.jsonl" "$var=$go" \
    "$bin" "$@" --trace how --trace-to "file:$receipts/$name.trace.jsonl" >"$receipts/$name.json" 2>"$receipts/$name.err" &
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
  local name receipt
  : >"$work/trie-command-extent.jsonl"
  while IFS= read -r name; do
    receipt="$receipts/$name.json"
    if jq -e '.outcome == "success" and .preview != true' "$receipt" >/dev/null 2>&1; then
      # PR411 retired mirror creation/acceptance. Check actual public boot
      # events separately, and actual authenticated lineage operations for
      # every stored-registry command. Unknown successful verbs are refused.
      python3 "$(dirname "$0")/check_recovery_trie.py" "$receipt" \
        "$receipts/$name.trie.jsonl" "$receipts/$name.trace.jsonl" \
        --identity-file "$receipts/$name.state-token" --controls \
        >>"$work/trie-command-extent.jsonl" || return 1
    fi
  done <"$work/trie-command-invocations"
  jq -s -e 'length > 1 and all(.executions > 0)
    and any(.source == "boot-command-trace")
    and any(.source == "public-lineage-capability")
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
    result = subprocess.run([binary, "inspect", "--key-hex", "00",
        "--state-dir", registry, "--blueprint", blueprint, *settings], capture_output=True, text=True,
        env={k: v for k, v in os.environ.items() if k != "SINGULAR_HARNESS_TRIE_TRACE"})
    receipt = json.loads(result.stdout)
    root = receipt.get("root")
    if not isinstance(root, str) or len(root) != 64:
        raise RuntimeError(f"public root unavailable: exit={result.returncode} receipt={receipt}")
    print(root)
PY
root_now() { python3 "$work/read-root.py" "$open_datum" "$reg" "$blueprint" --state-token "$state_token" "${node[@]}"; }
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
# Each send attempt writes exactly one of the three send events.
sent_once() { [ "$(jq -s --arg t "$1" '[.[] | select(.journalTxId == $t and (.journalEvent == "submitted" or .journalEvent == "submit-unknown" or .journalEvent == "rejected"))] | length' "$journal")" = 1 ]; }
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
insert_of() { args=(insert --fold --key-hex "$1" --payload "$work/insert-payload.json" --payload-schema detailed "${common[@]}" "${node[@]}" "${alice[@]}"); }

# ------------------------------------------------------------------
# The registry
# Recovery needs a fold that reaches its hold point. Allow time for booking
# and building on shared runners plus the CLI's unchanged 30-second signing
# margin; the former 45-second window left only 15 seconds for that work.
# ------------------------------------------------------------------
run preview create --process-time 120000 --retract-time 15000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
outcome_is preview success || setup_fail "create --preview did not succeed"
run create create --process-time 120000 --retract-time 15000 --seed "$(field preview .seed)" "${common[@]}" "${node[@]}" "${alice[@]}"
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
  [ "$command" != update ] || extra=(--payload "$work/payload.json" --payload-schema detailed)
  run "$command-absent" "$command" --key-hex 6d697373696e672d6b6579 \
    "${extra[@]}" "${common[@]}" "${node[@]}" "${alice[@]}"
  clause "$command of an absent key is refused before signing" exit_is "$command-absent" 10
  clause "$command names the key as not registered, labelled client policy" is_equal \
    "$(field "$command-absent" '.outcome + "/" + .reason')" \
    'client-refusal/missing-key is not registered (client policy)'
  run "$command-absent-preview" "$command" --preview --key-hex 6d697373696e672d6b6579 \
    "${extra[@]}" "${common[@]}" "${node[@]}" --wallet-address "$(field preview .wallet)"
  clause "$command preview names the same key as not registered, labelled client policy" is_equal \
    "$(field "$command-absent-preview" '.outcome + "/" + .reason')" \
    'client-refusal/missing-key is not registered (client policy)'
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
run bob-preview create --process-time 120000 --retract-time 15000 --preview --state-dir "$work/bob-preview" --blueprint "$blueprint" \
  "${node[@]}" "${bob[@]}"
outcome_is bob-preview success || setup_fail "the folder wallet's preview did not succeed"
bobkey="$(field bob-preview .walletKeyHash)"
bob_addr="$(field bob-preview .wallet)"

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
  run inspect-a inspect --key-hex 6b0a "${common[@]}" "${node[@]}"
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
    run "inspect-$source-source" inspect --key-hex 6b0a \
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
    [ "$command" != update ] || extra=(--payload "$work/payload.json" --payload-schema detailed)
    name="$command-active-preview"
    run "$name" "$command" --preview --key-hex 6b0a \
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
  run preview-incomplete update --preview --key-hex 6b0a --payload "$work/payload.json" --payload-schema detailed \
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
  run inspect-b inspect --key-hex 6b0b "${common[@]}" "${node[@]}"
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
  run update-a update --key-hex 6b0a --payload "$work/payload.json" --payload-schema detailed "${common[@]}" "${node[@]}" "${alice[@]}"
  clause "the next write, an update of another key, reconciles and succeeds" outcome_is update-a success
  clause "the killed fold is observed exactly once, by the update" \
    is_equal "$(since s2-killed | jq -r --arg t "$killed_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" update
  clause "the killed fold was prepared once, never sent again" prepared_once "$killed_fold"
  clause "the fold started from the root before the kill" is_equal "$(root_before_of "$killed_fold")" "$(cat "$snaps/s2.root")"
  clause "the confirmed killed fold left no retired trie files" trie_files_absent
  run inspect-d inspect --key-hex 6b0d "${common[@]}" "${node[@]}"
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
  run inspect-g inspect --key-hex 6b10 "${common[@]}" "${node[@]}"
  clause "inspect reads the killed insert's key active" is_equal "$(field inspect-g '.outcome + "/" + .leaf')" success/active
  clause "the journal was only appended to and no body changed" appended_only s5

# ------------------------------------------------------------------
fi
if part two-requests; then
  # an interrupted fold of two requests, booked by two wallets
  # ------------------------------------------------------------------
  # Alice books one insertion and bob books another, each booking alone
  # (insert without --fold books and stops). Bob folds both pending in one
  # standalone fold, which names no request; he booked one of the two, not
  # both. The fold is interrupted twice, each time with two fresh bookings:
  # once with its answer lost, once killed before the observation. The next
  # ordinary command recovers, every included request reconciled once,
  # nothing sent twice.
  control="two requests, lost answer"
  journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
  snap two-a-alice
  run two-book-a1 insert --key-hex 6b20 --payload "$work/insert-payload.json" --payload-schema detailed \
    "${common[@]}" "${node[@]}" "${alice[@]}"
  clause "alice's booking of 6b20 succeeds" outcome_is two-book-a1 success
  clause "alice's booking names her as the requester" is_equal "$(field two-book-a1 .requester)" "$alicekey"
  journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
  run two-book-a2 insert --key-hex 6b21 --payload "$work/insert-payload.json" --payload-schema detailed \
    "${common[@]}" "${node[@]}" "${bob[@]}"
  clause "bob's booking of 6b21 succeeds" outcome_is two-book-a2 success
  clause "bob's booking names him as the requester" is_equal "$(field two-book-a2 .requester)" "$bobkey"
  book_a1="$(field two-book-a1 .request)"
  book_a2="$(field two-book-a2 .request)"
  clause "the two bookings name distinct requests" bash -c '[ "$1" != "$2" ] && [ -n "$1" ] && [ -n "$2" ]' _ "$book_a1" "$book_a2"
  # Bob's fold journals to his partition.
  journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
  snap two-a
  # Held right after the fold is sent, before its answer is journalled.
  at_two_send() {
    two_sent_tx="$(fold_since two-a)"
    two_sent_last="$(last_event "$two_sent_tx")"
    two_sent_bound=1
    body_bound "$two_sent_tx" && two_sent_bound=0
  }
  two_sent_tx="" two_sent_last="" two_sent_bound=1 two_reached=0
  export SINGULAR_HARNESS_DROP_ANSWER=fold SINGULAR_HARNESS_HOLD_STEP=fold
  paused two-fold-a SINGULAR_HARNESS_HOLD_AFTER_SEND at_two_send fold \
    "${common[@]}" "${node[@]}" "${bob[@]}" || two_reached=1
  unset SINGULAR_HARNESS_DROP_ANSWER SINGULAR_HARNESS_HOLD_STEP
  lost_two="$(submission_tx two-fold-a fold)"
  clause "the two-request fold was held once sent, before the answer" is_equal "$two_reached" 0
  clause "at that moment the fold's prepared line was its last phase" is_equal "$two_sent_last" prepared
  clause "at that moment the fold's body was saved, bound by hash" is_equal "$two_sent_bound" 0
  clause "the held fold is the one the receipt names" is_equal "$two_sent_tx" "$lost_two"
  clause "the fold stops partial (exit 15)" exit_is two-fold-a 15
  clause "its receipt names the fold's case unknown" is_equal "$(submission_case two-fold-a fold)" unknown
  clause "the fold's last journalled phase is submit-unknown" is_equal "$(last_event "$lost_two")" submit-unknown
  clause "the interrupted fold's prepared line lists two transitions" \
    is_equal "$(prepared_of "$lost_two" | jq -r '.journalTransitions | length')" 2
  clause "the two transitions chain from the root before to the root after" \
    is_equal "$(prepared_of "$lost_two" | jq -r '.journalTransitions[1].transitionRootBefore == .journalTransitions[0].transitionRootAfter')" true
  clause "the scalars mirror the first and the last transition" \
    is_equal "$(prepared_of "$lost_two" | jq -r '.journalKey == .journalTransitions[0].transitionKey and .journalEdge == .journalTransitions[0].transitionEdge and .journalExpect == .journalTransitions[0].transitionExpect and .journalRootBefore == .journalTransitions[0].transitionRootBefore and .journalRootAfter == .journalTransitions[1].transitionRootAfter')" true
  clause "the transitions carry both booked requests" \
    is_equal "$(prepared_of "$lost_two" | jq -r --arg a "$book_a1" --arg b "$book_a2" '([.journalTransitions[].transitionRequest] | sort) == ([$a, $b] | sort)')" true
  # The next ordinary writes. While the fold is not yet on chain each is
  # refused before building anything; once it is, it reconciles and proceeds.
  two_refusals_clean=0
  for i in $(seq 1 40); do
    snap "two-a-try-$i"
    run two-recover-a insert --fold --key-hex 6b22 --payload "$work/insert-payload.json" --payload-schema detailed \
      "${common[@]}" "${node[@]}" "${bob[@]}"
    outcome_is two-recover-a partial || break
    if ! journal_same "two-a-try-$i" || ! trie_files_absent \
      || [ "$(field two-recover-a .unresolved.tx)" != "$lost_two" ]; then
      two_refusals_clean=1
    fi
    sleep 2
  done
  clause "every write refused while the fold was unknown named it and moved nothing" is_equal "$two_refusals_clean" 0
  clause "the next write reconciles and succeeds" outcome_is two-recover-a success
  clause "it observed the lost two-request fold" is_equal "$(field two-recover-a "[.reconciled.observed[]? | select(. == \"$lost_two\")] | length")" 1
  clause "the lost fold was prepared once" prepared_once "$lost_two"
  clause "the lost fold was sent once and never sent again" sent_once "$lost_two"
  clause "the lost fold is observed exactly once in the journal" is_equal "$(event_count "$lost_two" observed)" 1
  clause "the lost fold's observation was journalled by the reconciling insert" \
    is_equal "$(since two-a | jq -r --arg t "$lost_two" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
  clause "the fold started from the root before the lost answer" is_equal "$(root_before_of "$lost_two")" "$(cat "$snaps/two-a.root")"
  clause "the next fold started from the lost fold's root after" \
    is_equal "$(root_before_of "$(submission_tx two-recover-a fold)")" "$(root_after_of "$lost_two")"
  run inspect-two-a1 inspect --key-hex 6b20 "${common[@]}" "${node[@]}"
  clause "inspect reads the lost fold's first key 6b20 active" is_equal "$(field inspect-two-a1 '.outcome + "/" + .leaf')" success/active
  run inspect-two-a2 inspect --key-hex 6b21 "${common[@]}" "${node[@]}"
  clause "inspect reads the lost fold's second key 6b21 active" is_equal "$(field inspect-two-a2 '.outcome + "/" + .leaf')" success/active
  clause "the journal was only appended to and no body changed" appended_only two-a
  journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
  clause "alice's journal was only appended to and no body changed" appended_only two-a-alice

  # ------------------------------------------------------------------
  # killed before the observation
  # ------------------------------------------------------------------
  control="two requests, killed before the observation"
  journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
  snap two-b-alice
  run two-book-b1 insert --key-hex 6b30 --payload "$work/insert-payload.json" --payload-schema detailed \
    "${common[@]}" "${node[@]}" "${alice[@]}"
  clause "alice's booking of 6b30 succeeds" outcome_is two-book-b1 success
  journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
  run two-book-b2 insert --key-hex 6b31 --payload "$work/insert-payload.json" --payload-schema detailed \
    "${common[@]}" "${node[@]}" "${bob[@]}"
  clause "bob's booking of 6b31 succeeds" outcome_is two-book-b2 success
  book_b1="$(field two-book-b1 .request)"
  book_b2="$(field two-book-b2 .request)"
  clause "the two fresh bookings name distinct requests" bash -c '[ "$1" != "$2" ] && [ -n "$1" ] && [ -n "$2" ]' _ "$book_b1" "$book_b2"
  journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
  snap two-b
  two_b_reached=0
  export SINGULAR_HARNESS_HOLD_STEP=fold
  held two-fold-b SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED fold \
    "${common[@]}" "${node[@]}" "${bob[@]}" || two_b_reached=1
  unset SINGULAR_HARNESS_HOLD_STEP
  clause "the two-request fold reached the hold before observation" is_equal "$two_b_reached" 0
  killed_two="$(fold_since two-b)"
  clause "the fold's last journalled phase is confirmed" is_equal "$(last_event "$killed_two")" confirmed
  snap two-b-killed
  clause "the killed fold's prepared line lists two transitions" \
    is_equal "$(prepared_of "$killed_two" | jq -r '.journalTransitions | length')" 2
  clause "the killed fold's transitions chain from the root before to the root after" \
    is_equal "$(prepared_of "$killed_two" | jq -r '.journalTransitions[1].transitionRootBefore == .journalTransitions[0].transitionRootAfter')" true
  clause "the killed fold's scalars mirror the first and the last transition" \
    is_equal "$(prepared_of "$killed_two" | jq -r '.journalKey == .journalTransitions[0].transitionKey and .journalEdge == .journalTransitions[0].transitionEdge and .journalExpect == .journalTransitions[0].transitionExpect and .journalRootBefore == .journalTransitions[0].transitionRootBefore and .journalRootAfter == .journalTransitions[1].transitionRootAfter')" true
  clause "the killed fold's transitions carry both fresh requests" \
    is_equal "$(prepared_of "$killed_two" | jq -r --arg a "$book_b1" --arg b "$book_b2" '([.journalTransitions[].transitionRequest] | sort) == ([$a, $b] | sort)')" true
  run two-recover-b insert --fold --key-hex 6b32 --payload "$work/insert-payload.json" --payload-schema detailed \
    "${common[@]}" "${node[@]}" "${bob[@]}"
  clause "the next write reconciles and succeeds" outcome_is two-recover-b success
  clause "the killed fold is observed exactly once, by the insert" \
    is_equal "$(since two-b-killed | jq -r --arg t "$killed_two" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
  clause "the killed fold was prepared once" prepared_once "$killed_two"
  clause "the killed fold was sent once and never sent again" sent_once "$killed_two"
  clause "the next fold started from the killed fold's root after" \
    is_equal "$(root_before_of "$(submission_tx two-recover-b fold)")" "$(root_after_of "$killed_two")"
  run inspect-two-b1 inspect --key-hex 6b30 "${common[@]}" "${node[@]}"
  clause "inspect reads the killed fold's first key 6b30 active" is_equal "$(field inspect-two-b1 '.outcome + "/" + .leaf')" success/active
  run inspect-two-b2 inspect --key-hex 6b31 "${common[@]}" "${node[@]}"
  clause "inspect reads the killed fold's second key 6b31 active" is_equal "$(field inspect-two-b2 '.outcome + "/" + .leaf')" success/active
  clause "the journal was only appended to and no body changed" appended_only two-b
  journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
  clause "alice's journal was only appended to and no body changed" appended_only two-b-alice

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
    run "$cross-book" insert --key-hex "$key" --payload "$work/insert-payload.json" --payload-schema detailed \
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
      paused "$cross-fold" "$point" at_cross_send fold \
        --request "$(field "$cross-book" .request)" "${common[@]}" "${node[@]}" "${bob[@]}" || reached=1
      unset SINGULAR_HARNESS_DROP_ANSWER
    else
      held "$cross-fold" "$point" fold --request "$(field "$cross-book" .request)" \
        "${common[@]}" "${node[@]}" "${bob[@]}" || reached=1
    fi
    unset SINGULAR_HARNESS_HOLD_STEP
    # The fold's offset is measured in its own writer's journal.
    cross_fold="$(fold_since "$cross-bob-before")"
    snap "$cross-held"
    # Alice's updates journal to her partition again.
    journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
    refusals_clean=0
    # Her ordinary write proceeds independently while another wallet's fold
    # is unresolved: her journal is clean, so nothing names that fold and
    # only her own four phases move her journal.
    run "$cross-next" update --key-hex "$next_key" --payload "$work/payload.json" --payload-schema detailed \
      "${common[@]}" "${node[@]}" "${alice[@]}"
    outcome_is "$cross-next" success || refusals_clean=1
    cross_update="$(submission_tx "$cross-next" update)"
    # Her update journals exactly its own four phases; nothing of it touches
    # another wallet's fold, which her journal never names.
    cross_update_phases="$(jq -s -r --arg t "$cross_update" '[.[] | select(.journalTxId == $t) | .journalEvent] | sort | join(",")' "$journal")"
    [ "$cross_update_phases" = "confirmed,observed,prepared,submitted" ] \
      || {
        say "$control: her update journalled [$cross_update_phases], not its four phases"
        refusals_clean=1
      }
    cross_fold_alice="$(jq -s --arg t "$cross_fold" '[.[] | select(.journalTxId == $t)] | length' "$journal")"
    [ "$cross_fold_alice" = 0 ] \
      || {
        say "$control: her journal names the other wallet's fold $cross_fold"
        refusals_clean=1
      }
    # Bob's reconcile observes his own fold once it is on chain, submitting
    # nothing: the case's readback inspect carries his address, so the one
    # read reconciles his partition alone while reading the folded key back.
    bob_journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
    journal="$bob_journal"
    event_count_bob() { event_count "$1" "$2"; }
    for i in $(seq 1 40); do
      run "$cross-inspect" inspect --key-hex "$key" \
        "${common[@]}" "${node[@]}" --wallet-address "$bob_addr"
      outcome_is "$cross-inspect" success || break
      [ "$(event_count_bob "$cross_fold" observed)" = 1 ] && break
      sleep 2
    done
    snap "$cross-reconciled"
    # Alice's updates journal to her partition again.
    journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
    snap "$cross-next"
    loss=null
    if [[ "$cross_case" == *:lost-answer ]]; then loss="$(cat "$receipts/$cross-fold.json")"; fi
    cross_evidence="$receipts/$cross-evidence.json"
    cross_signers="$(
      journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
      signers_of "$cross_fold" | jq -Rsc 'split("\n") | map(select(. != ""))'
    )"
    jq -n --arg fold "$cross_fold" --arg key "$key" --arg point "$point" --argjson reached "$reached" \
      --arg folder "$bobkey" --argjson signers "$cross_signers" \
      --argjson clean "$refusals_clean" --argjson exit "$(cat "$receipts/$cross-next.exit")" --argjson loss "$loss" \
      --slurpfile booking "$receipts/$cross-book.json" --slurpfile next "$receipts/$cross-next.json" \
      --slurpfile inspect "$receipts/$cross-inspect.json" \
      --slurpfile booked "$snaps/$cross-booked.jsonl" --slurpfile held "$snaps/$cross-held.jsonl" \
      --slurpfile after "$snaps/$cross-next.jsonl" \
      --slurpfile reconciled "$snaps/$cross-reconciled.jsonl" \
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
    cross_clause "an unrelated wallet's write proceeds without touching the fold" \
      '.exit == 0 and .next.outcome == "success" and .clean == 0 and .inspect.outcome == "success"' \
      '.next.outcome = "partial"' '.exit = 15' '.clean = 1'
    cross_clause "the public lineage reaches the confirmed fold's recorded after-root" \
      '. as $e | [.held[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")][0].journalRootAfter == .roots.after' \
      '.roots.after += "tampered"' \
      '. as $e | .held |= map(if .journalTxId == $e.fold then .journalRootAfter += "tampered" else . end)'
    cross_clause "the fold is confirmed and observed exactly once, by the folder's reconcile" \
      '. as $e | ([.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed")] | length) == 1
      and ([.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "observed") | .journalCommand] == ["inspect"])
      and ([.after[] | select(.journalTxId == $e.fold)] | length) == 0
      and (if ([.held[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed")] | length) == 0
           then [.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed") | .journalCommand] == ["inspect"] else true end)' \
      '. as $e | .reconciled += [.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "confirmed")]' \
      '. as $e | .reconciled += [.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "observed")]'
    cross_clause "there is no second preparation or submission of the fold or its request" \
      '. as $e | ([.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")] | length) == 1
      and ([.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "submitted")] | length)
        == ([.held[] | select(.journalTxId == $e.fold and .journalEvent == "submitted")] | length)
      and ([.reconciled[] | select(.journalStep == "fold" and .journalEvent == "prepared" and (.journalInputs | index($e.booking.request)) != null)] | length) == 1
      and ([.after[] | select(.journalTxId == $e.fold)] | length) == 0' \
      '. as $e | .reconciled += [.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "prepared")]' \
      '. as $e | .reconciled += [(.reconciled[] | select(.journalTxId == $e.fold and .journalEvent == "prepared") | .journalEvent = "submitted")]' \
      '. as $e | .after += [(.held[] | select(.journalTxId == $e.fold and .journalEvent == "prepared"))]'
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
    journal="$(managed_journal "$reg" "$state_token" "$bobkey")"
    clause "the saved signed body is bound to its prepared line" body_bound "$cross_fold"
    journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
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
  run update-d update --key-hex 6b0d --payload "$work/payload.json" --payload-schema detailed "${common[@]}" "${node[@]}" "${alice[@]}"
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
  run update-e update --key-hex 6b0d --payload "$work/payload.json" --payload-schema detailed "${common[@]}" "${node[@]}" "${alice[@]}"
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
    local window
    window="$(tail -n +"$(($1 + 1))" "$nlog")"
    grep -m1 'ChainDB.OpenEvent.OpenedDB' <<<"$window" \
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
  # Blocks the node forged and adopted after LINE: "F/A", as forged_adopted_in
  # counts them in the node's log.
  forged_adopted_after() { forged_adopted_in "$nlog" "$1"; }
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
  # The private controller is sequential: quiesce and join the current
  # facade before stopping the exact node, then obtain fresh real settings.
  facade_generation=0
  await_marker() {
    local marker="$1"
    for _ in $(seq 1 1200); do
      [ -f "$work/facade-control/$marker" ] && return 0
      kill -0 "$devnet_pid" 2>/dev/null || return 1
      sleep 0.1
    done
    return 1
  }
  request_facade() {
    (
      set -C
      : >"$work/facade-control/$1"
    )
  }
  endpoint_refuses() {
    python3 - "$1" <<'ENDPOINT'
import sys
import urllib.error
import urllib.request
try:
    urllib.request.urlopen(sys.argv[1] + "/tip", timeout=2).close()
except urllib.error.HTTPError:
    sys.exit(1)
except urllib.error.URLError as error:
    sys.exit(0 if isinstance(error.reason, ConnectionRefusedError) else 1)
sys.exit(1)
ENDPOINT
  }
  pause_facade() {
    facade_generation=$((facade_generation + 1))
    request_facade "pause.$facade_generation" || setup_fail "duplicate facade pause request"
    await_marker "paused.$facade_generation" || setup_fail "the facade did not close and join its session"
    clause "the paused facade endpoint refuses requests" endpoint_refuses "$provider_url"
    [ "$failed" -eq 0 ] || setup_fail "the paused facade returned an answer"
  }
  resume_facade() {
    request_facade "resume.$facade_generation" || setup_fail "duplicate facade resume request"
    await_marker "ready.$facade_generation" || setup_fail "the facade did not acquire and replay the restarted node"
    settings="$(tail -n1 "$work/devnet.out")"
    sock="$(jq -er '.privateProbeSocket' <<<"$settings")"
    provider_url="$(jq -er '.providerUrl' <<<"$settings")"
    time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings")"
    network_magic="$(jq -er '.networkMagic' <<<"$settings")"
    [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_directory/time-manifest.json" ] || setup_fail "the resumed facade printed unusable actual settings"
    node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
    printf '%s\n' "$settings" >"$work/facade-settings-$facade_generation.json"
  }
  stop_node() {
    python3 "$process_control" stop "$1" --signal INT --seconds 30
  }
  start_node() {
    rm -f "$node_dir/node.sock"
    # Defer cancellation only across fork/start-tick acquisition, using shell
    # builtins. Cleanup then owns this exact child even before socket readiness
    # or a complete executable identity record; no unrelated PID is selected.
    pending_cancel=0
    trap 'pending_cancel=143' TERM
    trap 'pending_cancel=130' INT
    "$node_exe" "${node_args[@]}" >>"$nlog" 2>&1 </dev/null &
    node_pid=$!
    node_start=""
    if IFS= read -r node_stat <"/proc/$node_pid/stat"; then
      node_stat="${node_stat##*) }"
      read -r -a node_fields <<<"$node_stat"
      node_start="${node_fields[19]}"
    fi
    node_record="$work/replacement-node-$facade_generation.json"
    trap 'exit 143' TERM
    trap 'exit 130' INT
    [ "$pending_cancel" -eq 0 ] || exit "$pending_cancel"
    # This explicit private control cancels in the reproduced acquisition
    # window. It is never consulted by a product executable or ordinary run.
    if [ -n "${CLI_RECOVERY_CANCEL_AT_STARTUP:-}" ]; then
      printf '%s\n' "$node_pid/$node_start" >"$work/startup-cancellation-point"
      case "$CLI_RECOVERY_CANCEL_AT_STARTUP" in
        1) kill -TERM "$$" ;;
        delay)
          # Explicit private interruption control: the caller cancels or
          # times out while this actual owned replacement is acquiring.
          for _ in $(seq 1 600); do sleep 0.1; done
          setup_fail "startup interruption control was never cancelled"
          ;;
        *) setup_fail "unknown private startup cancellation control" ;;
      esac
    fi
    for _ in $(seq 1 600); do
      if [ -S "$node_dir/node.sock" ]; then
        python3 "$process_control" bind "$node_record" --pid "$node_pid" >/dev/null
        return 0
      fi
      kill -0 "$node_pid" 2>/dev/null || return 1
      sleep 0.1
    done
    # It remains our child and must still be bound for cleanup on failure.
    python3 "$process_control" bind "$node_record" --pid "$node_pid" >/dev/null || true
    return 1
  }

  orig_record="$work/original-node.json"
  python3 "$process_control" bind "$orig_record" --config "$node_dir/node-config.json" --socket "$sock" --owner "$devnet_pid" >"$work/original-node.pid" || setup_fail "the exact owned development node was not found"
  node_exe="$(jq -r .executable "$orig_record")"
  mapfile -t node_argv < <(jq -r '.arguments[]' "$orig_record")
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
  run preview-rb create --process-time 120000 --retract-time 15000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
  outcome_is preview-rb success || setup_fail "the second create --preview did not succeed"
  run create-rb create --process-time 120000 --retract-time 15000 --seed "$(field preview-rb .seed)" "${common[@]}" "${node[@]}" "${alice[@]}"
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
  pause_facade
  stop_node "$orig_record" || setup_fail "the development node did not stop"
  cp -a "$node_dir/db" "$work/node-db-snapshot"
  start_node || setup_fail "the development node did not restart after the snapshot"
  resume_facade
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
  pause_facade
  stop_node "$node_record" || setup_fail "the development node did not stop for the restore"
  wait "$node_pid" 2>/dev/null || true
  mv "$node_dir/db" "$work/node-db-forked"
  cp -a "$work/node-db-snapshot" "$node_dir/db"
  start_node || setup_fail "the development node did not restart on the restored database"
  resume_facade
  restored_tip="$(opened_tip_after "$mark")"
  [ -n "$restored_tip" ] || setup_fail "the restored node reported no tip it opened"
  post="$(probe_ins "${book_ins_a[@]}" "${fold_ins_a[@]}" "$rb_book#0" "$rb_fold#0")" \
    || setup_fail "the restored node answers no local state query"
  say "$control: restored at $restored_tip; node reads $(jq -c .tip <<<"$post")"
  clause "the restored node opened its database at the snapshot's tip" \
    jq -n -e --argjson s "$snap_tip" --argjson r "$restored_tip" '$s == $r'
  forged_pair() { [[ "$1" =~ ^([0-9]+)/([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; }
  # The count both adoption clauses stand on can fail, and neither edge of its
  # range splits a block. Shown on two logs written here in the node's own
  # lines: the original node's human adoption lines, a restart's machine ones.
  straddling_log="$work/adoption-count-straddling.log"
  uncovered_log="$work/adoption-count-uncovered.log"
  forge_line() { printf '[2026-01-01 00:00:00.0000Z][epyc:Forge.Loop.ForgedBlock](Info,41) Forged block in slot %s\n' "$1"; }
  human_adoption() { printf '[2026-01-01 00:00:00.0050Z][epyc:Forge.Loop.AdoptedBlock](Info,41) Adopted block forged in slot %s: %064d\n' "$1" "$1"; }
  machine_adoption() { printf '{"at":"2026-01-01T00:00:00.0050Z","ns":"Forge.Loop.AdoptedBlock","data":{"blockHash":"%064d","kind":"TraceAdoptedBlock","slot":%s,"txIds":[]}}\n' "$1" "$1"; }
  {
    forge_line 10
    human_adoption 10
    forge_line 11
    human_adoption 11
    forge_line 12
    machine_adoption 12
    forge_line 13
  } >"$straddling_log"
  {
    forge_line 11
    human_adoption 11
    forge_line 12
    forge_line 13
    machine_adoption 13
  } >"$uncovered_log"
  clause "a block forged just before the range starts and adopted in it counts for neither side" \
    is_equal "$(forged_adopted_in "$straddling_log" 1)" 2/2
  clause "a block forged and in flight at the end of the range counts for neither side" \
    is_equal "$(forged_adopted_in "$straddling_log" 0)" 3/3
  clause "a forged block with no adoption line is counted as forged and not covered" \
    is_equal "$(forged_adopted_in "$uncovered_log" 0)" 3/2
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

  # Query the rebuilt full-block archive itself before the product receipt:
  # the removed fork must not survive in a fresh public-history response.
  restored_archive_omits() {
    python3 - "$provider_url" "$rb_book" "$rb_fold" <<'ARCHIVE'
import json
import sys
import urllib.request
request = urllib.request.Request(sys.argv[1] + "/tx_info",
    data=json.dumps({"_tx_hashes": sys.argv[2:]}).encode(),
    headers={"Content-Type": "application/json"})
with urllib.request.urlopen(request, timeout=10) as response:
    rows = json.load(response)
sys.exit(0 if rows == [] else 1)
ARCHIVE
  }
  clause "the rebuilt facade archive omits both removed transactions" restored_archive_omits

  run inspect-rb inspect --key-hex 6c01 "${common[@]}" "${node[@]}" --wallet-address "$(field create-rb .wallet)"
  clause "the first inspect journals both rollbacks" \
    is_equal "$(event_count "$rb_book" rolled-back)/$(event_count "$rb_fold" rolled-back)" 1/1
  run inspect-rb inspect --key-hex 6c01 "${common[@]}" "${node[@]}" --wallet-address "$(field create-rb .wallet)"
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

# shellcheck disable=SC2034 # case_line and case_next are read through the namerefs of sl_case
if part state-line || part holding-update || part holding-terminate || part termination-fold; then
  # ------------------------------------------------------------------
  # the commands of the proved design, each interrupted three ways
  # ------------------------------------------------------------------
  # open-datum state create, state fold and registration book, reclaim and
  # cleanup, and singular state create, on a registry of their own beside the
  # current line's. Each command that sends is interrupted three ways: its
  # answer lost after the node took it, killed after the send, and never sent.
  # The transaction keeps its identity in the journal, the next write of the
  # same wallet observes an included one once and refuses while an unsent one is
  # unresolved, and nothing is sent twice. The new line's commands do not join
  # the trie observation, which belongs to the current line's commands; the
  # current line's registry is read back beside them instead.
  control="state line"
  sl_root="$work/state-line"
  mkdir -p "$sl_root"
  sl_base=(--blueprint "$blueprint" "${node[@]}")
  sl_params=(--process-time 60000 --reclaim-time 300000 --booking-width 60000)
  sl_app_policy="$(jq -r '.validators[] | select(.title == "open_datum_requests.open_datum_requests.spend") | .hash' "$blueprint")"
  [[ "$sl_app_policy" =~ ^[0-9a-f]{56}$ ]] || setup_fail "the blueprint carries no request validator hash"
  sl_forget() { sed -i "/^$1\$/d" "$work/trie-command-invocations"; }
  sl_run() {
    local n="$1"
    run "$@"
    sl_forget "$n"
  }
  # The transaction a step prepared last, in a journal.
  sl_prepared() { jq -rs --arg s "$2" '[.[] | select(.journalStep == $s and .journalEvent == "prepared")] | last | .journalTxId' "$1"; }
  sl_wait_until_ms() {
    local target="$1" now
    while :; do
      now="$(date +%s%3N)"
      [ "$now" -ge "$((target + 4000))" ] && break
      sleep 1
    done
  }
  # --- the first registry of the application: both scripts published, then the registry ---
  sl_main="$sl_root/main"
  sl_run sl-create state create "${sl_params[@]}" --state-dir "$sl_main" "${sl_base[@]}" "${alice[@]}"
  clause "the first creation succeeds" outcome_is sl-create success
  clause "it publishes each script in its own transaction, then creates the registry" \
    is_equal "$(field sl-create '[.submissions[].step] | tojson')" '["publish-state-script","publish-application-script","create"]'
  clause "each of its transactions was prepared, confirmed and observed, once each" \
    is_equal "$(field sl-create '[.submissions[] | select(.observed == true)] | length')" 3
  sl_token="$(field sl-create .stateToken)"
  [[ "$sl_token" =~ ^[0-9a-f]{56}\.[0-9a-f]{64}$ ]] || setup_fail "the first creation printed no state token"
  sl_state_policy="${sl_token%%.*}"
  clause "the node holds the registry's state output unspent" \
    jq -e --arg o "$(field sl-create .stateOutput)" '.live | index($o) != null' <(probe_ins "$(field sl-create .stateOutput)")
  # A later registry of the application, made by singular, reuses the live copy of the state script.
  sl_run sl-singular-create singular state create --application-policy "$sl_app_policy" \
    --state-dir "$sl_root/singular" "${sl_base[@]}" "${alice[@]}"
  clause "singular creates a registry of the same application" outcome_is sl-singular-create success
  clause "from the live copy of the state script: one transaction" \
    is_equal "$(field sl-singular-create '[.submissions[].step] | tojson')" '["create"]'
  clause "its registry is another registry" bash -c '[ "$1" != "$2" ]' _ "$(field sl-singular-create .stateToken)" "$sl_token"

  # --- state create, interrupted ---
  sl_create_line=(state create "${sl_params[@]}")
  # --- the booking line, and the bookings the cleanups need, made now so that their windows run beside the cases ---
  sl_book_line() { # KEY DIR WALLET...: the line that books KEY from DIR
    local key="$1" dir="$2"
    shift 2
    printf '%s\n' registration book --state-token "$sl_token" --key "$key" --payload "$work/payload.json" \
      --payload-schema detailed --deposit 2100000 --tip 1000000 --state-dir "$dir" "${sl_base[@]}" "$@"
  }
  sl_book() { # NAME: a clean booking by alice in the main directory, of the key that bears the name
    local name="$1" key="$1" line
    mapfile -t line < <(sl_book_line "$key" "$sl_main" "${alice[@]}")
    sl_run "$name" "${line[@]}"
    clause "$name: the booking succeeds" outcome_is "$name" success
  }
  if part state-line; then
    for sl_mode in lost-answer killed never-sent; do
      sl_book "sl-cleanup-pending-$sl_mode"
    done
    sl_first_cleanup_ms="$(field sl-cleanup-pending-lost-answer .reclaimEnd)"
  fi

  # sl_case LABEL STEP MODE JOURNAL LINE NEXT: one command interrupted one way,
  # then the next write of the same wallet and directory.
  sl_case() {
    local label="$1" step="$2" mode="$3" jr="$4"
    local -n ref_line="$5" ref_next="$6"
    local name="sl-$label-$mode" reached=0 lost="" i
    journal="$jr"
    case "$mode" in
      lost-answer)
        sl_at_send() {
          sl_held_tx="$(sl_prepared "$journal" "$step")"
          sl_held_last="$(last_event "$sl_held_tx")"
        }
        sl_held_tx="" sl_held_last=""
        export SINGULAR_HARNESS_DROP_ANSWER="$step" SINGULAR_HARNESS_HOLD_STEP="$step"
        paused "$name" SINGULAR_HARNESS_HOLD_AFTER_SEND sl_at_send "${ref_line[@]}" || reached=1
        unset SINGULAR_HARNESS_DROP_ANSWER SINGULAR_HARNESS_HOLD_STEP
        sl_forget "$name"
        lost="$(submission_tx "$name" "$step")"
        clause "$label, answer lost: the command was held once its transaction was sent" is_equal "$reached" 0
        clause "$label, answer lost: at that moment prepared was the transaction's last journalled phase" is_equal "$sl_held_last" prepared
        clause "$label, answer lost: the held transaction is the one the receipt names" is_equal "$sl_held_tx" "$lost"
        clause "$label, answer lost: the command stops partial (exit 15)" exit_is "$name" 15
        clause "$label, answer lost: its receipt names the transaction's case unknown" is_equal "$(submission_case "$name" "$step")" unknown
        ;;
      killed)
        export SINGULAR_HARNESS_HOLD_STEP="$step"
        held "$name" SINGULAR_HARNESS_HOLD_AFTER_SEND "${ref_line[@]}" || reached=1
        unset SINGULAR_HARNESS_HOLD_STEP
        sl_forget "$name"
        lost="$(sl_prepared "$journal" "$step")"
        clause "$label, killed: the command was killed once its transaction was sent" is_equal "$reached" 0
        clause "$label, killed: the transaction is journalled prepared and nothing more" is_equal "$(events_of "$lost")" '["prepared"]'
        ;;
      never-sent)
        export SINGULAR_HARNESS_DROP_SEND="$step"
        sl_run "$name" "${ref_line[@]}"
        unset SINGULAR_HARNESS_DROP_SEND
        lost="$(submission_tx "$name" "$step")"
        clause "$label, never sent: the command stops partial (exit 15)" exit_is "$name" 15
        clause "$label, never sent: its receipt names the transaction's case unknown" is_equal "$(submission_case "$name" "$step")" unknown
        clause "$label, never sent: the transaction is journalled prepared, then unknown" is_equal "$(events_of "$lost")" '["prepared","submit-unknown"]'
        ;;
    esac
    clause "$label, $mode: the interrupted command names a transaction" is_txid "$lost"
    clause "$label, $mode: the transaction was prepared once" prepared_once "$lost"
    clause "$label, $mode: its saved body is bound to its prepared line by hash" body_bound "$lost"
    cp "$journal" "$work/$name.before-next.jsonl"
    case "$mode" in
      never-sent)
        sl_run "$name-next" "${ref_next[@]}"
        clause "$label, $mode: the next write is refused partial (exit 15)" exit_is "$name-next" 15
        clause "$label, $mode: it names the transaction unresolved" is_equal "$(field "$name-next" .unresolved.tx)" "$lost"
        clause "$label, $mode: it names the case unknown" is_equal "$(field "$name-next" .unresolved.case)" unknown
        clause "$label, $mode: it built and sent nothing: the journal did not move" cmp -s "$work/$name.before-next.jsonl" "$journal"
        clause "$label, $mode: the transaction was never sent again" bash -c '[ "$1" = "[\"prepared\",\"submit-unknown\"]" ]' _ "$(events_of "$lost")"
        ;;
      *)
        # While the transaction is not yet on the chain the next write is refused before it builds anything.
        for i in $(seq 1 60); do
          sl_run "$name-next" "${ref_next[@]}"
          outcome_is "$name-next" partial || break
          sleep 2
        done
        clause "$label, $mode: the next write reconciles and succeeds" outcome_is "$name-next" success
        clause "$label, $mode: it observed the interrupted transaction" \
          is_equal "$(field "$name-next" "[.reconciled.observed[]? | select(. == \"$lost\")] | length")" 1
        clause "$label, $mode: the transaction is observed exactly once in the journal" is_equal "$(event_count "$lost" observed)" 1
        clause "$label, $mode: the transaction was prepared once and never sent again" prepared_once "$lost"
        ;;
    esac
  }

  # sl_next_of DIR WALLET...: the next write of a wallet: a booking of a fresh key.
  sl_next_of() {
    local dir="$1"
    shift
    local key
    key="sl-next-$(basename "$dir")"
    mapfile -t sl_next_line < <(sl_book_line "$key" "$dir" "$@")
  }

  if part state-line; then
    # --- state create, three ways (the creation journal of the application and the wallet) ---
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/create-$sl_mode"
      case_line=("${sl_create_line[@]}" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
      case_next=("${sl_create_line[@]}" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
      sl_case state-create create "$sl_mode" "$(managed_journal "$sl_dir" "$sl_state_policy." "$alicekey")" case_line case_next
    done

    # --- registration book, three ways ---
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/book-$sl_mode"
      mapfile -t case_line < <(sl_book_line "sl-book-$sl_mode" "$sl_dir" "${alice[@]}")
      sl_next_of "$sl_dir" "${alice[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case registration-book book "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$alicekey")" case_line case_next
    done

    # --- registration reclaim, three ways, inside the window of pendings booked now ---
    for sl_mode in lost-answer killed never-sent; do
      sl_book "sl-reclaim-pending-$sl_mode"
    done
    sl_wait_until_ms "$(field sl-reclaim-pending-lost-answer .processDeadline)"
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/reclaim-$sl_mode"
      sl_pending="$(field "sl-reclaim-pending-$sl_mode" .pending)"
      case_line=(registration reclaim --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
      sl_next_of "$sl_dir" "${alice[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case registration-reclaim reclaim "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$alicekey")" case_line case_next
    done

    # --- state fold, three ways, by the second wallet, each over a booking made just before ---
    for sl_mode in lost-answer killed never-sent; do
      sl_book "sl-fold-pending-$sl_mode"
      sl_dir="$sl_root/fold-$sl_mode"
      sl_pending="$(field "sl-fold-pending-$sl_mode" .pending)"
      case_line=(state fold --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${bob[@]}")
      sl_next_of "$sl_dir" "${bob[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case state-fold fold "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$bobkey")" case_line case_next
    done

    # --- registration cleanup, three ways, by the second wallet, once the windows of the pendings have run out ---
    sl_wait_until_ms "$sl_first_cleanup_ms"
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/cleanup-$sl_mode"
      sl_pending="$(field "sl-cleanup-pending-$sl_mode" .pending)"
      case_line=(registration cleanup --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${bob[@]}")
      sl_next_of "$sl_dir" "${bob[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case registration-cleanup cleanup "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$bobkey")" case_line case_next
    done

  fi

  # Each holding command has its own hosted partition. The same recovery
  # predicates judge included-but-unanswered, killed, and never-sent bodies.
  for sl_part in holding-update holding-terminate termination-fold; do
    if part "$sl_part"; then
      control="$sl_part"
      for sl_mode in lost-answer killed never-sent; do
        sl_label="sl-$sl_part-$sl_mode"
        sl_book "$sl_label-book"
        sl_pending="$(field "$sl_label-book" .pending)"
        sl_run "$sl_label-reach" state fold --state-token "$sl_token" --pending "$sl_pending" \
          --state-dir "$sl_main" "${sl_base[@]}" "${bob[@]}"
        clause "$sl_part, $sl_mode: a successful registration fold reaches the live holding" outcome_is "$sl_label-reach" success
        sl_holding="$(submission_tx "$sl_label-reach" fold)#1"
        clause "$sl_part, $sl_mode: that holding is on the chain" \
          jq -e --arg o "$sl_holding" '.live | index($o) != null' <(probe_ins "$sl_holding")
        sl_dir="$sl_root/$sl_part-$sl_mode"
        case "$sl_part" in
          holding-update)
            case_line=(holding update --state-token "$sl_token" --holding "$sl_holding" --payload "$work/payload.json" --payload-schema detailed --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
            sl_step=update
            sl_walletkey="$alicekey"
            sl_next_of "$sl_dir" "${alice[@]}"
            ;;
          holding-terminate)
            case_line=(holding terminate --state-token "$sl_token" --holding "$sl_holding" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
            sl_step=terminate
            sl_walletkey="$alicekey"
            sl_next_of "$sl_dir" "${alice[@]}"
            ;;
          termination-fold)
            sl_run "$sl_label-terminate" holding terminate --state-token "$sl_token" --holding "$sl_holding" --state-dir "$sl_main" "${sl_base[@]}" "${alice[@]}"
            clause "$sl_part, $sl_mode: termination booking succeeds" outcome_is "$sl_label-terminate" success
            sl_pending="$(field "$sl_label-terminate" .pending)"
            case_line=(state fold --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${bob[@]}")
            sl_step="fold"
            sl_walletkey="$bobkey"
            sl_next_of "$sl_dir" "${bob[@]}"
            ;;
        esac
        case_next=("${sl_next_line[@]}")
        sl_case "$sl_part" "$sl_step" "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$sl_walletkey")" case_line case_next
      done
    fi
  done

  # --- the current line beside the new one ---
  control="state line, the current line beside it"
  run sl-old-inspect inspect --key-hex 6b0a "${common[@]}" "${node[@]}"
  clause "the current line's registry still reads back at its first root" \
    is_equal "$(field sl-old-inspect '.outcome + "/" + .root')" "success/0000000000000000000000000000000000000000000000000000000000000000"

# ------------------------------------------------------------------
fi

if part trie-capability; then
  control="trie capability"
  clause "completed create has observed boot evidence and real recovery commands have authenticated lineage evidence bound to their identity, output, key, leaf and root" trie_extent
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
