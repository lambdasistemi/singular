#!/usr/bin/env bash
# usage: pty-run.sh SCENE-SCRIPT-PATH CAST-FILE
# Runs one scene inside a detached tmux pty of exactly 100x34, so the tour sees a terminal (the CLI
# narrates only on a terminal). The scene is wrapped in asciinema with SHELL=/bin/bash, writing CAST-FILE.
# The pty belongs to a tmux server of its own, on a socket in the run's scratch directory: it never
# touches the tmux server the presenter's session may be running (whose version may differ from this
# app's), it inherits this script's environment (the run's variables and the app's PATH), and it ends
# with the scene.
set -euo pipefail
: "${REHEARSAL_WORK:?pty-run.sh needs the run scratch directory}"
RUN="$REHEARSAL_WORK"
[ "$#" -eq 2 ] || {
  echo "usage: $0 SCENE-SCRIPT CAST-FILE" >&2
  exit 2
}
step=$1 cast=$2
name="play-$(basename "$step" .sh)"
rc="$RUN/$name.rc"
fin="$RUN/finished.$(basename "$step" .sh)"
rm -f "$rc" "$fin"
title="Singular Demo 1 play, $(basename "$step" .sh | sed 's/^scene-//')"
tm() { tmux -S "$RUN/tmux.sock" "$@"; }
# asciinema keeps an install id under the user's config directory; the run keeps it in its scratch instead
export ASCIINEMA_CONFIG_HOME="$RUN/asciinema-config"
inner="env SHELL=/bin/bash TERM=xterm-256color asciinema rec --overwrite -q --cols 100 --rows 34 -t $(printf '%q' "$title") -c $(printf '%q' "bash $step") $(printf '%q' "$cast")"
tm new-session -d -s "$name" -x 100 -y 34 "$inner; echo \$? > $rc"
until [ -f "$rc" ] || ! tm has-session -t "$name" 2>/dev/null; do sleep 0.5; done
tm kill-server 2>/dev/null || true # our own server, on our own socket; normally already gone
[ -f "$rc" ] || {
  echo "pty-run: $step: the pty ended without a status; the tour stopped early" >&2
  exit 1
}
code=$(cat "$rc")
[ "$code" -eq 0 ] || {
  echo "pty-run: $step exited $code" >&2
  exit "$code"
}
[ -f "$fin" ] || {
  echo "pty-run: $step did not reach its end (no finish marker); the tour stopped early" >&2
  exit 1
}
echo "pty-run: $(basename "$step" .sh) ok"
