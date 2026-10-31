#!/usr/bin/env bash
# The refusals of the proved design on a development network (#742): a fold
# made wrong in exactly one way is submitted to the node, and the node refuses it
# by the failure of a validator's own script, not by a builder's decline and not
# by a rule of the ledger the scripts do not see. Each refusal has a control: the
# same fold with the one fact restored, which the node accepts.
#
# usage: no_pin_registration_refusals.sh OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW HARNESS TABLE WORKDIR
#
# The arguments are those of the registration journey without singular, which no
# refusal needs, TABLE is the packaged table of releases the installed commands
# were built with, and HARNESS is the test program no-pin-refusals, which builds the
# fold of a pending registration the way the library's builder does, with one fact
# made wrong, and submits it: the packaged commands decline such a fold before
# they send it. Registries and
# bookings are made by the packaged commands. Every command is a separate
# process of a wallet in a directory and a home of its own.
#
#   no approval          the pending registration carries no approval
#   other address        the key's token is delivered to another address
#   less than deposit    the holding keeps less than the committed deposit
#   second registration  the key is already in the registry, shown by the
#                        proof the registry itself gives for it
#   extra token          the continuing state output holds a token besides its
#                        state token
#   parked state         a token parked at the state address is spent as a state
#   old registries       a write given a registry of an earlier release, or of a
#                        contract no release carries, is declined with the answer
#                        the reader gives for it; the chain as its own record holds
#                        it before and after is the same, beside a write that the
#                        installed release accepts and the chain records
#
# A refusal is judged from the node's answer: a failure of the code of a script
# of the application (Singular's state script, open datum's request validator),
# an explicit failure and not an overspent budget, and the transaction is not on
# the chain, read from the chain's own record. A control is accepted by the node
# and is on the chain. Each assertion is also run on altered input and must fail.
# The verdict table is WORKDIR/verdicts.md and the cases in words WORKDIR/receipt.md.
# shellcheck disable=SC2016 # single-quoted jq programs name jq variables, never shell ones
set -euo pipefail

[ "$#" -eq 7 ] || {
  echo "usage: $0 OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW HARNESS TABLE WORKDIR" >&2
  exit 2
}
open_datum="$1"
devnet="$2"
blueprint_source="$3"
chain_view="$4"
harness="$5"
release_table="$6"
work="$7"
rig_name=refusals
# shellcheck source=tools/no_pin_rig.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/no_pin_rig.sh"

# ------------------------------------------------------------------
# The assertions, as functions of files so that a control can hand each one
# altered input
# ------------------------------------------------------------------
# The node refused the transaction, by the failure of the code of one of these
# scripts: a named script, an explicit failure and not an overspent budget.
refused_by_script() { # RECEIPT SCRIPT-HASH...
  local receipt="$1"
  shift
  jq -e --argjson allowed "$(printf '%s\n' "$@" | jq -R . | jq -sc .)" '
    .outcome == "refused"
    and (.answer | test("PlutusFailure"))
    and (.answer | test("terminated because of an error"))
    and ((.answer | test("overspending the budget")) | not)
    and ((.answer | capture("The script hash is:ScriptHash [\\\\\"]+(?<hash>[0-9a-f]{56})").hash) as $hash
         | $allowed | index($hash) != null)' "$receipt"
}
accepted() { jq -e '.outcome == "accepted"' "$1"; }
chain_holds_tx() { chain tx "$1" >/dev/null 2>&1; }
# A transaction identifier is 64 hex digits; anything else is a missing receipt, and a
# missing receipt proves nothing about the chain.
chain_lacks_tx() { [[ "$1" =~ ^[0-9a-f]{64}$ ]] && ! chain_holds_tx "$1"; }
# The script of the application that the node blamed, by name.
blamed() { # RECEIPT
  jq -r --arg state "$state_policy" --arg request "$application_hash" '
    (.answer | capture("The script hash is:ScriptHash [\\\\\"]+(?<hash>[0-9a-f]{56})").hash) as $hash
    | if $hash == $state then "Singular state validator"
      elif $hash == $request then "open-datum request validator"
      else $hash end' "$1"
}
tx_id_of() { jq -r .transaction "$receipts/$1.json"; }

# ------------------------------------------------------------------
# The registry, the bookings and the spares
# ------------------------------------------------------------------
leg="creation"
# A processing window long enough to run every case inside, a reclaim window
# that is never used.
as carol create "$open_datum" create --blueprint plutus.json \
  --process-time 900000 --reclaim-time 60000 --booking-width 60000
token="$(field create .stateToken)"
[[ "$token" =~ ^[0-9a-f]{56}\.[0-9a-f]{64}$ ]] || setup_fail "the creation printed no state token"
state_policy="${token%%.*}"
say "registry $token created"
printf '%s\n' '{"name":"alice"}' >"$work/actors/alice/cwd/payload.json"

# Restore exactly the changed input beside each refusal. The control reads an
# unused key through the same packaged application command and live provider.
registry="$(field create .registry)"
read_command read-wrong-network-control "$open_datum" inspect --registry "$registry" --key reader-unused --koios-url "$provider_url"
read_command read-wrong-network "$open_datum" inspect --state-token "$token" --network-magic 1 --key reader-unused --koios-url "$provider_url"
read_command read-unknown-policy-control "$open_datum" inspect --registry "$registry" --key reader-unused --koios-url "$provider_url"
read_command read-unknown-policy "$open_datum" inspect --state-token "$(printf '%056d' 0).${token##*.}" --network-magic "$network_magic" --key reader-unused --koios-url "$provider_url"
read_command read-provider-failure-control "$open_datum" inspect --registry "$registry" --key reader-unused --koios-url "$provider_url"
# The live facade answers this nonexistent route with a transport error. No
# fault hook or fake provider enters the packaged command.
read_command read-provider-failure "$open_datum" inspect --registry "$registry" --key reader-unused --koios-url "$provider_url/reader-unavailable"

# book NAME KEY [DEPOSIT]: Alice books a key; the pending registration is printed.
book() {
  as alice "book-$1" "$open_datum" insert --blueprint plutus.json \
    --state-token "$token" --key "$2" --payload payload.json --deposit "${3:-3000000}" --tip 1000000
  field "book-$1" .pending
}
# fold NAME CASE PENDING FLAG...: Bob submits the fold of the case; the node's
# answer is the receipt, and no verdict is given here.
fold() {
  local name="$1" case="$2" pending="$3"
  shift 3
  run_as bob "$name" "$harness" fold --case "$case" --pending "$pending" \
    --blueprint plutus.json --state-token "$token" "$@"
  say "$name: $(jq -r '.outcome // "no outcome"' "$receipts/$name.json" 2>/dev/null || echo "no receipt")"
}
# case LEG NAME CASE PENDING CONTROL-PENDING FLAGS...: the attempt, the
# control, and their verdicts. The refusing scripts are those the caller names
# in refusers.
attempt_and_control() { # NAME CASE PENDING CONTROL-PENDING FLAG... (refusers set by the caller)
  local name="$1" case="$2" pending="$3" control_pending="$4"
  shift 4
  fold "attempt-$name" "$case" "$pending" "$@"
  settle
  check "$name: the node refuses the fold by the failure of the code of a script of the application" \
    refused_by_script "$receipts/attempt-$name.json" "${refusers[@]}"
  check "$name: the refused transaction is not on the chain" chain_lacks_tx "$(tx_id_of "attempt-$name")"
  fold "control-$name" honest "$control_pending"
  check "$name: the same fold with the one fact restored is accepted by the node" accepted "$receipts/control-$name.json"
  check "$name: the accepted transaction is on the chain" chain_holds_tx "$(tx_id_of "control-$name")"
  control "$name: an accepted fold is not a refusal" refused_by_script "$receipts/control-$name.json" "${refusers[@]}"
  control "$name: a refused fold is not accepted" accepted "$receipts/attempt-$name.json"
  control "$name: a transaction that is on the chain is not one the chain lacks" chain_lacks_tx "$(tx_id_of "control-$name")"
  control "$name: a missing receipt is not a transaction the chain lacks" chain_lacks_tx ""
  control "$name: a refusal by another script is not this one" refused_by_script "$receipts/attempt-$name.json" "0000000000000000000000000000000000000000000000000000000000000000"
}

leg="spares"
run_as bob spares "$harness" spares --blueprint plutus.json --state-token "$token"
parked="$(field spares .parked)"
spare="$(field spares .spare)"
[[ "$parked" =~ ^[0-9a-f]{64}#[0-9]+$ && "$spare" =~ ^[0-9a-f]{64}#[0-9]+$ ]] || {
  tail -5 "$receipts/spares.err" >&2 || true
  setup_fail "the spares were not made"
}

# ------------------------------------------------------------------
# 1. A fold without the approval
# ------------------------------------------------------------------
leg="no approval"
approved="$(book no-approval first-key)"
# The second registration of the same key is booked while the key is still unknown:
# once the key is registered, booking it is refused before anything is signed.
# The fold is what must refuse this request, so it is booked now and folded in
# leg 2.
second="$(book second-registration first-key)"
run_as bob plain-copy "$harness" plain-copy --pending "$approved" --blueprint plutus.json --state-token "$token"
copy="$(field plain-copy .output)"
[[ "$copy" =~ ^[0-9a-f]{64}#[0-9]+$ ]] || {
  tail -5 "$receipts/plain-copy.err" >&2 || true
  setup_fail "the registration without an approval was not made"
}
refusers=("$state_policy" "$application_hash")
attempt_and_control no-approval no-approval "$copy" "$approved"

# ------------------------------------------------------------------
# 2. A second registration of the active key
# ------------------------------------------------------------------
leg="second registration"
fresh="$(book second-registration-control another-key)"
refusers=("$state_policy")
attempt_and_control second-registration second-registration "$second" "$fresh"
# The key is active now: booking it again is refused before anything is signed.
run_as alice book-active-again "$open_datum" insert --blueprint plutus.json \
  --state-token "$token" --key first-key --payload payload.json --deposit 3000000 --tip 1000000
check "second registration: booking the active key is refused before anything is signed" \
  jq -e '.outcome == "client-refusal" and (.reason | contains("the key first-key is already registered")) and (.submissions | length) == 0' "$receipts/book-active-again.json"
check "second registration: the refused booking exits with the client refusal status" \
  test "$(cat "$receipts/book-active-again.status")" = 10
control "second registration: a successful booking is not the refusal of an active key" \
  jq -e '.outcome == "client-refusal" and (.reason | contains("is already registered"))' "$receipts/book-second-registration-control.json"

# ------------------------------------------------------------------
# 3. A token delivered to another address
# ------------------------------------------------------------------
leg="other address"
delivered="$(book other-address key-for-another-address)"
refusers=("$state_policy" "$application_hash")
attempt_and_control other-address other-address "$delivered" "$delivered"

# ------------------------------------------------------------------
# 4. A token delivered with less than the deposit
# ------------------------------------------------------------------
leg="less than the deposit"
short="$(book less-than-deposit key-for-a-short-holding 3000000)"
refusers=("$state_policy" "$application_hash")
attempt_and_control less-than-deposit less-than-deposit "$short" "$short"

# ------------------------------------------------------------------
# 5. An extra token in the continuing state output
# ------------------------------------------------------------------
leg="extra token"
extra="$(book extra-token key-for-an-extra-token)"
refusers=("$state_policy")
attempt_and_control extra-token extra-token "$extra" "$extra" --spare "$spare"

# ------------------------------------------------------------------
# 6. A parked token presented as a registry state
# ------------------------------------------------------------------
leg="parked state"
presented="$(book parked-state key-for-a-parked-state)"
refusers=("$state_policy")
attempt_and_control parked-state parked-state "$presented" "$presented" --parked "$parked"

# The malformed-batch refusal needs a genuine multi-request accepted control.
# Execute the current harness with both inputs and judge what the node actually
# included, rather than treating a repeated flag or a receipt as a batch.
leg="an accepted batch control"
batch_first="$(book batch-first batch-first-key)"
batch_second="$(book batch-second batch-second-key)"
fold batch-control honest "$batch_first" --pending "$batch_second"
view_tx batch-control "$(tx_id_of batch-control)"
batch_spends() { # CHAIN-TX FIRST SECOND
  jq -e --arg first "$2" --arg second "$3" '
    [.inputs[].ref] as $inputs
    | ($inputs | index($first)) != null and ($inputs | index($second)) != null' "$1"
}
check "the batch control is accepted by the node and included" chain_holds_tx "$(tx_id_of batch-control)"
check "the included batch control consumes both named requests" \
  batch_spends "$chain_dir/batch-control.tx.json" "$batch_first" "$batch_second"
control "an altered request reference is refused by the chain-input check" \
  batch_spends "$chain_dir/batch-control.tx.json" "$batch_first" "$(printf '%064d' 0)#0"

# ------------------------------------------------------------------
# The receipt
# ------------------------------------------------------------------
# shellcheck source=tools/no_pin_batch_refusals.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/no_pin_batch_refusals.sh"
leg="reading refusals"
check "wrong network, unknown state policy and failed provider reads are named beside passing controls; altered answers fail" \
  reading_evidence refusals

# ------------------------------------------------------------------
# 7. Registries the installed release does not serve
# ------------------------------------------------------------------
# A development network cannot hold a registry of an earlier release: the
# installed commands create only registries of their own release. The state
# tokens named here are therefore those of the contracts the packaged table
# lists for earlier releases, and of a contract no release carries; the write
# commands decline them before they open the provider, so the registry of the
# installed release made above is the one whose chain record could be changed,
# and it is the one read before and after. The observation is the chain's own
# record: every unspent output and every included transaction.
leg="old registries"
# Whatever the answer, the lines the reader prints for a state token are the
# lines every write command prints for the same one.
declined_with_guidance() { # WRITE-RECEIPT READ-RECEIPT
  jq -e --slurpfile read "$2" '
    .outcome == "client-refusal"
    and (.reason | startswith("state-token-foreign-release"))
    and ($read[0].guidance | length) > 0
    and ([$read[0].guidance[] as $line | .reason | contains($line)] | all)' "$1"
}
names_release() { # READ-RECEIPT RELEASE
  jq -e --arg release "$2" '[.guidance[] | contains($release)] | any' "$1"
}
names_no_release() { # READ-RECEIPT
  jq -e '(.guidance | length) > 0 and ([.guidance[] | contains("releases/tag")] | any | not)' "$1"
}
exited_nonzero() { [ "$(cat "$receipts/$1.status")" -ne 0 ]; }
chain_transactions() { chain transactions | jq '.transactions | length'; }
same_file() { cmp -s "$1" "$2"; }
same_count() { [ -n "$1" ] && [ "$1" = "$2" ]; }
# The two earlier rows that name the most releases, from the table the installed
# commands carry: policy, and the newest release of the row.
mapfile -t earlier_rows < <(jq -r '
  [.rows[] | select(.releases | length > 0)]
  | sort_by(.releases | length) | reverse | .[0:2][]
  | "\(."state-contract") \(.releases[-1])"' "$release_table")
[ "${#earlier_rows[@]}" -eq 2 ] || setup_fail "the table lists fewer than two earlier contracts"
unknown_policy="$(printf '%056d' 0)"
refused_writes=(insert fold update terminate reclaim cleanup)
write_arguments() { # VERB TOKEN
  case "$1" in
    insert) printf '%s\n' insert --blueprint plutus.json --state-token "$2" --key old-key --payload payload.json --deposit 3000000 --tip 1000000 ;;
    fold) printf '%s\n' fold --blueprint plutus.json --state-token "$2" ;;
    update) printf '%s\n' update --blueprint plutus.json --state-token "$2" --holding "$(printf '%064d' 7)#0" --payload payload.json ;;
    terminate) printf '%s\n' terminate --blueprint plutus.json --state-token "$2" --holding "$(printf '%064d' 7)#0" ;;
    reclaim | cleanup) printf '%s\n' "$1" --blueprint plutus.json --state-token "$2" --pending "$(printf '%064d' 7)#0" ;;
  esac
}
old_case=0
for row in "${earlier_rows[@]}" "$unknown_policy"; do
  old_case=$((old_case + 1))
  policy="${row%% *}"
  newest="${row#* }"
  old_token="$policy.${token##*.}"
  read_command "read-old-$old_case" "$open_datum" inspect --state-token "$old_token" --network-magic "$network_magic" --key reader-unused --koios-url "$provider_url"
  if [ "$policy" = "$unknown_policy" ]; then
    check "old case $old_case: the reader names no release for contracts no release carries" names_no_release "$receipts/read-old-$old_case.json"
  else
    check "old case $old_case: the reader names the newest release of the earlier contract, $newest" names_release "$receipts/read-old-$old_case.json" "$newest"
  fi
  view_unspent "old-$old_case-before"
  count_before="$(chain_transactions)"
  for verb in "${refused_writes[@]}"; do
    mapfile -t arguments < <(write_arguments "$verb" "$old_token")
    run_as alice "old-$old_case-$verb" "$open_datum" "${arguments[@]}"
    check "old case $old_case: $verb exits with a refusal" exited_nonzero "old-$old_case-$verb"
    check "old case $old_case: $verb declines with the lines the reader prints for the same registry" \
      declined_with_guidance "$receipts/old-$old_case-$verb.json" "$receipts/read-old-$old_case.json"
  done
  view_unspent "old-$old_case-after"
  check "old case $old_case: the chain holds the same unspent outputs before and after the refused writes" \
    same_file "$chain_dir/old-$old_case-before.unspent.json" "$chain_dir/old-$old_case-after.unspent.json"
  check "old case $old_case: the chain holds the same number of transactions before and after" \
    same_count "$count_before" "$(chain_transactions)"
done
# The control: a write the installed release accepts moves the chain, so the
# equality above is not one that nothing could break.
view_unspent "old-control-before"
control_count="$(chain_transactions)"
control_pending="$(book old-registries-control old-registries-control-key)"
settle
view_unspent "old-control-after"
check "the write the installed release accepts is recorded by the chain" chain_holds_tx "$(tx_of book-old-registries-control book)"
control "an accepted write leaves the unspent outputs unchanged" \
  same_file "$chain_dir/old-control-before.unspent.json" "$chain_dir/old-control-after.unspent.json"
control "an accepted write leaves the number of transactions unchanged" \
  same_count "$control_count" "$(chain_transactions)"
check "the accepted write names a pending registration" test -n "$control_pending"

{
  printf '# Refusals on a development network: receipt\n\n'
  printf 'Release (sha256 of the validators every wallet ran against): `%s`\n' "$release_hash"
  printf 'Registry: `%s`\n\n' "$token"
  printf 'Each refusal is the fold the library builds for a pending registration with one fact made wrong, submitted to the node; the control is the same fold with that fact restored.\n\n'
  printf '| refusal | the one fact made wrong | refused by | control |\n|---|---|---|---|\n'
  for name in no-approval second-registration other-address less-than-deposit extra-token parked-state; do
    printf '| %s | %s | %s | accepted, `%s` |\n' "$name" \
      "$(jq -r .alteredFact "$receipts/attempt-$name.json")" "$(blamed "$receipts/attempt-$name.json")" \
      "$(tx_id_of "control-$name")"
  done
  printf '\n## Reading refusals and their controls\n\n```json\n'
  cat "$work/reading-refusals.json"
  printf '\n```\n\n'
  cat "$work/batch-refusals.md"
  printf '\n## Verdicts\n\n'
  cat "$verdicts"
} >"$work/receipt.md"

# ------------------------------------------------------------------
# The verdict
# ------------------------------------------------------------------
leg="refusals"
[ "$(grep -c ' holds |' "$verdicts")" -gt 0 ] || {
  say "no clause was judged"
  failed=1
}
say "release $release_hash; $(grep -c ' holds |' "$verdicts") clauses hold, $(grep -c 'fails on altered input' "$verdicts") controls fail as they must"
if [ "$failed" -ne 0 ]; then
  say "NO-PIN-REFUSALS-FAILED"
  exit 1
fi
say "NO-PIN-REFUSALS-OK"
