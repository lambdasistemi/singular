#!/usr/bin/env bash
# Stop only the processes devnet-up.sh recorded (pid + start ticks must still match), then confirm they are gone.
set -euo pipefail
: "${REHEARSAL_WORK:?devnet-down.sh needs the run scratch directory}"
RUN="$REHEARSAL_WORK"
[ -s "$RUN/pids" ] || {
  echo "devnet-down: nothing recorded"
  exit 0
}
ticks() {
  local s
  s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"
  read -r -a f <<<"$s"
  echo "${f[19]}"
}
same() { [ "$(ticks "$1" 2>/dev/null || echo none)" = "$2" ]; }
while read -r pid tk role; do
  if same "$pid" "$tk"; then kill -TERM "$pid" 2>/dev/null || true; fi
done <"$RUN/pids"
for _ in $(seq 1 150); do
  alive=0
  while read -r pid tk role; do same "$pid" "$tk" && alive=1; done <"$RUN/pids"
  [ "$alive" -eq 0 ] && break
  sleep 0.2
done
while read -r pid tk role; do
  if same "$pid" "$tk"; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.5
  fi
done <"$RUN/pids"
while read -r pid tk role; do
  if same "$pid" "$tk"; then
    echo "devnet-down: $role $pid is still running" >&2
    exit 1
  fi
done <"$RUN/pids"
echo "devnet-down: every recorded process is gone"
