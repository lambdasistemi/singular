#!/usr/bin/env bash
# House Fourmolu application/check over the discovered Haskell extent
# (issue #278 S2).
#
# ONE configuration — the committed fourmolu.yaml at the repository root —
# is passed explicitly to every invocation, so a missing configuration
# fails loudly instead of silently falling back to Fourmolu's defaults
# (no orphan default check). Discovery is dynamic: every Haskell source
# under the two Haskell trees, with no directory exclusions — a new file
# or component directory is covered with no list to edit, and an empty
# discovery fails closed. The same script applies (inplace), checks
# (check) and is exercised by the controls (tools/format_controls.sh):
# one extent, one configuration, one pinned tool.
#
# The off-chain lint app and the conformance format-check app carry the
# same configuration over each tree in their Nix source (store-copy)
# contexts; this script is the whole-tree checkout-context carrier that
# `just format`, `just format-check` and `just ci` run.
#
# usage: format_haskell.sh <check|inplace> [ROOT]   (default ROOT: the
#        repository root; the controls pass a scratch copy)
# Run within nix develop: fourmolu comes from the development shell — the
# exact pinned binary the off-chain lock resolves.
set -euo pipefail

mode=${1:-}
target=${2:-}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
[ -n "$target" ] || target=$root

case "$mode" in
    check | inplace) ;;
    *)
        echo "usage: format_haskell.sh <check|inplace> [ROOT]" >&2
        exit 2
        ;;
esac

command -v fourmolu >/dev/null 2>&1 || {
    echo "format: fourmolu is not on PATH — run within nix develop (the pinned house formatter)" >&2
    exit 1
}

[ -r "$target/fourmolu.yaml" ] || {
    echo "format: the house fourmolu.yaml is missing under $target — refusing to run with Fourmolu defaults" >&2
    exit 1
}

files=$(cd "$target" && find offchain conformance -name '*.hs' -type f | sort)
[ -n "$files" ] || {
    echo "format: discovered no Haskell sources under $target" >&2
    exit 1
}
count=$(printf '%s\n' "$files" | wc -l)
echo "format: $count discovered Haskell sources, house fourmolu.yaml, mode=$mode" >&2

cd "$target"
fourmolu --config fourmolu.yaml --ghc-opt=-XImportQualifiedPost -m "$mode" $files
