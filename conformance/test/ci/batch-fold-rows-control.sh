#!/usr/bin/env bash
# Change actual suite output and inventory, then require the same check to fail.
# shellcheck disable=SC2016
set -euo pipefail
inventory="$1" rows="$2" frozen="$3"
check="$(dirname "$0")/batch-fold-rows.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
bash "$check" "$inventory" "$rows" "$frozen"
plant() {
  local name="$1" reason="$2" inv="$3" rws="$4" out
  if out="$(bash "$check" "$inv" "$rws" "$frozen" 2>&1)"; then fail "accepted: $name"; fi
  grep -qF "$reason" <<<"$out" || fail "$name refused for another reason: $out"
  echo "refused as required: $name"
}
ids="$(jq -r '.rows[] | select(.group == "batch-folding") | .id' "$rows")"
for claim in $ids; do
  awk -F'\t' -v OFS='\t' -v id="$claim" '$1 == id { $4 = "executed" } { print }' "$inventory" >"$scratch/inventory.tsv"
  plant "credit without a receipt: $claim" 'only a model-comparison receipt' "$scratch/inventory.tsv" "$rows"
  jq --arg id "$claim" '.rows |= map(select(.id != $id))' "$rows" >"$scratch/rows.json"
  plant "dropped requirement: $claim" 'is missing' "$inventory" "$scratch/rows.json"
  awk -F'\t' -v OFS='\t' -v id="$claim" '$1 == id { $3 = "Unexplained" } { print }' "$inventory" >"$scratch/inventory.tsv"
  plant "lost uncovered reason: $claim" 'does not give its uncovered reason' "$scratch/inventory.tsv" "$rows"
  awk -F'\t' -v OFS='\t' -v id="$claim" '$1 == id { $5 = "Other requirement" } { print }' "$inventory" >"$scratch/inventory.tsv"
  plant "lost requirement text: $claim" 'loses its requirement text' "$scratch/inventory.tsv" "$rows"
  jq --arg id "$claim" '(.rows[] | select(.id == $id) | .evidence) = "A journey passed"' "$rows" >"$scratch/rows.json"
  plant "lost evidence boundary: $claim" 'loses its separate evidence boundary' "$inventory" "$scratch/rows.json"
  jq --arg id "$claim" '(.rows[] | select(.id == $id) | .note) += " Batch size 123."' "$rows" >"$scratch/rows.json"
  plant "typed figure: $claim" 'retypes a measured number' "$inventory" "$scratch/rows.json"
  jq --arg id "$claim" '(.rows[] | select(.id == $id) | .note) += " The commit owner says so."' "$rows" >"$scratch/rows.json"
  plant "internal identifier: $claim" 'names an internal identifier' "$inventory" "$scratch/rows.json"
done
while read -r _hash previous; do
  [ -n "$previous" ] || continue
  jq --arg id "$previous" '(.rows[] | select(.id == $id) | .note) += " Changed."' "$rows" >"$scratch/rows.json"
  plant "changed preceding requirement: $previous" 'was edited or removed' "$inventory" "$scratch/rows.json"
done <"$frozen"
: >"$scratch/empty.txt"
if bash "$check" "$inventory" "$rows" "$scratch/empty.txt" >"$scratch/empty.log" 2>&1; then fail 'accepted an empty frozen list'; fi
grep -qF 'no preceding requirements are frozen' "$scratch/empty.log"
echo 'batch-folding controls: altered states, text, evidence and every preceding requirement refused'
