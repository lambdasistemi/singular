#!/usr/bin/env bash
# Corrupt actual runner output and rows: each wrong fact must be refused.
# usage: shared-publication-rows-control.sh INVENTORY.tsv ROWS.json FROZEN.txt
# shellcheck disable=SC2016
set -euo pipefail
inventory="$1" rows="$2" frozen="$3"
check="$(dirname "$0")/shared-publication-rows.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
bash "$check" "$inventory" "$rows" "$frozen" || fail 'unaltered inputs must pass'
plant() {
  local name="$1" reason="$2" inv="$3" rws="$4" out
  if out="$(bash "$check" "$inv" "$rws" "$frozen" 2>&1)"; then fail "accepted: $name"; fi
  grep -qF "$reason" <<<"$out" || fail "$name refused for another reason: $out"
  echo "refused as it must: $name"
}
alter_inventory() {
  awk -F'\t' -v OFS='\t' -v id="$claim" -v n="$1" -v value="$2" '$1 == id { $n = value } { print }' "$inventory" >"$scratch/inventory.tsv"
}
alter_rows() { jq --arg id "$claim" "$1" "$rows" >"$scratch/rows.json"; }
claim=later-creation-reuses-publications
alter_inventory 4 covered
plant 'covered without a receipt' 'only a model-comparison receipt' "$scratch/inventory.tsv" "$rows"
alter_rows '.rows |= map(select(.id != $id))'
plant 'a dropped reuse claim' 'is missing' "$inventory" "$scratch/rows.json"
grep -v "^$claim"$'\t' "$inventory" >"$scratch/inventory.tsv"
plant 'a dropped listed claim' 'is not listed exactly once' "$scratch/inventory.tsv" "$rows"
alter_inventory 3 'Accepted without an explanation'
plant 'missing uncovered reason' 'does not give its reason' "$scratch/inventory.tsv" "$rows"
alter_inventory 5 'Another requirement'
plant 'lost requirement text' 'loses its requirement text' "$scratch/inventory.tsv" "$rows"
alter_rows '(.rows[] | select(.id == $id) | .evidence) = "A journey passed"'
plant 'missing evidence boundary' 'does not name its separate evidence boundary' "$inventory" "$scratch/rows.json"
alter_rows '(.rows[] | select(.id == $id) | .source) = "Unknown law"'
plant 'missing declaration' 'does not name the creation declarations' "$inventory" "$scratch/rows.json"
alter_rows '(.rows[] | select(.id == $id) | .note) += " Costs 123 lovelace."'
plant 'typed cost' 'retypes a number' "$inventory" "$scratch/rows.json"
alter_rows '(.rows[] | select(.id == $id) | .note) += " The commit owner says so."'
plant 'internal identifier' 'names an internal identifier' "$inventory" "$scratch/rows.json"
alter_rows '.rows |= map(select(.group != "shared-publications"))'
plant 'empty group' 'a check over no rows proves nothing' "$inventory" "$scratch/rows.json"
# Quantify over every previous row rather than selecting one representative.
while read -r _hash previous; do
  [ -n "$previous" ] || continue
  jq --arg id "$previous" '(.rows[] | select(.id == $id) | .note) += " Changed."' "$rows" >"$scratch/rows.json"
  plant "changed preceding row $previous" 'was edited or removed' "$inventory" "$scratch/rows.json"
done <"$frozen"
: >"$scratch/empty.txt"
if bash "$check" "$inventory" "$rows" "$scratch/empty.txt" >"$scratch/empty.log" 2>&1; then fail 'accepted no preceding rows'; fi
grep -qF 'no preceding rows are frozen' "$scratch/empty.log" || fail 'empty frozen list refused for another reason'
echo 'shared-publication row controls: all planted changes refused'
