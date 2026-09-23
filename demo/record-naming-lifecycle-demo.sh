#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
node demo/naming-lifecycle-demo.mjs --fast >/dev/null
cast=docs/demos/assets/video/d02-naming-model.cast
mkdir -p "$(dirname "$cast")"
SHELL=/bin/bash DEMO_PAUSE_MS=3500 \
  nix shell github:NixOS/nixpkgs/117cc7f94e8072499b0a7aa4c52084fa4e11cc9b#asciinema \
  -c asciinema rec --overwrite --quiet --cols 80 --rows 24 \
  --env SHELL,TERM --title 'Singular D-02 naming Lean rehearsal' \
  -c 'node demo/naming-lifecycle-demo.mjs' "$cast"
node demo/validate-naming-lifecycle-cast.mjs "$cast"
