#!/usr/bin/env bash
# The ordinary CLI's recovery controls (#325): what `singular registry`
# does after a lost acknowledgement or an interrupted local commit, on one
# generated development node, every command a separate process.
#
# usage: cli_recovery_controls.sh SINGULAR DEVNET BLUEPRINT WORKDIR
#
#   accepting      an insert ends with both submissions included and
#                  observed, and the local files at the ledger's root;
#   lost answer    the node accepts an insert's fold but its answer is
#                  lost: the command stops naming the case `unknown`, and
#                  the next ordinary write reconciles the fold — applied to
#                  the mirror once, observed once, never sent again — and
#                  proceeds;
#   killed before  an insert is killed once its fold is confirmed, before
#   the commit     the mirror is saved: the next write applies the edge
#                  once and proceeds;
#   killed after   a terminate is killed once the mirror is saved, before
#   the mirror     its fold is observed: the next write applies nothing,
#                  observes the fold and proceeds;
#   never sent     an insert's fold never reaches the node: the next write
#                  stops before building anything, naming the case and the
#                  transaction, and the journal does not move.
#
# The harness points are SINGULAR_HARNESS_* variables, inert when unset.
# Every verdict is computed from the receipts the processes printed, the
# registry's journal, its saved bodies and its files; none is typed. The
# verdict table is WORKDIR/verdicts.md. A setup failure (no node, no
# socket, a create that does not complete) exits 3 and is never a
# verdict; any clause that does not hold exits 1.
set -euo pipefail

[ "$#" -eq 4 ] || {
  echo "usage: $0 SINGULAR DEVNET BLUEPRINT WORKDIR" >&2
  exit 2
}
singular="$1"
devnet="$2"
blueprint="$3"
work="$4"
[ ! -e "$work" ] || {
  echo "recovery: $work exists; every run takes a fresh directory" >&2
  exit 2
}
mkdir -p "$work"
work="$(cd "$work" && pwd)"
receipts="$work/receipts"
snaps="$work/snapshots"
mkdir -p "$receipts" "$snaps"
reg="$work/registry"
journal="$reg/journal.jsonl"
verdicts="$work/verdicts.md"

say() { echo "recovery: $*"; }
setup_fail() {
  echo "recovery: SETUP: $*" >&2
  exit 3
}

printf '| control | clause | verdict |\n|---|---|---|\n' >"$verdicts"
failed=0
control=""
# clause TEXT CMD...: the clause holds when CMD exits 0.
clause() {
  local text="$1"
  shift
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

# ------------------------------------------------------------------
# One development node
# ------------------------------------------------------------------
export TMPDIR="$work"
"$devnet" --fund-skey "$work/alice.skey" --fund-outputs 10 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
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

# run NAME ARGS...: one singular process; its receipt and exit status kept.
run() {
  local name="$1"
  shift
  local status=0
  "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  echo "$status" >"$receipts/$name.exit"
  say "$name: $(jq -r .outcome "$receipts/$name.json" 2>/dev/null || echo none) (exit $status)"
}
# held NAME VAR ARGS...: one singular process with the harness hold VAR set
# to a path, killed once it waits there. Returns 0 only when it was killed
# at the hold.
held() {
  local name="$1" var="$2"
  shift 2
  local go="$work/$name.go"
  rm -f "$go" "$go.waiting"
  env "$var=$go" "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" &
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
  return 1
}
field() { jq -r "$2" "$receipts/$1.json"; }
outcome_is() { [ "$(field "$1" .outcome)" = "$2" ]; }
exit_is() { [ "$(cat "$receipts/$1.exit")" = "$2" ]; }

# The registry's local files, as a later clause compares them.
snap() {
  if [ -f "$journal" ]; then cp "$journal" "$snaps/$1.jsonl"; else : >"$snaps/$1.jsonl"; fi
  jq -r .localRoot "$reg/state.json" >"$snaps/$1.root"
  sha256sum <"$reg/registry.mirror.json" | cut -d' ' -f1 >"$snaps/$1.mirror"
  find "$reg/submissions" -type f -exec sha256sum {} + 2>/dev/null | sort >"$snaps/$1.bodies" || true
}
root_now() { jq -r .localRoot "$reg/state.json"; }
mirror_now() { sha256sum <"$reg/registry.mirror.json" | cut -d' ' -f1; }
state_kept() { [ "$(root_now)" = "$(cat "$snaps/$1.root")" ]; }
mirror_kept() { [ "$(mirror_now)" = "$(cat "$snaps/$1.mirror")" ]; }
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

# envelope FILE CONTROLLER KEY
envelope() {
  jq -n --arg s "$state" --arg t "$token" --arg a "$active" --arg k "$3" --arg c "$2" '
      {constructor:0, fields:[
        {constructor:0, fields:[{int:1},{constructor:0,fields:[{bytes:$s},{bytes:$t}]},
          {bytes:$a},{bytes:$k},{bytes:$c},{int:2000000}]},
        {map:[{k:{bytes:"6e616d65"},v:{bytes:"616c696365"}}]}]}' >"$1"
}
insert_of() { args=(registry insert --key "$1" --envelope "$work/$1.json" "${common[@]}" "${node[@]}" "${alice[@]}"); }

# ------------------------------------------------------------------
# The registry
# ------------------------------------------------------------------
run preview registry create --preview "${common[@]}" "${node[@]}" "${alice[@]}"
outcome_is preview success || setup_fail "create --preview did not succeed"
run create registry create --seed "$(field preview .seed)" "${common[@]}" "${node[@]}" "${alice[@]}"
outcome_is create success || setup_fail "create did not succeed"
state="$(field create .pins.pinState)"
token="$(field create .token)"
active="$(field create .pins.pinActive)"
alicekey="$(field create .walletKeyHash)"
for k in 6b0a 6b0b 6b0c 6b0d 6b0e 6b0f; do envelope "$work/$k.json" "$alicekey" "$k"; done
jq -n '{int: 42}' >"$work/payload.json"
say "registry $token created"

# ------------------------------------------------------------------
# accepting
# ------------------------------------------------------------------
control=accepting
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
clause "state.json commits to the fold's journalled root after" is_equal "$(root_now)" "$(root_after_of "$fold")"
clause "the receipt's root is that root" is_equal "$(field insert-a .root)" "$(root_after_of "$fold")"
run inspect-a registry inspect --key 6b0a "${common[@]}" "${node[@]}"
clause "inspect reads the key active at that root" \
  is_equal "$(field inspect-a '.outcome + "/" + .leaf + "/" + .root')" "success/active/$(root_after_of "$fold")"
clause "the journal was only appended to and no body changed" appended_only s0

# ------------------------------------------------------------------
# lost answer
# ------------------------------------------------------------------
control="lost answer"
snap s1
export SINGULAR_HARNESS_DROP_ANSWER=fold
insert_of 6b0b
run insert-b "${args[@]}"
unset SINGULAR_HARNESS_DROP_ANSWER
lost="$(submission_tx insert-b fold)"
clause "the insert stops partial (exit 15)" exit_is insert-b 15
clause "its receipt names the booking's case included" is_equal "$(submission_case insert-b book)" included
clause "its receipt names the fold's case unknown" is_equal "$(submission_case insert-b fold)" unknown
clause "the fold's last journalled phase is submit-unknown" is_equal "$(last_event "$lost")" submit-unknown
clause "the fold's body was saved, bound to its prepared line, before the send" body_bound "$lost"
clause "nothing was committed locally: state.json unchanged" state_kept s1
clause "nothing was committed locally: the mirror unchanged" mirror_kept s1
# The next ordinary write. While the fold is not yet on chain it is
# refused before building anything; once it is, it reconciles and proceeds.
refusals_clean=0
for i in $(seq 1 40); do
  snap "s1-try-$i"
  insert_of 6b0c
  run insert-c "${args[@]}"
  outcome_is insert-c partial || break
  if ! journal_same "s1-try-$i" || ! state_kept "s1-try-$i" || ! mirror_kept "s1-try-$i" \
    || [ "$(field insert-c .unresolved.tx)" != "$lost" ]; then
    refusals_clean=1
  fi
  sleep 2
done
clause "every write refused while the fold was unknown named it and moved nothing" is_equal "$refusals_clean" 0
clause "the next write reconciles and succeeds" outcome_is insert-c success
clause "it applied the lost fold's edge to the mirror" is_equal "$(field insert-c -c .reconciled.applied)" "[\"$lost\"]"
clause "it observed the lost fold" is_equal "$(field insert-c "[.reconciled.observed[]? | select(. == \"$lost\")] | length")" 1
clause "the lost fold was prepared once, never sent again" prepared_once "$lost"
clause "the lost fold is observed exactly once in the journal" is_equal "$(event_count "$lost" observed)" 1
clause "the lost fold's observation was journalled by the reconciling insert" \
  is_equal "$(since s1 | jq -r --arg t "$lost" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
clause "the fold started from the root before the lost answer" is_equal "$(root_before_of "$lost")" "$(cat "$snaps/s1.root")"
clause "the next fold started from the lost fold's root after: one edge between" \
  is_equal "$(root_before_of "$(submission_tx insert-c fold)")" "$(root_after_of "$lost")"
run inspect-b registry inspect --key 6b0b "${common[@]}" "${node[@]}"
clause "inspect reads the lost answer's key active" is_equal "$(field inspect-b '.outcome + "/" + .leaf')" success/active
clause "the journal was only appended to and no body changed" appended_only s1

# ------------------------------------------------------------------
# killed before the commit
# ------------------------------------------------------------------
control="killed before the commit"
snap s2
reached=0
insert_of 6b0d
held insert-d SINGULAR_HARNESS_HOLD_BEFORE_COMMIT "${args[@]}" || reached=1
clause "the insert was killed after its fold was confirmed, before the commit" is_equal "$reached" 0
killed_fold="$(fold_since s2)"
clause "the fold's last journalled phase is confirmed" is_equal "$(last_event "$killed_fold")" confirmed
clause "nothing was committed locally: state.json unchanged" state_kept s2
clause "nothing was committed locally: the mirror unchanged" mirror_kept s2
snap s2-killed
run update-a registry update --key 6b0a --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"
clause "the next write, an update of another key, reconciles and succeeds" outcome_is update-a success
clause "it applied the killed fold's edge to the mirror once" is_equal "$(field update-a -c .reconciled.applied)" "[\"$killed_fold\"]"
clause "the killed fold is observed exactly once, by the update" \
  is_equal "$(since s2-killed | jq -r --arg t "$killed_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" update
clause "the killed fold was prepared once, never sent again" prepared_once "$killed_fold"
clause "the fold started from the root before the kill" is_equal "$(root_before_of "$killed_fold")" "$(cat "$snaps/s2.root")"
clause "state.json now commits to the fold's root after: one edge" is_equal "$(root_now)" "$(root_after_of "$killed_fold")"
run inspect-d registry inspect --key 6b0d "${common[@]}" "${node[@]}"
clause "inspect reads the killed insert's key active" is_equal "$(field inspect-d '.outcome + "/" + .leaf')" success/active
clause "the journal was only appended to and no body changed" appended_only s2

# ------------------------------------------------------------------
# killed after the mirror
# ------------------------------------------------------------------
control="killed after the mirror"
snap s3
reached=0
held terminate-a SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED registry terminate --key 6b0a \
  "${common[@]}" "${node[@]}" "${alice[@]}" || reached=1
clause "the terminate was killed after its mirror was saved, before its observation" is_equal "$reached" 0
saved_fold="$(fold_since s3)"
clause "the fold's last journalled phase is confirmed" is_equal "$(last_event "$saved_fold")" confirmed
clause "the mirror was saved" bash -c "[ '$(mirror_now)' != '$(cat "$snaps/s3.mirror")' ]"
clause "state.json was not yet written" state_kept s3
snap s3-killed
insert_of 6b0e
run insert-e "${args[@]}"
clause "the next write reconciles and succeeds" outcome_is insert-e success
clause "it applied nothing to the mirror: the edge was already applied" is_equal "$(field insert-e -c .reconciled.applied)" "[]"
clause "the killed fold is observed exactly once, by the insert" \
  is_equal "$(since s3-killed | jq -r --arg t "$saved_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
clause "the killed fold was prepared once, never sent again" prepared_once "$saved_fold"
clause "the fold started from the root before the kill" is_equal "$(root_before_of "$saved_fold")" "$(cat "$snaps/s3.root")"
clause "the next fold started from the killed fold's root after: one edge between" \
  is_equal "$(root_before_of "$(submission_tx insert-e fold)")" "$(root_after_of "$saved_fold")"
run inspect-t registry inspect --key 6b0a "${common[@]}" "${node[@]}"
clause "inspect reads the terminated key terminal" is_equal "$(field inspect-t '.outcome + "/" + .leaf')" success/terminal
clause "the journal was only appended to and no body changed" appended_only s3

# ------------------------------------------------------------------
# never sent
# ------------------------------------------------------------------
control="never sent"
snap s4
export SINGULAR_HARNESS_DROP_SEND=fold
insert_of 6b0f
run insert-f "${args[@]}"
unset SINGULAR_HARNESS_DROP_SEND
unsent="$(submission_tx insert-f fold)"
clause "the insert stops partial naming its fold unknown" is_equal "$(field insert-f .outcome)/$(submission_case insert-f fold)" partial/unknown
clause "the unsent fold names a transaction" is_txid "$unsent"
sleep 10
snap s4-refused
run update-d registry update --key 6b0d --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"
clause "the next write stops partial (exit 15)" exit_is update-d 15
clause "it names the unsent fold" is_equal "$(field update-d .unresolved.tx)" "$unsent"
clause "it names the case unknown" is_equal "$(field update-d .unresolved.case)" unknown
clause "its reason names the transaction" bash -c "jq -e --arg t '$unsent' '.reason | contains(\$t)' '$receipts/update-d.json'"
clause "it appended nothing to the journal" journal_same s4-refused
clause "it committed nothing locally" bash -c "[ '$(root_now)' = '$(cat "$snaps/s4-refused.root")' ] && [ '$(mirror_now)' = '$(cat "$snaps/s4-refused.mirror")' ]"
clause "the unsent fold was prepared once and never acknowledged" \
  is_equal "$(events_of "$unsent")" '["prepared","submit-unknown"]'

# ------------------------------------------------------------------
# the whole journal
# ------------------------------------------------------------------
control="every control"
clause "every journalled transaction has exactly one prepared line" \
  jq -s -e '[group_by(.journalTxId)[] | [.[] | select(.journalEvent == "prepared")] | length] | all(. == 1)' "$journal"
clause "the journal was only appended to and no body changed since the registry was created" appended_only s0

jq -r '.journalEvent' "$journal" | sort | uniq -c
cat "$verdicts"
if [ "$failed" -ne 0 ]; then
  say "RECOVERY-CONTROLS-FAILED"
  exit 1
fi
say "RECOVERY-CONTROLS-OK"
