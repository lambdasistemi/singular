#!/usr/bin/env bash
set -euo pipefail

# Reproduce old behavior from immutable source, never from the repaired model.
repo_root=$(git rev-parse --show-toplevel)
model_revision=6efe1f119a2332484e690b4c128c4bc5fd4d689b
lean --version | grep -q 'version 4.25.0'
repro_dir=$(mktemp -d)
trap 'rm -rf -- "$repro_dir"' EXIT
mkdir -p "$repro_dir/Singular"
git -C "$repo_root" show "$model_revision:lean/Singular/Model.lean" >"$repro_dir/Singular/Model.lean"
cd "$repro_dir"
lean -o Singular/Model.olean Singular/Model.lean
LEAN_PATH="$repro_dir" lean --run "$repo_root/specs/494-protected-rejection/HistoricalCounterexample.lean"
