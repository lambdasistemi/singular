#!/usr/bin/env bash
# demo1-two-actor-control (#419, #437): the two-actor access check, shown
# failing a complete Demo 1 run.
#
# usage: demo1_two_actor_control.sh REPO-ROOT
#
# Runs the whole packaged Demo 1 check (demo1_cli_check.sh) with
# DEMO1_TWO_ACTOR_DELIBERATE_OPEN=1, so Bob's traced fold process opens
# Alice's journal before it folds. That run must fail, and fail only
# at the access check: exit 1, the journey's one failure being
# "bob's fold accessed alice's directory", after the control was switched
# on and Bob's fold itself succeeded. Any other outcome fails this control
# and is named: the run passing, a setup failure, or another failure.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$1"
check="${DEMO1_CLI_CHECK:?demo1-two-actor-control needs DEMO1_CLI_CHECK}"
fail() {
  echo "demo1-two-actor-control: FAIL: $*" >&2
  exit 1
}

out="$(mktemp "${RUNNER_TEMP:-/tmp}/demo1-two-actor-control.XXXXXX")"
# The journey's own scratch is removed by that check. This file is the
# copy the verdict is read from. DEMO1_KEEP_SCRATCH=1 keeps it and names it.
# shellcheck disable=SC2329 # the EXIT trap below invokes this
release_out() {
  local code=$?
  trap - EXIT
  if [ -n "${out:-}" ] && [ -e "$out" ]; then
    if [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
      echo "kept scratch: $out" >&2
    else
      chmod u+rwx "$out" 2>/dev/null || true
      rm -rf "$out" || true
      if [ -e "$out" ]; then
        echo "scratch remains: $out" >&2
        code=1
      fi
    fi
  fi
  exit "$code"
}
trap release_out EXIT
status=0
# The raw run stays visible in the job log and is judged from the copy.
DEMO1_TWO_ACTOR_DELIBERATE_OPEN=1 bash "$check" "$root" 2>&1 | tee "$out" || status="${PIPESTATUS[0]}"

echo "demo1-two-actor-control: the run with the deliberate open exited $status"
[ "$status" -ne 0 ] || fail "the run passed although bob's fold process opened alice's journal"
if grep -q '^journey: SETUP: ' "$out"; then
  fail "setup failure, not the access check: $(grep '^journey: SETUP: ' "$out" | head -n 1)"
fi
grep -qx "journey: two actors: the deliberate open control is on; bob's process opens alice's journal" "$out" \
  || fail "the run never reached the two-actor stage with the control on (exit $status)"
grep -q '^journey: two-fold: success' "$out" \
  || fail "bob's fold itself did not succeed, so the access check was not what failed"
failures="$(grep -c '^journey: FAIL: ' "$out" || true)"
[ "$failures" -eq 1 ] || fail "expected exactly one journey failure, found $failures"
grep -q "^journey: FAIL: bob's fold accessed alice's directory: .*journal\.jsonl" "$out" \
  || fail "the run failed elsewhere: $(grep '^journey: FAIL: ' "$out")"
grep -qE '^verify-release: REFUSED command-failed: the journey exited 1(;.*)?$' "$out" \
  || fail "the release verification did not report the journey's failure"
[ "$status" -eq 1 ] || fail "expected exit 1 for the access-check failure, got $status"
echo "demo1-two-actor-control: PASS — the complete Demo 1 run failed at the access check: $(grep "^journey: FAIL: " "$out")"
