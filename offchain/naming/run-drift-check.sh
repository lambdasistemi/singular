#!/usr/bin/env bash
# vector-drift-check (issue #49) — is the vendored v0.2.0 wire copy
# still what the live corpus ships?
#
# Compares offchain/naming/src/Naming/Wire/Vectors.hs (the PINNED copy;
# the pin is deliberate, D-016) against the corresponding rows of
# lean/lifecycle-corpus.json (epic 15's LIVE corpus). Divergence is
# reported, never resolved: this check does not update the vendored
# bytes and does not re-point the suite at the live file — a human
# decides when the live corpus has moved.
#
# The check itself is offchain/naming/drift/Main.hs: pure base +
# bytestring, compiled with the dev-shell GHC exactly like the wire
# suite (run-suite.sh) — no cabal, no package index, no network, no jq.
#
# Usage (paths default to the repository root):
#   bash offchain/naming/run-drift-check.sh [PATH-TO-Vectors.hs] [PATH-TO-corpus.json]
#
# A vectors file outside the repository must keep its module layout:
# place the copy at <dir>/Naming/Wire/Vectors.hs and pass
# <dir>/Naming/Wire/Vectors.hs as the first argument.
#
# Exit codes (the check's own, forwarded): 0 = in agreement,
# 1 = drift reported, 2 = the check itself could not run.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
VECTORS="${1:-$ROOT/offchain/naming/src/Naming/Wire/Vectors.hs}"
CORPUS="${2:-$ROOT/lean/lifecycle-corpus.json}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SRC="$(cd "$(dirname "$VECTORS")/../.." && pwd)"
ghc -O0 -Wall -i"$SRC" -outputdir "$OUT/obj" \
  --make "$DIR/drift/Main.hs" -o "$OUT/drift-check" 1>&2
set +e
"$OUT/drift-check" "$VECTORS" "$CORPUS"
status=$?
set -e
echo "exit_status: $status"
exit "$status"
