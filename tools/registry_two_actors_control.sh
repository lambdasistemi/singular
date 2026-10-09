#!/usr/bin/env bash
# registry-two-actors control (#381): the foreign-open access check, shown
# firing on a real booking aimed at another actor's state root.
#
# usage: registry_two_actors_control.sh BASE-WORKDIR HARNESS...
#
# HARNESS... is the journey invocation without its work directory; the
# wrapper appends one fresh work directory per leg. The positive leg must
# not fire the guard and must not fail setup; the control leg, run with
# SINGULAR_TWO_ACTOR_CONTROL=foreign-open, must end failed at the guard
# with status 2 and the single guard diagnostic naming the path. A pass,
# a setup failure or any other failure of the control leg fails this
# control and is named. The raw legs stay visible in the job log.
set -euo pipefail

[ "$#" -ge 2 ] || {
  echo "usage: $0 BASE-WORKDIR HARNESS..." >&2
  exit 2
}
base="$1"
shift
positive_out="$(mktemp "${RUNNER_TEMP:-/tmp}/two-actors-positive.XXXXXX")"
control_out="$(mktemp "${RUNNER_TEMP:-/tmp}/two-actors-control.XXXXXX")"
# shellcheck disable=SC2329 # the EXIT trap below invokes this
release_out() {
  local code=$?
  trap - EXIT
  for out in "$positive_out" "$control_out"; do
    if [ -n "${out:-}" ] && [ -e "$out" ]; then
      chmod u+rwx "$out" 2>/dev/null || true
      rm -f "$out" || true
    fi
  done
  exit "$code"
}
trap release_out EXIT
fail() {
  echo "two-actors-control: FAIL: $*" >&2
  echo "two-actors-control: FAIL: $*"
  exit 1
}

mkdir -p "$base/positive" "$base/control"
positive_status=0
"$@" "$base/positive/journey" >"$positive_out" 2>&1 || positive_status=$?
echo "two-actors-control: the positive run exited $positive_status"
if grep -q '^two actors: GUARD: ' "$positive_out"; then
  fail "the positive run fired the guard: $(grep '^two actors: GUARD: ' "$positive_out" | head -n 1)"
fi
[ "$positive_status" -ne 2 ] || fail "the positive run fired the guard (exit 2)"
if grep -q '^two actors: SETUP: ' "$positive_out"; then
  fail "setup failure, not the access check: $(grep '^two actors: SETUP: ' "$positive_out" | head -n 1)"
fi
[ "$positive_status" -ne 3 ] || fail "setup failure, not the access check (exit 3)"
if grep -q '^two actors: FAIL: ' "$positive_out"; then
  fail "the positive run failed before the control: $(grep '^two actors: FAIL: ' "$positive_out" | head -n 1)"
fi
if [ "$positive_status" -ne 0 ] && [ "$positive_status" -ne 1 ]; then
  fail "the positive run ended $positive_status, expected 0 or 1"
fi

control_status=0
SINGULAR_TWO_ACTOR_CONTROL=foreign-open "$@" "$base/control/journey" >"$control_out" 2>&1 || control_status=$?
echo "two-actors-control: the foreign-open run exited $control_status"
grep -qx "two actors: foreign-open control is on" "$control_out" \
  || fail "the control never engaged (exit $control_status)"
if grep -q '^two actors: SETUP: ' "$control_out"; then
  fail "setup failure, not the access check: $(grep '^two actors: SETUP: ' "$control_out" | head -n 1)"
fi
[ "$control_status" -ne 3 ] || fail "setup failure, not the access check (exit 3)"
[ "$control_status" -ne 0 ] || fail "the control passed although a booking aimed at another actor's state root"
guards="$(grep -c '^two actors: GUARD: ' "$control_out" || true)"
[ "$guards" -eq 1 ] || fail "expected the single guard diagnostic, found $guards (exit $control_status)"
[ "$control_status" -eq 2 ] || fail "expected exit 2 for the guard failure, got $control_status"
echo "two-actors-control: PASS — the foreign-open run failed at the guard: $(grep "^two actors: GUARD: " "$control_out")"
