#!/usr/bin/env bash
#
# Self-test for tools/commit-subjects.sh (#195).
#
# Builds a throwaway git repository in a temp directory and asserts both
# directions, in order:
#   1. a stack whose first and last commits carry Conventional subjects and
#      whose middle commit reads "Singular wire: …" (the grammar that made
#      nine commits invisible to release-please in v0.7.0) FAILS the checker,
#      which must name that middle commit's short SHA and subject;
#   2. the same stack with the middle subject corrected to "feat: …" PASSES;
#   3. a stack containing a real merge commit (git merge --no-ff) with
#      GitHub's own "Merge pull request #N from x/y" subject PASSES — merge
#      commits are exempt, because rejecting them would turn the gate off.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/commit-subjects.sh"

fail() {
  echo "commit-subjects.test.sh: $*" >&2
  exit 1
}

[ -x "$script" ] || fail "missing executable $script"

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

# The checker reads the range through git, so it must run with the throwaway
# repository as its working directory.
run_check() {
  ( cd "$repo" && bash "$script" "$1" 2>&1 )
}

repo="$workdir/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name "test"
git -C "$repo" config user.email "test@example.invalid"
git -C "$repo" commit -q --allow-empty -m "feat: seed the stack"

# The stack under test: Conventional bookends around the malformed middle.
git -C "$repo" commit -q --allow-empty -m "feat: open the stack"
git -C "$repo" commit -q --allow-empty -m "Singular wire: carry the edge tag beside Operation"
git -C "$repo" commit -q --allow-empty -m "fix: close the stack"

base="$(git -C "$repo" rev-parse HEAD~3)"
mid="$(git -C "$repo" rev-parse --short HEAD~1)"
head="$(git -C "$repo" rev-parse HEAD)"

echo "control: a non-Conventional middle subject must fail, naming that commit"
set +e
out="$(run_check "$base..$head")"
rc=$?
set -e
[ "$rc" -ne 0 ] \
  || fail "checker passed a stack whose middle subject has no Conventional type"
echo "$out" | grep -q "$mid" \
  || fail "checker failure does not name the offending commit $mid:
$out"
echo "$out" | grep -q "Singular wire: carry the edge tag beside Operation" \
  || fail "checker failure does not quote the offending subject:
$out"

echo "control: the same stack with the middle subject corrected must pass"
git -C "$repo" reset -q --soft HEAD~2
git -C "$repo" commit -q --allow-empty -m "feat: carry the edge tag beside Operation"
head="$(git -C "$repo" rev-parse HEAD)"
set +e
out="$(run_check "$base..$head")"
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "checker rejected a stack whose every subject is Conventional:
$out"

echo "control: a real merge commit must be exempt"
git -C "$repo" checkout -q -b side "$base"
git -C "$repo" commit -q --allow-empty -m "feat: side work"
git -C "$repo" checkout -q main
git -C "$repo" merge -q --no-ff side -m "Merge pull request #1 from x/y"
head="$(git -C "$repo" rev-parse HEAD)"
# The range now spans the merge and the commits on both of its parents.
set +e
out="$(run_check "$base..$head")"
rc=$?
set -e
[ "$rc" -eq 0 ] \
  || fail "checker rejected a range whose only irregular commit is a merge:
$out"

echo "commit-subjects.test.sh: all assertions passed"
