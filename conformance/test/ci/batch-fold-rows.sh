#!/usr/bin/env bash
# Published batch requirements remain uncovered until model-comparison receipts
# exist. Every preceding requirement is protected as complete canonical JSON.
set -euo pipefail
inventory="$1" rows="$2" frozen="$3"
group=batch-folding
required='public-mixed-batch-fold skipped-batch-holders configuration-output-is-not-skipped folder-keeps-batch-surplus largest-fitting-batch named-batch-and-state-policy measured-batch-limits'
reason='no executable comparison with the application-held model exists yet'
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
column() { awk -F'\t' -v id="$1" -v n="$2" '$1 == id { print $n }' "$inventory"; }
ids="$(jq -r --arg group "$group" '.rows[] | select(.group == $group) | .id' "$rows")"
[ -n "$ids" ] || fail 'no batch-folding requirements: an empty group proves nothing'
for need in $required; do
  grep -qx "$need" <<<"$ids" || fail "the requirement $need is missing"
done
judged=0
for id in $ids; do
  [ "$(awk -F'\t' -v id="$id" '$1 == id' "$inventory" | grep -c .)" -eq 1 ] || fail "$id is not listed exactly once"
  [ "$(column "$id" 2)" = "$group" ] || fail "$id is listed outside its group"
  [ "$(column "$id" 4)" = uncovered ] || fail "$id: only a model-comparison receipt may change a row's standing"
  grep -qF "$reason" <<<"$(column "$id" 3)" || fail "$id does not give its uncovered reason"
  requirement="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | .requirement' "$rows")"
  [ -n "$requirement" ] && [ "$(column "$id" 5)" = "$requirement" ] || fail "$id loses its requirement text"
  evidence="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | .evidence // ""' "$rows")"
  for boundary in no-pin-registration-journey no-pin-batch-refusals no-pin-batch-measurement 'nothing about agreement with the model'; do
    grep -qF "$boundary" <<<"$evidence" || fail "$id loses its separate evidence boundary ($boundary)"
  done
  source="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | .source' "$rows")"
  [ -n "$source" ] && [ "$source" != null ] || fail "$id has no source or operational limit"
  text="$(jq -r --arg id "$id" '.rows[] | select(.id == $id) | [.requirement,.source,.expected,.evidence,.note] | map(. // "") | join("\n")' "$rows")"
  if grep -qE '[0-9]' <<<"$text"; then fail "$id retypes a measured number"; fi
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
[ "$kept" -gt 0 ] || fail 'no preceding requirements are frozen'
previous="$(jq -r --arg group "$group" '.rows[] | select(.group != $group) | .id' "$rows" | sort)"
protected="$(awk '{print $2}' "$frozen" | sort)"
[ "$previous" = "$protected" ] || fail 'the frozen list does not protect every preceding requirement exactly once'
echo "batch-folding rows: $judged requirements uncovered; $kept preceding requirements unchanged"
