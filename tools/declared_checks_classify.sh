#!/usr/bin/env bash
# declared-checks-classify: the pure verdict over three plain files.
#
# Usage: declared_checks_classify.sh DECLARED HOSTED LIST JOBS [TOOLMARKERS CITATIONS]
#   DECLARED  lines `flake|kind|attr`, kind `app` or `check`: every app and
#             check the repository flakes declare (written by the integration
#             layer, which evaluates each flake once).
#   HOSTED    lines `run <flake> <attr>` (a workflow step runs the app) and
#             `check <flake> <attr> <mechanism>` (a workflow step hosts the
#             check; the mechanism words name how, so the output table shows
#             build-only hosting as such). Written by the integration layer
#             from the resolver's shared extraction, with bare builds
#             resolved to the check they build and flake-check runs expanded
#             to every check of their flake. Building an app is not hosting
#             it: only `run` lines host apps.
#   LIST      lines `flake|attribute|kind|reason[|file]`: the
#             declared-not-hosted entries with their reasons. A `tool:`
#             reason carries a fifth field: the repository-relative path
#             of the file that defines the tool and must hold the marker
#             line `Tool, not a guarantee: <purpose>`.
#   JOBS      one workflow job id per line: what a `hosted under another
#             name` reason may name.
#   TOOLMARKERS optional lines
#             `<flake>|<attribute>|<path> marked|unmarked|missing
#             names|nameless`: the state of the marker line of each tool
#             entry's file and whether that file names the attribute it
#             certifies, as the integration layer found them in the tree.
#             Read lazily: a run with no tool entry needs no source.
#   CITATIONS   optional lines `<citation-form>|<path>`: every occurrence
#             of a tool's citation forms in the published text, as the
#             integration layer discovered it. A root tool's forms are the
#             unqualified spellings `.#<attribute>`, `./#<attribute>` and
#             the quoted `'#<attribute>'` / `"#<attribute>`, plus the path
#             of the file that defines it; a tool of another flake is
#             cited only by its flake-qualified spellings
#             `<flake>#<attribute>` and `./<flake>#<attribute>`, plus its
#             defining file's path. An unqualified `.#<attribute>` never
#             cites another flake's tool. Read lazily: a run with no tool
#             entry needs no source.
#
# The classifier reads no flake, no git tree, no network and no clock, so a
# test feeds it fixtures. Exit 0: every declared entry hosted or reasoned
# and every list entry live. Exit 1: a verdict failure, each named on
# stderr. Exit 2: setup failure (a missing input, an empty declared extent,
# a missing tool-marker or citation source) — never a verdict.
#
# The tool class is the operator ruling of 2026-10-12: a runnable check is
# an obligation (hosted), a tool (marked, never cited as evidence), or
# temporary (deleted before merging). A tool entry fails when the file that
# defines the tool is missing or carries no marker line, when that file
# does not name the attribute it certifies or lives outside the entry's
# own flake directory (the marker travels with the defining wrapper, so
# a marked stranger cannot certify an unrelated obligation), and when any
# citation form bound to the tool's flake and app identity appears in the
# published text, the tool's own file included. Checking the marker's
# presence is the subject here: the marker text is the declaration.
set -euo pipefail

setup_fail() {
  echo "declared-checks-classify: SETUP: $1" >&2
  exit 2
}

fail=0
verdict_fail() {
  echo "declared-checks-classify: FAIL: $1" >&2
  fail=1
}

[ "$#" -ge 4 ] || setup_fail "usage: $0 DECLARED HOSTED LIST JOBS [STATES [TOOLMARKERS [CITATIONS]]]"
declared_file="$1"
hosted_file="$2"
list_file="$3"
jobs_file="$4"
toolmarkers_file="${5:-}"
citations_file="${6:-}"

[ -f "$declared_file" ] || setup_fail "no declared-entries file $declared_file"
[ -f "$hosted_file" ] || setup_fail "no hosted-references file $hosted_file"
[ -f "$list_file" ] || setup_fail "no declared-not-hosted list $list_file"
[ -f "$jobs_file" ] || setup_fail "no job-ids file $jobs_file"

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

declare -A declared_apps=()
declare -A declared_checks=()
declare -A declared_flakes=()
apps_total=0
checks_total=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  IFS='|' read -r df dk da dummy <<<"$line"
  [ -z "${dummy:-}" ] || setup_fail "malformed declared line (not three fields): $line"
  case "$dk" in
    app)
      declared_apps["$df|$da"]=1
      apps_total=$((apps_total + 1))
      ;;
    check)
      declared_checks["$df|$da"]=1
      checks_total=$((checks_total + 1))
      ;;
    *)
      setup_fail "malformed declared line (kind is not app or check): $line"
      ;;
  esac
  [ -n "$df" ] && [ -n "$da" ] || setup_fail "malformed declared line (empty flake or attribute): $line"
  declared_flakes["$df"]=1
done <"$declared_file"
[ "$((apps_total + checks_total))" -gt 0 ] \
  || setup_fail "the declared extent is empty (no apps and no checks)"

declare -A hosted_apps=()
declare -A hosted_check_mechanism=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    '' | '#'*) continue ;;
  esac
  kind="${line%% *}"
  rest="${line#* }"
  case "$kind" in
    run)
      hflake="${rest%% *}"
      hattr="${rest#* }"
      hattr="${hattr%% *}"
      [ -n "$hflake" ] && [ -n "$hattr" ] || setup_fail "malformed hosted line: $line"
      hosted_apps["$hflake|$hattr"]=1
      ;;
    check)
      hflake="${rest%% *}"
      hrest="${rest#* }"
      hattr="${hrest%% *}"
      mechanism="${hrest#* }"
      [ -n "$hflake" ] && [ -n "$hattr" ] || setup_fail "malformed hosted line: $line"
      [ -n "$mechanism" ] || mechanism="built by a workflow step"
      hosted_check_mechanism["$hflake|$hattr"]="$mechanism"
      ;;
    *)
      setup_fail "malformed hosted line (kind is not run or check): $line"
      ;;
  esac
done <"$hosted_file"

declare -A job_ids=()
while IFS= read -r j || [ -n "$j" ]; do
  j="$(trim "$j")"
  [ -n "$j" ] || continue
  job_ids["$j"]=1
done <"$jobs_file"
[ "${#job_ids[@]}" -gt 0 ] || setup_fail "no job ids in $jobs_file"

declare -A tool_marker_status=()
declare -A tool_marker_names=()
declare -A tool_citation_paths=()
tool_inputs_loaded=0
load_tool_inputs() {
  local entry="$1" line tf tp tkey tstatus tmention textra kf ka kp kx
  if [ "$tool_inputs_loaded" -eq 0 ]; then
    [ -n "$toolmarkers_file" ] \
      || setup_fail "$entry: a tool entry needs the tool-marker source handed as the sixth argument (a file of '<flake>|<attribute>|<path> marked|unmarked|missing names|nameless' lines)"
    [ -f "$toolmarkers_file" ] \
      || setup_fail "the tool-marker source $toolmarkers_file does not exist"
    [ -n "$citations_file" ] \
      || setup_fail "$entry: a tool entry needs the citation source handed as the seventh argument (a file of '<citation-form>|<path>' lines)"
    [ -f "$citations_file" ] \
      || setup_fail "the citation source $citations_file does not exist"
    while IFS=' ' read -r tkey tstatus tmention textra || [ -n "$tkey" ]; do
      [ -n "$tkey" ] || continue
      IFS='|' read -r kf ka kp kx <<<"$tkey"
      [ -n "$kf" ] && [ -n "$ka" ] && [ -n "$kp" ] && [ -z "${kx:-}" ] \
        || setup_fail "malformed tool-marker key '$tkey' in $toolmarkers_file (expected '<flake>|<attribute>|<path>')"
      case "$tstatus" in
        marked | unmarked | missing) ;;
        *) setup_fail "malformed tool-marker line '$tkey $tstatus $tmention' in $toolmarkers_file (expected '<flake>|<attribute>|<path> marked|unmarked|missing names|nameless')" ;;
      esac
      case "$tmention" in
        names | nameless) ;;
        *) setup_fail "malformed tool-marker line '$tkey $tstatus $tmention' in $toolmarkers_file (expected '<flake>|<attribute>|<path> marked|unmarked|missing names|nameless')" ;;
      esac
      [ -z "${textra:-}" ] \
        || setup_fail "malformed tool-marker line '$tkey $tstatus $tmention $textra' in $toolmarkers_file (expected '<flake>|<attribute>|<path> marked|unmarked|missing names|nameless')"
      [ -z "${tool_marker_status["$tkey"]+x}" ] \
        || setup_fail "the tool-marker source answers twice for $tkey"
      tool_marker_status["$tkey"]="$tstatus"
      tool_marker_names["$tkey"]="$tmention"
    done <"$toolmarkers_file"
    while IFS='|' read -r tf tp || [ -n "$tf" ]; do
      [ -n "$tf" ] || continue
      [ -n "$tp" ] || setup_fail "malformed citation line '$tf' in $citations_file (expected '<citation-form>|<path>')"
      if [ -n "${tool_citation_paths["$tf"]+x}" ]; then
        tool_citation_paths["$tf"]="${tool_citation_paths["$tf"]}, $tp"
      else
        tool_citation_paths["$tf"]="$tp"
      fi
    done <"$citations_file"
    tool_inputs_loaded=1
  fi
}

declare -A listed=()
declare -A tool_entry=()
tool_count=0
tool_names=""
listed_count=0
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  case "$line" in
    '' | '#'*) continue ;;
  esac
  IFS='|' read -r ef ea ek er efile extra <<<"$line"
  where="list line $lineno: $line"
  [ -n "$ef" ] && [ -n "$ea" ] && [ -n "$ek" ] || {
    verdict_fail "$where: a flake, attribute and kind are required"
    continue
  }
  [ -z "${extra:-}" ] || {
    verdict_fail "$where: more than five fields"
    continue
  }
  case "$ek" in
    app)
      [ -n "${declared_apps["$ef|$ea"]+x}" ] || {
        verdict_fail "$where: no declared app $ea in flake $ef (stale entry)"
        continue
      }
      ;;
    check)
      [ -n "${declared_checks["$ef|$ea"]+x}" ] || {
        verdict_fail "$where: no declared check $ea in flake $ef (stale entry)"
        continue
      }
      ;;
    *)
      verdict_fail "$where: kind must be app or check"
      continue
      ;;
  esac
  [ -z "${listed["$ef|$ea|$ek"]+x}" ] || {
    verdict_fail "$where: duplicate entry for $ef $ea ($ek)"
    continue
  }
  listed["$ef|$ea|$ek"]=1
  listed_count=$((listed_count + 1))
  if [ "$ek" = app ]; then
    [ -z "${hosted_apps["$ef|$ea"]+x}" ] || {
      verdict_fail "$where: app $ea of flake $ef is in fact hosted (stale entry)"
      continue
    }
  else
    [ -z "${hosted_check_mechanism["$ef|$ea"]+x}" ] || {
      verdict_fail "$where: check $ea of flake $ef is in fact hosted (stale entry)"
      continue
    }
  fi
  er="$(trim "$er")"
  [ -n "$er" ] || {
    verdict_fail "$where: no reason"
    continue
  }
  if [ -n "${efile:-}" ]; then has_file=yes; else has_file=no; fi
  case "$er" in
    'tool: '*)
      [ "$has_file" = yes ] || {
        verdict_fail "$where: a tool entry carries, as its fifth field, the path of the file that holds its marker"
        continue
      }
      ;;
    *)
      [ "$has_file" = no ] || {
        verdict_fail "$where: only a tool entry carries a fifth field (the file that holds its marker)"
        continue
      }
      ;;
  esac
  case "$er" in
    'retired: '*)
      case "$er" in
        *component-inventory*) ;;
        *)
          verdict_fail "$where: a retired reason cites the classification and its reason in offchain/nix/component-inventory.nix"
          ;;
      esac
      ;;
    'developer utility: '*)
      verdict_fail "$where: the developer-utility class was retired by the tool class of 2026-10-12; mark the file that defines the entry with a 'Tool, not a guarantee:' line and use a 'tool:' reason"
      ;;
    'hosted under another name: '*)
      tokens=$(printf '%s' "$er" | tr -cs 'A-Za-z0-9_-' '\n') \
        || setup_fail "reading the job identifier of $where"
      named=no
      while IFS= read -r tok || [ -n "$tok" ]; do
        [ -n "$tok" ] || continue
        if [ -n "${job_ids["$tok"]+x}" ]; then named=yes; fi
      done <<<"$tokens"
      [ "$named" = yes ] || {
        verdict_fail "$where: the reason names no declared job identifier"
        continue
      }
      ;;
    'tool: '*)
      if [ "$ef" != "." ]; then
        case "$efile" in
          "$ef/"*) ;;
          *)
            verdict_fail "$where: the file that defines the tool, $efile, lives outside the flake $ef; the marker travels with the file that defines the app"
            ;;
        esac
      fi
      load_tool_inputs "$where"
      tkey="$ef|$ea|$efile"
      tstatus="${tool_marker_status["$tkey"]-}"
      tmention="${tool_marker_names["$tkey"]-}"
      case "$tstatus" in
        marked) ;;
        unmarked)
          verdict_fail "$where: the file that defines the tool, $efile, carries no 'Tool, not a guarantee:' marker line"
          ;;
        missing)
          verdict_fail "$where: the file that defines the tool, $efile, does not exist"
          ;;
        *)
          verdict_fail "$where: no tool-marker line was handed for $ef $ea ($efile), the file that defines the tool"
          ;;
      esac
      if [ "$tstatus" = marked ] && [ "$tmention" != names ]; then
        verdict_fail "$where: the file that defines the tool, $efile, does not name the attribute $ea it certifies; the marker must live in the file that defines the app"
      fi
      tool_forms=()
      if [ "$ef" = "." ]; then
        tool_forms=(".#$ea" "./#$ea" "'#$ea" '"'"#$ea")
      else
        tool_forms=("$ef#$ea" "./$ef#$ea")
      fi
      for cit_form in "${tool_forms[@]}" "$efile"; do
        if [ -n "${tool_citation_paths["$cit_form"]+x}" ]; then
          verdict_fail "$where: the tool $ea of flake $ef is cited as evidence or guarantee in ${tool_citation_paths["$cit_form"]} (as $cit_form); a tool is never cited"
        fi
      done
      tool_count=$((tool_count + 1))
      tool_names="$tool_names$ef $ea, "
      tool_entry["$ef|$ea|$ek"]=1
      ;;
    *)
      verdict_fail "$where: the reason must start with 'retired:', 'hosted under another name:' or 'tool:'"
      continue
      ;;
  esac
done <"$list_file"

hosted_apps_count=0
for key in "${!hosted_apps[@]}"; do
  if [ -n "${declared_apps[$key]+x}" ]; then hosted_apps_count=$((hosted_apps_count + 1)); fi
done
hosted_checks_count=0
for key in "${!hosted_check_mechanism[@]}"; do
  if [ -n "${declared_checks[$key]+x}" ]; then hosted_checks_count=$((hosted_checks_count + 1)); fi
done

for d in "${!declared_flakes[@]}"; do
  for key in "${!declared_apps[@]}"; do
    [ "${key%%|*}" = "$d" ] || continue
    a="${key#*|}"
    if [ -n "${hosted_apps[$key]+x}" ]; then
      printf 'hosted app %s %s (run by a workflow step)\n' "$d" "$a"
    elif [ -z "${listed["$d|$a|app"]+x}" ]; then
      verdict_fail "app $a of flake $d is declared and named by no workflow step, and carries no declared-not-hosted entry"
    elif [ -n "${tool_entry["$d|$a|app"]+x}" ]; then
      printf 'not hosted app %s %s (tool, named below)\n' "$d" "$a"
    else
      printf 'not hosted app %s %s (declared-not-hosted list)\n' "$d" "$a"
    fi
  done
  for key in "${!declared_checks[@]}"; do
    [ "${key%%|*}" = "$d" ] || continue
    c="${key#*|}"
    if [ -n "${hosted_check_mechanism[$key]+x}" ]; then
      printf 'hosted check %s %s (%s)\n' "$d" "$c" "${hosted_check_mechanism[$key]}"
    elif [ -z "${listed["$d|$c|check"]+x}" ]; then
      verdict_fail "check $c of flake $d is declared and named by no workflow step, and carries no declared-not-hosted entry"
    elif [ -n "${tool_entry["$d|$c|check"]+x}" ]; then
      printf 'not hosted check %s %s (tool, named below)\n' "$d" "$c"
    else
      printf 'not hosted check %s %s (declared-not-hosted list)\n' "$d" "$c"
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "declared-checks-classify: FAIL" >&2
  exit 1
fi
printf 'declared %d apps and %d checks across %d flakes; hosted %d apps and %d checks; %d reasoned entries; %d tools\n' \
  "$apps_total" "$checks_total" "${#declared_flakes[@]}" "$hosted_apps_count" "$hosted_checks_count" "$listed_count" "$tool_count"
if [ "$tool_count" -gt 0 ]; then
  tool_names="${tool_names%, }"
  printf 'tools, marked and never cited as evidence: %s\n' "$tool_names"
fi
echo "declared-checks-classify: PASS"
