#!/usr/bin/env bash
# Scratch left by the Demo 1 checks is removed on success and on failure,
# including a directory the run made unreadable. DEMO1_KEEP_SCRATCH=1 keeps
# that scratch and prints "kept scratch: <path>" on stderr.
#
# usage: demo1_scratch_removal.test.sh TWO-ACTOR CONTROLS-CHECK CLI-CHECK ATTACH-CHECK
set -euo pipefail

[ "$#" -eq 4 ] || {
  echo "usage: $0 TWO-ACTOR CONTROLS-CHECK CLI-CHECK ATTACH-CHECK" >&2
  exit 2
}
control="$1"
controls_check="$2"
cli_check="$3"
attach_check="$4"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-scratch-removal.XXXXXX")"
trap 'chmod -R u+rwx "$scratch" 2>/dev/null || true; rm -rf "$scratch"' EXIT
fail() {
  echo "demo1-scratch-removal.test: FAIL: $*" >&2
  exit 1
}

# paths NAME DIR GLOB: the entries of DIR matching GLOB, one per line.
paths() {
  local dir="$1" glob="$2" match
  shopt -s nullglob
  for match in "$dir"/$glob; do
    printf '%s\n' "$match"
  done
  shopt -u nullglob
}

on="journey: two actors: the deliberate open control is on; bob's process opens alice's journal"
folded="journey: two-fold: success"
access="journey: FAIL: bob's fold accessed alice's directory: 77 openat(AT_FDCWD, \"/w/two-actors/alice/journal.jsonl\", O_RDONLY) = -1 EACCES"
refused="verify-release: REFUSED command-failed: the journey exited 1; receipts in /w"

write_stub() {
  local name="$1" code="$2" line
  shift 2
  {
    echo '#!/usr/bin/env bash'
    for line in "$@"; do printf 'printf "%%s\\n" %q\n' "$line"; done
    echo "exit $code"
  } >"$scratch/$name.sh"
  chmod +x "$scratch/$name.sh"
}

# run_control NAME WANT: the two-actor control over stub NAME exits WANT
# and leaves no scratch in its own temporary directory.
run_control() {
  local name="$1" want="$2" runner status=0 left
  runner="$scratch/$name-runner"
  mkdir -p "$runner"
  RUNNER_TEMP="$runner" DEMO1_CLI_CHECK="$scratch/$name.sh" \
    bash "$control" /repo >"$scratch/$name.out" 2>"$scratch/$name.err" || status=$?
  [ "$status" -eq "$want" ] || fail "$name: exit $status, expected $want: $(tail -n 1 "$scratch/$name.out")"
  left="$(paths "$runner" 'demo1-two-actor-control.*')"
  [ -z "$left" ] || fail "$name: scratch remains: $left"
  echo "demo1-scratch-removal.test: $name: exit $status, scratch gone"
}

write_stub access-check 1 "$on" "$folded" "$access" "$refused"
run_control access-check 0
write_stub run-passed 0 "$on" "$folded"
run_control run-passed 1

keep_runner="$scratch/keep-runner"
mkdir -p "$keep_runner"
status=0
RUNNER_TEMP="$keep_runner" DEMO1_KEEP_SCRATCH=1 DEMO1_CLI_CHECK="$scratch/run-passed.sh" \
  bash "$control" /repo >"$scratch/keep.out" 2>"$scratch/keep.err" || status=$?
[ "$status" -eq 1 ] || fail "keep: exit $status, expected 1"
kept="$(paths "$keep_runner" 'demo1-two-actor-control.*')"
[ -n "$kept" ] || fail "keep: scratch was removed"
[ "$(printf '%s\n' "$kept" | wc -l)" -eq 1 ] || fail "keep: more than one scratch: $kept"
grep -qF "kept scratch: $kept" "$scratch/keep.err" || fail "keep: stderr does not name the scratch: $(cat "$scratch/keep.err")"
echo "demo1-scratch-removal.test: keep: scratch remains and is named"

# A stand-in nix creates an unreadable directory in the check's scratch
# and fails, so removal has to make the tree writable first.
nix_stub="$scratch/bin"
mkdir -p "$nix_stub"
cat >"$nix_stub/nix" <<'EOF'
#!/usr/bin/env bash
shopt -s nullglob
matches=("$RUNNER_TEMP"/$SCRATCH_GLOB)
[ "${#matches[@]}" -eq 1 ] || {
  echo "nix stub: expected one scratch matching $SCRATCH_GLOB, found ${#matches[@]}" >&2
  exit 1
}
mkdir -p "${matches[0]}/locked/inside"
chmod 000 "${matches[0]}/locked"
exit 1
EOF
chmod +x "$nix_stub/nix"

# early_fail NAME SCRIPT GLOB ENV-ASSIGNMENT...: SCRIPT fails after creating
# its scratch, and that scratch is gone. With DEMO1_KEEP_SCRATCH=1 the same
# failure keeps the unreadable directory and names it.
early_fail() {
  local name="$1" script="$2" glob="$3"
  shift 3
  local runner="$scratch/$name-runner" status=0 left
  mkdir -p "$runner"
  env PATH="$nix_stub:$PATH" RUNNER_TEMP="$runner" SCRATCH_GLOB="$glob" "$@" \
    bash "$script" "$scratch/root" >"$scratch/$name.out" 2>"$scratch/$name.err" || status=$?
  [ "$status" -ne 0 ] || fail "$name: expected failure, exited 0: $(tail -n 5 "$scratch/$name.err")"
  left="$(paths "$runner" "$glob")"
  [ -z "$left" ] || fail "$name: scratch remains after failure: $left"
  echo "demo1-scratch-removal.test: $name: exit $status, scratch gone"

  local keep_dir="$scratch/$name-keep" kept_path mode
  mkdir -p "$keep_dir"
  status=0
  env PATH="$nix_stub:$PATH" RUNNER_TEMP="$keep_dir" SCRATCH_GLOB="$glob" DEMO1_KEEP_SCRATCH=1 "$@" \
    bash "$script" "$scratch/root" >"$scratch/$name-keep.out" 2>"$scratch/$name-keep.err" || status=$?
  [ "$status" -ne 0 ] || fail "$name keep: expected failure, exited 0"
  kept_path="$(paths "$keep_dir" "$glob")"
  [ -n "$kept_path" ] || fail "$name keep: scratch was removed"
  [ "$(printf '%s\n' "$kept_path" | wc -l)" -eq 1 ] || fail "$name keep: more than one scratch: $kept_path"
  grep -qF "kept scratch: $kept_path" "$scratch/$name-keep.err" \
    || fail "$name keep: stderr does not name the scratch: $(cat "$scratch/$name-keep.err")"
  [ -d "$kept_path/locked" ] || fail "$name keep: the unreadable directory is gone"
  # chmod 000 clears access and leaves a directory setgid bit in place.
  # Either way the owner cannot list the directory, so removal still needs
  # a mode change. The keep path must not have made it writable.
  mode="$(stat -c %a "$kept_path/locked")"
  [ $((8#$mode & 0777)) -eq 0 ] || fail "$name keep: locked directory mode is $mode, expected no access"
  echo "demo1-scratch-removal.test: $name keep: scratch remains, still unreadable, and is named"
}

mkdir -p "$scratch/root/offchain"
early_fail controls "$controls_check" 'demo1-controls.*'
early_fail cli-check "$cli_check" 'demo1.*' DEMO1_VERIFY_RELEASE=/bin/false
early_fail attach "$attach_check" 'demo1-attach.*'

echo "demo1-scratch-removal.test: all cases passed"
