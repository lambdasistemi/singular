#!/usr/bin/env bash
# A mixed batch and its reachable duplicate-free control, sourced by the
# registration journey after its original lifecycle. The shared rig owns all
# wallets, processes and chain observations. No request reference is passed to
# either automatic fold; receipts are checked against the chain afterwards.
# shellcheck disable=SC2016,SC2034,SC2154

batch_as() {
  local actor="$1" name="$2" program="$3"
  shift 3
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' \
    "$program" "$@" "${node[@]}" --wallet-skey "$actor.skey" \
    >"$work/invocations/$name.json"
  as "$actor" "$name" "$program" "$@"
  jq -cn --arg name "$name" --argjson status "$(cat "$receipts/$name.status")" \
    '{command:$name,exit:$status}' >>"$work/batch-attempts.jsonl"
}

batch_fresh_folder() {
  local actor="$1"
  [ ! -e "$work/actors/$actor" ] || setup_fail "a batch folder directory was reused"
  mkdir -p "$work/actors/$actor/cwd" "$work/actors/$actor/home"
  cp "$work/actors/bob/cwd/bob.skey" "$work/actors/$actor/cwd/$actor.skey"
  cp "$work/release/plutus.json" "$work/actors/$actor/cwd/plutus.json"
  (cd "$work/actors/$actor" && find cwd home -mindepth 1 | LC_ALL=C sort) \
    >"$listings/$actor-before.txt"
}

batch_book() { # PREFIX LABEL TOKEN KEY TIP
  local prefix="$1" label="$2" registry_token="$3" key="$4" take="$5"
  batch_as alice "$prefix-book-$label" "$open_datum" insert --blueprint plutus.json \
    --state-token "$registry_token" --key "$key" --payload batch-payload.json \
    --deposit 3000000 --tip "$take"
  view_tx "$prefix-book-$label" "$(field "$prefix-book-$label" '.pending | split("#")[0]')"
}

batch_registry() { # NAME: print the identity minted on chain, not the receipt's claim
  local name="$1"
  batch_as carol "$name" "$open_datum" create --blueprint plutus.json \
    --process-time 900000 --reclaim-time 60000 --booking-width 60000
  view_tx "$name" "$(tx_of "$name" create)"
  jq -er --arg policy "$state_policy" \
    '.mint[] | select(.policy == $policy and .quantity == 1) | "\(.policy).\(.name)"' \
    "$chain_dir/$name.tx.json"
}

batch_scenario() { # PREFIX WITH-DUPLICATE
  local prefix="$1" duplicate="$2" batch_token foreign_token seed_pending seed_holding
  local first_actor="$prefix-first" rest_actor="$prefix-rest" foreign_actor="$prefix-foreign"
  local label take
  leg="a public mixed batch: $prefix"
  batch_token="$(batch_registry "$prefix-create")"
  foreign_token="$(batch_registry "$prefix-other-create")"

  # Reach the active key and its termination through accepted packaged writes.
  batch_book "$prefix" seed "$batch_token" batch-terminal 1000000
  seed_pending="$(jq -er --arg app "$application_hash" \
    '.outputs[] | select(.credential == {type:"script",hash:$app} and .datum.constructor == 1) | .ref' \
    "$chain_dir/$prefix-book-seed.tx.json")"
  batch_as bob "$prefix-seed-fold" "$open_datum" fold --blueprint plutus.json \
    --state-token "$batch_token" --pending "$seed_pending"
  view_tx "$prefix-seed-fold" "$(tx_of "$prefix-seed-fold" fold)"
  seed_holding="$(jq -er --arg app "$application_hash" \
    '.outputs[] | select(.credential == {type:"script",hash:$app} and .datum.constructor == 2) | .ref' \
    "$chain_dir/$prefix-seed-fold.tx.json")"
  batch_as alice "$prefix-terminate" "$open_datum" terminate --blueprint plutus.json \
    --state-token "$batch_token" --holding "$seed_holding"
  view_tx "$prefix-terminate" "$(tx_of "$prefix-terminate" terminate)"

  # Three valuable registrations precede the whole-value termination; the
  # zero-tip registration is left by a cap of four. All amounts are checked
  # from the observed inputs, rather than assumed by the verdicts.
  for label in alpha beta gamma left; do
    case "$label" in
      alpha) take=10000000 ;;
      beta) take=9000000 ;;
      gamma) take=8000000 ;;
      left) take=0 ;;
    esac
    batch_book "$prefix" "$label" "$batch_token" "batch-$label" "$take"
  done
  if [ "$duplicate" = yes ]; then
    batch_book "$prefix" duplicate "$batch_token" batch-alpha 1000000
  fi
  # It shares the application address and is more valuable than any target
  # registration, but belongs to another registry and must remain untouched.
  batch_book "$prefix" foreign "$foreign_token" batch-foreign 11000000

  view_unspent "$prefix-before"
  batch_fresh_folder "$first_actor"
  batch_as "$first_actor" "$prefix-first" "$open_datum" fold --blueprint plutus.json \
    --state-token "$batch_token" --limit 4
  view_tx "$prefix-first" "$(tx_of "$prefix-first" fold)"
  view_unspent "$prefix-after-first"

  batch_fresh_folder "$rest_actor"
  batch_as "$rest_actor" "$prefix-rest" "$open_datum" fold --blueprint plutus.json \
    --state-token "$batch_token"
  view_tx "$prefix-rest" "$(tx_of "$prefix-rest" fold)"
  view_unspent "$prefix-after-rest"

  batch_fresh_folder "$foreign_actor"
  batch_as "$foreign_actor" "$prefix-foreign" "$open_datum" fold --blueprint plutus.json \
    --state-token "$foreign_token"
  view_tx "$prefix-foreign" "$(tx_of "$prefix-foreign" fold)"
  view_unspent "$prefix-after-foreign"
}

mkdir -p "$work/invocations"
printf '%s\n' '{"name":"batch"}' >"$work/actors/alice/cwd/batch-payload.json"
batch_scenario batch-control no
batch_scenario batch-duplicate yes

observe_batches() {
  python3 -I "$(dirname "$chain_view")/no_pin_batch_observations.py" "$work" "$state_policy" "$application_hash" \
    >"$work/batch-journey.json" 2>"$work/batch-journey.err"
}
leg="mixed batches and their controls"
check "a fresh nonbooker discovers mixed batches, skips foreign and duplicate requests, takes four then the rest, and receives the chain-derived surplus; altered observations fail" \
  observe_batches
