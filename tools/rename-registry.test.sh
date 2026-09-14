#!/usr/bin/env bash
#
# Self-test for tools/rename-registry.sh (#108).
#
# Drives the rename twice on a throwaway detached worktree cut from main
# and asserts, in order:
#   1. the first run completes and its gate passes on a clean main;
#   2. the second run is a no-op (index state and tracked file contents
#      unchanged) and its gate passes again;
#   3. the gate alone FAILS when a stray MPFS_BLUEPRINT line is planted in
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

echo "run 1: rename a clean main"
out="$(run_rename)" || fail "first run failed"
echo "$out" | tail -n 1 | grep -qx 'rename-registry.sh: complete' \
  || fail "first run did not complete cleanly"

echo "run 2: no-op and the gate passes"
before="$(snapshot)"
run_rename >/dev/null || fail "second run failed"
after="$(snapshot)"
[ "$before" = "$after" ] || fail "second run changed the tree"

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
