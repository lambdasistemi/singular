#!/usr/bin/env bash
# Shared-publication requirements retain receipt-derived standings and explicit
# limits. The frozen canonical rows protect the entire preceding inventory.
# usage: shared-publication-rows.sh INVENTORY.tsv ROWS.json FROZEN.txt
set -euo pipefail
inventory="$1" rows="$2" frozen="$3"
group=shared-publications
required='later-creation-reuses-publications independent-creator-reuses-publications different-application-keeps-own-state-script shared-publication-registration measured-creation-cost'
reason='no executable comparison with the application-held model exists yet'
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
column() { awk -F'\t' -v id="$1" -v n="$2" '$1 == id { print $n }' "$inventory"; }
ids="$(jq -r --arg group "$group" '.rows[] | select(.group == $group) | .id' "$rows")"
[ -n "$ids" ] || fail "no shared-publication row: a check over no rows proves nothing"
for need in $required; do
  grep -qx "$need" <<<"$ids" || fail "the statement $need is missing"
done
judged=0
for id in $ids; do
  [ "$(awk -F'\t' -v id="$id" '$1 == id' "$inventory" | grep -c .)" -eq 1 ] \
    || fail "$id is not listed exactly once"
  [ "$(column "$id" 2)" = "$group" ] || fail "$id is listed outside its group"
  [ "$(column "$id" 4)" = uncovered ] || fail "$id: only a model-comparison receipt may change a row's standing"
  grep -qF "$reason" <<<"$(column "$id" 3)" || fail "$id does not give its reason"
  requirement="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | .requirement' "$rows")"
  [ -n "$requirement" ] && [ "$(column "$id" 5)" = "$requirement" ] || fail "$id loses its requirement text"
  evidence="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | .evidence // ""' "$rows")"
  for boundary in no-pin-registration-journey cli-recovery-partition 'measurement receipts' 'nothing about agreement with the model'; do
    grep -qF "$boundary" <<<"$evidence" || fail "$id does not name its separate evidence boundary ($boundary)"
  done
  source="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | .source' "$rows")"
  grep -qE 'genesis_inversion|recognition_inversion|create_journey|configurationCreate_inversion|configuration_immutable' <<<"$source" \
    || fail "$id does not name the creation declarations"
  text="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | [.requirement,.source,.expected,.evidence,.note] | map(. // "") | join("\n")' "$rows")"
  if grep -qE '[0-9]' <<<"$text"; then fail "$id retypes a number"; fi
  if grep -qiE '#[0-9]|(^|[^a-z])[qa]-[0-9]|note-|(^|[^a-z])(review|ticket|seat|pane)([^a-z]|$)|commit owner' <<<"$text"; then
    fail "$id names an internal identifier"
  fi
  judged=$((judged + 1))
done
kept=0
while read -r hash id; do
  [ -n "$id" ] || continue
  actual="$(jq -S -c --arg id "$id" '.rows[] | select(.id == $id)' "$rows" | sha256sum | cut -d' ' -f1)"
  [ -n "$(column "$id" 1)" ] || fail "the preceding row $id is no longer listed"
  [ "$actual" = "$hash" ] || fail "the preceding row $id was edited or removed"
  kept=$((kept + 1))
done <"$frozen"
[ "$kept" -gt 0 ] || fail "no preceding rows are frozen"
previous="$(jq -r --arg group "$group" '.rows[] | select(.group != $group) | .id' "$rows" | sort)"
protected="$(awk '{print $2}' "$frozen" | sort)"
[ "$previous" = "$protected" ] || fail "the frozen list does not protect every preceding row exactly once"
echo "shared-publication rows: $judged statements uncovered with their reason; $kept preceding rows unchanged"
