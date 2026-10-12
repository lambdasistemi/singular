#!/usr/bin/env bash
# declared-checks-issue-states: the read-only issue-state query of the census.
#
# Usage: declared_checks_issue_states.sh ROOT OUTPUT
#   Reads the pending-issue numbers from ROOT's declared-not-hosted list and
#   writes `<number> <open|closed>` lines to OUTPUT, one per number, through
#   a read-only query of the repository's issues. With no pending entry the
#   output is empty and the run still passes.
#
# Authentication travels only through the environment: gh reads GH_TOKEN (or
# GITHUB_TOKEN); the script binds no credential, stores none, and reads no
# credential file itself. The hosted job binds its read-only workflow token
# as GH_TOKEN in the step's environment. A failed query is a setup failure
# (exit 2, never a verdict, never a silent pass): each acquisition step
# carries its own setup failure tested in this shell, never in a subshell.
# The wrapper owns a scratch directory created and removed on every exit;
# OUTPUT itself is the caller's deliverable, not scratch. No process is
# stopped.
set -euo pipefail

setup_fail() {
  echo "declared-checks-issue-states: SETUP: $1" >&2
  exit 2
}

[ "$#" -eq 2 ] || setup_fail "usage: $0 ROOT OUTPUT"
root="$1"
output="$2"
[ -d "$root" ] || setup_fail "$root is not a directory"
list="$root/tools/declared_checks_not_hosted.list"
[ -f "$list" ] || setup_fail "no declared-not-hosted list $list"

work="$(mktemp -d)" || {
  echo "declared-checks-issue-states: SETUP: cannot create a scratch directory" >&2
  exit 2
}
trap 'rm -rf "$work"' EXIT

sed -nE 's/^[^#].*pending wiring: #([0-9]+),.*/\1/p' "$list" | sort -nu >"$work/numbers.txt" \
  || setup_fail "reading the pending issue numbers from $list"
: >"$output" || setup_fail "cannot write $output"
while IFS= read -r number || [ -n "$number" ]; do
  [ -n "$number" ] || continue
  state=$(gh issue view "$number" --repo lambdasistemi/singular --json state -q .state 2>"$work/gh.err") \
    || setup_fail "querying the state of issue #$number (gh reads GH_TOKEN; an unauthenticated run cannot query)"
  state="${state,,}"
  case "$state" in
    open | closed) ;;
    *) setup_fail "the query answered '$state' for issue #$number (expected open or closed)" ;;
  esac
  printf '%s %s\n' "$number" "$state" >>"$output" || setup_fail "writing $output"
done <"$work/numbers.txt"
echo "declared-checks-issue-states: PASS"
