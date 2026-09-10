#!/usr/bin/env bash
# Naming wire vector suite (issue #45) — compile with the dev-shell GHC and run.
# Pure base + bytestring: no cabal, no package index, no network (D-011
# logic). Run from anywhere; CI entry point and local receipt producer:
#
#   nix develop ./offchain --quiet --command bash offchain/naming/run-suite.sh
# (from the repository root; the codec itself lives at
# offchain/naming/src since issue #51 moved it inside the offchain
# flake root — the suite stays a direct-ghc unit suite.)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
ghc -O0 -Wall -i"$DIR/src" -outputdir "$OUT/obj" \
  --make "$DIR/test/Main.hs" -o "$OUT/naming-wire-test" 1>&2
"$OUT/naming-wire-test"
