#!/usr/bin/env bash
# The Demo 1 rehearsal in one command: build the on-chain release from this
# checkout, build the release's own binaries from the archive's flakes, start
# one fresh private devnet, record every scene of the play as a cast, gate
# every cast, assert the chain, stop the devnet, and print one result line per
# scene and the totals. Devnet only: nothing here touches any other network,
# and only the processes devnet-up.sh records are ever stopped.
#
# usage: run-rehearsal.sh REHEARSAL-DIR OUT-DIR
#        run-rehearsal.sh --check-workarounds DIR
#
# REHEARSAL-DIR is the directory holding this script and its siblings (the
# scene and harness scripts, WORKAROUNDS.md); OUT-DIR receives the casts, the
# gate output and the run log. The scratch directory (the release, the
# extracted archive, the devnet and the two players' directories) is created
# under TMPDIR and removed on every exit. --check-workarounds runs only the
# mechanical comment-to-row check of DIR/WORKAROUNDS.md against the scripts
# in DIR (the final phase runs it too; by hand it proves the check can fail).
#
# Environment:
#   REHEARSAL_ROOT         the repository root (the release is built from it)
#   REHEARSAL_PAUSE_SCALE  multiplies every read pause (default 1)
set -euo pipefail

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

fmt() { # fmt SECONDS -> "3m 05s" or "42s"
  local t=$1
  if [ "$t" -ge 60 ]; then printf '%dm %02ds' $((t / 60)) $((t % 60)); else printf '%ds' "$t"; fi
}
now_s() { echo $((${EPOCHREALTIME/./} / 1000000)); }

# scoped TIMEOUT COMMAND...: run under a memory-capped user scope when the
# host has systemd-run, else under the bare timeout.
scoped() {
  if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --user --scope -q -p MemoryMax=48G -p MemorySwapMax=0 timeout "$@"
  else
    timeout "$@"
  fi
}

# check_workarounds DIR: the mechanical comment-to-row check, in the one
# direction that cannot be gamed by counting. For every `# WORKAROUND:`
# comment in the scene and harness scripts, the text between the colon and
# the arrow (what the user hits) must appear verbatim inside the symptom cell
# of some row of WORKAROUNDS.md; and every row whose workaround cell does not
# start with `no site:` must be matched by at least one comment. Prints the
# three numbers on standard output, every finding on standard error.
check_workarounds() {
  local dir=$1 md="$1/WORKAROUNDS.md"
  local bad=0 comments=0 rows=0 nosite=0 tmp f text
  local rscene rsymptom rwork cfile ctext matched
  [ -f "$md" ] || {
    echo "workarounds check: no WORKAROUNDS.md in $dir" >&2
    return 1
  }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/workarounds-check.XXXXXX")"
  # the rows: one line per table row, the four cells joined by tabs, `\|` unescaped
  awk '
    /^\|/ && $0 !~ /^\|[[:space:]]*scene/ && $0 !~ /^\|[-| :]+\|$/ {
      line = $0
      sub(/^\|/, "", line); sub(/\|[[:space:]]*$/, "", line)
      gsub(/\\\|/, "\001", line)
      n = split(line, c, "|")
      out = ""
      for (i = 1; i <= n; i++) {
        gsub(/\001/, "|", c[i])
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", c[i])
        out = out (i > 1 ? "\t" : "") c[i]
      }
      print out
    }
  ' "$md" >"$tmp/rows"
  # every comment: one line per `# WORKAROUND:` line, the text between the colon and the arrow
  : >"$tmp/comments"
  for f in "$dir"/*.sh; do
    while IFS= read -r text; do
      printf '%s\t%s\n' "$(basename "$f")" "$text" >>"$tmp/comments"
    done < <(grep -h '^# WORKAROUND: ' "$f" 2>/dev/null | sed -e 's/^# WORKAROUND: //' -e 's/ -> .*//' | sed 's/[[:space:]]*$//')
  done
  while IFS=$'\t' read -r rscene rsymptom rwork; do
    rows=$((rows + 1))
    case "$rwork" in "no site:"*) nosite=$((nosite + 1)) ;; esac
  done <"$tmp/rows"
  # direction 1: every comment's text is inside some row's symptom cell
  while IFS=$'\t' read -r cfile ctext; do
    [ -n "$ctext" ] || {
      echo "workarounds check: a WORKAROUND comment in $cfile has no arrow" >&2
      bad=1
      continue
    }
    comments=$((comments + 1))
    matched=""
    while IFS=$'\t' read -r rscene rsymptom rwork; do
      case "$rsymptom" in *"$ctext"*)
        matched=1
        break
        ;;
      esac
    done <"$tmp/rows"
    if [ -z "$matched" ]; then
      echo "workarounds check: no row's symptom carries verbatim: $ctext ($cfile)" >&2
      bad=1
    fi
  done <"$tmp/comments"
  # direction 2: every row with a live site is matched by at least one comment
  while IFS=$'\t' read -r rscene rsymptom rwork; do
    case "$rwork" in "no site:"*) continue ;; esac
    matched=""
    while IFS=$'\t' read -r cfile ctext; do
      [ -n "$ctext" ] || continue
      case "$rsymptom" in *"$ctext"*)
        matched=$cfile
        break
        ;;
      esac
    done <"$tmp/comments"
    if [ -z "$matched" ]; then
      echo "workarounds check: the row '$rscene: $rsymptom' has no WORKAROUND comment at its site" >&2
      bad=1
    fi
  done <"$tmp/rows"
  rm -rf "$tmp"
  printf '%d comments, %d rows, %d without a site\n' "$comments" "$rows" "$nosite"
  [ "$bad" -eq 0 ]
}

if [ "${1:-}" = "--check-workarounds" ]; then
  { [ "$#" -eq 2 ] && [ -d "$2" ]; } || {
    usage >&2
    exit 2
  }
  check_workarounds "$2"
  exit $?
fi

[ "$#" -eq 2 ] || {
  usage >&2
  exit 2
}
home=$1 out=$2
: "${REHEARSAL_ROOT:?run-rehearsal.sh needs the repository root}"
: "${REHEARSAL_PAUSE_SCALE:=1}"

# ---------------------------------------------------------------- the run
work="$(mktemp -d "${TMPDIR:-/tmp}/demo1-rehearsal.XXXXXX")"
export REHEARSAL_WORK="$work"
export TMPDIR="$work"
devnet_started=""
cleanup() {
  if [ -n "$devnet_started" ] && [ -f "$work/pids" ]; then
    bash "$home/devnet-down.sh" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

exec > >(tee "$out/run.log") 2>&1
sleep 0.3 # let the log's tee open before the first line

t0=$(now_s)
phase() { # phase LABEL COMMAND...: run the command, print its line with the elapsed time, return its status
  local label=$1 s rc=0
  shift
  s=$(now_s)
  "$@" || rc=$? # not `"$@"; ...`: under `phase ... || fail_run` errexit is off, so the status is taken here
  if [ "$rc" -eq 0 ]; then
    printf 'phase %s: %s\n' "$label" "$(fmt $(($(now_s) - s)))"
  else
    printf 'phase %s: FAILED (exit %d) after %s\n' "$label" "$rc" "$(fmt $(($(now_s) - s)))"
  fi
  return "$rc"
}

cast_stream() { tail -n +2 "$1" | jq -j '.[2]' | sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' | tr -d '\r'; }
cast_seconds() { printf '%.0f' "$(tail -n 1 "$1" | jq -r '.[0]')"; }

scene_nums=(0 2 3 4 5 6)
scene_names=(vault named unique permanent permissionless reusable)
scene_casts=()
for idx in "${!scene_nums[@]}"; do
  scene_casts+=("$out/scene-${scene_nums[$idx]}-${scene_names[$idx]}.cast")
done
scene_status=()  # one entry per scene attempted, in order
scene_result() { # scene_result INDEX STATUS [LAST-ERROR]
  local idx=$1 status=$2 last_error=${3:-}
  local n=${scene_nums[$idx]} name=${scene_names[$idx]} cast=${scene_casts[$idx]}
  if [ "$status" = PASS ]; then
    printf 'scene %s %s: PASS  %s  %s  %s\n' "$n" "$name" "$(basename "$cast")" \
      "$(fmt "$(cast_seconds "$cast")")" \
      "$(cast_stream "$cast" | grep -E '^result: ' | tail -1)"
  else
    printf 'scene %s %s: FAIL  %s  %s\n' "$n" "$name" "$(basename "$cast")" "$last_error"
  fi
}

gate_ran=""
run_gate() { # run_gate CAST...: the gate, its output kept in the out directory
  local rc=0
  gate_ran=1
  set +e
  bash "$home/gate.sh" "$@" 2>&1 | tee "$out/gate-output.txt"
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}
teardown() {
  if [ -n "$devnet_started" ]; then
    phase "devnet down" bash "$home/devnet-down.sh" || true
    devnet_started=""
  fi
}
fail_run() { # fail_run FIRST-FAILING-PHASE [LAST-ERROR]: teardown, the gate on what exists, the lines, exit 1
  local first=$1 last_error=${2:-} idx
  local done_casts=()
  teardown
  for idx in "${!scene_status[@]}"; do
    [ "${scene_status[$idx]}" = PASS ] && done_casts+=("${scene_casts[$idx]}")
  done
  if [ -z "$gate_ran" ] && [ "${#done_casts[@]}" -gt 0 ]; then
    run_gate "${done_casts[@]}" || true # the gate on what exists; its FAIL lines name what it found
  fi
  for idx in "${!scene_status[@]}"; do
    scene_result "$idx" "${scene_status[$idx]}" "$last_error"
  done
  printf 'demo1-rehearsal: FAIL  first failing phase: %s  total: %s\n' "$first" "$(fmt $(($(now_s) - t0)))"
  sleep 0.3
  exit 1
}

# ------------------------------------------------------ release and binaries
cd "$REHEARSAL_ROOT"
phase "release assembly" nix run .#release-artifacts -- "$work/release" || fail_run "release assembly"
phase "binaries" bash "$home/build-binaries.sh" "$work" || fail_run "binaries"
export REHEARSAL_BIN="$work/bin"
export REHEARSAL_EXTRACTED="$work/verify/extracted"
export E2E_GENESIS_DIR="$work/verify/extracted/offchain/e2e-test/genesis"
bash "$home/setup-players.sh" >/dev/null || fail_run "the players' directories"

# ------------------------------------------------------------------ the scenes
# Scene 0 needs no node (wallet create and wallet address take only the network magic), so it runs
# first; the devnet is then started funding the two addresses its vaults print.
for idx in "${!scene_nums[@]}"; do
  n=${scene_nums[$idx]}
  name=${scene_names[$idx]}
  if [ "$n" = 2 ]; then
    devnet_started=1
    phase "devnet up" scoped 900 bash "$home/devnet-up.sh" || fail_run "devnet up"
    bash "$home/setup-layout.sh" >/dev/null || fail_run "devnet up"
  fi
  if phase "scene $n ($name)" bash "$home/pty-run.sh" "$home/scene-$n-$name.sh" "${scene_casts[$idx]}"; then
    scene_status+=("PASS")
  else
    scene_status+=("FAIL")
    last_error="$(cast_stream "${scene_casts[$idx]}" 2>/dev/null | grep -E '^(play|finish|comment_lines|pty-run): ' | tail -1 || true)"
    [ -n "$last_error" ] || last_error="the tour stopped early; see the run log"
    fail_run "scene $n ($name)" "$last_error"
  fi
done

# -------------------------------------------------- gate, assertions, teardown
phase "gate" run_gate "${scene_casts[@]}" || {
  printf 'gate: FAIL\n'
  fail_run "the cast gate"
}
printf 'gate: PASS\n'
phase "chain assertions" bash "$home/verify.sh" || fail_run "the chain assertions"
printf 'chain assertions: PASS\n'
phase "devnet down" bash "$home/devnet-down.sh" || fail_run "devnet down"
devnet_started=""

# ------------------------------------------------------- the workaround record
wa="$(check_workarounds "$home")" || {
  printf 'workarounds: %s\n' "$wa"
  fail_run "the workarounds check"
}
printf 'phase workarounds check: 0s\n'
printf 'workarounds: %s\n' "$wa"

# ------------------------------------------------------------------ the summary
for idx in "${!scene_nums[@]}"; do
  scene_result "$idx" PASS
done
printf 'demo1-rehearsal: PASS  %d/6 scenes  total: %s  pause scale: %s\n' \
  "${#scene_casts[@]}" "$(fmt $(($(now_s) - t0)))" "$REHEARSAL_PAUSE_SCALE"
if [ "$REHEARSAL_PAUSE_SCALE" != 1 ]; then
  printf "NOT THE PRESENTER'S TIMING\n"
fi
sleep 0.3 # let the log's tee drain before this shell exits
