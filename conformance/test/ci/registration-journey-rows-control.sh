#!/usr/bin/env bash
# registration-journey-rows.sh must be able to fail. On scratch copies of the real inventory and the
# real rows, each alteration below plants one wrong fact, and the check must refuse it naming the
# reason; the unaltered inputs must pass first, so a check that refuses everything is seen too.
#
# usage: registration-journey-rows-control.sh INVENTORY.tsv ROWS.json FROZEN.txt
set -euo pipefail

inventory="$1" rows="$2" frozen="$3"
here="$(cd "$(dirname "$0")" && pwd)"
check="$here/registration-journey-rows.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash "$check" "$inventory" "$rows" "$frozen" >/dev/null || fail "the unaltered inputs must pass"

# plant NAME WANT ALTERED-INVENTORY ALTERED-ROWS: the check must exit non-zero and say WANT.
plant() {
  local name="$1" want="$2" inv="$3" rws="$4" out
  if out="$(bash "$check" "$inv" "$rws" "$frozen" 2>&1)"; then
    fail "planted '$name' was accepted"
  fi
  grep -qF -- "$want" <<<"$out" || fail "planted '$name' was refused for another reason: $out"
  echo "refused as it must: $name"
}

# jq programs below name jq variables, never shell ones.
# shellcheck disable=SC2016
alter_rows() { jq --arg id "$1" "$2" "$rows" >"$scratch/rows.json"; }
# alter_inventory ID COLUMN TEXT: replace one column of one listing line.
alter_inventory() {
  awk -F'\t' -v OFS='\t' -v id="$1" -v n="$2" -v text="$3" '$1 == id { $n = text } { print }' "$inventory" >"$scratch/inventory.tsv"
}

fold=registration-fold-outcome
wait_row=unfoldable-registration-waits-for-reclaim

alter_inventory "$fold" 4 executed
plant "a row typed executed" "only a receipt may change a row's state" "$scratch/inventory.tsv" "$rows"

grep -v "^$wait_row"$'\t' "$inventory" >"$scratch/inventory.tsv"
plant "a statement the runner does not list" "is not listed exactly once" "$scratch/inventory.tsv" "$rows"

alter_inventory "$fold" 3 "The fold is accepted and pays out as stated."
plant "a row without its reason" "does not give its reason" "$scratch/inventory.tsv" "$rows"

alter_inventory "$fold" 5 "A booked registration is folded."
plant "a row without the previous design's outcome" "does not state the previous design's outcome" "$scratch/inventory.tsv" "$rows"

# shellcheck disable=SC2016
alter_rows "$fold" '(.rows[] | select(.id == $id) | .requirement) += " The folder receives 3 lovelace."'
plant "an outcome retyped as a number" "retypes a number" "$inventory" "$scratch/rows.json"

# shellcheck disable=SC2016
alter_rows "$fold" '(.rows[] | select(.id == $id) | .note) += " Raised by the commit owner."'
plant "an internal identifier" "names an internal identifier" "$inventory" "$scratch/rows.json"

# shellcheck disable=SC2016
alter_rows "$fold" '(.rows[] | select(.id == $id) | .evidence) |= sub("no-pin-registration-refusals"; "another job")'
plant "a row that does not name both hosted jobs" "does not name its separate evidence boundary" "$inventory" "$scratch/rows.json"

# shellcheck disable=SC2016
alter_rows "$fold" '(.rows[] | select(.id == $id) | .source) = "a statement nobody can find"'
plant "a row that does not name its declarations" "does not name the declarations" "$inventory" "$scratch/rows.json"

# shellcheck disable=SC2016
alter_rows "$wait_row" '.rows |= map(select(.id != $id))'
plant "the decided difference removed" "is missing from the registration-journeys group" "$inventory" "$scratch/rows.json"

# shellcheck disable=SC2016
alter_rows x '.rows |= map(select(.group != "registration-journeys"))'
plant "a group with no row" "a check over no rows proves nothing" "$inventory" "$scratch/rows.json"

# shellcheck disable=SC2016
alter_rows holding-update-outcome '(.rows[] | select(.id == $id) | .note) += " Edited."'
plant "a retained row edited by one field" "was edited or removed" "$inventory" "$scratch/rows.json"

# shellcheck disable=SC2016
alter_rows termination-fold-outcome '.rows |= map(select(.id != $id))'
grep -v '^termination-fold-outcome'$'\t' "$inventory" >"$scratch/inventory.tsv"
plant "a retained row deleted" "is no longer listed" "$scratch/inventory.tsv" "$scratch/rows.json"

: >"$scratch/empty-frozen.txt"
if bash "$check" "$inventory" "$rows" "$scratch/empty-frozen.txt" >/dev/null 2>&1; then
  fail "an empty list of frozen rows was accepted"
fi
echo "refused as it must: no frozen comparison row"

echo "registration-journey rows: the check refuses each planted wrong fact"
