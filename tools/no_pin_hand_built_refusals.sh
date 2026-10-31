#!/usr/bin/env bash
# Three hand-built transactions, each submitted to the node beside the same
# transaction with its one wrong fact restored (#764).
#
# What the job shows. The packaged commands decline most wrong requests before
# they send anything, so on their own they never show what the chain itself
# refuses. Here the registry, the keys and their holdings are made by the
# packaged commands, and each wrong transaction and its control are built by the
# test-only harness with the repository's transaction builders, signed and
# submitted to a development node that runs the validators as built from main:
#
#   taken key                  a registration of a key the registry already
#                              holds, carrying the answer the registry gives for
#                              that key, is refused by the state validator; the
#                              control registers a key that is not registered
#   update without controller  an update of a holding signed by a wallet that is
#                              not its controller is refused by the open-datum
#                              request validator; the control is the same update
#                              signed by the controller
#   token leaving holding      a spend of a holding that does not return the
#                              key's token to it is refused by the request
#                              validator; the control is the same spend with the
#                              token kept in the holding
#
# A refusal counts only when the node's answer names the validator by its hash
# and shows an explicit failure of its code, not an exhausted budget, and the
# chain's own record does not hold the transaction. A control counts only when
# the node accepts it and the chain's own record holds it. That record is the
# development network's independent one, not the harness's. Each judging
# assertion is also handed the other role's receipt and must fail there.
# WORKDIR/receipt.md is the verdict table of six rows, WORKDIR/verdicts.md the
# clauses behind it and WORKDIR/receipts the node's answers.
#
# What it does not show. Each case is evidence over the one input it runs: three
# transactions on one development network. It does not show that every wrong
# transaction is refused, that the validators agree with the model on any other
# input, or anything about a public network. What the packaged commands build is
# not judged here.
#
# usage: no_pin_hand_built_refusals.sh OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW HARNESS WORKDIR
# shellcheck disable=SC2016 # single-quoted jq programs name jq variables, never shell ones
set -euo pipefail
[ "$#" -eq 6 ] || {
  echo "usage: $0 OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW HARNESS WORKDIR" >&2
  exit 2
}
open_datum="$1" devnet="$2" blueprint_source="$3" chain_view="$4" harness="$5" work="$6"
rig_name=hand-built-refusals
# shellcheck source=tools/no_pin_rig.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/no_pin_rig.sh"

# ------------------------------------------------------------------
# The assertions, as functions of files so that a control can hand each one
# altered input
# ------------------------------------------------------------------
# The node refused the transaction by an explicit failure of the code of one
# named script, and not by an exhausted budget.
refused_by_script() { # RECEIPT SCRIPT-HASH
  jq -e --arg hash "$2" '
    .outcome == "refused"
    and (.answer | test("PlutusFailure"))
    and (.answer | test("terminated because of an error"))
    and ((.answer | test("overspending the budget")) | not)
    and (.answer | capture("The script hash is:ScriptHash [\\\\\"]+(?<hash>[0-9a-f]{56})").hash == $hash)' "$1"
}
accepted() { jq -e '.outcome == "accepted"' "$1"; }
chain_holds_tx() { chain tx "$1" >/dev/null 2>&1; }
# A transaction identifier is 64 hex digits; anything else is a missing receipt,
# and a missing receipt proves nothing about the chain.
chain_lacks_tx() { [[ "$1" =~ ^[0-9a-f]{64}$ ]] && ! chain_holds_tx "$1"; }
tx_id_of() { jq -r '.transaction // ""' "$receipts/$1.json" 2>/dev/null || true; }
fact_of() { jq -r '.alteredFact // ""' "$receipts/$1.json" 2>/dev/null || true; }
outcome_of() { jq -r '.outcome // ""' "$receipts/$1.json" 2>/dev/null || true; }
# The node answered with a verdict on the transaction; anything else is a
# receipt the harness could not produce.
judged() { jq -e '.outcome == "accepted" or .outcome == "refused"' "$receipts/$1.json" >/dev/null 2>&1; }
# The script of the application that the node blamed, by name.
blamed() { # NAME
  local who
  who="$(jq -r --arg state "$state_policy" --arg request "$application_hash" '
    (.answer | capture("The script hash is:ScriptHash [\\\\\"]+(?<hash>[0-9a-f]{56})").hash) as $hash
    | if $hash == $state then "Singular state validator"
      elif $hash == $request then "open-datum request validator"
      else $hash end' "$receipts/$1.json" 2>/dev/null)" || who=""
  echo "${who:-none named}"
}
# A refusal names the one fact it makes wrong; its control names none.
names_fact() { # NAME ROLE
  local fact
  fact="$(fact_of "$1")"
  if [ "$2" = refusal ]; then
    [ -n "$fact" ] && [[ "$fact" != none* ]]
  else
    [[ "$fact" == none* ]]
  fi
}
# A refusal row passes when the named script refused, the chain lacks the
# transaction and the receipt names the altered fact; a control row passes when
# the node accepted, the chain holds the transaction and the receipt names none.
refusal_passes() { # NAME SCRIPT-HASH
  refused_by_script "$receipts/$1.json" "$2" >/dev/null 2>&1 \
    && chain_lacks_tx "$(tx_id_of "$1")" && names_fact "$1" refusal
}
control_passes() { # NAME
  accepted "$receipts/$1.json" >/dev/null 2>&1 \
    && chain_holds_tx "$(tx_id_of "$1")" && names_fact "$1" control
}
# Wait until the chain's record holds a transaction the node accepted. No
# verdict is given here.
await_on_chain() { # NAME
  accepted "$receipts/$1.json" >/dev/null 2>&1 || return 0
  for _ in $(seq 1 240); do
    chain_holds_tx "$(tx_id_of "$1")" && return 0
    sleep 0.5
  done
}

# ------------------------------------------------------------------
# The six rows
# ------------------------------------------------------------------
cases=(taken-key update-without-controller token-leaving-holding)
rows="$work/rows.md"
# Exactly one refusal row and one control row for each case, and nothing else.
six_rows() { # TABLE
  local case role
  [ "$(grep -c '^| ' "$1")" -eq 7 ] || return 1
  for case in "${cases[@]}"; do
    for role in refusal control; do
      [ "$(grep -c "^| $case | $role |" "$1")" -eq 1 ] || return 1
    done
  done
}
every_row_passes() { # TABLE
  [ "$(grep -c ' | pass |$' "$1")" -eq 6 ]
}
# row CASE ROLE NAME SCRIPT-HASH: one line of the table, computed from the
# receipt and the chain's record; a receipt that is missing or unreadable gives
# a row that fails.
row() {
  local case="$1" role="$2" name="$3" refuser="$4"
  local outcome fact blamed_by on_chain verdict
  outcome="$(outcome_of "$name")"
  [ -n "$outcome" ] || outcome="COULD-NOT-EVALUATE"
  fact="$(fact_of "$name")"
  case "$fact" in
    none*) fact=none ;;
    "") fact="COULD-NOT-EVALUATE" ;;
  esac
  blamed_by="none"
  verdict=fail
  if [ "$role" = refusal ]; then
    blamed_by="$(blamed "$name")"
    ! refusal_passes "$name" "$refuser" || verdict=pass
  else
    ! control_passes "$name" || verdict=pass
  fi
  on_chain=no
  ! chain_holds_tx "$(tx_id_of "$name")" || on_chain=yes
  printf '| %s | %s | %s | `%s` | %s | %s | %s | %s |\n' \
    "$case" "$role" "$fact" "$(tx_id_of "$name")" "$outcome" "$blamed_by" "$on_chain" "$verdict" >>"$rows"
}

# ------------------------------------------------------------------
# The registry and its keys
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
# The payload an update writes, in the directory of each wallet that submits one.
for actor in alice bob; do
  printf '%s\n' '{"name":"alice","note":"updated"}' >"$work/actors/$actor/cwd/updated.json"
done

# book NAME KEY: Alice books the key; the pending registration is printed.
book() {
  as alice "book-$1" "$open_datum" insert --blueprint plutus.json \
    --state-token "$token" --key "$2" --payload payload.json --deposit 3000000 --tip 1000000
  field "book-$1" .pending
}
# register_key NAME KEY: Alice books the key, Bob folds it with the packaged
# command, and the reference of the holding the fold created is printed.
register_key() {
  local name="$1" key="$2"
  as alice "book-$name" "$open_datum" insert --blueprint plutus.json \
    --state-token "$token" --key "$key" --payload payload.json --deposit 3000000 --tip 1000000
  as bob "register-$name" "$open_datum" fold --blueprint plutus.json \
    --state-token "$token" --pending "$(field "book-$name" .pending)"
  view_tx "register-$name" "$(tx_of "register-$name" fold)"
  jq -er --arg sp "$state_policy" --arg sn "${token##*.}" \
    '.outputs[] | select(any(.assets[]; .policy == $sp and .name != $sn)) | .ref' \
    "$chain_dir/register-$name.tx.json"
}
# submit ACTOR NAME SUBCOMMAND ARGS...: the harness builds one transaction as
# the wallet, submits it, and prints the node's answer; no verdict is given here.
submit() {
  local actor="$1" name="$2"
  shift 2
  run_as "$actor" "$name" "$harness" "$@" --blueprint plutus.json --state-token "$token"
  say "$name: $(outcome_of "$name" || true)"
}
# pair CASE ATTEMPT CONTROL REFUSER: the verdicts of one case, once both its
# transactions have been submitted.
pair() {
  local case="$1" attempt="$2" control="$3" refuser="$4" name
  leg="$case"
  await_on_chain "$control"
  settle
  for name in "$attempt" "$control"; do
    if ! judged "$name"; then
      record "$leg" "the node judges $name" "COULD-NOT-EVALUATE"
      say "$name: COULD-NOT-EVALUATE: $(tail -1 "$receipts/$name.err" 2>/dev/null || echo "no output")"
      failed=1
    fi
  done
  check "$case: the node refuses the attempt by the explicit failure of the validator's own code" \
    refused_by_script "$receipts/$attempt.json" "$refuser"
  check "$case: the refused transaction is absent from the chain" chain_lacks_tx "$(tx_id_of "$attempt")"
  check "$case: the node accepts the control" accepted "$receipts/$control.json"
  check "$case: the accepted control is on the chain" chain_holds_tx "$(tx_id_of "$control")"
  check "$case: the attempt names the one fact it makes wrong" names_fact "$attempt" refusal
  check "$case: the control names none" names_fact "$control" control
  # Each judging assertion is handed the other role's receipt and must fail. When
  # a receipt is missing the assertion would fail for that reason alone, which
  # shows nothing, so these run only on receipts the node answered.
  if judged "$attempt" && judged "$control"; then
    control "$case: a control does not name a wrong fact" names_fact "$control" refusal
    control "$case: an attempt does not name none" names_fact "$attempt" control
    control "$case: an accepted control is not a refusal" refused_by_script "$receipts/$control.json" "$refuser"
    control "$case: a refused attempt is not accepted" accepted "$receipts/$attempt.json"
    control "$case: an included control is not absent from the chain" chain_lacks_tx "$(tx_id_of "$control")"
    control "$case: another script's failure is not this refusal" \
      refused_by_script "$receipts/$attempt.json" "00000000000000000000000000000000000000000000000000000000"
  fi
  control "$case: a missing identifier is not absence from the chain" chain_lacks_tx ""
}

# ------------------------------------------------------------------
# 1. Registering a key that is already registered
# ------------------------------------------------------------------
# A second booking of the key is made while the key is still unknown, because
# booking a registered key is refused before anything is signed. The key is then
# registered by the packaged commands, and the harness folds the second booking
# with the answer the registry gives for that key; the control folds a booking
# of a key that is not registered.
leg="taken key"
taken="$(book taken-key-again taken-key)"
register_key taken-key taken-key >/dev/null
fresh="$(book fresh-key fresh-key)"
submit bob attempt-taken-key fold --case second-registration --pending "$taken"
submit bob control-taken-key fold --case honest --pending "$fresh"
pair taken-key attempt-taken-key control-taken-key "$state_policy"

# ------------------------------------------------------------------
# 2. Updating a holding without its controller's signature
# ------------------------------------------------------------------
# Alice controls the holding. Bob builds the update and signs it; the control
# is the same update built and signed by Alice.
leg="update without controller"
updatable="$(register_key update-key update-key)"
submit bob attempt-update update --case no-controller-signature --holding "$updatable" --payload updated.json
submit alice control-update update --case honest --holding "$updatable" --payload updated.json
pair update-without-controller attempt-update control-update "$application_hash"

# ------------------------------------------------------------------
# 3. Moving a key's token out of its holding
# ------------------------------------------------------------------
# Alice signs both transactions; the attempt spends the holding and does not
# return the key's token to it, and the control returns it.
leg="token leaving holding"
leaving="$(register_key leave-key leave-key)"
submit alice attempt-leave leave --case token-out --holding "$leaving"
submit alice control-leave leave --case honest --holding "$leaving"
pair token-leaving-holding attempt-leave control-leave "$application_hash"

# ------------------------------------------------------------------
# The verdict table
# ------------------------------------------------------------------
leg="verdict table"
printf '| case | role | altered fact | transaction | node outcome | blamed script | on the chain | verdict |\n|---|---|---|---|---|---|---|---|\n' >"$rows"
row taken-key refusal attempt-taken-key "$state_policy"
row taken-key control control-taken-key ""
row update-without-controller refusal attempt-update "$application_hash"
row update-without-controller control control-update ""
row token-leaving-holding refusal attempt-leave "$application_hash"
row token-leaving-holding control control-leave ""
check "the table has one refusal row and one control row for each case" six_rows "$rows"
check "every row of the table passes" every_row_passes "$rows"
# The two table assertions are handed altered tables and must fail.
grep -v '^| taken-key | control |' "$rows" >"$work/rows-missing.md" || true
control "a table without one row" six_rows "$work/rows-missing.md"
{
  cat "$rows"
  grep '^| taken-key | refusal |' "$rows" || true
} >"$work/rows-doubled.md"
control "a table with a row twice" six_rows "$work/rows-doubled.md"
sed 's/ | pass |$/ | fail |/' "$rows" >"$work/rows-failing.md"
control "a table whose rows fail" every_row_passes "$work/rows-failing.md"

{
  printf '# Hand-built transactions on a development network\n\n'
  printf 'Release (sha256 of the validators every wallet ran against): `%s`\nRegistry: `%s`\n\n' "$release_hash" "$token"
  cat "$rows"
  printf '\n## Verdicts\n\n'
  cat "$verdicts"
} >"$work/receipt.md"

[ "$failed" -eq 0 ] || {
  say "NO-PIN-HAND-BUILT-REFUSALS-FAILED"
  exit 1
}
say "NO-PIN-HAND-BUILT-REFUSALS-OK"
