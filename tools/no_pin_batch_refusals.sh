#!/usr/bin/env bash
# Batch refusals beside included controls, sourced by registration refusals.
# The rig owns the running node, wallets, chain reader and durable artifacts.
# Client messages are checked against unchanged chain records; malformed
# transactions require the intended node script failure and an included control.
# SC2016: single-quoted jq programs use jq variables. SC2034/SC2154: the
# sourcing refusal script and rig supply and consume the shared variables.
# shellcheck disable=SC2016,SC2034,SC2154

refusal_book() { # NAME REGISTRY KEY DEPOSIT PAYLOAD
  local name="$1" registry_token="$2" key="$3" deposit="$4" payload="$5"
  as alice "book-$name" "$open_datum" insert --blueprint plutus.json \
    --state-token "$registry_token" --key "$key" --payload "$payload" --deposit "$deposit" --tip 1000000
  local pending
  pending="$(field "book-$name" .pending)"
  view_tx "book-$name" "${pending%#*}"
  printf '%s\n' "$pending"
}

refusal_message() { # RECEIPT EXPECTED-SUBSTRING (or capacity)
  if [ "$2" = capacity ]; then
    jq -e '.outcome == "client-refusal" and (.submissions | length) == 0
      and (.reason | capture("^the (?<metric>transaction size|execution memory|execution steps) (?<used>[0-9]+)( bytes)? exceeds the limit (?<limit>[0-9]+)( bytes)?$")
        | (.used | tonumber) > (.limit | tonumber))' "$1"
  else
    jq -e --arg reason "$2" '.outcome == "client-refusal" and (.submissions | length) == 0 and (.reason | contains($reason))' "$1"
  fi
}

refusal_same_chain() { # BEFORE AFTER
  jq -e -s '.[0].transactions == .[1].transactions' "$1" "$2"
}

refusal_nonzero_status() {
  local status
  status="$(cat "$1")"
  [[ "$status" =~ ^[0-9]+$ ]] && [ "$status" -ne 0 ]
}

refusal_attempt() { # NAME EXPECTED REGISTRY [FLAGS...]
  local name="$1" expected="$2" registry_token="$3"
  shift 3
  leg="$name"
  chain transactions >"$chain_dir/$name.before.json"
  run_as bob "$name" "$open_datum" fold --blueprint plutus.json --state-token "$registry_token" "$@"
  settle
  chain transactions >"$chain_dir/$name.after.json"
  check "the packaged command refuses with the named cause and no submission" \
    refusal_message "$receipts/$name.json" "$expected"
  check "the refused command exits unsuccessfully" \
    refusal_nonzero_status "$receipts/$name.status"
  check "no transaction reached the chain during the refused command" \
    refusal_same_chain "$chain_dir/$name.before.json" "$chain_dir/$name.after.json"
  control "a different refusal is not this cause" \
    refusal_message "$receipts/$name.json" "a cause that this command did not report"
}

refusal_control() { # NAME REGISTRY [FLAGS...]
  local name="$1" registry_token="$2"
  shift 2
  as bob "$name" "$open_datum" fold --blueprint plutus.json --state-token "$registry_token" "$@"
  view_tx "$name" "$(tx_of "$name" fold)"
  check "the passing control is independently included" chain_holds_tx "$(tx_of "$name" fold)"
  control "the included control is not a client refusal" \
    refusal_message "$receipts/$name.json" "there is nothing to fold"
  control "the included control did not exit as a failed command" \
    refusal_nonzero_status "$receipts/$name.status"
}

refusal_record() { # LABEL ATTEMPT CONTROL
  printf '| %s | %s | `%s` |\n' "$1" "$(field "$2" .reason)" "$(tx_of "$3" fold)" >>"$work/batch-refusals.md"
}

printf '## Batch refusals and their included controls\n\n| requirement | observed refusal | included control |\n|---|---|---|\n' >"$work/batch-refusals.md"

# A node-judged batch that mints and moves an additional state-role token.
# The mutation's mint quantity is read from the built body, not its case label.
leg="state policy movement"
policy_first="$(refusal_book policy-first "$token" policy-first-key 3000000 payload.json)"
policy_second="$(refusal_book policy-second "$token" policy-second-key 3000000 payload.json)"
fold attempt-state-policy state-policy-movement "$policy_first" --pending "$policy_second"
settle
check "the built malformed body actually mints an additional registry token" \
  jq -e '.mintedRegistryToken == 1' "$receipts/attempt-state-policy.json"
check "the node rejects the batch by the state validator's explicit failure" \
  refused_by_script "$receipts/attempt-state-policy.json" "$state_policy"
check "the malformed batch is absent from the chain" chain_lacks_tx "$(tx_id_of attempt-state-policy)"
fold control-state-policy honest "$policy_first" --pending "$policy_second"
check "the same batch without the extra movement is accepted by the node" \
  accepted "$receipts/control-state-policy.json"
if accepted "$receipts/control-state-policy.json" >/dev/null; then
  view_tx control-state-policy "$(tx_id_of control-state-policy)"
  check "the included control consumes both original requests" \
    batch_spends "$chain_dir/control-state-policy.tx.json" "$policy_first" "$policy_second"
else
  record "$leg" "the included batch control is available" "COULD-NOT-EVALUATE"
  failed=1
fi
check "the honest control has zero mint of the registry token" \
  jq -e '.mintedRegistryToken == 0' "$receipts/control-state-policy.json"
control "an accepted control is not a state-script refusal" \
  refused_by_script "$receipts/control-state-policy.json" "$state_policy"
control "an honest body is not an extra state-token mint" \
  jq -e '.mintedRegistryToken == 1' "$receipts/control-state-policy.json"
control "another script's refusal does not establish this state-policy boundary" \
  refused_by_script "$receipts/attempt-state-policy.json" "00000000000000000000000000000000000000000000000000000000"
control "an included control is not an absent transaction" chain_lacks_tx "$(tx_id_of control-state-policy)"
printf '| state policy movement | %s | `%s` |\n' "$(blamed "$receipts/attempt-state-policy.json")" "$(tx_id_of control-state-policy)" >>"$work/batch-refusals.md"

# A named foreign request must refuse the whole batch, before any submission.
as carol batch-other-create "$open_datum" create --blueprint plutus.json \
  --process-time 900000 --reclaim-time 60000 --booking-width 60000
view_tx batch-other-create "$(tx_of batch-other-create create)"
other_token="$(jq -er --arg policy "$state_policy" '.mint[] | select(.policy == $policy and .quantity == 1) | "\(.policy).\(.name)"' "$chain_dir/batch-other-create.tx.json")"
own_first="$(refusal_book named-own-first "$token" named-own-first-key 3000000 payload.json)"
own_second="$(refusal_book named-own-second "$token" named-own-second-key 3000000 payload.json)"
other_pending="$(refusal_book named-other "$other_token" named-other-key 3000000 payload.json)"
refusal_attempt named-other "$other_pending belongs to another registry" "$token" --pending "$own_first" --pending "$other_pending"
refusal_control control-named-other "$token" --pending "$own_first" --pending "$own_second"
check "the named passing batch consumes both of this registry's requests" \
  batch_spends "$chain_dir/control-named-other.tx.json" "$own_first" "$own_second"
chain transactions >"$chain_dir/named-other.control.json"
control "a chain containing the accepted control is not the pre-refusal chain" \
  refusal_same_chain "$chain_dir/named-other.before.json" "$chain_dir/named-other.control.json"
view_unspent named-other-still-pending
check "the foreign request was not trimmed into the passing control" \
  jq -e --arg ref "$other_pending" 'any(.outputs[]; .ref == $ref)' "$chain_dir/named-other-still-pending.unspent.json"
control "an altered foreign reference is not the preserved pending request" \
  jq -e --arg ref "$(printf '%064d' 0)#0" 'any(.outputs[]; .ref == $ref)' "$chain_dir/named-other-still-pending.unspent.json"
refusal_record "named request of another registry" named-other control-named-other
refusal_control control-other-registry "$other_token" --pending "$other_pending"

# Restore the duplicate-key fact by pairing one request with a distinct key.
duplicate_first="$(refusal_book named-duplicate-first "$token" named-duplicate-key 3000000 payload.json)"
duplicate_second="$(refusal_book named-duplicate-second "$token" named-duplicate-key 3000000 payload.json)"
distinct="$(refusal_book named-distinct "$token" named-distinct-key 3000000 payload.json)"
duplicate_key="$(printf '%s' named-duplicate-key | od -An -tx1 | tr -d ' \n')"
refusal_attempt named-duplicate "two pending registrations name the key $duplicate_key" "$token" --pending "$duplicate_first" --pending "$duplicate_second"
refusal_control control-named-duplicate "$token" --pending "$duplicate_first" --pending "$distinct"
check "the distinct-key control consumes both named requests" \
  batch_spends "$chain_dir/control-named-duplicate.tx.json" "$duplicate_first" "$distinct"
refusal_record "named duplicate key" named-duplicate control-named-duplicate

# Each large holding is individually accepted. The named combined batch must
# refuse for an observed byte or execution limit, never shrink or reach the node.
python3 -c 'import json,sys; json.dump({"data":"x"*8000},open(sys.argv[1],"w"))' "$work/actors/alice/cwd/large-payload.json"
large_first="$(refusal_book large-first "$token" large-first-key 50000000 large-payload.json)"
large_second="$(refusal_book large-second "$token" large-second-key 50000000 large-payload.json)"
refusal_attempt named-oversize capacity "$token" --pending "$large_first" --pending "$large_second"
refusal_control control-large-first "$token" --pending "$large_first"
refusal_control control-large-second "$token" --pending "$large_second"
control "an individually accepted holding is not a capacity refusal" \
  refusal_message "$receipts/control-large-first.json" capacity
jq '.reason = "the transaction size 1 bytes exceeds the limit 2 bytes"' "$receipts/named-oversize.json" >"$scratch/false-capacity-bound.json"
control "a reversed capacity inequality cannot establish an oversized batch" \
  refusal_message "$scratch/false-capacity-bound.json" capacity
check "each large request is included whole in its passing control" \
  batch_spends "$chain_dir/control-large-first.tx.json" "$large_first" "$large_first"
check "the second large request is included whole in its passing control" \
  batch_spends "$chain_dir/control-large-second.tx.json" "$large_second" "$large_second"
refusal_record "named batch above a network limit" named-oversize control-large-first

# First all discovered target registrations are already registered. Compute
# that premise from included folds and the current policy-holder census.
view_unspent all-unfoldable
chain transactions >"$chain_dir/all-unfoldable.transactions.json"
all_unfoldable_accounting() { # RECEIPT UNSPENT INCLUDED-TRANSACTIONS
  jq -e -n --arg app "$application_hash" --arg sp "$state_policy" --arg sn "${token##*.}" \
    --slurpfile receipt "$1" --slurpfile view "$2" --slurpfile included "$3" '
    [$view[0].outputs[] | select(any(.assets[]; .policy == $app))
     | select(((.datum | type) == "object" and .datum.constructor == 0) | not)] as $holders
    | [$holders[] | select(.datum.constructor == 1
       and .datum.fields[0].fields[0].fields == [{bytes:$sp},{bytes:$sn}])] as $own
    | [$included[0].transactions[]
       | select(any(.inputs[].assets[]; .policy == $sp and .name == $sn))
       | .inputs[] | select(.datum.constructor == 1)
       | .datum.fields[0].fields[1].bytes] as $registered
    | ($own | length) > 0
      and all($own[]; .datum.fields[0].fields[1].bytes as $key | $registered | index($key) != null)
      and $receipt[0].folded == [] and $receipt[0].left == 0
      and ([$receipt[0].skipped[].reference] | sort) == ([$holders[].ref] | sort)'
}
refusal_attempt nothing-foldable "there is nothing to fold" "$token"
check "all own pending keys are registered and every holder that is not configuration remains in failure accounting" \
  all_unfoldable_accounting "$receipts/nothing-foldable.json" "$chain_dir/all-unfoldable.unspent.json" "$chain_dir/all-unfoldable.transactions.json"
jq '.skipped |= .[1:]' "$receipts/nothing-foldable.json" >"$scratch/missing-failure-skip.json"
control "an omitted failure skip is detected by the independent census" \
  all_unfoldable_accounting "$scratch/missing-failure-skip.json" "$chain_dir/all-unfoldable.unspent.json" "$chain_dir/all-unfoldable.transactions.json"
configuration_holder="$(jq -er --arg app "$application_hash" '
  [.outputs[] | select(any(.assets[]; .policy == $app)
     and (.datum | type) == "object" and .datum.constructor == 0)]
  | if length > 0 then .[0].ref else error("no configuration holder") end' "$chain_dir/all-unfoldable.unspent.json")"
jq --arg ref "$configuration_holder" \
  '.skipped += [{reference: $ref, reason: "not accepted by the application'"'"'s decode"}]' \
  "$receipts/nothing-foldable.json" >"$scratch/configuration-skip.json"
control "a configuration holder named as skipped is detected by the independent census" \
  all_unfoldable_accounting "$scratch/configuration-skip.json" "$chain_dir/all-unfoldable.unspent.json" "$chain_dir/all-unfoldable.transactions.json"
fresh="$(refusal_book foldable-beside-unfoldable "$token" fresh-beside-unfoldable 3000000 payload.json)"
refusal_control control-nothing-foldable "$token"
check "the automatic passing control consumes the new foldable request" \
  batch_spends "$chain_dir/control-nothing-foldable.tx.json" "$fresh" "$fresh"
refusal_record "nothing foldable, with complete skips" nothing-foldable control-nothing-foldable

# A separately reached empty registry distinguishes no pending requests from
# an observed set of individually unfoldable requests.
as carol empty-create "$open_datum" create --blueprint plutus.json \
  --process-time 900000 --reclaim-time 60000 --booking-width 60000
view_tx empty-create "$(tx_of empty-create create)"
empty_token="$(jq -er --arg policy "$state_policy" '.mint[] | select(.policy == $policy and .quantity == 1) | "\(.policy).\(.name)"' "$chain_dir/empty-create.tx.json")"
refusal_attempt nothing-pending "there is nothing to fold" "$empty_token"
empty_control="$(refusal_book empty-control "$empty_token" empty-control-key 3000000 payload.json)"
refusal_control control-nothing-pending "$empty_token"
check "the same automatic command folds after a request is booked" \
  batch_spends "$chain_dir/control-nothing-pending.tx.json" "$empty_control" "$empty_control"
refusal_record "nothing pending" nothing-pending control-nothing-pending
