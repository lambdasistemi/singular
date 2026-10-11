#!/usr/bin/env bash
# Self-test for registry_two_actors_control.sh (#381): the control passes
# only on the run that fails at the foreign-open guard, and names every
# other outcome. Each case is a stand-in for the journey harness that
# prints the lines a real leg prints and exits as it would.
#
# usage: registry_two_actors_control.test.sh CONTROL-SCRIPT
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 CONTROL-SCRIPT" >&2
  exit 2
}
control="$1"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/two-actors-control-test.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "two-actors-control.test: FAIL: $*" >&2
  exit 1
}

on="two actors: foreign-open control is on"
guard="two actors: GUARD: 77 openat(AT_FDCWD, \"/w/bob-home/.local/state/singular/net-42/policy-name/wallets/kh/journal.jsonl\", O_RDONLY) = 3"
row="two actors: Alice inserts a key and folds her insertion: passed"

# case NAME POSITIVE_EXIT POSITIVE_LINE CONTROL_EXIT LINE...: a stand-in
# harness whose positive leg prints POSITIVE_LINE and exits POSITIVE_EXIT,
# and whose control leg prints LINE... and exits CONTROL_EXIT. The control
# leg refuses to run without the foreign-open switch on, and the positive
# leg refuses it on.
case_of() {
  local name="$1" positive="$2" positive_line="$3" control_code="$4"
  shift 4
  {
    echo '#!/usr/bin/env bash'
    # shellcheck disable=SC2016 # the stand-in expands it, not this script
    echo 'if [ "${SINGULAR_TWO_ACTOR_CONTROL:-}" = foreign-open ]; then'
    # shellcheck disable=SC2016
    echo '  [ "$#" -ge 1 ] || { echo "the control leg names no workdir"; exit 9; }'
    for line in "$@"; do printf '  printf "%%s\\n" %q\n' "$line"; done
    echo "  exit $control_code"
    echo 'else'
    echo '  [ "$#" -ge 1 ] || { echo "the positive leg names no workdir"; exit 9; }'
    printf '  printf "%%s\\n" %q\n' "$positive_line"
    echo "  exit $positive"
    echo 'fi'
  } >"$scratch/$name.sh"
  chmod +x "$scratch/$name.sh"
}
# expect NAME STATUS TEXT: the control over case NAME exits STATUS and its
# last line contains TEXT.
expect() {
  local name="$1" want="$2" text="$3" status=0
  RUNNER_TEMP="$scratch" bash "$control" "$scratch/$name-work" "$scratch/$name.sh" >"$scratch/$name.out" 2>&1 || status=$?
  [ "$status" -eq "$want" ] || fail "$name: exit $status, expected $want: $(tail -n 1 "$scratch/$name.out")"
  tail -n 1 "$scratch/$name.out" | grep -qF "$text" || fail "$name: last line does not name '$text': $(tail -n 1 "$scratch/$name.out")"
  echo "two-actors-control.test: $name: exit $status, $(tail -n 1 "$scratch/$name.out")"
}

case_of guard-fire 1 "$row" 2 "$on" "$row" "$guard"
expect guard-fire 0 "PASS"
case_of control-passed 1 "$row" 0 "$on" "$row"
expect control-passed 1 "although a booking"
case_of setup-in-control 1 "$row" 3 "$on" "two actors: SETUP: development source did not print settings"
expect setup-in-control 1 "setup failure"
case_of setup-in-positive 3 "two actors: SETUP: development source did not print settings" 2 "$on" "$guard"
expect setup-in-positive 1 "setup failure"
case_of positive-fired-guard 2 "$row" 2 "$on" "$guard"
expect positive-fired-guard 1 "positive run fired the guard"
case_of positive-failed 1 "two actors: FAIL: alice folded another request" 2 "$on" "$row" "$guard"
expect positive-failed 1 "failed before the control"
case_of control-off 1 "$row" 2 "$row" "$guard"
expect control-off 1 "never engaged"
case_of two-guards 1 "$row" 2 "$on" "$row" "$guard" "$guard"
expect two-guards 1 "single guard diagnostic"
case_of control-row-failure 1 "$row" 1 "$on" "$row" "two actors: FAIL: the foreign-open control passed"
expect control-row-failure 1 "single guard diagnostic"
echo "two-actors-control.test: all cases passed"
