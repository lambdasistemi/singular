#!/usr/bin/env bash
set -euo pipefail
cd /tmp/projects/singular/milestone-1/docs-links
exec /run/current-system/sw/bin/grok --always-approve -m grok-4.6 </dev/tty >/dev/tty 2>&1
