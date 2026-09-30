#!/usr/bin/env bash
# One dedicated conformance row as its CI step runs it (#287).
#
# usage: dedicated-row.sh ROW -- COMMAND...
#
# COMMAND is the row invocation; it receives --receipts-dir
# "$CONFORMANCE_DEDICATED_RECEIPTS/ROW". The row's exit status is the
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
echo "$row receipts: $receipts"

"$@" --receipts-dir "$receipts"
rc=$?
echo "$row exit: $rc"
exit "$rc"
