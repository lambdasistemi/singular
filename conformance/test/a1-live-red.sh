#!/usr/bin/env bash
set -euo pipefail

: "${A1_CABAL_PROJECT:?set A1_CABAL_PROJECT to the runtime-root Cabal project file}"
: "${A1_EVIDENCE_DIR:?set A1_EVIDENCE_DIR to the runtime-root evidence directory}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root/conformance"

log="$A1_EVIDENCE_DIR/A1-live-red.log"
receipts="$(mktemp -d "$A1_EVIDENCE_DIR/A1-live-red-receipts.XXXXXX")"
blueprint="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"

set +e
REGISTRY_BLUEPRINT="$blueprint" \
    nix develop .#default --command cabal run \
        --project-file="$A1_CABAL_PROJECT" \
        conformance:exe:fold-budget-regression -- \
        --receipts-dir "$receipts" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e

if [[ $status -eq 0 ]]; then
    printf '%s\n' "A1 RED expected the base interpreter to fail, but it exited 0" >&2
    exit 1
fi

for marker in \
    'A1 node evaluation map:' \
    'A1 test-only fallback:' \
    'A1 fixed fallback refused:' \
    'model and chain disagree for insertActive'; do
    if ! grep -Fq "$marker" "$log"; then
        printf 'A1 RED output omitted required evidence: %s\n' "$marker" >&2
        exit 1
    fi
done

printf 'A1 RED confirmed; exit=%s log=%s receipts=%s\n' "$status" "$log" "$receipts"
