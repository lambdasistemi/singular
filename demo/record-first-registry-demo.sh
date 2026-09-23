#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

# Fail before recording if the simulated journey disagrees with its assertions.
node demo/first-registry-demo.mjs --fast >/dev/null

cast=docs/assets/video/first-registry-model-demo.cast
mkdir -p "$(dirname "$cast")"
SHELL=/bin/bash DEMO_PAUSE_MS=3500 \
  nix shell github:NixOS/nixpkgs/117cc7f94e8072499b0a7aa4c52084fa4e11cc9b#asciinema \
  -c asciinema rec --overwrite --quiet --cols 80 --rows 24 \
  --env SHELL,TERM --title 'Singular D-01 registry model rehearsal' \
  -c 'node demo/first-registry-demo.mjs' "$cast"

node demo/validate-first-registry-cast.mjs "$cast"
