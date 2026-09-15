#!/usr/bin/env bash
# Compute the actual changed set before entering the Git-free Nix builder.
set -euo pipefail
cd "$(dirname "$0")"
base=$(git merge-base HEAD "${1:?usage: lint-changes.sh BASE [--select-only OUTPUT]}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Complete both commands first: process-substitution failures must not turn
# a missing base/diff into an apparently valid empty set.
git diff --name-only --diff-filter=ACMR -z --relative "$base" -- lib app test e2e-test > "$work/paths"
git ls-files --others --exclude-standard -z -- lib app test e2e-test >> "$work/paths"
printf '[\n' > "$work/files.json"
separator=''
declare -A seen=()
while IFS= read -r -d '' file; do
    [[ "$file" == *.hs ]] || continue
    [[ "$file" =~ ^[A-Za-z0-9_./-]+$ && -f "$file" ]] || { echo "Invalid changed source: $file" >&2; exit 1; }
    [[ -z "${seen[$file]:-}" ]] || continue
    seen[$file]=1
    printf '%s  "%s"' "$separator" "$file" >> "$work/files.json"
    separator=$',\n'
done < "$work/paths"
printf '\n]\n' >> "$work/files.json"
if [[ "${2:-}" == --select-only ]]; then
    cp "$work/files.json" "${3:?selection output is required}"
    exit 0
fi
[[ $# == 1 ]] || { echo "Unexpected lint selection arguments" >&2; exit 1; }
cat "$work/files.json"
export SINGULAR_LINT_FLAKE="git+file://$(git rev-parse --show-toplevel)?dir=offchain"
export SINGULAR_LINT_SELECTION="$work/files.json"
nix build -L --no-link --impure --expr '
  let flake = builtins.getFlake (builtins.getEnv "SINGULAR_LINT_FLAKE");
      files = builtins.fromJSON (builtins.readFile (builtins.getEnv "SINGULAR_LINT_SELECTION"));
  in flake.checks.${builtins.currentSystem}.lint.override { inherit files; }
'
