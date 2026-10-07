#!/usr/bin/env bash
# shellcheck disable=SC2016 # the fixtures quote the verdict section's own Markdown backticks
# Self-test for demo1_cli_controls_composition.sh (#419): the composition
# control passes only for a trustworthy other-asset inspect whose swapped-in
# receipt fails the authentication clause for the missed withholding alone.
# A stand-in renderer prints a chosen verdict section and exit.
#
# usage: demo1_cli_controls_composition.test.sh COMPOSITION-SCRIPT
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 COMPOSITION-SCRIPT" >&2
  exit 2
}
composition="$1"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-composition-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "demo1-composition.test: FAIL: $*" >&2
  exit 1
}

clause='| `INV299-AUTHENTICATED` | inspect with the public history it needs withheld prints no leaf and names HistoryIncomplete | '
alone="${clause}does not hold: the withholding never reached the command's history read: none of the registry's history reads was withheld |"
beside="${clause}does not hold: the outcome is \"client-refusal\", not \"stale-state\"; the withholding never reached the command's history read: none of the registry's history reads was withheld |"

cat >"$scratch/render" <<'EOF'
#!/usr/bin/env bash
[ "$1" = render ] || exit 64
cat "$STUB_MD"
exit "$STUB_EXIT"
EOF
chmod +x "$scratch/render"

printed='{"outcome":"success","leaf":"active"}'
honest_control() {
  jq -n --argjson c "$printed" '{
    step: 5, action: "provoke inspect-without-history", target: "process", key: "held",
    outcome: "success", command: $c, withheldReads: 0,
    process: {exit: 0, journalBefore: 7, journalAfter: 7},
    evidence: ["evidence/step-005-inspect-without-history-another-asset.json"]}'
}
# case_of NAME CONTROL-JQ WITNESS-READS PRINTED ROW EXIT: a run directory, a
# copy of it and a stand-in render.
case_of() {
  local name="$1" mutate="$2" reads="$3" kept="$4" row="$5" code="$6" dir="$scratch/$1"
  mkdir -p "$dir/work/receipts" "$dir/work/evidence" "$dir/copy/receipts"
  jq -n --argjson n "$reads" '{step: 5, action: "provoke inspect-without-history", target: "process", key: "held", withheldReads: $n}' \
    >"$dir/work/receipts/step-005.json"
  honest_control | jq "$mutate" >"$dir/work/evidence/step-005-inspect-without-history-another-asset.receipt.json"
  [ -z "$kept" ] || printf '%s\n' "$kept" >"$dir/work/evidence/step-005-inspect-without-history-another-asset.json"
  printf '%s\n%s\n' "| \`R299-05\` | a clause | holds |" "$row" >"$dir/rendered.md"
  echo "$code" >"$dir/exit"
}
# expect NAME STATUS TEXT
expect() {
  local name="$1" want="$2" text="$3" status=0 dir="$scratch/$1"
  STUB_MD="$dir/rendered.md" STUB_EXIT="$(cat "$dir/exit")" \
    bash "$composition" "$dir/work" "$scratch/render" "$dir/copy" >"$dir.out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || fail "$name: exit $status, expected $want: $(cat "$dir.out")"
  grep -qF -- "$text" "$dir.out" || fail "$name: output lacks '$text': $(cat "$dir.out")"
  echo "demo1-composition.test: $name: exit $status"
}

case_of trustworthy . 1 "$printed" "$alone" 1
expect trustworthy 0 "fails the authentication clause for the missed withholding alone"
[ -s "$scratch/trustworthy/copy.sha256" ] || fail "trustworthy: no hashes of the inputs and the render"
cmp -s "$scratch/trustworthy/copy/receipts/step-005.json" \
  "$scratch/trustworthy/work/evidence/step-005-inspect-without-history-another-asset.receipt.json" \
  || fail "trustworthy: the other-asset receipt was not swapped in"

case_of client-refusal '.outcome = "client-refusal" | .command.outcome = "client-refusal" | .process.exit = 10' 1 \
  '{"outcome":"client-refusal","leaf":"active"}' "$beside" 1
expect client-refusal 1 "is not a successful ordinary inspect"
case_of output-missing . 1 "" "$alone" 1
expect output-missing 1 "is not kept"
case_of output-differs . 1 '{"outcome":"success","leaf":"terminal"}' "$alone" 1
expect output-differs 1 "is not the output kept"
case_of no-leaf '.command.leaf = null' 1 '{"outcome":"success","leaf":null}' "$alone" 1
expect no-leaf 1 "is not a successful ordinary inspect"
case_of journal-moved '.process.journalAfter = 8' 1 "$printed" "$alone" 1
expect journal-moved 1 "is not a successful ordinary inspect"
case_of control-withheld '.withheldReads = 1' 1 "$printed" "$alone" 1
expect control-withheld 1 "is not a successful ordinary inspect"
case_of witness-withheld-none . 0 "$printed" "$alone" 1
expect witness-withheld-none 1 "the witness's forwarder withheld none"
case_of other-step '.step = 6' 1 "$printed" "$alone" 1
expect other-step 1 "is not of the witness's step"
case_of beside-other-findings . 1 "$printed" "$beside" 1
expect beside-other-findings 1 "does not fail for the missed withholding alone"
case_of still-holds . 1 "$printed" "${clause}holds |" 0
expect still-holds 1 "the swapped copy still holds"
echo "demo1-composition.test: all cases passed"
