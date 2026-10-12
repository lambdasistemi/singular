#!/usr/bin/env bash
# declared-checks-classify: the pure verdict over three plain files.
#
# Usage: declared_checks_classify.sh DECLARED HOSTED LIST JOBS [STATES]
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
#   LIST      lines `flake|attribute|kind|reason`: the declared-not-hosted
#             entries with their reasons.
#   JOBS      one workflow job id per line: what a `hosted under another
#             name` reason may name.
#   STATES    optional lines `<number> <open|closed>`: the issue states a
#             `pending wiring` reason names. Read lazily: a run with no
#             pending entry needs no source.
#
# The classifier reads no flake, no git tree, no network and no clock, so a
# test feeds it fixtures. Exit 0: every declared entry hosted or reasoned
# and every list entry live. Exit 1: a verdict failure, each named on
# stderr. Exit 2: setup failure (a missing input, an empty declared extent,
# an unreachable or malformed state source) — never a verdict.
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

[ "$#" -ge 4 ] || setup_fail "usage: $0 DECLARED HOSTED LIST JOBS [STATES]"
declared_file="$1"
hosted_file="$2"
list_file="$3"
jobs_file="$4"
states_file="${5:-}"

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

# The state of an issue a `pending wiring` reason names, loaded once from
# the handed source into globals in this shell (never a subshell, so a
# setup failure ends the run). An unreachable or malformed source is a
# setup failure with a diagnostic, never a verdict and never a silent pass.
declare -A issue_state=()
issue_states_loaded=0
issue_state_value=""
issue_state_of() {
  local number="$1" n s
  issue_state_value=""
  if [ "$issue_states_loaded" -eq 0 ]; then
    [ -n "$states_file" ] \
      || setup_fail "a pending-wiring entry names issue #$number and no issue-state source was handed (pass a file of '<number> <open|closed>' lines as the fifth argument)"
    [ -f "$states_file" ] \
      || setup_fail "the issue-state source $states_file does not exist"
    while IFS=' ' read -r n s dummy || [ -n "$n" ]; do
      [ -n "$n" ] || continue
      case "$n" in
        '' | *[!0-9]*) setup_fail "malformed issue-state line '$n $s' in $states_file (expected '<number> <open|closed>')" ;;
      esac
      case "$s" in
        open | closed) ;;
        *) setup_fail "malformed issue-state line '$n $s' in $states_file (expected '<number> <open|closed>')" ;;
      esac
      [ -z "${dummy:-}" ] || setup_fail "malformed issue-state line '$n $s $dummy' in $states_file (expected '<number> <open|closed>')"
      issue_state["$n"]="$s"
    done <"$states_file"
    issue_states_loaded=1
  fi
  [ -n "${issue_state[$number]+x}" ] \
    || setup_fail "the issue-state source answers nothing for issue #$number, which a pending-wiring entry names"
  issue_state_value="${issue_state[$number]}"
}

declare -A listed=()
declare -A pending_entry=()
pending_count=0
pending_names=""
listed_count=0
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  case "$line" in
    '' | '#'*) continue ;;
  esac
  IFS='|' read -r ef ea ek er extra <<<"$line"
  where="list line $lineno: $line"
  [ -n "$ef" ] && [ -n "$ea" ] && [ -n "$ek" ] || {
    verdict_fail "$where: a flake, attribute and kind are required"
    continue
  }
  [ -z "${extra:-}" ] || {
    verdict_fail "$where: more than four fields"
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
  case "$er" in
    'retired: '*)
      case "$er" in
        *component-inventory*) ;;
        *)
          verdict_fail "$where: a retired reason cites the classification and its reason in offchain/nix/component-inventory.nix"
          ;;
      esac
      ;;
    'developer utility: '*) ;;
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
    'pending wiring: '*)
      if [[ "$er" =~ ^pending\ wiring:\ \#([0-9]+),.+ ]]; then
        issue="${BASH_REMATCH[1]}"
      else
        verdict_fail "$where: a pending-wiring reason names its issue as '#<number>, <what hosts it>'"
        continue
      fi
      if [ "$ef" != "release-review" ] || [ "$issue" != "565" ] || [ "$ek" != "app" ]; then
        verdict_fail "$where: pending wiring admits only the release-review check and default apps (kind app) with issue #565 (closed membership)"
        continue
      fi
      if [ "$ea" != "check" ] && [ "$ea" != "default" ]; then
        verdict_fail "$where: pending wiring admits only the release-review check and default apps with issue #565 (closed membership)"
        continue
      fi
      issue_state_of "$issue"
      case "$issue_state_value" in
        open)
          pending_count=$((pending_count + 1))
          pending_names="$pending_names$ef $ea (#$issue), "
          pending_entry["$ef|$ea|$ek"]=1
          ;;
        closed)
          verdict_fail "$where: issue #$issue is closed; the pending-wiring entry outlived its fix"
          ;;
      esac
      ;;
    *)
      verdict_fail "$where: the reason must start with 'retired:', 'developer utility:', 'hosted under another name:' or 'pending wiring:'"
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
    elif [ -n "${pending_entry["$d|$a|app"]+x}" ]; then
      printf 'not hosted app %s %s (pending wiring, named below)\n' "$d" "$a"
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
    elif [ -n "${pending_entry["$d|$c|check"]+x}" ]; then
      printf 'not hosted check %s %s (pending wiring, named below)\n' "$d" "$c"
    else
      printf 'not hosted check %s %s (declared-not-hosted list)\n' "$d" "$c"
    fi
  done
done

if [ "$fail" -ne 0 ]; then
  echo "declared-checks-classify: FAIL" >&2
  exit 1
fi
printf 'declared %d apps and %d checks across %d flakes; hosted %d apps and %d checks; %d reasoned entries; %d pending wiring\n' \
  "$apps_total" "$checks_total" "${#declared_flakes[@]}" "$hosted_apps_count" "$hosted_checks_count" "$listed_count" "$pending_count"
if [ "$pending_count" -gt 0 ]; then
  pending_names="${pending_names%, }"
  printf 'pending wiring, temporary until the slice that hosts them removes the entries: %s\n' "$pending_names"
fi
echo "declared-checks-classify: PASS"
