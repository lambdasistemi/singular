#!/usr/bin/env bash
# A fault for the attach controls, never a readback: run tools/demo1_readback.sh
# as given, then, for the Koios read only and only when it held, change one raw
# fact of the record it kept while leaving every stated comparison true and the
# verdict "holds". The take's own judgement must recompute the comparison from
# the facts, find the change, and stop before its next write.
#
# usage: TAMPER=FACT demo1_readback_tamper.sh READBACK-ARGS...
#        TAMPER=FACT demo1_readback_tamper.sh --record FILE
#          (the second form changes an existing record in place, nothing else)
#
#   datum     another well-formed inline datum, its hash recomputed to match it
#   lag       the indexer's tip 100000 slots further behind than it was, never
#             below slot 0; a node too young for that to exceed the record's
#             maximum lag is a setup failure (exit 3), never a control
#   census    the provider's answer naming a second output holding the token
#   quantity  the answer's quantity of the token the JSON number 1.4, not "1"
#   index     the answer's output index of its holder 0.4 past its own
#   entry     a second entry for the token in the holder, its quantity "0.5"
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" = --record ]; then
  out="$2"
else
  status=0
  bash "$here/demo1_readback.sh" "$@" || status=$?
  provider="" out=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) provider="$2" ;;
      --out) out="$2" ;;
    esac
    shift
  done
  if [ "$status" -ne 0 ] || [ "$provider" != koios ]; then
    exit "$status"
  fi
fi
datum="d87980"
hash="$(printf '%s' "$datum" | xxd -r -p | b2sum -l 256 | cut -d' ' -f1)"
case "${TAMPER:?TAMPER names the fact to change}" in
  datum)
    jq --arg d "$datum" --arg h "$hash" \
      '.indexer.datumCbor = $d | .indexer.datumHashRecomputed = $h' "$out" >"$out.tampered"
    ;;
  lag)
    jq '.indexer.tipSlot = ((.indexer.tipSlot | tonumber) - 100000 | if . < 0 then 0 else . end | tostring)' \
      "$out" >"$out.tampered"
    jq -e '((.inspect.observedTip | split(".")[0] | tonumber) - (.indexer.tipSlot | tonumber)) > (.maxLagSlots | tonumber)' \
      "$out.tampered" >/dev/null || {
      rm -f "$out.tampered"
      echo "readback-tamper: setup: the node is too young for a tip beyond the maximum lag" >&2
      exit 3
    }
    ;;
  census)
    jq '.requests |= map(if (.url | endswith("/asset_utxos"))
          then .response += [.response[0] | .tx_index = (.tx_index + 7)] else . end)' "$out" >"$out.tampered"
    ;;
  quantity)
    jq '.policy as $p | .assetName as $n | .requests |= map(if (.url | endswith("/asset_utxos"))
          then .response |= map(.asset_list |= map(if .policy_id == $p and .asset_name == $n
            then .quantity = 1.4 else . end)) else . end)' "$out" >"$out.tampered"
    ;;
  index)
    jq '.requests |= map(if (.url | endswith("/asset_utxos"))
          then .response |= map(.tx_index = (.tx_index + 0.4)) else . end)' "$out" >"$out.tampered"
    ;;
  entry)
    jq '.policy as $p | .assetName as $n | .requests |= map(if (.url | endswith("/asset_utxos"))
          then .response |= map(.asset_list += [{policy_id: $p, asset_name: $n, quantity: "0.5"}]) else . end)' \
      "$out" >"$out.tampered"
    ;;
  *)
    echo "readback-tamper: unknown TAMPER=$TAMPER" >&2
    exit 2
    ;;
esac
mv "$out.tampered" "$out"
jq -e '.holds and .comparisons.sameOutput and .comparisons.sameDatumBytes and .comparisons.sameDatumHash and .comparisons.withinLag' "$out" >/dev/null
exit 0
