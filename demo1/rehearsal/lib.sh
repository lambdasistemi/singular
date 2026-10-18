#!/usr/bin/env bash
# Helpers for the scripted tour. Sourced by each scene, never executed.
# shellcheck disable=SC1090,SC1091  # the sourced env files live in the run's scratch directory, not beside this script
# The scratch root (REHEARSAL_WORK) and the built binaries (REHEARSAL_BIN)
# come from the caller: run-rehearsal.sh sets both before any scene runs.
# Prints the standard timing prompt
#   [+prev | total | n/N %] demo$
# itself, because a scripted tour has no interactive shell to print it.
: "${REHEARSAL_WORK:?lib.sh needs the run scratch directory}"
: "${REHEARSAL_BIN:?lib.sh needs the built binaries directory}"
: "${REHEARSAL_PAUSE_SCALE:=1}"
RUN="$REHEARSAL_WORK"
bin="$REHEARSAL_BIN"
cd "$RUN/play"
export PATH="$bin:$PATH"
[ ! -f "$RUN/session.env" ] || . "$RUN/session.env" # scene 0 runs before the devnet, so before this file
[ -f "$RUN/${TOKEN_ENV:-token.env}" ] && . "$RUN/${TOKEN_ENV:-token.env}"
: "${DEMO_TOTAL:?DEMO_TOTAL is the number of tool commands in this scene}"
: "${DEMO_TOOL:=singular}"
: "${PAUSE:=4}"
# WORKAROUND: the CLI's own ANSI colors would fight the tour's fixed palette -> NO_COLOR=1 for the tour; the tour's palette (header, comment, command, result, expected failure) carries the meaning.
export NO_COLOR=1

reset=$'\033[0m' dim=$'\033[0;90m' green=$'\033[1;32m'

now_us() {
  local t=$EPOCHREALTIME
  echo "${t/./}"
}
session0=$(now_us)
done_n=0
last_d=0
exec 9<> <(:)
tick() { read -r -t 0.008 -u 9 || true; }

# WORKAROUND: tokens, hashes and transaction ids run 56-64 hex characters and lines wrap at 100 columns -> short abbreviates any hex run of 48+ characters to its first eight on screen; full values stay in the receipts.
short() { sed -E 's/([0-9a-f]{8})[0-9a-f]{40,}/\1…/g'; }

# read_pause [SECONDS]: sleep one read pause, multiplied by
# REHEARSAL_PAUSE_SCALE (the developer knob: 0.1 turns the presenter's
# sixteen minutes of pauses into a debugging run).
read_pause() {
  sleep "$(awk -v s="${1:-$PAUSE}" -v m="$REHEARSAL_PAUSE_SCALE" 'BEGIN { printf "%.3f", s * m }')"
}

prompt_line() {
  local t last tot
  t=$(($(now_us) - session0))
  printf -v last '+%d.%02ds' $((last_d / 1000000)) $(((last_d / 10000) % 100))
  printf -v tot '%dm %02ds' $((t / 60000000)) $(((t / 1000000) % 60))
  printf '[%s | %s | %d/%d %d%%] demo$ ' "$last" "$tot" "$done_n" "$DEMO_TOTAL" $((done_n * 100 / DEMO_TOTAL))
}
type_out() {
  local s=$1 i
  printf '%b' "$green"
  for ((i = 0; i < ${#s}; i++)); do
    printf '%s' "${s:i:1}"
    tick
  done
  printf '%b\n' "$reset"
}
# WORKAROUND: a single screen update carrying a whole command's output is huge in the cast -> pace re-emits what a command prints in pieces of at most 80 characters; the bytes and the terminal's own wrapping are unchanged.
pace() {
  local line i
  while IFS= read -r line; do
    for ((i = 0; i < ${#line}; i += 80)); do
      printf '%s' "${line:i:80}"
      tick
    done
    printf '\n'
  done
}
frame() { printf '\033[H\033[2J\033[3J'; }

# comment_lines TEXT: the comment above a command; at most two lines, each short enough for the terminal
comment_lines() {
  local l n=0
  while IFS= read -r l; do
    n=$((n + 1))
    [ "$n" -le 2 ] || {
      echo "comment_lines: more than two lines" >&2
      exit 1
    }
    [ ${#l} -le 96 ] || {
      echo "comment_lines: line of ${#l} characters: $l" >&2
      exit 1
    }
    printf '%b# %s%b\n' "$dim" "$l" "$reset"
  done <<<"$1"
}

# section NAME...: from a page on standard input, only the named top-level sections
section() { awk -v want="$*" 'BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) w[a[i] ":"] = 1 } /^[A-Za-z]+:/ { on = ($1 in w) } on'; }

# play [-t|-f] [-p SECONDS] COMMENT COMMAND
#   -t  one of the tool's commands that must succeed (counts in n/N; a non-zero exit aborts the tour)
#   -f  one of the tool's commands that must be REFUSED (counts in n/N; exit 0 aborts the tour: no fabricated refusal)
#   -s  one of the tool's commands that stages a bundle for an external signer (counts in n/N): its documented
#       outcome is waiting-for-signatures, exit 19, and any other status aborts the tour
# shellcheck disable=SC2312  # the command is the tour's typed line: eval is the mechanism, and its output is paced
play() {
  local tool=0 want=any pause=$PAUSE
  while [ $# -gt 2 ]; do
    case "$1" in -t)
      tool=1
      want=ok
      shift
      ;;
    -f)
      tool=1
      want=refused
      shift
      ;;
    -s)
      tool=1
      want=staged
      shift
      ;;
    -p)
      pause=$2
      shift 2
      ;;
    *) break ;; esac
  done
  local comment=$1 cmd=$2 s rc
  frame
  comment_lines "$comment"
  prompt_line
  type_out "$cmd"
  s=$(now_us)
  set +e
  eval "$cmd" | pace
  rc=${PIPESTATUS[0]}
  set -e
  last_d=$(($(now_us) - s))
  [ "$tool" -eq 1 ] && done_n=$((done_n + 1))
  case "$want" in
    ok) [ "$rc" -eq 0 ] || {
      echo "play: expected success, exit $rc: $cmd" >&2
      exit 1
    } ;;
    refused) [ "$rc" -ne 0 ] || {
      echo "play: expected a refusal, exit 0: $cmd" >&2
      exit 1
    } ;;
    staged) [ "$rc" -eq 19 ] || {
      echo "play: expected waiting-for-signatures (exit 19), exit $rc: $cmd" >&2
      exit 1
    } ;;
  esac
  read_pause "$pause"
  return 0
}

# play_cd COMMENT DIR: type `cd DIR` and really change directory (in this shell, not a subshell)
play_cd() {
  frame
  comment_lines "$1"
  prompt_line
  type_out "cd $2"
  cd "$2"
  last_d=0
  read_pause
}

# finish: type exit, print the result line (the same text the interactive prompt's EXIT trap prints)
finish() {
  local t
  printf '\n'
  prompt_line
  type_out exit
  t=$(($(now_us) - session0))
  printf '\nresult: %d/%d %s commands in %dm %02ds\n' "$done_n" "$DEMO_TOTAL" "$DEMO_TOOL" $((t / 60000000)) $(((t / 1000000) % 60))
  read_pause 3
  [ "$done_n" -eq "$DEMO_TOTAL" ] || {
    echo "finish: counted $done_n tool commands, declared $DEMO_TOTAL" >&2
    exit 1
  }
  : >"$RUN/finished.$(basename "$0" .sh)"
}
