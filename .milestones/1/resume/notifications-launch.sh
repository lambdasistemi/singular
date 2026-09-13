#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" > /tmp/projects/singular/milestone-1/notifications/notify.pid
export PATH=/home/paolino/.codex/skills/telegram/scripts:$PATH
exec /code/llm-settings/shared/skills/notify/scripts/notify-loop.sh singular-ms1-844 600 /tmp/projects/singular/milestone-1/epic-17/STATUS.md /tmp/projects/singular/milestone-1/epic-18/STATUS.md
