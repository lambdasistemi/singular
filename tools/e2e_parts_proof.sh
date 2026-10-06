#!/usr/bin/env bash
# The devnet E2E lanes select the whole suite. Every module is wrapped in
# exactly one lane (Test.Tags.lane, "{lane:NAME}"), and each CI part runs one
# lane with --match "{lane:NAME}". Before any part runs, this proves:
#   - every listed lane selects at least one example;
#   - the lanes' selections add up to exactly the full suite;
#   - skipping every lane selects nothing: no example is untagged.
# Dry runs only: no node starts.
#
# usage: e2e_parts_proof.sh PARTS-JSON   (run from offchain/, REGISTRY_BLUEPRINT set)
set -euo pipefail
parts="$1"
count() {
  local out
  if ! out="$(nix run --quiet .#cage-tests-e2e -- --dry-run --no-color "$@" 2>&1)"; then
    echo "FAIL: the dry run itself failed (args: $*):" >&2
    printf '%s\n' "$out" | tail -20 >&2
    exit 1
  fi
  local n
  n="$(printf '%s\n' "$out" | awk '/ examples?, /{n=$1} END{if (n != "") print n}')"
  if [ -z "$n" ]; then
    echo "FAIL: the dry run printed no example count (args: $*); its last lines:" >&2
    printf '%s\n' "$out" | tail -20 >&2
    exit 1
  fi
  echo "$n"
}
total="$(count)"
[ "$total" -gt 0 ] || { echo "FAIL: the full suite selects no example"; exit 1; }
untagged="$(count --skip "{lane:")"
echo "untagged examples (outside every lane): $untagged"
[ "$untagged" -eq 0 ] || { echo "FAIL: $untagged example(s) carry no lane, so no part would run them"; exit 1; }
sum=0
while IFS=$'\t' read -r name lane; do
  n="$(count --match "{lane:$lane}")"
  echo "lane $lane ($name): $n example(s)"
  [ "$n" -gt 0 ] || { echo "FAIL: lane $lane selects no example"; exit 1; }
  sum=$((sum + n))
done < <(jq -r '.[] | [.name, .lane] | @tsv' "$parts")
echo "lanes select $sum of $total examples"
[ "$sum" -eq "$total" ] || { echo "FAIL: the lanes overlap or leave examples out ($sum selected, $total in the suite)"; exit 1; }
echo "E2E-LANES-PROOF: every example is in exactly one listed lane"
