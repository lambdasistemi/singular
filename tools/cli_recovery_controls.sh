#!/usr/bin/env bash
# Recovery of the commands of the proved design, on one generated development
# node per partition. Each sending command loses its answer, is killed after
# sending, and is prepared but never sent. Receipts, saved bodies and journals
# establish identity and reconciliation without automatic resubmission.
# usage: cli_recovery_controls.sh SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR REPO-ROOT
# shellcheck disable=SC2016 # jq programs name jq variables, never shell ones
set -euo pipefail

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
[ ! -e "$work" ] || {
  echo "recovery: $work exists; every run takes a fresh directory" >&2
  exit 2
}
mkdir -p "$work"
work="$(cd "$work" && pwd)"
receipts="$work/receipts"
mkdir -p "$receipts"
# shellcheck source=tools/managed_state.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/managed_state.sh"
# The journal under test, reassigned per phase and writer: journals live in
# managed identity partitions, never directly at the configured root.
journal=""
verdicts="$work/verdicts.md"

say() { echo "recovery: $*"; }
setup_fail() {
  echo "recovery: SETUP: $*" >&2
  exit 3
}
known_parts="state-line holding-update holding-terminate termination-fold shared-publications"
for requested in ${CLI_RECOVERY_PARTS:-}; do
  [[ " $known_parts " == *" $requested "* ]] || setup_fail "CLI_RECOVERY_PARTS names an unknown part: $requested (known: $known_parts)"
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
  # DEMO1_KEEP_SCRATCH=1 keeps originals for the per-partition collector.
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
# Defer cancellation only across the initial fixture fork/start-tick
# acquisition, using shell builtins. Cleanup then owns this exact direct child even before the private
# devnet prints usable settings or a complete executable identity exists.
pending_cancel=0
trap 'pending_cancel=143' TERM
trap 'pending_cancel=130' INT
"$devnet" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" --fund-outputs 10 --fund-lovelace 2000000000 \
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
# run NAME ARGS...: one ordinary process; its receipt and exit status kept.
# A `singular` first word selects singular and is dropped.
run() {
  local name="$1"
  shift
  local status=0
  local bin="$open_datum"
  if [ "${1:-}" = singular ]; then
    bin="$singular"
    shift
  fi
  : >"$receipts/$name.trace.jsonl"
  "$bin" "$@" --trace how --trace-to "file:$receipts/$name.trace.jsonl" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
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
  if [ "${1:-}" = singular ]; then
    bin="$singular"
    shift
  fi
  local go="$work/$name.go"
  rm -f "$go" "$go.waiting"
  : >"$receipts/$name.trace.jsonl"
  env "$var=$go" \
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
  if [ "${1:-}" = singular ]; then
    bin="$singular"
    shift
  fi
  local go="$work/$name.go"
  rm -f "$go" "$go.waiting"
  : >"$receipts/$name.trace.jsonl"
  env "$var=$go" \
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

# The journal's prepared line of TX.
prepared_of() { jq -c --arg t "$1" 'select(.journalTxId == $t and .journalEvent == "prepared")' "$journal"; }
prepared_once() { [ "$(jq -s --arg t "$1" '[.[] | select(.journalTxId == $t and .journalEvent == "prepared")] | length' "$journal")" = 1 ]; }
events_of() { jq -s -c --arg t "$1" '[.[] | select(.journalTxId == $t) | .journalEvent]' "$journal"; }
event_count() {
  jq -s --arg t "$1" --arg e "$2" '[.[] | select(.journalTxId == $t and .journalEvent == $e)] | length' "$journal"
}
last_event() { jq -s -r --arg t "$1" '[.[] | select(.journalTxId == $t)] | last | .journalEvent' "$journal"; }
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
submission_case() { field "$1" "[.submissions[]? | select(.step == \"$2\") | .case] | last"; }
submission_tx() { field "$1" "[.submissions[]? | select(.step == \"$2\") | .tx] | last"; }
# Equal, and about something: an empty or null value never matches.
is_equal() { [ -n "$1" ] && [ "$1" != null ] && [ "$1" = "$2" ]; }
is_txid() { [[ "$1" =~ ^[0-9a-f]{64}$ ]]; }

jq -n '{int: 42}' >"$work/payload.json"

part() {
  if [ -z "${CLI_RECOVERY_PARTS:-}" ] || [[ " $CLI_RECOVERY_PARTS " == *" $1 "* ]]; then
    current_part="$1"
    part_clauses[$1]="${part_clauses[$1]:-0}"
    return 0
  fi
  return 1
}
# shellcheck disable=SC2034 # case_line and case_next are read through the namerefs of sl_case
if part state-line || part holding-update || part holding-terminate || part termination-fold || part shared-publications; then
  # ------------------------------------------------------------------
  # the commands of the proved design, each interrupted three ways
  # ------------------------------------------------------------------
  # Every retained command is interrupted three ways. This bootstrap runs
  # only the new commands; each wallet identity comes from its managed journal.
  control="state line"
  sl_root="$work/state-line"
  mkdir -p "$sl_root"
  sl_base=(--blueprint "$blueprint" "${node[@]}")
  sl_params=(--process-time 60000 --reclaim-time 300000 --booking-width 60000)
  sl_app_policy="$(jq -r '.validators[] | select(.title == "open_datum_requests.open_datum_requests.spend") | .hash' "$blueprint")"
  [[ "$sl_app_policy" =~ ^[0-9a-f]{56}$ ]] || setup_fail "the blueprint carries no request validator hash"
  sl_run() { run "$@"; }
  sl_wallet_identity() {
    local identities
    identities="$(find "$1" -path '*/wallets/*/journal.jsonl' -type f | sed -E 's|.*/wallets/([^/]+)/journal.jsonl|\1|' | sort -u)"
    [[ "$identities" =~ ^[0-9a-f]{56}$ ]] || setup_fail "no unique wallet identity in $1"
    printf '%s' "$identities"
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
  sl_run sl-create create "${sl_params[@]}" --state-dir "$sl_main" "${sl_base[@]}" "${alice[@]}"
  clause "the first creation succeeds" outcome_is sl-create success
  clause "it publishes each script in its own transaction, then creates the registry" \
    is_equal "$(field sl-create '[.submissions[].step] | tojson')" '["publish-state-script","publish-application-script","create"]'
  clause "each of its transactions was prepared, confirmed and observed, once each" \
    is_equal "$(field sl-create '[.submissions[] | select(.observed == true)] | length')" 3
  alicekey="$(sl_wallet_identity "$sl_main")"
  sl_token="$(field sl-create .stateToken)"
  [[ "$sl_token" =~ ^[0-9a-f]{56}\.[0-9a-f]{64}$ ]] || setup_fail "the first creation printed no state token"
  sl_state_policy="${sl_token%%.*}"
  clause "the node holds the registry's state output unspent" \
    jq -e --arg o "$(field sl-create .stateOutput)" '.live | index($o) != null' <(probe_ins "$(field sl-create .stateOutput)")
  # A later registry of the application, made by singular, reuses the live copy of the state script.
  sl_run sl-singular-create singular registry create --application-policy "$sl_app_policy" \
    --state-dir "$sl_root/singular" "${sl_base[@]}" "${bob[@]}"
  clause "singular creates a registry of the same application" outcome_is sl-singular-create success
  clause "from the live copy of the state script: one transaction" \
    is_equal "$(field sl-singular-create '[.submissions[].step] | tojson')" '["create"]'
  clause "its registry is another registry" bash -c '[ "$1" != "$2" ]' _ "$(field sl-singular-create .stateToken)" "$sl_token"

  bobkey="$(sl_wallet_identity "$sl_root/singular")"

  # --- create, interrupted ---
  sl_create_line=(create "${sl_params[@]}")
  # --- the booking line, and the bookings the cleanups need, made now so that their windows run beside the cases ---
  sl_book_line() { # KEY DIR WALLET...: the line that books KEY from DIR
    local key="$1" dir="$2"
    shift 2
    printf '%s\n' insert --state-token "$sl_token" --key "$key" --payload "$work/payload.json" \
      --payload-schema detailed --deposit 3000000 --tip 1000000 --state-dir "$dir" "${sl_base[@]}" "$@"
  }
  sl_book() { # NAME: a clean booking by alice in the main directory, of the key that bears the name
    local name="$1" key="${2:-$1}" line
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
    if [ "${#key}" -gt 32 ]; then key="n-$(basename "$dir")"; fi
    mapfile -t sl_next_line < <(sl_book_line "$key" "$dir" "$@")
  }

  if part state-line; then
    # --- create, three ways (the creation journal of the application and the wallet) ---
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/create-$sl_mode"
      case_line=("${sl_create_line[@]}" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
      case_next=("${sl_create_line[@]}" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
      sl_case state-create create "$sl_mode" "$(managed_journal "$sl_dir" "$sl_state_policy." "$alicekey")" case_line case_next
    done

    # --- insert, three ways ---
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/book-$sl_mode"
      mapfile -t case_line < <(sl_book_line "sl-book-$sl_mode" "$sl_dir" "${alice[@]}")
      sl_next_of "$sl_dir" "${alice[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case registration-book book "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$alicekey")" case_line case_next
    done

    # --- reclaim, three ways, inside the window of pendings booked now ---
    for sl_mode in lost-answer killed never-sent; do
      sl_book "sl-reclaim-pending-$sl_mode"
    done
    sl_wait_until_ms "$(field sl-reclaim-pending-lost-answer .processDeadline)"
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/reclaim-$sl_mode"
      sl_pending="$(field "sl-reclaim-pending-$sl_mode" .pending)"
      case_line=(reclaim --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
      sl_next_of "$sl_dir" "${alice[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case registration-reclaim reclaim "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$alicekey")" case_line case_next
    done

    # --- fold, three ways, by the second wallet, each over a booking made just before ---
    for sl_mode in lost-answer killed never-sent; do
      sl_book "sl-fold-pending-$sl_mode"
      sl_dir="$sl_root/fold-$sl_mode"
      sl_pending="$(field "sl-fold-pending-$sl_mode" .pending)"
      case_line=(fold --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${bob[@]}")
      sl_next_of "$sl_dir" "${bob[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case state-fold fold "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$bobkey")" case_line case_next
    done

    # --- cleanup, three ways, by the second wallet, once the windows of the pendings have run out ---
    sl_wait_until_ms "$sl_first_cleanup_ms"
    for sl_mode in lost-answer killed never-sent; do
      sl_dir="$sl_root/cleanup-$sl_mode"
      sl_pending="$(field "sl-cleanup-pending-$sl_mode" .pending)"
      case_line=(cleanup --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${bob[@]}")
      sl_next_of "$sl_dir" "${bob[@]}"
      case_next=("${sl_next_line[@]}")
      sl_case registration-cleanup cleanup "$sl_mode" "$(managed_journal "$sl_dir" "$sl_token" "$bobkey")" case_line case_next
    done

  fi

  if part shared-publications; then
    control="shared publications"
    # shellcheck source=tools/shared_publication_checks.sh
    # shellcheck disable=SC1091
    source "$(dirname "$0")/shared_publication_checks.sh"
    sp_source="$(jq -er '.independentSourceDirectory' <<<"$settings")/independent-facade-sources.jsonl"
    sp_chain="$(dirname "$0")/no_pin_chain_view.py"
    sp_view() {
      local name="$1" tx="$2" attempt
      for attempt in $(seq 1 240); do
        if python3 -I "$sp_chain" tx "$tx" <"$sp_source" >"$receipts/$name.chain.json" 2>/dev/null; then return 0; fi
        sleep 0.5
      done
      setup_fail "the independent chain record did not hold $tx"
    }
    sp_spend() {
      local name="$1" ref="$2" key="$3" output
      "$devnet" spend-reference --tx-in "$ref" --wallet-skey "$key" "${node[@]}" >"$receipts/$name.json"
      output="$(field "$name" .control.output)"
      sp_view "$name" "${output%#*}"
      clause "the ordinary reference spend covers the script fee and is included unchanged" \
        check_shared_spent_reference_fee "$receipts/$name.json" "$receipts/$name.chain.json"
      jq '.builder.fee = (.requiredFee - 1) | .control.fee = .builder.fee' "$receipts/$name.json" >"$receipts/$name.low-fee.json"
      jq --argjson fee "$(jq '.builder.fee' "$receipts/$name.low-fee.json")" '.fee = $fee' \
        "$receipts/$name.chain.json" >"$receipts/$name.low-fee.chain.json"
      clause "a reference spend below the ledger minimum is refused by the same check" \
        sp_refuses check_shared_spent_reference_fee "$receipts/$name.low-fee.json" "$receipts/$name.low-fee.chain.json"
    }
    sp_steps() { is_equal "$(field "$1" '[.submissions[].step] | tojson')" "$2"; }
    sp_scripts() { is_equal "$(field "$1" '[.scripts[].outcome] | tojson')" "$2"; }
    sp_refuses() { if "$@" >/dev/null 2>&1; then return 1; else return 0; fi; }
    sp_prepared_unchanged() {
      jq -s -e --slurpfile before "$1" --arg tx "$2" '
        [.[] | select(.journalTxId == $tx and .journalEvent == "prepared")] as $now
        | [$before[] | select(.journalTxId == $tx and .journalEvent == "prepared")] as $old
        | ($now | length) == 1 and ($old | length) == 1 and $now == $old' "$journal"
    }

    sl_run shared-independent create "${sl_params[@]}" --state-dir "$sl_root/shared-independent" "${sl_base[@]}" "${bob[@]}"
    sp_view shared-independent "$(submission_tx shared-independent create)"
    sp_view shared-publisher "$(submission_tx sl-create publish-state-script)"
    sp_view shared-first-create "$(submission_tx sl-create create)"
    sp_refs="$(field sl-create '[.scripts[].reference] | tojson')"
    clause "a wallet that never published reads both copies owned by the other wallet" \
      check_shared_independent_creation "$receipts/shared-independent.json" "$receipts/shared-independent.chain.json" "$receipts/shared-publisher.chain.json" "$sp_refs"
    clause "the publisher's own creation cannot establish independent reuse" \
      sp_refuses check_shared_independent_creation "$receipts/sl-create.json" "$receipts/shared-first-create.chain.json" "$receipts/shared-publisher.chain.json" "$sp_refs"

    # Before the publication: no transaction has been prepared. Cancelling
    # the calling process leaves the live state copy untouched.
    sp_app_ref="$(field sl-create '.scripts[] | select(.script == "application") | .reference')"
    sp_spend shared-remove-first "$sp_app_ref" "$work/alice.skey"
    sp_before="$sl_root/shared-before-publication"
    reached=0
    held shared-before-publication SINGULAR_HARNESS_HOLD_BEFORE_LOCK \
      create "${sl_params[@]}" --state-dir "$sp_before" "${sl_base[@]}" "${bob[@]}" || reached=1
    clause "before publication: the caller was cancelled before taking the write lock" is_equal "$reached" 0
    sl_run shared-before-next create "${sl_params[@]}" --state-dir "$sp_before" "${sl_base[@]}" "${bob[@]}"
    clause "before publication: rerunning succeeds" outcome_is shared-before-next success
    clause "before publication: only the missing application script is published, then one creation" \
      sp_steps shared-before-next '["publish-application-script","create"]'
    clause "before publication: the shared state is reused and the missing application is published" \
      sp_scripts shared-before-next '["reused","published"]'

    # After publication: keep its prepared identity and signed body, then
    # reconcile it once and reuse both live copies on the repeated command.
    sp_app_ref="$(field shared-before-next '.scripts[] | select(.script == "application") | .reference')"
    sp_spend shared-remove-second "$sp_app_ref" "$work/bob.skey"
    sp_after="$sl_root/shared-after-publication"
    case_line=(create "${sl_params[@]}" --state-dir "$sp_after" "${sl_base[@]}" "${bob[@]}")
    case_next=("${case_line[@]}")
    sl_case shared-publication publish-application-script killed \
      "$(managed_journal "$sp_after" "$sl_state_policy." "$bobkey")" case_line case_next
    clause "after publication: the repeated command sends the creation alone" \
      sp_steps sl-shared-publication-killed-next '["create"]'
    clause "after publication: both shared scripts are reused" \
      sp_scripts sl-shared-publication-killed-next '["reused","reused"]'
    sp_publication_tx="$(sl_prepared "$journal" publish-application-script)"
    clause "after publication: the original prepared identity and body hash remain unchanged" \
      sp_prepared_unchanged "$work/sl-shared-publication-killed.before-next.jsonl" "$sp_publication_tx"
    clause "after publication: the saved signed body still matches that original hash" body_bound "$sp_publication_tx"

    # The command is deliberately not idempotent: the saved creation is
    # observed, never resubmitted, and a new invocation makes a new registry.
    sp_unknown="$sl_root/shared-uncertain-create"
    case_line=(create "${sl_params[@]}" --state-dir "$sp_unknown" "${sl_base[@]}" "${bob[@]}")
    case_next=("${case_line[@]}")
    sl_case shared-create create lost-answer \
      "$(managed_journal "$sp_unknown" "$sl_state_policy." "$bobkey")" case_line case_next
    sp_lost="$(submission_tx sl-shared-create-lost-answer create)"
    clause "uncertain creation: the original prepared identity and body hash remain unchanged" \
      sp_prepared_unchanged "$work/sl-shared-create-lost-answer.before-next.jsonl" "$sp_lost"
    clause "uncertain creation: the saved signed body still matches that original hash" body_bound "$sp_lost"
    jq --arg tx "$sp_lost" 'if .journalTxId == $tx and .journalEvent == "prepared" then .journalBodyHash += "changed" else . end' \
      "$work/sl-shared-create-lost-answer.before-next.jsonl" >"$receipts/shared-prepared-tampered.json"
    clause "an altered saved creation body hash is refused" \
      sp_refuses sp_prepared_unchanged "$receipts/shared-prepared-tampered.json" "$sp_lost"
    sp_view shared-original-create "$sp_lost"
    sp_next="$(submission_tx sl-shared-create-lost-answer-next create)"
    sp_view shared-next-create "$sp_next"
    clause "uncertain creation: the next invocation uses both shared copies and sends only a new creation" \
      sp_steps sl-shared-create-lost-answer-next '["create"]'
    clause "uncertain creation: neither script is published again" \
      sp_scripts sl-shared-create-lost-answer-next '["reused","reused"]'
    sp_old_token="$(jq -r '.outputs[0].assets[0] | .policy + "." + .name' "$receipts/shared-original-create.chain.json")"
    clause "uncertain creation: the further invocation creates a different registry, not a duplicate submission" \
      bash -c '[ "$1" != "$2" ]' _ "$sp_old_token" "$(field sl-shared-create-lost-answer-next .stateToken)"
    clause "uncertain creation: the original saved registry is still live" \
      jq -e --arg ref "$sp_lost#0" '.live | index($ref) != null' <(probe_ins "$sp_lost#0")
    clause "uncertain creation: the new receipt names an actual spent seed" \
      jq -e --arg seed "$(field sl-shared-create-lost-answer-next .seed)" 'any(.inputs[]; .ref == $seed)' "$receipts/shared-next-create.chain.json"
    clause "uncertain creation: the seed of the original transaction is not spent a second time" \
      jq -e --slurpfile old "$receipts/shared-original-create.chain.json" \
      'all(.inputs[]; .ref as $ref | all($old[0].inputs[]; .ref != $ref))' "$receipts/shared-next-create.chain.json"
    sp_old_seed="$(jq -er 'if (.inputs | length) == 1 then .inputs[0].ref else error("creation has no unique seed input") end' "$receipts/shared-original-create.chain.json")"
    sl_run shared-repeated-seed create "${sl_params[@]}" --seed "$sp_old_seed" --state-dir "$sp_unknown" "${sl_base[@]}" "${bob[@]}"
    clause "an explicitly repeated spent seed is refused without another submission" \
      jq -e '.outcome == "client-refusal" and (.reason | contains("is not an unspent output")) and (.submissions | length) == 0' "$receipts/shared-repeated-seed.json"

    python3 -I "$sp_chain" transactions <"$sp_source" >"$receipts/shared-all-transactions.chain.json"
    clause "funding is conserved on chain and no reserved input is spent twice" \
      check_shared_funding_conserved "$receipts/shared-all-transactions.chain.json"
    jq '.transactions[0].fee += 1' "$receipts/shared-all-transactions.chain.json" >"$receipts/shared-funding-tampered.json"
    clause "an altered funding amount is refused" \
      sp_refuses check_shared_funding_conserved "$receipts/shared-funding-tampered.json"
    clause "the shared-publication recovery leg publishes no witness and configures no witness pin" \
      check_shared_no_witness_publication "$receipts/shared-all-transactions.chain.json" "$sl_state_policy" "$sl_app_policy"
    jq --arg pin "$sl_state_policy" --arg app "$sl_app_policy" \
      '(.transactions[].outputs[] | select(.credential.hash == $app and .datum.constructor == 0) | .datum.fields[0].fields) += [{bytes:$pin}]' \
      "$receipts/shared-all-transactions.chain.json" >"$receipts/shared-pin-tampered.json"
    clause "a witness pin in the recovery configuration is refused" \
      sp_refuses check_shared_no_witness_publication "$receipts/shared-pin-tampered.json" "$sl_state_policy" "$sl_app_policy"
    jq --arg foreign "$(jq -r '.transactions[0].signers[0]' "$receipts/shared-all-transactions.chain.json")" \
      '(.transactions[].outputs[] | select(.referenceScript != null) | .referenceScript.hash) = $foreign' \
      "$receipts/shared-all-transactions.chain.json" >"$receipts/shared-publication-tampered.json"
    clause "a reference publication under another policy is refused" \
      sp_refuses check_shared_no_witness_publication "$receipts/shared-publication-tampered.json" "$sl_state_policy" "$sl_app_policy"
    control="harness appendix"
    clause "every discovered shared-publication check ran on passing and refusing input" shared_publication_checks_covered
    # Temporarily introduce an uncalled predicate; the guard must reject it.
    # shellcheck disable=SC2329 # intentionally uncalled negative control
    check_shared_uncalled_control() { return 0; }
    clause "an uncalled predicate is refused by the coverage guard" sp_refuses shared_publication_checks_covered
    unset -f check_shared_uncalled_control
    clause "removing the temporary control restores predicate coverage" shared_publication_checks_covered
  fi

  # Each holding command has its own hosted partition. The same recovery
  # predicates judge included-but-unanswered, killed, and never-sent bodies.
  for sl_part in holding-update holding-terminate termination-fold; do
    if part "$sl_part"; then
      control="$sl_part"
      for sl_mode in lost-answer killed never-sent; do
        sl_label="sl-$sl_part-$sl_mode"
        sl_book "$sl_label-book" "$sl_part-$sl_mode"
        sl_pending="$(field "$sl_label-book" .pending)"
        sl_run "$sl_label-reach" fold --state-token "$sl_token" --pending "$sl_pending" \
          --state-dir "$sl_main" "${sl_base[@]}" "${bob[@]}"
        clause "$sl_part, $sl_mode: a successful registration fold reaches the live holding" outcome_is "$sl_label-reach" success
        sl_holding="$(submission_tx "$sl_label-reach" fold)#1"
        clause "$sl_part, $sl_mode: that holding is on the chain" \
          jq -e --arg o "$sl_holding" '.live | index($o) != null' <(probe_ins "$sl_holding")
        sl_dir="$sl_root/$sl_part-$sl_mode"
        case "$sl_part" in
          holding-update)
            case_line=(update --state-token "$sl_token" --holding "$sl_holding" --payload "$work/payload.json" --payload-schema detailed --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
            sl_step=update
            sl_walletkey="$alicekey"
            sl_next_of "$sl_dir" "${alice[@]}"
            ;;
          holding-terminate)
            case_line=(terminate --state-token "$sl_token" --holding "$sl_holding" --state-dir "$sl_dir" "${sl_base[@]}" "${alice[@]}")
            sl_step=terminate
            sl_walletkey="$alicekey"
            sl_next_of "$sl_dir" "${alice[@]}"
            ;;
          termination-fold)
            sl_run "$sl_label-terminate" terminate --state-token "$sl_token" --holding "$sl_holding" --state-dir "$sl_main" "${sl_base[@]}" "${alice[@]}"
            clause "$sl_part, $sl_mode: termination booking succeeds" outcome_is "$sl_label-terminate" success
            sl_pending="$(field "$sl_label-terminate" .pending)"
            case_line=(fold --state-token "$sl_token" --pending "$sl_pending" --state-dir "$sl_dir" "${sl_base[@]}" "${bob[@]}")
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
