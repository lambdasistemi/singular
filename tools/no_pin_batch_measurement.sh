#!/usr/bin/env bash
# Recorded-parameter evaluation owns the claim; a private node corroborates.
# shellcheck disable=SC2034 # the sourced rig consumes these arguments
# shellcheck disable=SC2016 # jq variables in single-quoted programs
set -euo pipefail
open_datum="$1"
devnet="$2"
blueprint_source="$3"
chain_view="$4"
harness="$5"
parameter_source="$6"
recorded_parameters="$7"
committed="$8"
node_program="$9"
work="${10}"
results="$work"
work="$results/fresh"
mode="${11:---check}"
measurement="$(dirname "$chain_view")/no_pin_batch_measurement.py"
if [ "$mode" = --help ]; then
  printf '%s\n' 'Re-evaluate kept batches and corroborate their count boundaries with a fresh development node:' \
    '  nix run .#no-pin-batch-measurement' \
    'Explicitly capture and refresh the committed measurement:' \
    '  nix run .#no-pin-batch-measurement -- --refresh test/fixtures/batch-measurement'
  exit 0
fi
if [ "$mode" = --check ]; then
  python3 -I "$measurement" revalidate "$harness" "$recorded_parameters" \
    "$parameter_source" "$blueprint_source" "$committed" "$results/kept"
elif [ "$mode" = --refresh ] && [ "$#" -eq 12 ]; then
  refresh_destination="$(realpath -m "${12}")"
else
  echo 'expected --check, --help or --refresh DESTINATION' >&2
  exit 2
fi
rig_name=batch-measurement
prepare_extra_funding() {
  python3 -I "$measurement" derive "$parameter_source" "$E2E_GENESIS_DIR" "$work/genesis"
  export E2E_GENESIS_DIR="$work/genesis"
}
# shellcheck source=tools/no_pin_rig.sh
source "$(dirname "$chain_view")/no_pin_rig.sh"
measurement_cleanup() {
  local status=$?
  cp "$evidence" "$work/node-source.jsonl" 2>/dev/null || true
  # Preserve the interrupted command's status for the rig's existing cleanup.
  if (exit "$status"); then release_scratch; else release_scratch; fi
}
trap measurement_cleanup EXIT
python3 -I "$measurement" "$parameter_source" "$provider_url" "$work/node-parameters.json"
"$node_program" --version >"$work/node-version.txt"
mkdir -p "$work/packets" "$work/bundles" "$work/staged"
printf '%s\n' '{"measurement":"batch"}' >"$work/actors/alice/cwd/payload.json"
folder_address="$("$harness" wallet-address "$network_magic" "$work/actors/bob/cwd/bob.skey" | jq -er .address)"

measure_harness() { # NAME COMMAND ...
  local name="$1" command="$2"
  shift 2
  run_as bob "$name" "$harness" "$command" --blueprint plutus.json --state-token "$token" "$@"
  [ "$(cat "$receipts/$name.status")" = 0 ] || {
    cat "$receipts/$name.err" >&2
    setup_fail "the measurement harness failed: $name"
  }
}
book_registration() { # NAME KEY TAKE
  as alice "$1" "$open_datum" insert --blueprint plutus.json --state-token "$token" \
    --key "$2" --payload payload.json --deposit 3000000 --tip "$3"
}
build_bundle() { # NAME [named requests]
  local name="$1" status=0
  shift
  (
    cd "$work/actors/bob/cwd"
    env -i HOME="$work/actors/bob/home" PATH=/nonexistent LC_ALL=C.UTF-8 \
      "$timeout_bin" 900 "$open_datum" fold --blueprint plutus.json --state-token "$token" \
      --wallet-address "$folder_address" --bundle "$work/bundles/$name.json" \
      --state-dir "$work/staged/$name" "${node[@]}" "$@" \
      >"$receipts/$name.json" 2>"$receipts/$name.err" </dev/null
  ) || status=$?
  printf '%s\n' "$status" >"$receipts/$name.status"
}

for kind in registrations terminations mixed; do
  as carol "$kind-create" "$open_datum" create --blueprint plutus.json \
    --process-time 900000 --reclaim-time 60000 --booking-width 60000
  token="$(field "$kind-create" .stateToken)"
  view_tx "$kind-create" "$(tx_of "$kind-create" create)"
  pending_flags=()
  # Distinct, fixed-width keys and one payload shape; both kinds are booked
  # by the packaged commands. No key reaches an active state by a seed hook.
  for index in $(seq 1 12); do
    label="$(printf '%02d' "$index")"
    request_kind=registration
    if [ "$kind" = terminations ] || { [ "$kind" = mixed ] && [ $((index % 2)) = 0 ]; }; then
      request_kind=termination
    fi
    key="measure-$label"
    if [ "$request_kind" = registration ]; then
      book_registration "$kind-book-$label" "$key" "$((2000000 + 1000 * (12 - index)))"
      pending="$(field "$kind-book-$label" .pending)"
    else
      book_registration "$kind-seed-$label" "$key" 1000000
      as bob "$kind-prime-$label" "$open_datum" fold --blueprint plutus.json --state-token "$token" \
        --pending "$(field "$kind-seed-$label" .pending)"
      view_tx "$kind-prime-$label" "$(tx_of "$kind-prime-$label" fold)"
      holding="$(jq -er --arg app "$application_hash" \
        '.outputs[] | select(.credential == {type:"script",hash:$app} and .datum.constructor == 2) | .ref' \
        "$chain_dir/$kind-prime-$label.tx.json")"
      as alice "$kind-book-$label" "$open_datum" terminate --blueprint plutus.json \
        --state-token "$token" --holding "$holding"
      pending="$(field "$kind-book-$label" .pending)"
    fi
    pending_flags+=(--pending "$pending")
  done
  python3 -I "$measurement" pool "$kind" "$work"
  # Preserve the ordinary discovery/no-limit build as well as the named
  # sizes. Every pool is larger than the measured boundary or the job fails.
  build_bundle "$kind-automatic"
  last=0
  for count in $(seq 1 12); do
    name="$kind-$count"
    packet="$work/packets/$name"
    build_bundle "$name" "${pending_flags[@]:0:count*2}"
    if [ "$(cat "$receipts/$name.status")" = 19 ] \
      && jq -e '.outcome == "waiting-for-signatures"' "$receipts/$name.json" >/dev/null; then
      measure_harness "$name-keep" keep-batch --bundle "$work/bundles/$name.json" --output "$packet"
    else
      python3 -I "$measurement" builder-capacity "$receipts/$name.json"
      measure_harness "$name-keep" build-beyond-capacity --output "$packet" "${pending_flags[@]:0:count*2}"
    fi
    cp "$receipts/$name-keep.json" "$packet/preparation.json"
    cp "$receipts/$name.json" "$packet/builder.json"
    "$harness" evaluate-batch "$recorded_parameters" "$packet" >"$packet/evaluation.json"
    if jq -e '.exceeded | length > 0' "$packet/evaluation.json" >/dev/null; then
      last="$count"
      break
    fi
  done
  [ "$last" -gt 1 ] && [ "$last" -le 12 ] || setup_fail 'the pool does not bracket a positive target limit'
  accepted_count=$((last - 1))
  measure_harness "$kind-refused" send-batch --transaction "$work/packets/$kind-$last/transaction.cbor"
  cp "$receipts/$kind-refused.json" "$work/packets/$kind-$last/node.json"
  if ! jq -e '.outcome == "refused"' "$receipts/$kind-refused.json" >/dev/null; then
    say "DISAGREEMENT: node accepted the target's first refused $kind size $last"
    exit 1
  fi
  measure_harness "$kind-accepted" send-batch --transaction "$work/packets/$kind-$accepted_count/transaction.cbor"
  cp "$receipts/$kind-accepted.json" "$work/packets/$kind-$accepted_count/node.json"
  if ! jq -e '.outcome == "accepted"' "$receipts/$kind-accepted.json" >/dev/null; then
    say "DISAGREEMENT: node refused the target's accepted $kind size $accepted_count"
    exit 1
  fi
  view_tx "$kind-accepted" "$(field "$kind-accepted" .transaction)"
  python3 -I "$measurement" included "$evidence" "$(field "$kind-accepted" .transaction)" \
    "$work/packets/$kind-$accepted_count/transaction.cbor"
done
if [ "$mode" = --refresh ]; then
  python3 -I "$measurement" refresh "$harness" "$recorded_parameters" "$parameter_source" \
    "$blueprint_source" "$work" "$refresh_destination"
  cp "$refresh_destination/receipt.json" "$results/receipt.json"
else
  python3 -I "$measurement" fresh-result "$harness" "$recorded_parameters" "$parameter_source" \
    "$blueprint_source" "$work" "$results"
fi
