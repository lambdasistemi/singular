#!/usr/bin/env bash
# negative-host-lint (row 6d): format and lint of applications/open-datum/negative.
# Uses the repository's pinned formatter and linter over the host's own
# sources, since the new package sits outside Off-chain lint's extent.
# usage: negative_host_lint.sh REPO-ROOT
set -euo pipefail
[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$1"
cd "$root"

fail() {
  echo "negative-host-lint: FAIL: $*" >&2
  exit 1
}

# The host's own sources exist.
[ -f applications/open-datum/negative/singular-negative.cabal ] || fail "host cabal absent"
[ -f applications/open-datum/negative/app/Main.hs ] || fail "host Main absent"

# Format with the pinned house formatter from the open-datum flake.
fourmolu="$(nix build --quiet --no-link --print-out-paths ./applications/open-datum/offchain#fourmolu)"
[ -x "$fourmolu/bin/fourmolu" ] || fail "fourmolu binary missing at $fourmolu"
# shellcheck disable=SC2046
"$fourmolu/bin/fourmolu" --mode check $(find applications/open-datum/negative -name '*.hs' | sort) \
  || fail "unformatted host module (run fourmolu on applications/open-datum/negative)"

# Positive control: an unformatted copy fails the same check.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp applications/open-datum/negative/src/Negative/Parse.hs "$tmp/Unformatted.hs"
printf '\n\n   badly   formatted   =   1\n' >>"$tmp/Unformatted.hs"
if "$fourmolu/bin/fourmolu" --mode check "$tmp/Unformatted.hs" >/dev/null 2>&1; then
  fail "control: unformatted copy passed the format check"
fi

# The host builds warning-clean: the hermetic Nix build, which carries
# the cabal file's -Wall -Werror (a cabal build outside Nix would need a
# machine-local package index and network fetches that runners lack).
nix build --quiet --no-link --print-out-paths ./applications/open-datum/offchain#singular-negative >/dev/null \
  || fail "host does not build warning-clean"

# Lint with the pinned house linter: the exact HLint the offchain dev
# shell carries, over the host's own sources.
# shellcheck disable=SC2046
if ! nix develop ./applications/open-datum/offchain --quiet --command hlint $(find applications/open-datum/negative -name '*.hs' | sort); then
  fail "hlint reports a hint (see above)"
fi
# Positive control: a hinted copy fails the same check.
cp applications/open-datum/negative/src/Negative/Parse.hs "$tmp/Hinted.hs"
printf '\nbadlyHinted xs = length xs == 0\n' >>"$tmp/Hinted.hs"
if hlint "$tmp/Hinted.hs" >/dev/null 2>&1; then
  fail "control: hinted copy passed the lint check"
fi

# Aggregate jobs: the two stable check names. Each aggregate needs exactly
# the discovery and the matrix job of its family, carries `if: always()`,
# and passes exactly when every needed result is success (registry.yml
# precedent: `e2e` and `demo1-attach`). yq-go comes from the lint app's
# runtimeInputs. The result guard executes the aggregate's own run script
# under bash -e over every combination of success, failure, cancelled and
# skipped: reading the text cannot tell `&&` from `||`, `= success` from
# `!= failure`, or one variable tested twice.
workflow=".github/workflows/negative-host.yml"
[ -f "$workflow" ] || fail "workflow $workflow absent"

aggregate_needs() {
  # $1 = workflow file, $2 = aggregate id, $3 = discovery id, $4 = matrix id.
  # One guard: needs equals the two expected jobs as a set.
  local file="$1" agg="$2" disc="$3" mat="$4"
  local have want
  have="$(yq eval ".jobs.\"$agg\".needs[]" "$file" | sort -u | tr '\n' ' ')" || return 1
  want="$(printf '%s\n%s\n' "$disc" "$mat" | sort -u | tr '\n' ' ')" || return 1
  [ "$have" = "$want" ] || return 1
}

aggregate_if() {
  # One guard: the job carries `if: always()`.
  local file="$1" agg="$2"
  [ "$(yq eval ".jobs.\"$agg\".if" "$file")" = "always()" ] || return 1
}

aggregate_result() {
  # One guard: the run script exits 0 exactly when both needed results are
  # success. Every env variable is set to the result of the job its binding
  # (`${{ needs.<job>.result }}`) names, over all sixteen combinations.
  local file="$1" agg="$2" disc="$3" mat="$4"
  local run_script vars
  run_script="$(yq eval ".jobs.\"$agg\".steps[0].run" "$file")" || return 1
  vars="$(yq eval ".jobs.\"$agg\".steps[0].env | keys | .[]" "$file")" || return 1
  [ -n "$vars" ] || return 1
  local disc_vars mat_vars v binding ref
  disc_vars=""
  mat_vars=""
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    binding="$(yq eval ".jobs.\"$agg\".steps[0].env.\"$v\"" "$file")" || return 1
    case "$binding" in
      *'needs.'*'.result'*) ;;
      *) return 1 ;;
    esac
    ref="${binding##*needs.}"
    ref="${ref%%.result*}"
    if [ "$ref" = "$disc" ]; then
      disc_vars="$disc_vars $v"
    elif [ "$ref" = "$mat" ]; then
      mat_vars="$mat_vars $v"
    else
      return 1
    fi
  done <<<"$vars"
  local d m args status
  # shellcheck disable=SC2086
  for d in success failure cancelled skipped; do
    for m in success failure cancelled skipped; do
      args=""
      for v in $disc_vars; do
        args="$args $v=$d"
      done
      for v in $mat_vars; do
        args="$args $v=$m"
      done
      if env $args bash -e -c "$run_script" >/dev/null 2>&1; then
        status=0
      else
        status=1
      fi
      if [ "$d" = success ] && [ "$m" = success ]; then
        [ "$status" = 0 ] || return 1
      else
        [ "$status" != 0 ] || return 1
      fi
    done
  done
}

check_aggregate() {
  aggregate_needs "$@" || return 1
  aggregate_if "$@" || return 1
  aggregate_result "$@" || return 1
}

assert_control() {
  # $1 = broken file, $2 = aggregate id, $3 = discovery id, $4 = matrix id,
  # $5 = own guard (needs, if or result): the copy is rejected by its own
  # guard alone, passing the other two.
  local file="$1" agg="$2" disc="$3" mat="$4" own="$5"
  if check_aggregate "$file" "$agg" "$disc" "$mat"; then
    return 1
  fi
  case "$own" in
    needs)
      if aggregate_needs "$file" "$agg" "$disc" "$mat"; then
        return 1
      fi
      aggregate_if "$file" "$agg" || return 1
      aggregate_result "$file" "$agg" "$disc" "$mat" || return 1
      ;;
    if)
      aggregate_needs "$file" "$agg" "$disc" "$mat" || return 1
      if aggregate_if "$file" "$agg"; then
        return 1
      fi
      aggregate_result "$file" "$agg" "$disc" "$mat" || return 1
      ;;
    result)
      aggregate_needs "$file" "$agg" "$disc" "$mat" || return 1
      aggregate_if "$file" "$agg" || return 1
      if aggregate_result "$file" "$agg" "$disc" "$mat"; then
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

check_aggregate "$workflow" negative-host-pairs negative-host-parts negative-host-part \
  || fail "aggregate Negative host pairs: needs/if/result check failed"
check_aggregate "$workflow" negative-host-mutants negative-host-mutant-list negative-host-mutant \
  || fail "aggregate Negative host mutants: needs/if/result check failed"

# Controls through the same guards, one mechanical yq change each.
# Pairs result controls: `||` for `&&`; `!= failure` for `= success`;
# the matrix variable tested twice.
yq eval '(.jobs."negative-host-pairs".steps[].run | select(. != null)) |= sub("&&"; "||")' "$workflow" >"$tmp/broken-pairs-or.yml"
assert_control "$tmp/broken-pairs-or.yml" negative-host-pairs negative-host-parts negative-host-part result \
  || fail "control: pairs || copy not rejected by the result guard alone"
yq eval '(.jobs."negative-host-pairs".steps[].run | select(. != null)) |= sub("= success"; "!= failure")' "$workflow" >"$tmp/broken-pairs-test.yml"
assert_control "$tmp/broken-pairs-test.yml" negative-host-pairs negative-host-parts negative-host-part result \
  || fail "control: pairs != failure copy not rejected by the result guard alone"
yq eval '(.jobs."negative-host-pairs".steps[].run | select(. != null)) |= sub("PART\" = success"; "PARTS\" = success")' "$workflow" >"$tmp/broken-pairs-twice.yml"
assert_control "$tmp/broken-pairs-twice.yml" negative-host-pairs negative-host-parts negative-host-part result \
  || fail "control: pairs twice-tested copy not rejected by the result guard alone"
yq eval '.jobs."negative-host-pairs".needs = ["negative-host-parts"]' "$workflow" >"$tmp/broken-pairs-needs.yml"
assert_control "$tmp/broken-pairs-needs.yml" negative-host-pairs negative-host-parts negative-host-part needs \
  || fail "control: pairs needs copy not rejected by the needs guard alone"
yq eval 'del(.jobs."negative-host-pairs".if)' "$workflow" >"$tmp/broken-pairs-if.yml"
assert_control "$tmp/broken-pairs-if.yml" negative-host-pairs negative-host-parts negative-host-part if \
  || fail "control: pairs no-if copy not rejected by the if guard alone"
# Mutants result controls, needs control and if control: the same five.
yq eval '(.jobs."negative-host-mutants".steps[].run | select(. != null)) |= sub("&&"; "||")' "$workflow" >"$tmp/broken-mutants-or.yml"
assert_control "$tmp/broken-mutants-or.yml" negative-host-mutants negative-host-mutant-list negative-host-mutant result \
  || fail "control: mutants || copy not rejected by the result guard alone"
yq eval '(.jobs."negative-host-mutants".steps[].run | select(. != null)) |= sub("= success"; "!= failure")' "$workflow" >"$tmp/broken-mutants-test.yml"
assert_control "$tmp/broken-mutants-test.yml" negative-host-mutants negative-host-mutant-list negative-host-mutant result \
  || fail "control: mutants != failure copy not rejected by the result guard alone"
yq eval '(.jobs."negative-host-mutants".steps[].run | select(. != null)) |= sub("MUTANT\" = success"; "MUTANTS\" = success")' "$workflow" >"$tmp/broken-mutants-twice.yml"
assert_control "$tmp/broken-mutants-twice.yml" negative-host-mutants negative-host-mutant-list negative-host-mutant result \
  || fail "control: mutants twice-tested copy not rejected by the result guard alone"
yq eval '.jobs."negative-host-mutants".needs = ["negative-host-mutant-list"]' "$workflow" >"$tmp/broken-mutants-needs.yml"
assert_control "$tmp/broken-mutants-needs.yml" negative-host-mutants negative-host-mutant-list negative-host-mutant needs \
  || fail "control: mutants needs copy not rejected by the needs guard alone"
yq eval 'del(.jobs."negative-host-mutants".if)' "$workflow" >"$tmp/broken-mutants-if.yml"
assert_control "$tmp/broken-mutants-if.yml" negative-host-mutants negative-host-mutant-list negative-host-mutant if \
  || fail "control: mutants no-if copy not rejected by the if guard alone"

echo "negative-host-lint: PASS"
