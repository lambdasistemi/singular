#!/usr/bin/env bash
#
# Require a Conventional Commit subject on every non-merge commit in a range
# (#195). release-please classifies a change by the subject's type; a subject
# like "Singular wire: …" matches no type, so the work silently drops out of
# the changelog — nine commits vanished from v0.7.0 that way. This gate makes
# the grammar a merge-blocking check instead of a changelog surprise.
#
# Usage: tools/commit-subjects.sh <base>..<head>
#
# Merge commits are exempt: GitHub writes their "Merge pull request #N from
# …" subjects, the grammar is not the author's to choose, and a gate that
# failed on every PR merge would be turned off within a day.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <base>..<head>" >&2
  exit 2
fi
range="$1"

commits="$(git log --format='%h%x09%P%x09%s' "$range")" || {
  echo "commit-subjects.sh: cannot resolve range $range" >&2
  exit 2
}

rc=0
checked=0
exempt=0
while IFS=$'\t' read -r sha parents subject; do
  # A parent list with a space means two or more parents: a merge commit.
  case "$parents" in
    *' '*)
      exempt=$((exempt + 1))
      continue
      ;;
  esac
  checked=$((checked + 1))
  if ! grep -Eq '^[a-z]+(\([^)]+\))?!?: .+' <<<"$subject"; then
    echo "$sha $subject" >&2
    rc=1
  fi
done <<<"$commits"

if [ "$rc" -eq 0 ]; then
  echo "commit-subjects.sh: ok ($checked non-merge commit(s) Conventional, $exempt merge(s) exempt)"
else
  echo "commit-subjects.sh: the commits above have no Conventional Commit type; release-please cannot classify them (#195)" >&2
fi
exit "$rc"
