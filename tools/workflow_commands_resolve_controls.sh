#!/usr/bin/env bash
# workflow-commands-resolve-controls: the resolver catches what it claims.
#
# The controls require the clean tree to pass, a planted workflow step
# naming a nonexistent app to fail, and a planted external reference to a
# nonexistent registry package to fail. They never edit the tracked tree.
# Exit 0: the clean tree passes and both plants fail. Exit 1: the resolver
# missed a plant or refused the clean tree. Exit 2: the harness failed.
#
# Usage: workflow_commands_resolve_controls.sh [ROOT] (default: the working tree).
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
check="$(cd "$(dirname "$0")" && pwd)/workflow_commands_resolve.sh"
[ -x "$check" ] || {
  echo "workflow-commands-resolve-controls: no resolver $check" >&2
  exit 2
}
[ -d "$root/.github/workflows" ] || {
  echo "workflow-commands-resolve-controls: no workflows under $root" >&2
  exit 2
}

if ! clean_out=$("$check" "$root" 2>&1); then
  echo "workflow-commands-resolve-controls: resolver refused the clean tree" >&2
  printf '%s\n' "$clean_out" >&2
  exit 1
fi
# The single clean run's summary reaches the log; the tree is not resolved twice.
printf '%s\n' "$clean_out"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
plant="$work/plant.yml"
cat >"$plant" <<'EOF'
jobs:
  plant:
    runs-on: nixos
    steps:
      - run: nix run --quiet .#this-app-does-not-exist-xyz
EOF
grep -q 'this-app-does-not-exist-xyz' "$plant" || {
  echo "workflow-commands-resolve-controls: plant did not apply" >&2
  exit 2
}
if out=$("$check" "$root" "$plant" 2>&1); then
  echo "workflow-commands-resolve-controls: resolver MISSED the planted app" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
case "$out" in
  *"this-app-does-not-exist-xyz"*) ;;
  *)
    echo "workflow-commands-resolve-controls: failure names no plant" >&2
    printf '%s\n' "$out" >&2
    exit 1
    ;;
esac

plant_ext="$work/plant-external.yml"
cat >"$plant_ext" <<'EOF'
jobs:
  plant:
    runs-on: nixos
    steps:
      - run: nix run --quiet nixpkgs#this-pkg-does-not-exist-xyz
EOF
grep -q 'this-pkg-does-not-exist-xyz' "$plant_ext" || {
  echo "workflow-commands-resolve-controls: external plant did not apply" >&2
  exit 2
}
if out=$("$check" "$root" "$plant_ext" 2>&1); then
  echo "workflow-commands-resolve-controls: resolver MISSED the planted external package" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
case "$out" in
  *"this-pkg-does-not-exist-xyz"*) ;;
  *)
    echo "workflow-commands-resolve-controls: failure names no external plant" >&2
    printf '%s\n' "$out" >&2
    exit 1
    ;;
esac
echo "workflow-commands-resolve-controls: PASS"
