#!/usr/bin/env bash
# The registration journeys of the no-pin design (folded, reclaimed, cleaned up and the decided
# difference) are published beside the previous design's early-rejection requirements, which stay
# exactly as they were. Their state comes from the inventory the runner prints (receipts decide it),
# never from this script: with no executing comparison against the application-held model they read
# uncovered, with that reason, and the hosted jobs are named as a separate evidence boundary.
#
# usage: registration-journey-rows.sh INVENTORY.tsv ROWS.json FROZEN.txt
#   INVENTORY.tsv   the output of `conformance list`
#   ROWS.json       the committed requirement inventory
#   FROZEN.txt      `sha256  row-id` of each previous-design row, as canonical compact JSON
set -euo pipefail

inventory="$1" rows="$2" frozen="$3"
group=registration-journeys
required="registration-fold-outcome registration-reclaim-outcome registration-cleanup-outcome unfoldable-registration-waits-for-reclaim"
reason='no executable comparison with the application-held model exists yet'
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
column() { awk -F'\t' -v id="$1" -v n="$2" '$1 == id { print $n }' "$inventory"; }
field() { jq -r --arg id "$1" --arg name "$2" '.rows[] | select(.id == $id) | .[$name] // empty' "$rows"; }

# The extent is read out of the inventory: every row of the group is judged, and a group with no
# row is a failure, not a pass.
ids="$(jq -r --arg group "$group" '.rows[] | select(.group == $group) | .id' "$rows")"
[ -n "$ids" ] || fail "no row in the $group group: a check over no rows proves nothing"
for need in $required; do
  grep -qx "$need" <<<"$ids" || fail "the statement $need is missing from the $group group"
done

judged=0
for id in $ids; do
  [ "$(awk -F'\t' -v id="$id" '$1 == id' "$inventory" | grep -c .)" -eq 1 ] \
    || fail "$id is not listed exactly once by the runner"
  [ "$(column "$id" 2)" = "$group" ] || fail "$id is listed outside the $group group"
  [ "$(column "$id" 4)" = uncovered ] \
    || fail "$id reads '$(column "$id" 4)', not uncovered: only a receipt may change a row's state, and no comparison with the application-held model exists yet"
  grep -qF "$reason" <<<"$(column "$id" 3)" || fail "$id does not give its reason: $reason"
  grep -qF 'previous design' <<<"$(column "$id" 5)" || fail "$id does not state the previous design's outcome"
  grep -qF 'OpenDatumApplicationHeld.Money.oldAllocation' <<<"$(field "$id" source)" \
    || fail "$id does not name the declarations that state its outcomes"
  evidence="$(field "$id" evidence)"
  for named in no-pin-registration-journey no-pin-registration-refusals 'nothing about agreement with the model'; do
    grep -qF "$named" <<<"$evidence" || fail "$id does not name its separate evidence boundary ($named)"
  done
  # No outcome is retyped as a number, and no internal identifier reaches a reader.
  text="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | [.requirement, .expected, .source, .evidence, .note] | map(. // "") | join("\n")' "$rows")"
  if grep -qE '[0-9]' <<<"$text"; then fail "$id retypes a number: its outcomes are named by their declarations"; fi
  if grep -qiE '#[0-9]|(^|[^a-z])[qa]-[0-9]|note-|(^|[^a-z])(review|ticket|seat|pane)([^a-z]|$)|commit owner' <<<"$text"; then
    fail "$id names an internal identifier"
  fi
  judged=$((judged + 1))
done

# The previous design's rows are kept as they were: present, listed, and byte-identical as
# canonical JSON. A deletion or a quiet retirement changes the hash.
kept=0
while read -r hash id; do
  [ -n "$id" ] || continue
  actual="$(jq -S -c --arg id "$id" '.rows[] | select(.id == $id)' "$rows" | sha256sum | cut -d' ' -f1)"
  [ -n "$(column "$id" 1)" ] || fail "the previous design's row $id is no longer listed"
  [ "$actual" = "$hash" ] || fail "the previous design's row $id was edited or removed"
  kept=$((kept + 1))
done <"$frozen"
[ "$kept" -gt 0 ] || fail "no previous-design row is frozen: a check over no rows proves nothing"

echo "registration-journey rows: $judged statements uncovered with their reason, $kept previous-design rows unchanged"
