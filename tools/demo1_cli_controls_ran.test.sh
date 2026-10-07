#!/usr/bin/env bash
# shellcheck disable=SC2016 # the fixtures quote the verdict section's own Markdown backticks
# Self-test for demo1_cli_controls_ran.sh (#419): a runner exit is trusted
# only when the verdict section judged at least one clause, and every clause
# that does not hold or is uncovered is named.
#
# usage: demo1_cli_controls_ran.test.sh RAN-SCRIPT
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 RAN-SCRIPT" >&2
  exit 2
}
ran="$1"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-controls-ran-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "demo1-controls-ran.test: FAIL: $*" >&2
  exit 1
}

# verdicts NAME LINE...: a run directory whose verdict section is LINE...
verdicts() {
  local name="$1"
  shift
  mkdir -p "$scratch/$name/receipts"
  echo '{}' >"$scratch/$name/receipts/step-001.json"
  mkdir -p "$scratch/$name/evidence" "$scratch/$name/targets/process" "$scratch/$name/artifact-controls/withheld-elsewhere"
  echo '{}' >"$scratch/$name/evidence/step-001-inspect-without-history-another-asset.receipt.json"
  : >"$scratch/$name/targets/process/journal.jsonl"
  for kept in withheld-elsewhere.md withheld-elsewhere.err withheld-elsewhere.sha256 inputs.sha256; do
    echo "$kept" >"$scratch/$name/artifact-controls/$kept"
  done
  printf '%s\n' "$@" >"$scratch/$name/controls.md"
}
# expect NAME STATUS WANT TEXT: judging NAME after a runner exit STATUS exits
# WANT and its output contains TEXT.
expect() {
  local name="$1" given="$2" want="$3" text="$4" status=0
  DEMO1_CONTROLS_RESULTS="$scratch/results-$name" bash "$ran" "$scratch/$name" "$given" >"$scratch/$name.out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || fail "$name: exit $status, expected $want: $(cat "$scratch/$name.out")"
  grep -qF -- "$text" "$scratch/$name.out" || fail "$name: output does not contain '$text': $(cat "$scratch/$name.out")"
  echo "demo1-controls-ran.test: $name: exit $status"
}

held='| `R299-05` | the same insert is accepted | holds |'
broken='| `fold_inversion` | the same fold is accepted | does not hold: the outcome is "client-error" |'
saved='| `INV299-AUTHENTICATED` | inspect with the saved proof material moved aside prints no leaf | uncovered: inspect never reads saved proof material |'
case_row='| a case | `a_statement` | uncovered: the live suite runs no transaction for it |'

verdicts all-hold "$held" "" "2 of 2 clauses hold; 0 do not; 0 are uncovered."
expect all-hold 0 0 "clauses judged: 2 of 2 clauses hold"
[ -f "$scratch/results-all-hold/controls.md" ] && [ -f "$scratch/results-all-hold/receipts/step-001.json" ] \
  || fail "all-hold: the verdict section and receipts were not kept for upload"
for kept in evidence/step-001-inspect-without-history-another-asset.receipt.json targets/process/journal.jsonl \
  artifact-controls/withheld-elsewhere.md artifact-controls/withheld-elsewhere.err \
  artifact-controls/withheld-elsewhere.sha256 artifact-controls/inputs.sha256; do
  [ -f "$scratch/results-all-hold/$kept" ] || fail "all-hold: $kept was not kept for upload"
done
[ ! -e "$scratch/results-all-hold/artifact-controls/withheld-elsewhere" ] \
  || fail "all-hold: a whole copy of the run was uploaded beside the composition files"

verdicts red "$held" "$broken" "$saved" "" "1 of 3 clauses hold; 1 do not; 1 are uncovered." "" "$case_row"
expect red 1 1 "not holding: $broken"
expect red 1 1 "not holding: $saved"
grep -qF "$case_row" "$scratch/red.out" && fail "red: a row of the approved-cases table was named as a clause"

verdicts no-summary "$held"
expect no-summary 0 1 "no clause summary"
verdicts zero "0 of 0 clauses hold; 0 do not; 0 are uncovered."
expect zero 0 1 "counts no clause"
mkdir -p "$scratch/setup"
expect setup 3 3 "no clause summary"
echo "demo1-controls-ran.test: all cases passed"
