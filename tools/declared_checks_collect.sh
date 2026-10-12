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
# check of their flake, collects the workflow job ids once, scans the
# marker line, the attribute naming and the citations of every tool entry,
# and calls the pure classifier. Building an app is not hosting it.
#
# The tool scan (the operator ruling of 2026-10-12): each tool entry names
# the file that defines its tool, and that file must carry the marker line
# `Tool, not a guarantee: <purpose>` and name the attribute it certifies
# (the marker travels with the defining wrapper; the classifier also
# requires the file to live in the entry's own flake directory). The
# published text — every tracked file under docs/ plus every tracked
# README.md plus the pull request template, discovered from the tree so a
# new page joins without editing this check — must not cite the tool in
# any form bound to its flake and app identity: for a root tool the
# unqualified spellings `.#<attribute>`, `./#<attribute>` and the quoted
# `'#<attribute>'` / `"#<attribute>`, for another flake's tool only its
# flake-qualified spellings `<flake>#<attribute>` and
# `./<flake>#<attribute>` (an unqualified `.#<attribute>` never cites
# another flake's tool), and for every tool the path of the file that
# defines it. A tool's own file citing one of its own command forms is a
# citation too; a file naming its own path is self-reference, not a
# citation, so the path form is not sought there. Every scan is
# case-sensitive: installer references are exact identities. The citation
# extent deliberately excludes the workflows (their run lines are the
# hosting oracle this census already reads; their comments name hosted
# carriers and are judged as comments), the frozen specs/ acceptance
# records (dated testimony of closed slices, kept unchanged by this
# ticket's own design, not live claims), and contributor tooling outside
# the published text (the justfile, the nix files).
#
# `${GREP_BIN:-grep}` scans the marker, naming and citation patterns, so
# the failing-scan control can prove a scan failure is a setup failure:
# the default is the plain grep every other scan in this repository uses.
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

# The tool entries of the list: the marker file each names, whose marker
# state, attribute naming and citations this layer hands to the classifier
# as plain files.
declare -A tool_file_of=()
while IFS='|' read -r tf ta tk tr tfile || [ -n "$tf" ]; do
  case "$tf" in
    '' | '#'*) continue ;;
  esac
  case "$tr" in
    'tool: '*) tool_file_of["$tf|$ta|$tk"]="$tfile" ;;
  esac
done <"$list"

escape_ere() {
  # shellcheck disable=SC2016 # the dollar is a regex anchor inside the sed pattern, never expanded
  printf '%s' "$1" | sed -e 's/[][\.*^$()+?{}|]/\\&/g'
}

# scan_grep [-i] PATTERN FILE: exit 0 the pattern matches, exit 1 it does
# not. Any other grep status (a read or I/O failure) is a setup failure
# with the diagnostic, never a clean scan and never a verdict: an
# incomplete scan cannot become absence evidence.
scan_grep() {
  local status
  local -a grep_args=(-E -q)
  if [ "${1:-}" = "-i" ]; then
    grep_args=(-E -q -i)
    shift
  fi
  if "${GREP_BIN:-grep}" "${grep_args[@]}" -- "$1" "$2" >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ]; then return 1; fi
  setup_fail "scanning $2 for a tool marker or citation failed (exit $status)"
}

# check_citation_own FORM PATTERN: the tool's own defining file matching
# the pattern is emitted once as `form|path`.
check_citation_own() {
  local form="$1" pattern="$2"
  if scan_grep "$pattern" "$target"; then
    if [ -z "${citation_done["$form|$tfile"]+x}" ]; then
      citation_done["$form|$tfile"]=1
      printf '%s|%s\n' "$form" "$tfile" >>"$work/citations"
    fi
  fi
}

# check_citation FORM PATTERN: every extent member matching the pattern
# is emitted once as `form|path`. The path form of the defining file is
# not sought in that file itself: a file naming its own path is
# self-reference, not a citation.
check_citation() {
  local form="$1" pattern="$2" ef
  for ef in "${extent[@]}"; do
    if scan_grep "$pattern" "$root/$ef"; then
      if [ -z "${citation_done["$form|$ef"]+x}" ]; then
        citation_done["$form|$ef"]=1
        printf '%s|%s\n' "$form" "$ef" >>"$work/citations"
      fi
    fi
  done
}

: >"$work/toolmarkers"
: >"$work/citations"
if [ "${#tool_file_of[@]}" -gt 0 ]; then
  # The published text a citation would live in, discovered from the
  # tree. The enumeration is captured to a file and its completion is
  # checked: an unchecked listing that dies silently would shrink the
  # extent. The two fixed members of the floor must be present and
  # tracked: losing either would silently shrink the extent, so it is a
  # setup failure, never a quieter scan.
  git -C "$root" ls-files -z -- docs '*README.md' '.github/pull_request_template.md' >"$work/extent.raw" \
    || setup_fail "listing the citation extent (tracked files under docs/, every README.md, the pull request template) failed"
  extent=()
  while IFS= read -r -d '' ef; do
    extent+=("$ef")
  done <"$work/extent.raw"
  [ "${#extent[@]}" -gt 0 ] || setup_fail "the citation extent is empty (no tracked file under docs/, no README.md, no pull request template)"
  [ -n "$(git -C "$root" ls-files -- README.md)" ] \
    || setup_fail "the citation extent lost the root README.md"
  [ -n "$(git -C "$root" ls-files -- .github/pull_request_template.md)" ] \
    || setup_fail "the citation extent lost the pull request template"
  # Every intended member must exist and be readable: a tracked file
  # absent from the checkout is a broken scan, never a skipped one.
  for ef in "${extent[@]}"; do
    [ -f "$root/$ef" ] \
      || setup_fail "citation extent member $ef is tracked but missing from the checkout"
    [ -r "$root/$ef" ] \
      || setup_fail "citation extent member $ef is tracked but not readable"
  done
  declare -A citation_done=()
  marker_pattern='^[[:space:]]*#?[[:space:]]*Tool, not a guarantee: '
  for key in "${!tool_file_of[@]}"; do
    IFS='|' read -r tf ta tk <<<"$key"
    tfile="${tool_file_of["$key"]}"
    target="$root/$tfile"
    eattr="$(escape_ere "$ta")"
    eflake="$(escape_ere "$tf")"
    if [ ! -f "$target" ]; then
      status=missing
      mention=nameless
    elif [ ! -r "$target" ]; then
      setup_fail "the file that defines the tool, $tfile, is not readable"
    else
      if scan_grep "$marker_pattern" "$target"; then
        status=marked
      else
        status=unmarked
      fi
      if scan_grep "(^|[^A-Za-z0-9_-])$eattr([^A-Za-z0-9_-]|$)" "$target"; then
        mention=names
      else
        mention=nameless
      fi
    fi
    printf '%s|%s|%s %s %s\n' "$tf" "$ta" "$tfile" "$status" "$mention" >>"$work/toolmarkers"
    # The citation forms bound to the tool's flake and app identity. A
    # root tool answers every unqualified spelling; another flake's tool
    # answers only its flake-qualified spellings, so an ordinary
    # same-named reference elsewhere is never misattributed to it.
    if [ "$tf" = "." ]; then
      check_citation ".#$ta" "(^|[^A-Za-z0-9_./-])\\.#$eattr([^A-Za-z0-9_-]|$)"
      check_citation "./#$ta" "(^|[^A-Za-z0-9_./-])\\./#$eattr([^A-Za-z0-9_-]|$)"
      check_citation "'#$ta" "'#$eattr([^A-Za-z0-9_-]|$)"
      check_citation '"'"#$ta" '"'"#$eattr([^A-Za-z0-9_-]|$)"
    else
      check_citation "$tf#$ta" "(^|[^A-Za-z0-9_./-])$eflake#$eattr([^A-Za-z0-9_-]|$)"
      check_citation "./$tf#$ta" "(^|[^A-Za-z0-9_./-])\\./$eflake#$eattr([^A-Za-z0-9_-]|$)"
    fi
    check_citation "$tfile" "(^|[^A-Za-z0-9_./-])$(escape_ere "$tfile")([^A-Za-z0-9_./-]|$)"
    # A tool's own file citing one of its own command forms is a
    # citation too.
    if [ -f "$target" ]; then
      if [ "$tf" = "." ]; then
        check_citation_own ".#$ta" "(^|[^A-Za-z0-9_./-])\\.#$eattr([^A-Za-z0-9_-]|$)"
        check_citation_own "./#$ta" "(^|[^A-Za-z0-9_./-])\\./#$eattr([^A-Za-z0-9_-]|$)"
        check_citation_own "'#$ta" "'#$eattr([^A-Za-z0-9_-]|$)"
        check_citation_own '"'"#$ta" '"'"#$eattr([^A-Za-z0-9_-]|$)"
      else
        check_citation_own "$tf#$ta" "(^|[^A-Za-z0-9_./-])$eflake#$eattr([^A-Za-z0-9_-]|$)"
        check_citation_own "./$tf#$ta" "(^|[^A-Za-z0-9_./-])\\./$eflake#$eattr([^A-Za-z0-9_-]|$)"
      fi
    fi
  done
fi

if [ -n "$issue_states" ]; then
  if bash "$classify" "$work/declared.txt" "$work/hosted.txt" "$list" "$work/jobs.txt" "$issue_states" "$work/toolmarkers" "$work/citations" >"$work/classify.out" 2>"$work/classify.err"; then
    status=0
  else
    status=$?
  fi
else
  if bash "$classify" "$work/declared.txt" "$work/hosted.txt" "$list" "$work/jobs.txt" "" "$work/toolmarkers" "$work/citations" >"$work/classify.out" 2>"$work/classify.err"; then
    status=0
  else
    status=$?
  fi
fi
cat "$work/classify.out"
cat "$work/classify.err" >&2
exit "$status"
