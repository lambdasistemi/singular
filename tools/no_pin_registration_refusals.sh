#!/usr/bin/env bash
# The refusals of the proved design on a development network (#742): a fold
# made wrong in exactly one way is submitted to the node, and the node refuses it
# by the failure of a validator's own script, not by a builder's decline and not
# by a rule of the ledger the scripts do not see. Each refusal has a control: the
# same fold with the one fact restored, which the node accepts.
#
# usage: no_pin_registration_refusals.sh OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW HARNESS WORKDIR
#
# The arguments are those of the registration journey without singular, which no
# refusal needs, and HARNESS is the test program no-pin-refusals, which builds the
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
#
# A refusal is judged from the node's answer: a failure of the code of a script
# of the application (Singular's state script, open datum's request validator),
# an explicit failure and not an overspent budget, and the transaction is not on
# the chain, read from the chain's own record. A control is accepted by the node
# and is on the chain. Each assertion is also run on altered input and must fail.
# The verdict table is WORKDIR/verdicts.md and the cases in words WORKDIR/receipt.md.
# shellcheck disable=SC2016 # single-quoted jq programs name jq variables, never shell ones
set -euo pipefail

[ "$#" -eq 6 ] || {
  echo "usage: $0 OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW HARNESS WORKDIR" >&2
  exit 2
}
open_datum="$1"
devnet="$2"
blueprint_source="$3"
chain_view="$4"
harness="$5"
work="$6"
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
second="$(book second-registration first-key)"
fresh="$(book second-registration-control another-key)"
refusers=("$state_policy")
attempt_and_control second-registration second-registration "$second" "$fresh"

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
