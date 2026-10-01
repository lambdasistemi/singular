#!/usr/bin/env bash
# One dedicated conformance row as its CI step runs it (#287).
#
# usage: dedicated-row.sh ROW -- COMMAND...
#
# COMMAND is the row invocation; it receives --receipts-dir
# "$CONFORMANCE_DEDICATED_RECEIPTS/ROW". The receipts root is published to the
# workflow environment before the row runs, so the always-run upload collects
# a failing row's receipts and replay index too. The row's exit status is the
# script's.
set -uo pipefail

row="${1:?usage: dedicated-row.sh ROW -- COMMAND...}"
shift
if [ "${1:-}" != "--" ]; then
  echo "usage: dedicated-row.sh ROW -- COMMAND..." >&2
  exit 64
fi
shift

root="${CONFORMANCE_DEDICATED_RECEIPTS:?CONFORMANCE_DEDICATED_RECEIPTS must name the receipts root}"
receipts="$root/$row"
mkdir -p "$receipts"
[ -z "${GITHUB_ENV:-}" ] || printf 'CONFORMANCE_DEDICATED_RECEIPTS=%s\n' "$root" >>"$GITHUB_ENV"
echo "$row receipts: $receipts"

"$@" --receipts-dir "$receipts"
rc=$?
echo "$row exit: $rc"
exit "$rc"
