#!/usr/bin/env bash
# declared-checks-collect: the one impure layer of the census.
#
# Usage: declared_checks_collect.sh [ROOT] [ISSUE-STATES]
#   ROOT defaults to the working tree. ISSUE-STATES is a file of
#   `<number> <open|closed>` lines for the `pending wiring` entries, as read
#   by a read-only query of the repository's issues (the hosted job hands
#   it; a local run hands a file or omits it when no pending entry needs it).
#
# The layer evaluates the declared app and check names of every tracked
# flake once (a new flake directory joins without editing this check; an
# empty extent is exit 2), runs the resolver's shared extraction over the
# workflows once, resolves bare builds onto the check they build (a bare
# build hosts a check only when the bare installable resolves to that
# check's derivation, proven by outPath) and flake-check runs onto every
# check of their flake, collects the workflow job ids once, and calls the
# pure classifier. Building an app is not hosting it.
#
# The wrapper owns its scratch directory (created and removed on every
# exit); no build state lands in the checkout, no process is stopped. Every
# acquisition step carries its own setup failure (exit 2, never a verdict);
# the classifier's verdict and its exit travel through files tested in this
# shell, never through a subshell or a pipeline ending in grep or head.
set -euo pipefail

SYSTEM="x86_64-linux"

root="${1:-$PWD}"
issue_states="${2:-}"
if [ ! -d "$root" ]; then
  root="$PWD"
  issue_states="${1:-}"
fi
root=$(realpath -m "$root")

tools="$(cd "$(dirname "$0")" && pwd)"
resolver="$tools/workflow_commands_resolve.sh"
classify="$tools/declared_checks_classify.sh"
list="$root/tools/declared_checks_not_hosted.list"

setup_fail() {
  echo "declared-checks-collect: SETUP: $1" >&2
  exit 2
}

work="$(mktemp -d)" || {
  echo "declared-checks-collect: SETUP: cannot create a scratch directory" >&2
  exit 2
}
trap 'rm -rf "$work"' EXIT

[ -f "$resolver" ] || setup_fail "no resolver $resolver"
[ -f "$classify" ] || setup_fail "no classifier $classify"
[ -f "$list" ] || setup_fail "no declared-not-hosted list $list"
[ -e "$root/.git" ] || setup_fail "$root is not a git work tree; the declared set is read from the tracked flakes"

workflows=()
for f in "$root"/.github/workflows/*.yml; do
  if [ -f "$f" ]; then workflows+=("$f"); fi
done
[ "${#workflows[@]}" -gt 0 ] || setup_fail "no workflow files under $root/.github/workflows"

git -C "$root" ls-files -- '*flake.nix' | LC_ALL=C sort >"$work/tracked-flakes.txt" \
  || setup_fail "reading the tracked flake files"
[ -s "$work/tracked-flakes.txt" ] || setup_fail "no tracked flake.nix under $root (empty declared extent)"

flakes=()
while IFS= read -r p || [ -n "$p" ]; do
  [ -n "$p" ] || continue
  flakes+=("$(dirname "$p")")
done <"$work/tracked-flakes.txt"
[ "${#flakes[@]}" -gt 0 ] || setup_fail "no tracked flake.nix under $root (empty declared extent)"

# attrNames of one output of one flake into a destination file. A flake
# that does not provide the output at all declares nothing of that kind
# (empty); a flake that does not evaluate is a setup failure, never a
# verdict. Runs in this shell; the caller tests the result here.
eval_names() {
  local dir="$1" output="$2" dest="$3" path msg
  if [ "$dir" = "." ]; then path="$root"; else path="$root/$dir"; fi
  [ -d "$path" ] || setup_fail "tracked flake directory $path is absent"
  if nix eval --json "$path#$output.$SYSTEM" --apply builtins.attrNames >"$work/eval.json" 2>"$work/eval.err"; then
    jq -r '.[]' "$work/eval.json" >"$dest" 2>"$work/eval.err" \
      || setup_fail "reading the $output names of flake $dir"
    return 0
  fi
  msg=$(cat "$work/eval.err")
  case "$msg" in
    *"does not provide attribute"*) : >"$dest" ;;
    *) setup_fail "flake $dir does not evaluate its $output output: $msg" ;;
  esac
}

: >"$work/declared.txt"
declare -A declared_checks=()
for d in "${flakes[@]}"; do
  eval_names "$d" apps "$work/names.txt" || setup_fail "evaluating the apps of flake $d"
  while IFS= read -r a || [ -n "$a" ]; do
    [ -n "$a" ] || continue
    printf '%s|app|%s\n' "$d" "$a" >>"$work/declared.txt"
  done <"$work/names.txt"
  eval_names "$d" checks "$work/names.txt" || setup_fail "evaluating the checks of flake $d"
  while IFS= read -r c || [ -n "$c" ]; do
    [ -n "$c" ] || continue
    printf '%s|check|%s\n' "$d" "$c" >>"$work/declared.txt"
    declared_checks["$d|$c"]=1
  done <"$work/names.txt"
done

bash "$resolver" --emit-references "$root" "${workflows[@]}" >"$work/refs.txt" 2>"$work/refs.err" \
  || setup_fail "the resolver failed extracting the workflow references"
cat "$work/refs.err" >&2

for f in "${workflows[@]}"; do
  awk '/^jobs:/ {inside=1; next} inside && /^  [A-Za-z0-9_-]+:$/ {sub(/^  /, ""); sub(/:$/, ""); print}' "$f"
done >"$work/jobs.txt" || setup_fail "collecting the workflow job ids"
[ -s "$work/jobs.txt" ] || setup_fail "no job ids found in the workflow files"

# What a bare `nix build .#<attr>` in a flake directory actually builds:
# resolve the bare installable exactly as the build does and compare it
# with the named check. A flake can declare checks.unit beside an
# unrelated top-level or legacy package unit and no packages.unit, so the
# absence of a same-named package proves nothing; only installable
# identity credits the check. An unresolvable installable credits nothing
# (the census then fails loudly on the unhosted check rather than
# claiming it hosted).
bare_builds_check() {
  local dir="$1" attr="$2" path built_out check_out
  if [ "$dir" = "." ]; then path="$root"; else path="$root/$dir"; fi
  built_out=$(nix eval --raw "$path#$attr.outPath" 2>/dev/null) || return 1
  check_out=$(nix eval --raw "$path#checks.$SYSTEM.$attr.outPath" 2>/dev/null) || return 1
  [ "$built_out" = "$check_out" ]
}

: >"$work/hosted.txt"
declare -A flake_checked=()
while IFS=' ' read -r kind dir attr || [ -n "$kind" ]; do
  [ -n "$kind" ] || continue
  case "$kind" in
    run)
      if [ "$attr" != "-" ]; then printf 'run %s %s\n' "$dir" "$attr" >>"$work/hosted.txt"; fi
      ;;
    build)
      case "$attr" in
        checks."$SYSTEM".*)
          printf 'check %s %s named-check-build (nix build of %s)\n' "$dir" "${attr#checks."$SYSTEM".}" "$attr" >>"$work/hosted.txt"
          ;;
        *)
          [ "$attr" != "-" ] || continue
          if [ -n "${declared_checks["$dir|$attr"]+x}" ]; then
            if bare_builds_check "$dir" "$attr"; then
              printf 'check %s %s bare-build (the bare installable resolves to checks.%s.%s)\n' "$dir" "$attr" "$SYSTEM" "$attr" >>"$work/hosted.txt"
            fi
          fi
          ;;
      esac
      ;;
    flake-check) flake_checked["$dir"]=1 ;;
    *) setup_fail "unknown emitted reference kind '$kind'" ;;
  esac
done <"$work/refs.txt"
for d in "${!flake_checked[@]}"; do
  for key in "${!declared_checks[@]}"; do
    if [ "${key%%|*}" = "$d" ]; then
      printf 'check %s %s flake-check (nix flake check builds every check of the flake)\n' "$d" "${key#*|}" >>"$work/hosted.txt"
    fi
  done
done

if [ -n "$issue_states" ]; then
  if bash "$classify" "$work/declared.txt" "$work/hosted.txt" "$list" "$work/jobs.txt" "$issue_states" >"$work/classify.out" 2>"$work/classify.err"; then
    status=0
  else
    status=$?
  fi
else
  if bash "$classify" "$work/declared.txt" "$work/hosted.txt" "$list" "$work/jobs.txt" >"$work/classify.out" 2>"$work/classify.err"; then
    status=0
  else
    status=$?
  fi
fi
cat "$work/classify.out"
cat "$work/classify.err" >&2
exit "$status"
