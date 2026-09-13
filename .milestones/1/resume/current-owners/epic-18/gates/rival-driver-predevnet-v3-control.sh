#!/usr/bin/env bash
set -euo pipefail

gate=${1:-}
test -f "$gate" || { echo 'CONTROL RED: gate path required' >&2; exit 1; }

check_selection_contract() {
  local body=$1
  local lines count
  lines=$(printf '%s\n' "$body" | rg 'nix develop --command cabal list-bin')
  count=$(printf '%s\n' "$lines" | wc -l)
  test "$count" -eq 2 || return 1
  test "$(printf '%s\n' "$lines" | rg -v -- '-O0' | wc -l)" -eq 0 || return 1
}

baseline=$(<"$gate")
check_selection_contract "$baseline" || {
  echo 'CONTROL RED: v3 does not bind both list-bin resolutions to -O0' >&2; exit 1; }
printf 'PASS exact-build-selection baseline\n'

mutant=${baseline/'nix develop --command cabal list-bin exe:retirement-rows -O0'/'nix develop --command cabal list-bin exe:retirement-rows'}
if check_selection_contract "$mutant"; then
  echo 'CONTROL RED: wrong-build-selection mutant survived' >&2
  exit 1
fi
printf 'PASS wrong-build-selection mutant rejected\n'

set +e
missing_tool_output=$("$gate" /not-inspected /not-inspected 2>&1)
missing_tool_rc=$?
set -e
test "$missing_tool_rc" -ne 0 || {
  echo 'CONTROL RED: gate accepted missing declared JSON tool' >&2; exit 1; }
printf '%s\n' "$missing_tool_output" | rg -Fq 'ABSOLUTE_PYTHON3' || {
  echo 'CONTROL RED: missing-tool refusal was not explicit' >&2; exit 1; }
printf 'PASS missing-declared-tool rejected before source execution\n'
