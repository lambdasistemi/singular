#!/usr/bin/env bash
# demo1-cli-controls ran-proof (#419): judge that a controls run judged
# clauses, before its exit is trusted.
#
# usage: demo1_cli_controls_ran.sh RUN-DIR STATUS
#
# RUN-DIR is the controls runner's work directory; STATUS is the runner's
# exit. The verdict section RUN-DIR/controls.md must end its clause table
# with "N of M clauses hold; X do not; U are uncovered." for some M > 0:
# otherwise no clause was judged and a zero STATUS is turned into 1, so a
# run that judged nothing can never read as a pass. The summary and every
# clause that does not hold or is uncovered are printed, so a red run names
# its clauses in the log. With DEMO1_CONTROLS_RESULTS set, the verdict
# section, the runner's stderr, the receipts and what admission reads back
# (the evidence and the targets' journals and bodies; the
# composition control's other-asset receipt and its printed output among
# them) are copied there for upload, whatever the outcome, with the
# composition control's render, its stderr and the hashes of its inputs and
# render. Exits with the resulting status.
set -euo pipefail

[ "$#" -eq 2 ] || {
  echo "usage: $0 RUN-DIR STATUS" >&2
  exit 2
}
run="$1"
status="$2"
verdicts="$run/controls.md"

if [ -n "${DEMO1_CONTROLS_RESULTS:-}" ]; then
  mkdir -p "$DEMO1_CONTROLS_RESULTS"
  for kept in controls.md controls.err receipts evidence targets; do
    [ ! -e "$run/$kept" ] || cp -R "$run/$kept" "$DEMO1_CONTROLS_RESULTS/"
  done
  for kept in withheld-elsewhere.md withheld-elsewhere.err withheld-elsewhere.sha256 inputs.sha256; do
    if [ -e "$run/artifact-controls/$kept" ]; then
      mkdir -p "$DEMO1_CONTROLS_RESULTS/artifact-controls"
      cp "$run/artifact-controls/$kept" "$DEMO1_CONTROLS_RESULTS/artifact-controls/"
    fi
  done
fi

summary_re='^([0-9]+) of ([0-9]+) clauses hold; ([0-9]+) do not; ([0-9]+) are uncovered\.$'
summary=""
[ ! -f "$verdicts" ] || summary="$(grep -E "$summary_re" "$verdicts" | tail -n 1 || true)"
if [ -z "$summary" ]; then
  echo "demo1-cli-controls: no clause summary in the verdict section: the run judged no clause (runner exit $status)" >&2
  [ "$status" -ne 0 ] || status=1
  exit "$status"
fi
[[ $summary =~ $summary_re ]]
total="${BASH_REMATCH[2]}"
if [ "$total" -eq 0 ]; then
  echo "demo1-cli-controls: the clause summary counts no clause: $summary (runner exit $status)" >&2
  [ "$status" -ne 0 ] || status=1
  exit "$status"
fi
echo "demo1-cli-controls: clauses judged: $summary"
# The clause table is everything above the summary line; the approved-cases
# table after it is not a clause.
awk -v s="$summary" '$0 == s { exit } /\| (does not hold|uncovered)(: |$)/ { print "demo1-cli-controls: not holding: " $0 }' "$verdicts"
exit "$status"
