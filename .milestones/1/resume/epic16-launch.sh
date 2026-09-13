#!/usr/bin/env bash
set -euo pipefail
cd /tmp/projects/singular/milestone-1/epic-16
exec /run/current-system/sw/bin/claude --dangerously-skip-permissions --model 'claude-opus-5' --effort high </dev/tty >/dev/tty 2>&1
