#!/usr/bin/env bash
# The ordinary CLI's recovery controls (#325): what `singular registry`
# does after a lost acknowledgement or an interrupted local commit, on one
# generated development node, every command a separate process.
#
# usage: cli_recovery_controls.sh SINGULAR DEVNET BLUEPRINT WORKDIR REPO-ROOT
#
#   accepting      an insert ends with both submissions included and
#                  observed, and the local files at the ledger's root;
#   lost answer    the node accepts an insert's fold but its answer is
#                  lost: at the moment of the send the fold's prepared line
#                  and its saved body are already on disk; the command
#                  stops naming the case `unknown`, and the next ordinary
#                  write reconciles the fold — applied to the mirror once,
#                  observed once, never sent again — and proceeds;
#   killed before  an insert is killed once its fold is confirmed, before
#   the commit     the mirror is saved: the next write applies the edge
#                  once, brings state.json along and proceeds;
#   killed after   a terminate is killed once the mirror is saved, before
#   the mirror     state.json: the next write applies nothing, brings
#                  state.json to the mirror, observes the fold, proceeds;
#   killed before  an insert is killed once state.json is written, before
#   the            its fold is observed: the next write applies nothing,
#   observation    leaves state.json, observes the fold and proceeds;
#   never sent,    an insert's fold never reaches the node; once the tip
#   past its       has passed the fold's validity upper bound, the next
#   upper bound    write journals it excluded, with the chain point and
#                  the live inputs it read, and proceeds from the root
#                  before it;
#   never sent,    an insert's booking never reaches the node; a booking
#   without an     has no upper bound, so the next write stops before
#   upper bound    building anything, naming the case and the transaction,
#                  and the journal does not move;
#   rolled back    on a second registry, an insert observed and then
#                  undone by restarting the node on a copy of its database
#                  taken before it — a generated-DevNet mechanism, not a
#                  public-chain fork: the node's own reads show the blocks
#                  that carried it gone and its inputs unspent; the next
#                  command journals both transactions rolled back and
#                  returns the mirror and state.json to the fold's root
#                  before; nothing is sent again; the next write stops
#                  naming the case and the transaction.
#
# The harness points are SINGULAR_HARNESS_* variables, inert when unset.
# Every verdict is computed from the receipts the processes printed, the
# registry's journal, its saved bodies and its files; none is typed. The
# verdict table is WORKDIR/verdicts.md. A setup failure (no node, no
# socket, a create that does not complete) exits 3 and is never a
# verdict; any clause that does not hold exits 1.
# shellcheck disable=SC2016 # single-quoted jq programs name jq variables, never shell ones
set -euo pipefail

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
hexkey >"$work/bob.skey"

# ------------------------------------------------------------------
# One development node
# ------------------------------------------------------------------
export TMPDIR="$work"
"$devnet" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" --fund-outputs 10 --fund-lovelace 2000000000 \
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
# probe_ins TXIN...: the node's own answer — its tip and which of TXIN
# are unspent — read through `devnet probe`, never through the CLI.
probe_ins() {
  local a=() t
  for t in "$@"; do a+=(--tx-in "$t"); done
  "$devnet" probe --node-socket "$sock" --network-magic 42 "${a[@]}"
}
common=(--registry "$reg" --blueprint "$blueprint")
alice=(--wallet-skey "$work/alice.skey")
bob=(--wallet-skey "$work/bob.skey")

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
  say "$name: $(jq -r .outcome "$receipts/$name.json" 2>/dev/null || echo none) (exit $status)"
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

# The payload every insert here carries; the command builds the rest of the
# envelope from the registry, the key and the signing wallet.
insert_of() { args=(registry insert --fold --key-hex "$1" --payload "$work/insert-payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"); }

# ------------------------------------------------------------------
# The registry
# ------------------------------------------------------------------
run preview registry create --process-time 45000 --retract-time 15000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
outcome_is preview success || setup_fail "create --preview did not succeed"
run create registry create --process-time 45000 --retract-time 15000 --seed "$(field preview .seed)" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.processTime == 45000 and .retractTime == 15000' "$receipts/create.json" >/dev/null \
  || setup_fail "the recovery registry did not read back the short CI windows"
outcome_is create success || setup_fail "create did not succeed"
token="$(field create .token)"
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
run bob-preview registry create --process-time 45000 --retract-time 15000 --preview --registry "$work/bob-preview" --blueprint "$blueprint" \
  "${node[@]}" "${bob[@]}"
outcome_is bob-preview success || setup_fail "the folder wallet's preview did not succeed"
bobkey="$(field bob-preview .walletKeyHash)"

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
run inspect-a registry inspect --key-hex 6b0a "${common[@]}" "${node[@]}"
clause "inspect reads the key active at that root" \
  is_equal "$(field inspect-a '.outcome + "/" + .leaf + "/" + .root')" "success/active/$(root_after_of "$fold")"
clause "the journal was only appended to and no body changed" appended_only s0

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
boot_ids="$(jq -sc '[.[] | select(.journalStep == "boot") | .journalTxId] | unique' "$journal")"
jq -c --argjson ids "$boot_ids" 'select(.journalTxId as $id | $ids | index($id) | not)' \
  "$preview_copy/journal.jsonl" >"$work/preview-incomplete-journal"
mv "$work/preview-incomplete-journal" "$preview_copy/journal.jsonl"
preview_copy_before="$(find "$preview_copy" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
run preview-incomplete registry update --preview --key-hex 6b0a --payload "$work/payload.json" \
  --registry "$preview_copy" --blueprint "$blueprint" "${node[@]}" --wallet-address "$(field preview .wallet)"
clause "preview refuses missing create rather than trusting the matching root" exit_is preview-incomplete 14
clause "preview names HistoryIncomplete" is_equal \
  "$(field preview-incomplete '.outcome + "/" + .reason')" 'stale-state/TrieState HistoryIncomplete'
clause "preview leaves its incomplete copy unchanged" is_equal \
  "$(find "$preview_copy" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)" "$preview_copy_before"
clause "successful previews leave every original registry file unchanged" is_equal \
  "$(find "$reg" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)" "$preview_before"

# ------------------------------------------------------------------
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
clause "it applied the lost fold's edge to the mirror" is_equal "$(field insert-c ".reconciled.applied | tojson")" "[\"$lost\"]"
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
run update-a registry update --key-hex 6b0a --payload "$work/payload.json" "${common[@]}" "${node[@]}" "${alice[@]}"
clause "the next write, an update of another key, reconciles and succeeds" outcome_is update-a success
clause "it applied the killed fold's edge to the mirror once" is_equal "$(field update-a ".reconciled.applied | tojson")" "[\"$killed_fold\"]"
clause "it brought state.json along" is_equal "$(field update-a .reconciled.stateFollowed)" true
clause "the killed fold is observed exactly once, by the update" \
  is_equal "$(since s2-killed | jq -r --arg t "$killed_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" update
clause "the killed fold was prepared once, never sent again" prepared_once "$killed_fold"
clause "the fold started from the root before the kill" is_equal "$(root_before_of "$killed_fold")" "$(cat "$snaps/s2.root")"
clause "state.json now commits to the fold's root after: one edge" is_equal "$(root_now)" "$(root_after_of "$killed_fold")"
run inspect-d registry inspect --key-hex 6b0d "${common[@]}" "${node[@]}"
clause "inspect reads the killed insert's key active" is_equal "$(field inspect-d '.outcome + "/" + .leaf')" success/active
clause "the journal was only appended to and no body changed" appended_only s2

# ------------------------------------------------------------------
# killed after the mirror
# ------------------------------------------------------------------
control="killed after the mirror"
snap s3
reached=0
held terminate-a SINGULAR_HARNESS_HOLD_AFTER_MIRROR registry terminate --fold --key-hex 6b0a \
  "${common[@]}" "${node[@]}" "${alice[@]}" || reached=1
clause "the terminate was killed after its mirror was saved, before state.json" is_equal "$reached" 0
saved_fold="$(fold_since s3)"
clause "the fold's last journalled phase is confirmed" is_equal "$(last_event "$saved_fold")" confirmed
clause "the mirror was saved" bash -c "[ '$(mirror_now)' != '$(cat "$snaps/s3.mirror")' ]"
clause "state.json was not yet written" state_kept s3
snap s3-killed
insert_of 6b0e
run insert-e "${args[@]}"
clause "the next write reconciles and succeeds" outcome_is insert-e success
clause "it applied nothing to the mirror: the edge was already applied" is_equal "$(field insert-e ".reconciled.applied | tojson")" "[]"
clause "it brought state.json to the mirror's root" is_equal "$(field insert-e .reconciled.stateFollowed)" true
clause "the killed fold is observed exactly once, by the insert" \
  is_equal "$(since s3-killed | jq -r --arg t "$saved_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
clause "the killed fold was prepared once, never sent again" prepared_once "$saved_fold"
clause "the fold started from the root before the kill" is_equal "$(root_before_of "$saved_fold")" "$(cat "$snaps/s3.root")"
clause "the next fold started from the killed fold's root after: one edge between" \
  is_equal "$(root_before_of "$(submission_tx insert-e fold)")" "$(root_after_of "$saved_fold")"
run inspect-t registry inspect --key-hex 6b0a "${common[@]}" "${node[@]}"
clause "inspect reads the terminated key terminal" is_equal "$(field inspect-t '.outcome + "/" + .leaf')" success/terminal
clause "the journal was only appended to and no body changed" appended_only s3

# ------------------------------------------------------------------
# killed before the observation
# ------------------------------------------------------------------
control="killed before the observation"
snap s5
reached=0
insert_of 6b10
held insert-g SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED "${args[@]}" || reached=1
clause "the insert was killed after state.json, before its fold was observed" is_equal "$reached" 0
written_fold="$(fold_since s5)"
clause "the fold's last journalled phase is confirmed" is_equal "$(last_event "$written_fold")" confirmed
clause "state.json already commits to the fold's root after" is_equal "$(root_now)" "$(root_after_of "$written_fold")"
snap s5-killed
insert_of 6b11
run insert-h "${args[@]}"
clause "the next write reconciles and succeeds" outcome_is insert-h success
clause "it applied nothing to the mirror" is_equal "$(field insert-h ".reconciled.applied | tojson")" "[]"
clause "it left state.json as it was" is_equal "$(field insert-h .reconciled.stateFollowed)" false
clause "the killed fold is observed exactly once, by the insert" \
  is_equal "$(since s5-killed | jq -r --arg t "$written_fold" '[.[] | select(.journalTxId == $t and .journalEvent == "observed") | .journalCommand] | join(",")')" insert
clause "the killed fold was prepared once, never sent again" prepared_once "$written_fold"
clause "the next fold started from the killed fold's root after: one edge between" \
  is_equal "$(root_before_of "$(submission_tx insert-h fold)")" "$(root_after_of "$written_fold")"
run inspect-g registry inspect --key-hex 6b10 "${common[@]}" "${node[@]}"
clause "inspect reads the killed insert's key active" is_equal "$(field inspect-g '.outcome + "/" + .leaf')" success/active
clause "the journal was only appended to and no body changed" appended_only s5

# ------------------------------------------------------------------
# another wallet's fold at every hold supported by the fold path
# ------------------------------------------------------------------
# Discovery supplies executions, not a source-text verdict. Every discovered
# call is reached on the node and has receipt/journal predicates below.
fold_holds() {
  local source line
  for source in Session Fold; do
    while IFS= read -r line; do
      if [[ "$line" =~ harnessHoldAt[[:space:]]+\"(SINGULAR_HARNESS_HOLD_[A-Z_]+)\" ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
      fi
    done <"$root/offchain/cli/src/Singular/CLI/$source.hs"
  done | sort -u
}
mapfile -t fold_points < <(fold_holds)
[ "${#fold_points[@]}" -gt 0 ] || setup_fail "the fold path declares no hold points"
printf '%s\n' "${fold_points[@]}" >"$work/fold-holds.list"
cross_cases=("${fold_points[@]}")
for point in "${fold_points[@]}"; do
  if [ "$point" = SINGULAR_HARNESS_HOLD_AFTER_SEND ]; then cross_cases+=("$point:lost-answer"); fi
done
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
  done
  cross_check=$((cross_check + 1))
}
cross_index=0
for cross_case in "${cross_cases[@]}"; do
  point="${cross_case%%:*}"
  cross_index=$((cross_index + 1))
  cross="cross-$cross_index"
  control="another wallet's fold at $cross_case"
  printf -v key '6d%02x' "$cross_index"
  snap "$cross-before"
  run "$cross-book" registry insert --key-hex "$key" --payload "$work/insert-payload.json" \
    "${common[@]}" "${node[@]}" "${alice[@]}"
  snap "$cross-booked"
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
  cross_fold="$(fold_since "$cross-booked")"
  snap "$cross-held"
  refusals_clean=0
  for i in $(seq 1 40); do
    snap "$cross-try-$i"
    run "$cross-next" registry update --key-hex 6b0d --payload "$work/payload.json" \
      "${common[@]}" "${node[@]}" "${alice[@]}"
    outcome_is "$cross-next" partial || break
    if ! journal_same "$cross-try-$i" || ! state_kept "$cross-try-$i" || ! mirror_kept "$cross-try-$i" \
      || [ "$(field "$cross-next" .unresolved.tx)" != "$cross_fold" ]; then refusals_clean=1; fi
    # Retain every refusal; the next run otherwise reuses the receipt name.
    cp "$receipts/$cross-next.json" "$receipts/$cross-refused-$i.json"
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
    --arg beforeMirror "$(cat "$snaps/$cross-before.mirror")" --arg bookedMirror "$(cat "$snaps/$cross-booked.mirror")" \
    --arg heldMirror "$(cat "$snaps/$cross-held.mirror")" --arg afterMirror "$(mirror_now)" \
    '{fold:$fold,key:$key,point:$point,reached:$reached,folder:$folder,signers:$signers,clean:$clean,exit:$exit,loss:$loss,
      booking:$booking[0],next:$next[0],inspect:$inspect[0],booked:$booked,held:$held,after:$after,
      roots:{before:$beforeRoot,booked:$bookedRoot,held:$heldRoot,after:$afterRoot},
      mirrors:{before:$beforeMirror,booked:$bookedMirror,held:$heldMirror,after:$afterMirror}}' >"$cross_evidence"
  cross_check=1
  cross_clause "the requester booked only, leaving the root and mirror unchanged" \
    '. as $e | .booking.outcome == "success" and .booking.request == (.booking.booking + "#0")
      and ([.booked[] | select(.journalTxId == $e.booking.booking) | .journalEvent] == ["prepared","submitted","confirmed","observed"])
      and .roots.before == .roots.booked and .mirrors.before == .mirrors.booked' \
    '.roots.booked += "tampered"' '.mirrors.booked += "tampered"' '.booking.outcome = "partial"' \
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
  cross_clause "reconciliation applies the edge exactly when the killed command had not saved it" \
    '.next.reconciled.applied == (if .mirrors.held == .mirrors.booked then [.fold] else [] end)
      and .next.reconciled.stateFollowed == (.roots.held == .roots.before)
      and (if .mirrors.held == .mirrors.booked then .mirrors.after != .mirrors.held else .mirrors.after == .mirrors.held end)' \
    '.next.reconciled.applied += [.fold]' '.next.reconciled.stateFollowed |= not' \
    '.mirrors.after = (if .mirrors.held == .mirrors.booked then .mirrors.held else "tampered" end)'
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
done
control="fold hold-point coverage"
jq -s --rawfile declared "$work/fold-holds.list" \
  '{declared:($declared | split("\n") | map(select(. != "")) | sort),
    executed:[.[] | select(.reached == 0) | .point] | unique | sort}' "$receipts"/cross-*-evidence.json >"$receipts/fold-hold-coverage.json"
cross=fold-holds cross_check=1 cross_evidence="$receipts/fold-hold-coverage.json"
cross_clause "every discovered fold hold point was reached" \
  '(.declared | length) > 0 and .declared == .executed' '.executed = .executed[1:]' '.declared = [] | .executed = []'

# ------------------------------------------------------------------
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
clause "the excluded line names the chain point it read" \
  bash -c "[[ '$(jq -r '.journalChainPoint // ""' <<<"$excluded_line")' =~ ^[0-9]+\.[0-9a-f]{64}$ ]]"
clause "the excluded line names inputs the node reports unspent" \
  jq -n -e --argjson l "${excluded_line:-null}" --argjson p "$unsent_live" '($l.journalInputs | length) > 0 and ($l.journalInputs - $p.live == [])'
clause "its receipt names the fold excluded" is_equal "$(field update-d ".reconciled.excluded | tojson")" "[\"$unsent\"]"
clause "the write then succeeds" outcome_is update-d success
clause "state.json still commits to the unsent fold's root before: the excluded edge was never applied" \
  is_equal "$(root_now)" "$(root_before_of "$unsent")"
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
clause "it committed nothing locally" bash -c "[ '$(root_now)' = '$(cat "$snaps/s6-refused.root")' ] && [ '$(mirror_now)' = '$(cat "$snaps/s6-refused.mirror")' ]"
clause "the unsent booking was prepared once and never acknowledged" \
  is_equal "$(events_of "$unbooked")" '["prepared","submit-unknown"]'

# ------------------------------------------------------------------
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
forged_adopted_after() {
  local forged adopted
  forged="$(tail -n +"$(($1 + 1))" "$nlog" | grep -c 'Forged block in slot' || true)"
  adopted="$(tail -n +"$(($1 + 1))" "$nlog" | grep -cF '"ns":"Forge.Loop.AdoptedBlock"' || true)"
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
journal="$reg/journal.jsonl"
common=(--registry "$reg" --blueprint "$blueprint")
run preview-rb registry create --process-time 45000 --retract-time 15000 --preview "${common[@]}" "${node[@]}" "${alice[@]}"
outcome_is preview-rb success || setup_fail "the second create --preview did not succeed"
run create-rb registry create --process-time 45000 --retract-time 15000 --seed "$(field preview-rb .seed)" "${common[@]}" "${node[@]}" "${alice[@]}"
jq -e '.processTime == 45000 and .retractTime == 15000' "$receipts/create-rb.json" >/dev/null \
  || setup_fail "the rollback registry did not read back the short CI windows"
outcome_is create-rb success || setup_fail "the second create did not succeed"
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
cp "$reg/registry.mirror.json" "$snaps/rb1.mirror.json"

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

# Killed after the rollback is journalled, before the mirror is rebuilt:
# the files still hold the rolled-back fold's root after.
reached=0
held inspect-rb-k1 SINGULAR_HARNESS_HOLD_BEFORE_REWIND registry inspect --key-hex 6c01 "${common[@]}" "${node[@]}" || reached=1
clause "an inspect is killed after journalling the rollback, before rebuilding the mirror" is_equal "$reached" 0
clause "at that moment both transactions are journalled rolled back" \
  is_equal "$(event_count "$rb_book" rolled-back)/$(event_count "$rb_fold" rolled-back)" 1/1
clause "at that moment the mirror and state.json are as the insert left them" \
  bash -c "[ '$(mirror_now)' = '$(cat "$snaps/rb1.mirror")' ] && [ '$(root_now)' = '$(cat "$snaps/rb1.root")' ]"
# Killed after the mirror is rebuilt, before state.json follows it.
reached=0
held inspect-rb-k2 SINGULAR_HARNESS_HOLD_BEFORE_REWIND_STATE registry inspect --key-hex 6c01 "${common[@]}" "${node[@]}" || reached=1
clause "a second inspect is killed after rebuilding the mirror, before state.json" is_equal "$reached" 0
clause "at that moment the mirror holds its bytes from before the insert and state.json the insert's root" \
  bash -c "[ '$(mirror_now)' = '$(cat "$snaps/rb0.mirror")' ] && [ '$(root_now)' = '$(cat "$snaps/rb1.root")' ]"
run inspect-rb registry inspect --key-hex 6c01 "${common[@]}" "${node[@]}"
clause "the next inspect journals no second rollback and rebuilds nothing more" \
  jq -e 'has("mirrorRewound") and .mirrorRewound == null and .rolledBack == []' "$receipts/inspect-rb.json"
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
  clause "the rolled-back line of $t names a chain point on the restored chain" \
    on_restored_chain "$(rolled_line "$t" | jq -r '.journalChainPoint // "" | split(".") | last')"
  clause "the rolled-back line of $t names spent inputs the node reports unspent" \
    jq -n -e --argjson l "$(rolled_line "$t")" --argjson p "$post" '($l.journalInputs | length) > 0 and ($l.journalInputs - $p.live == [])'
done
clause "the fold's rolled-back line names the root the mirror returned to: the fold's root before" \
  is_equal "$(rolled_line "$rb_fold" | jq -r .journalRootBefore)" "$(root_before_of "$rb_fold")"
clause "inspect stops partial naming the booking's case rolled-back" \
  is_equal "$(field inspect-rb '.outcome + "/" + .unresolved.case + "/" + .unresolved.tx')" "partial/rolled-back/$rb_book"
clause "inspect reads the ledger's root at the fold's root before" is_equal "$(field inspect-rb .root)" "$(root_before_of "$rb_fold")"
clause "state.json returned to the fold's root before" is_equal "$(root_now)" "$(root_before_of "$rb_fold")"
clause "the mirror returned to the bytes it had before the rolled-back insert" \
  is_equal "$(mirror_now)" "$(cat "$snaps/rb0.mirror")"
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
clause "it committed nothing locally" bash -c "[ '$(root_now)' = '$(cat "$snaps/rb2.root")' ] && [ '$(mirror_now)' = '$(cat "$snaps/rb2.mirror")' ]"
clause "the node's blocks since the restore still carry neither transaction" \
  is_equal "$(carried_since "$mark" "$rb_book")$(carried_since "$mark" "$rb_fold")" 00
clause "at the end too, the adoption record covers every block the node forged" \
  forged_pair "$(forged_adopted_after "$snap_mark")"
say "$control: $(chained_after "$mark" | wc -l) block(s) chained by the restored node"
jq -r '.journalEvent' "$journal" | sort | uniq -c

control="trie capability"
clause "completed real recovery commands have nonempty trie evidence bound to their key, leaf and root" trie_extent

cat "$verdicts"
if [ "$failed" -ne 0 ]; then
  say "RECOVERY-CONTROLS-FAILED"
  exit 1
fi
say "RECOVERY-CONTROLS-OK"
