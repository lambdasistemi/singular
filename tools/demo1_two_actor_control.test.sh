#!/usr/bin/env bash
# Self-test for demo1_two_actor_control.sh (#419): the control passes only on
# the run that fails at the two-actor access check, and names every other
# outcome. Each case is a stand-in for the packaged Demo 1 check that prints
# the lines a real run prints and exits as it would.
#
# usage: demo1_two_actor_control.test.sh CONTROL-SCRIPT
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 CONTROL-SCRIPT" >&2
  exit 2
}
control="$1"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-two-actor-control-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "demo1-two-actor-control.test: FAIL: $*" >&2
  exit 1
}

on="journey: two actors: the deliberate open control is on; bob's process opens alice's journal"
folded="journey: two-fold: success"
access="journey: FAIL: bob's fold accessed alice's directory: 77 openat(AT_FDCWD, \"/w/two-actors/alice/journal.jsonl\", O_RDONLY) = -1 EACCES"
refused="verify-release: REFUSED command-failed: the journey exited 1; receipts in /w"

# case NAME EXIT LINE...: a stand-in check printing LINE... and exiting EXIT;
# it refuses to run without the deliberate open switched on.
case_of() {
  local name="$1" code="$2" line
  shift 2
  {
    echo '#!/usr/bin/env bash'
    # shellcheck disable=SC2016 # the stand-in expands it, not this script
    echo '[ "${DEMO1_TWO_ACTOR_DELIBERATE_OPEN:-}" = 1 ] || { echo "the control did not switch the deliberate open on"; exit 9; }'
    for line in "$@"; do printf 'printf "%%s\\n" %q\n' "$line"; done
    echo "exit $code"
  } >"$scratch/$name.sh"
}
# expect NAME STATUS TEXT: the control over case NAME exits STATUS and its
# last line contains TEXT.
expect() {
  local name="$1" want="$2" text="$3" status=0
  RUNNER_TEMP="$scratch" DEMO1_CLI_CHECK="$scratch/$name.sh" bash "$control" /repo >"$scratch/$name.out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || fail "$name: exit $status, expected $want: $(tail -n 1 "$scratch/$name.out")"
  tail -n 1 "$scratch/$name.out" | grep -qF "$text" || fail "$name: last line does not name '$text': $(tail -n 1 "$scratch/$name.out")"
  echo "demo1-two-actor-control.test: $name: exit $status, $(tail -n 1 "$scratch/$name.out")"
}

case_of access-check 1 "$on" "$folded" "$access" "$refused"
expect access-check 0 "PASS"
case_of run-passed 0 "$on" "$folded"
expect run-passed 1 "the run passed"
case_of setup 1 "journey: SETUP: the development node never answered" "verify-release: REFUSED command-failed: the journey exited 3"
expect setup 1 "setup failure"
case_of control-off 1 "$folded" "$access" "$refused"
expect control-off 1 "never reached the two-actor stage"
case_of fold-refused 1 "$on" "journey: FAIL: two-fold: outcome refused (exit 10), expected success" "$refused"
expect fold-refused 1 "bob's fold itself did not succeed"
case_of other-failure 1 "$on" "$folded" "journey: FAIL: the key bob folded is not active" "$refused"
expect other-failure 1 "the run failed elsewhere"
case_of two-failures 1 "$on" "$folded" "$access" "journey: FAIL: a second failure" "$refused"
expect two-failures 1 "exactly one journey failure"
case_of other-exit 10 "$on" "$folded" "$access" "verify-release: REFUSED command-failed: the journey exited 10"
expect other-exit 1 "did not report the journey's failure"
echo "demo1-two-actor-control.test: all cases passed"
