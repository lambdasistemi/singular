#!/usr/bin/env bash
# Four termination refusals, each submitted to the node beside an accepted
# control. The packaged commands reach every holding and termination request;
# only the deliberately malformed transactions use the test-only harness.
# The node's script failure and the independent chain record decide verdicts.
# shellcheck disable=SC2016
set -euo pipefail
[ "$#" -eq 6 ] || {
  echo "usage: $0 OPEN_DATUM DEVNET BLUEPRINT CHAIN_VIEW HARNESS WORKDIR" >&2
  exit 2
}
open_datum="$1" devnet="$2" blueprint_source="$3" chain_view="$4" harness="$5" work="$6"
rig_name=termination-refusals
# shellcheck source=tools/no_pin_rig.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/no_pin_rig.sh"

refused_by_script() {
  jq -e --arg hash "$2" '
    .outcome == "refused"
    and (.answer | test("PlutusFailure"))
    and (.answer | test("terminated because of an error"))
    and ((.answer | test("overspending the budget")) | not)
    and (.answer | capture("The script hash is:ScriptHash [\\\\\"]+(?<hash>[0-9a-f]{56})").hash == $hash)' "$1"
}
chain_holds_tx() { chain tx "$1" >/dev/null 2>&1; }
chain_lacks_tx() { [[ "$1" =~ ^[0-9a-f]{64}$ ]] && ! chain_holds_tx "$1"; }
tx_id_of() { field "$1" .transaction; }

leg=creation
as carol create "$open_datum" state create --blueprint plutus.json \
  --process-time 900000 --reclaim-time 60000 --booking-width 60000
token="$(field create .stateToken)"
[[ "$token" =~ ^[0-9a-f]{56}\.[0-9a-f]{64}$ ]] || setup_fail "the creation printed no state token"
state_policy="${token%%.*}"
printf '%s\n' '{"name":"alice"}' >"$work/actors/alice/cwd/payload.json"

# Each case starts from its own reachable registration and booking. A second
# active key makes a different-key change a real alternative, not an unknown key.
register() {
  local name="$1" key="$2"
  as alice "book-$name" "$open_datum" registration book --blueprint plutus.json \
    --state-token "$token" --key "$key" --payload payload.json --deposit 3000000 --tip 1000000
  as bob "register-$name" "$open_datum" state fold --blueprint plutus.json \
    --state-token "$token" --pending "$(field "book-$name" .pending)"
  view_tx "register-$name" "$(tx_of "register-$name" fold)"
  jq -er --arg sp "$state_policy" --arg sn "${token##*.}" \
    '.outputs[] | select(any(.assets[]; .policy == $sp and .name != $sn)) | .ref' \
    "$chain_dir/register-$name.tx.json"
}
leg="other active key"
register other other-active-key >"$work/other-holding.txt"

for case in burn-without-fold other-key no-approval spend-without-burn; do
  leg="$case"
  holding="$(register "$case" "termination-$case")"
  as alice "terminate-$case" "$open_datum" holding terminate --blueprint plutus.json \
    --state-token "$token" --holding "$holding"
  pending="$(field "terminate-$case" .pending)"
  refuser="$state_policy"
  [ "$case" != spend-without-burn ] || refuser="$application_hash"
  run_as bob "attempt-$case" "$harness" terminate --case "$case" \
    --pending "$pending" --key "termination-$case" --other-key other-active-key \
    --blueprint plutus.json --state-token "$token"
  if ! jq -e '.outcome == "accepted" or .outcome == "refused"' "$receipts/attempt-$case.json" >/dev/null 2>&1; then
    record "$leg" "the node judges the malformed termination" "COULD-NOT-EVALUATE"
    say "$case: COULD-NOT-EVALUATE: $(tail -1 "$receipts/attempt-$case.err")"
    failed=1
  fi
  settle
  check "$case: the node refuses by the intended validator's explicit script failure" \
    refused_by_script "$receipts/attempt-$case.json" "$refuser"
  check "$case: the refused transaction is absent from the chain" chain_lacks_tx "$(tx_id_of "attempt-$case")"
  # The control restores the omitted fact and uses the same request. The
  # packaged builder supplies the accepted transaction, with no test hook.
  as bob "control-$case" "$open_datum" state fold --blueprint plutus.json --state-token "$token" --pending "$pending"
  control_tx="$(tx_of "control-$case" fold)"
  view_tx "control-$case" "$control_tx"
  check "$case: the passing control is included" chain_holds_tx "$control_tx"
  control "$case: an included transaction is not absent" chain_lacks_tx "$control_tx"
  control "$case: a missing identity is not ledger absence" chain_lacks_tx ""
  control "$case: another script's failure is not this refusal" \
    refused_by_script "$receipts/attempt-$case.json" "00000000000000000000000000000000000000000000000000000000"
done

# The last control made this key terminal through its genuine burn. The
# packaged fold declines its new registration; here the node also judges
# a registration that carries the current state's own presence proof.
leg="registration after termination"
as alice book-terminal "$open_datum" registration book --blueprint plutus.json \
  --state-token "$token" --key termination-spend-without-burn --payload payload.json --deposit 3000000 --tip 1000000
run_as bob attempt-terminal "$harness" fold --case second-registration \
  --pending "$(field book-terminal .pending)" --blueprint plutus.json --state-token "$token"
settle
check "a new registration of the terminated key is refused by the state validator" \
  refused_by_script "$receipts/attempt-terminal.json" "$state_policy"
check "the refused registration is absent from the chain" chain_lacks_tx "$(tx_id_of attempt-terminal)"
register terminal-control fresh-key-after-termination >"$work/terminal-control-holding.txt"
check "a fresh key still registers beside the refused terminal key" chain_holds_tx "$(tx_of register-terminal-control fold)"
control "a fresh registration is not the refused terminal registration" \
  chain_lacks_tx "$(tx_of register-terminal-control fold)"

{
  printf '# Termination refusals on a development network\n\n'
  printf 'Release: `%s`\nRegistry: `%s`\n\n' "$release_hash" "$token"
  printf '| attempt | node outcome | intended refusing script | passing control |\n|---|---|---|---|\n'
  for case in burn-without-fold other-key no-approval spend-without-burn; do
    refuser="$state_policy"
    [ "$case" != spend-without-burn ] || refuser="$application_hash"
    printf '| %s | %s | `%s` | `%s` |\n' "$case" \
      "$(field "attempt-$case" '.outcome // "COULD-NOT-EVALUATE"')" "$refuser" "$(tx_of "control-$case" fold)"
  done
  printf '\n## Verdicts\n\n'
  cat "$verdicts"
} >"$work/receipt.md"
[ "$failed" -eq 0 ] || exit 1
say "NO-PIN-TERMINATION-REFUSALS-OK"
