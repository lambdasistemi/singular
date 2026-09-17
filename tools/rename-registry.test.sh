#!/usr/bin/env bash
#
# Self-test for tools/rename-registry.sh (#108).
#
# Drives the rename twice on a throwaway detached worktree cut from main
# and asserts, in order:
#   1. seeded whole-word MPFS mentions in a tracked .lean and a tracked
#      .html file are rewritten to the expected registry wording (positive;
#      forbids passing because no matching input existed);
#   2. the first run completes and its gate passes on a clean main;
#   3. the second run is a no-op (index state and tracked file contents
#      unchanged) and its gate passes again;
#   4. the gate alone FAILS when residuals are seeded in a tracked .lean
#      and a tracked .html file, naming both paths (negative; a setup or
#      missing-file failure is not the control);
#   5. the gate alone FAILS when a stray MPFS_BLUEPRINT line is planted in
#      a tracked .sh file — the kind of stray the pre-#108 scan missed.
#
# The rename tool and this test are exempt from the scan and the gate: they
# must keep naming the product they rename.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$(cd "$here/.." && git rev-parse --show-toplevel)"
script="$src/tools/rename-registry.sh"

fail() {
  echo "rename-registry.test.sh: $*" >&2
  exit 1
}

# The script's identity diff requires an origin/main ref; depth-1 CI
# checkouts (nix develop -c just ci) do not have one, so materialize it at
# the commit under test. A normal checkout uses the real origin/main.
base=origin/main
git -C "$src" rev-parse --verify --quiet "$base" >/dev/null || base=HEAD
git -C "$src" rev-parse --verify --quiet origin/main >/dev/null \
  || git -C "$src" update-ref refs/remotes/origin/main "$base"

workdir="$(mktemp -d)"
scratch="$workdir/tree"
cleanup() {
  git -C "$src" worktree remove --force "$scratch" >/dev/null 2>&1 || true
  rm -rf "$workdir"
}
trap cleanup EXIT

git -C "$src" worktree add --detach "$scratch" "$base" >/dev/null

# Index state plus the content of every tracked file: anything a re-run
# moves, rewrites or re-stamps shows up here.
snapshot() {
  ( cd "$scratch" \
    && git ls-files -s \
    && echo '--- contents ---' \
    && git ls-files -z | xargs -0 sha256sum )
}

run_rename() {
  ( cd "$scratch" && "$script" "$@" )
}

echo "positive: seeded MPFS in tracked .lean and .html must be rewritten"
pos_lean="$scratch/lean/Singular/Model.lean"
pos_html="$scratch/simulator/index.html"
[ -f "$pos_lean" ] || fail "positive setup: $pos_lean missing"
[ -f "$pos_html" ] || fail "positive setup: $pos_html missing"
printf '%s\n' '-- MPFS positive control lean' >> "$pos_lean"
printf '%s\n' '<!-- MPFS positive control html -->' >> "$pos_html"
grep -q 'MPFS positive control lean' "$pos_lean" \
  || fail "positive setup: lean seed missing"
grep -q 'MPFS positive control html' "$pos_html" \
  || fail "positive setup: html seed missing"
set +e
pos_out="$(run_rename 2>&1)"
pos_rc=$?
set -e
lean_ok=0
html_ok=0
grep -q 'registry positive control lean' "$pos_lean" && lean_ok=1 || true
grep -q 'registry positive control html' "$pos_html" && html_ok=1 || true
[ "$lean_ok" -eq 1 ] && [ "$html_ok" -eq 1 ] \
  || fail "positive: tracked rewrite missing lean=$lean_ok html=$html_ok (expected both 1)"
grep -q 'MPFS positive control lean' "$pos_lean" \
  && fail "positive: seeded MPFS remains in .lean" || true
grep -q 'MPFS positive control html' "$pos_html" \
  && fail "positive: seeded MPFS remains in .html" || true
[ "$pos_rc" -eq 0 ] || fail "positive: rename failed on seeded tree"
# Reset to a clean main for the canonical run 1 / run 2 below; the positive
# scratch has already proven the rewrite and must not pollute the no-op check.
git -C "$src" worktree remove --force "$scratch" >/dev/null
git -C "$src" worktree add --detach "$scratch" "$base" >/dev/null

echo "run 1: rename a clean main"
out="$(run_rename)" || fail "first run failed"
echo "$out" | tail -n 1 | grep -qx 'rename-registry.sh: complete' \
  || fail "first run did not complete cleanly"

echo "run 2: no-op and the gate passes"
before="$(snapshot)"
run_rename >/dev/null || fail "second run failed"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "second run changed the tree"

echo "control: seeded residuals in tracked .lean and .html must fail the gate naming both"
neg_lean="$scratch/simulator/formal/Model.lean"
neg_html="$scratch/simulator/page-body.html"
[ -f "$neg_lean" ] || fail "negative setup: $neg_lean missing"
[ -f "$neg_html" ] || fail "negative setup: $neg_html missing"
printf '%s\n' '-- MPFS residual negative control lean' >> "$neg_lean"
printf '%s\n' '<!-- MPFS residual negative control html -->' >> "$neg_html"
grep -q 'MPFS residual negative control lean' "$neg_lean" \
  || fail "negative setup: lean seed missing"
grep -q 'MPFS residual negative control html' "$neg_html" \
  || fail "negative setup: html seed missing"
set +e
neg_out="$(run_rename --gate-only 2>&1)"
neg_rc=$?
set -e
[ "$neg_rc" -ne 0 ] || fail "gate passed despite seeded .lean/.html residuals"
echo "$neg_out" | grep -q 'simulator/formal/Model.lean' \
  || fail "gate failure does not name the seeded .lean file"
echo "$neg_out" | grep -q 'simulator/page-body.html' \
  || fail "gate failure does not name the seeded .html file"
# Remove only the seeded residuals so the following .sh control proves its
# own file in isolation.
sed -i '/MPFS residual negative control/d' "$neg_lean" "$neg_html"
grep -q 'MPFS residual negative control' "$neg_lean" \
  && fail "negative cleanup failed for .lean" || true
grep -q 'MPFS residual negative control' "$neg_html" \
  && fail "negative cleanup failed for .html" || true

echo "control: stray MPFS_BLUEPRINT in a .sh must fail the gate"
planted="$scratch/offchain/naming/run-suite.sh"
printf 'export MPFS_BLUEPRINT=/tmp/mpfs-blueprint.json\n' >> "$planted"
set +e
gate_out="$(run_rename --gate-only 2>&1)"
gate_rc=$?
set -e
[ "$gate_rc" -ne 0 ] || fail "gate passed despite the planted stray"
echo "$gate_out" | grep -q 'offchain/naming/run-suite.sh' \
  || fail "gate failure does not name the stray file"

echo "rename-registry.test.sh: all assertions passed"
