#!/usr/bin/env bash
# The devnet E2E parts select the whole suite: every named part selects at
# least one example, and the parts' selections add up to exactly the full
# suite (a part matching nothing, or a module no part names, fails here).
# Dry runs only: no node starts.
#
# usage: e2e_parts_proof.sh PARTS-JSON   (run from offchain/, REGISTRY_BLUEPRINT set)
set -euo pipefail
parts="$1"
count() {
  # shellcheck disable=SC2086 # hspec arguments split on spaces
  nix run --quiet .#cage-tests-e2e -- --dry-run $1 2>/dev/null \
    | awk '/ examples?, /{n=$1} END{print n+0}'
}
total="$(count "")"
[ "$total" -gt 0 ] || { echo "FAIL: the full suite selects no example"; exit 1; }
sum=0
n_parts="$(jq length "$parts")"
for i in $(seq 0 $((n_parts - 1))); do
  name="$(jq -r ".[$i].name" "$parts")"
  args="$(jq -r ".[$i].args" "$parts")"
  empty_ok="$(jq -r ".[$i].mayBeEmpty" "$parts")"
  n="$(count "$args")"
  echo "part '$name': $n example(s)"
  if [ "$n" -eq 0 ] && [ "$empty_ok" != true ]; then
    echo "FAIL: part '$name' selects no example"
    exit 1
  fi
  sum=$((sum + n))
done
echo "parts select $sum of $total examples"
[ "$sum" -eq "$total" ] || { echo "FAIL: the parts overlap or leave examples out ($sum selected, $total in the suite)"; exit 1; }
echo "E2E-PARTS-PROOF: the parts select the whole suite exactly once"
