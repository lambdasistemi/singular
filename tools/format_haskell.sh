#!/usr/bin/env bash
# House Fourmolu application/check over the discovered Haskell extent
# (issue #278 S2).
#
# ONE configuration — the committed fourmolu.yaml at the repository root —
# is passed explicitly to every invocation, so a missing configuration
# fails loudly instead of silently falling back to Fourmolu's defaults
# (no orphan default check). Discovery is the tracked/source projection,
# mirroring the code inventory's two contexts (audit findings F001/F002):
#
#   - a Git checkout reads its extent from the index: every TRACKED *.hs
#     file wherever it lives — a newly added component tree is covered
#     with nothing to edit — while ignored untracked build noise
#     (offchain/dist-newstyle and friends) never enters the set, and a
#     tracked file stays in the set even when an ignore pattern matches
#     its path;
#   - a Git-free source (Nix store copy, scratch export) has no index to
#     read and no untracked noise to skip: every present *.hs file is
#     repository source.
#
# Both contexts fail closed on an empty extent. The same script applies
# (inplace), checks (check) and is exercised by the controls
# (tools/format_controls.sh): one extent, one configuration, one pinned
# tool — no directory exclusions anywhere.
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
target=$(cd "$target" && pwd -P)

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

# The tracked/source projection (see the header). A repository root is its
# own Git top level; a scratch copy is either Git-free or carries its own
# initialized index. Anything that is merely INSIDE some unrelated
# repository is treated as Git-free and walked, never silently read from
# that outer index.
top=$(git -C "$target" rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$target" ]; then
  context="git-checkout (tracked files from the index; untracked noise skipped)"
  files=$(git -C "$target" ls-files --cached -- '*.hs' | sort)
else
  context="git-free source (every present file is repository source)"
  files=$(cd "$target" && find . -name '*.hs' -type f | sed 's|^\./||' | sort)
fi
[ -n "$files" ] || {
  echo "format: discovered no Haskell sources under $target ($context)" >&2
  exit 1
}
count=$(printf '%s\n' "$files" | wc -l)
echo "format: $count discovered Haskell sources, $context, house fourmolu.yaml, mode=$mode" >&2

cd "$target"
mapfile -t file_list <<<"$files"
fourmolu --config fourmolu.yaml --ghc-opt=-XImportQualifiedPost -m "$mode" "${file_list[@]}"
