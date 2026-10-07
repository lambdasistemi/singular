#!/usr/bin/env bash
# demo1-cli-controls composition control (#419): the withheld-history
# witness rests on a withholding that reached inspect's history read.
#
# usage: demo1_cli_controls_composition.sh WORK CONTROLS COPY
#
# WORK is the controls run's directory; CONTROLS the cli-controls runner;
# COPY a copy of the run's receipts and evidence prepared by the caller. The
# backend ran the authentication clause's inspect twice: through a forwarder
# withholding another asset's history (kept as
# evidence/step-NNN-inspect-without-history-another-asset.receipt.json), and
# through one withholding the registry's own (the witness's receipt).
#
# The other-asset receipt must be a trustworthy ordinary inspect: it
# succeeded, printed a leaf, exited 0, left the journal where it was, withheld
# none of the registry's history reads, and the output it printed is kept
# beside it, the very value the receipt carries. Swapped in for the witness's
# own receipt and rendered by the same judgement, the authentication clause
# must fail for that reason alone: its row reads "does not hold:" followed by
# exactly the never-reached finding, nothing beside it. The inputs and the
# render are hashed into COPY.sha256.
set -euo pipefail

[ "$#" -eq 3 ] || {
  echo "usage: $0 WORK CONTROLS COPY" >&2
  exit 2
}
work="$1"
controls="$2"
copy="$3"
fail_control() {
  echo "controls: CONTROL FAILED: $*" >&2
  exit 1
}
say() { echo "controls: $*"; }

witness=""
for f in "$work"/receipts/*.json; do
  grep -qF '"action": "provoke inspect-without-history"' "$f" || continue
  witness="$f"
  break
done
[ -n "$witness" ] || fail_control "no receipt of the withheld-history inspect"
step="$(basename "$witness" .json)"
missed="$work/evidence/$step-inspect-without-history-another-asset.receipt.json"
[ -s "$missed" ] || fail_control "the backend kept no receipt of the inspect whose forwarder withheld another asset's history"

jq -e '.withheldReads >= 1' "$witness" >/dev/null \
  || fail_control "the witness's forwarder withheld none of the registry's history reads"
jq -e --slurpfile w "$witness" '
  .step == $w[0].step and .action == $w[0].action
  and .target == $w[0].target and .key == $w[0].key' "$missed" >/dev/null \
  || fail_control "the other-asset receipt is not of the witness's step, action, target and key"
jq -e '
  .outcome == "success"
  and .command.outcome == "success"
  and (.command.leaf | type == "string")
  and .process.exit == 0
  and .process.journalBefore == .process.journalAfter
  and .withheldReads == 0
  and (.evidence | length) > 0' "$missed" >/dev/null \
  || fail_control "the other-asset receipt is not a successful ordinary inspect that printed a leaf, exited 0, left the journal still and withheld nothing"
printed="$(jq -r '.evidence[0]' "$missed")"
[ -s "$work/$printed" ] || fail_control "the output the other-asset inspect printed is not kept: $printed"
[ "$(jq -S . "$work/$printed")" = "$(jq -S .command "$missed")" ] \
  || fail_control "the other-asset receipt's command is not the output kept in $printed"

cp "$missed" "$copy/receipts/$(basename "$witness")"
status=0
"$controls" render "$copy/receipts" >"$copy.md" 2>"$copy.err" || status=$?
[ "$status" -ne 0 ] || fail_control "the swapped copy still holds"
# shellcheck disable=SC2016 # the backticks are the section's own Markdown
row='| `INV299-AUTHENTICATED` | inspect with the public history it needs withheld prints no leaf and names HistoryIncomplete | does not hold: the withholding never reached the command'"'"'s history read: none of the registry'"'"'s history reads was withheld |'
found=1
while IFS= read -r line || [ -n "$line" ]; do
  if [ "$line" = "$row" ]; then
    found=0
    break
  fi
done <"$copy.md"
[ "$found" -eq 0 ] \
  || fail_control "the authentication clause does not fail for the missed withholding alone"
sha256sum "$witness" "$missed" "$work/$printed" "$copy.md" "$copy.err" >"$copy.sha256"
say "composition control: inspect with another asset's history withheld fails the authentication clause for the missed withholding alone"
