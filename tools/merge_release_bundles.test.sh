#!/usr/bin/env bash
# The controls of merge_release_bundles.sh (#695): a release that ships
# bundles needs every platform's and merges them, a missing or extra bundle
# is refused, and an older release merges nothing.
#
# usage: merge_release_bundles.test.sh MERGE CONF
set -euo pipefail
[ "$#" -eq 2 ] || {
  echo "usage: merge_release_bundles.test.sh MERGE CONF" >&2
  exit 2
}
merge="$1"
conf="$2"
# shellcheck source=/dev/null
. "$conf"
work="$(mktemp -d "${TMPDIR:-/tmp}/merge-bundles-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
newer="99.0.0"

release_dir() {
  rm -rf "$work/release" "$work/bundles"
  mkdir -p "$work/release" "$work/bundles"
  printf 'docs' >"$work/release/singular-docs-$1.tar.gz"
  printf 'onchain' >"$work/release/singular-onchain-$1.tar.gz"
  (cd "$work/release" && sha256sum ./*.tar.gz | sed 's|  \./|  |' >SHA256SUMS)
}
bundle() { printf 'bundle %s' "$1" >"$work/bundles/singular-$2-$1.tar.gz"; }
must_fail() {
  label="$1"
  shift
  if "$@" >"$work/out" 2>&1; then
    echo "merge-release-bundles-controls: FAIL $label was accepted"
    exit 1
  fi
  echo "merge-release-bundles-controls: $label refused: $(grep -m1 FAIL "$work/out" | cut -c1-120)"
}

# every platform present: merged, listed after the archives, sums valid
release_dir "$newer"
for system in $SYSTEMS; do bundle "$system" "$newer"; done
bash "$merge" "$conf" "$work/release" "$work/bundles" "$newer" >"$work/out"
platforms=0
for _ in $SYSTEMS; do platforms=$((platforms + 1)); done
[ "$(wc -l <"$work/release/SHA256SUMS" | tr -d ' ')" -eq "$((2 + platforms))" ] \
  || {
    echo "merge-release-bundles-controls: FAIL the merged sums have the wrong number of lines"
    exit 1
  }
(cd "$work/release" && sha256sum --check --strict --quiet SHA256SUMS)
echo "merge-release-bundles-controls: every platform merges and the merged sums verify"

# one platform missing
for system in $SYSTEMS; do
  release_dir "$newer"
  for other in $SYSTEMS; do [ "$other" = "$system" ] || bundle "$other" "$newer"; done
  must_fail "a release without the $system bundle" bash "$merge" "$conf" "$work/release" "$work/bundles" "$newer"
done
# no bundle directory at all
release_dir "$newer"
must_fail "a release with no bundle directory" bash "$merge" "$conf" "$work/release" "" "$newer"
# a bundle for a platform the release does not ship
release_dir "$newer"
for system in $SYSTEMS; do bundle "$system" "$newer"; done
printf 'extra' >"$work/bundles/singular-$newer-riscv64-linux.tar.gz"
must_fail "an unexpected bundle" bash "$merge" "$conf" "$work/release" "$work/bundles" "$newer"
# a release before bundles merges nothing and needs none
release_dir "$LAST_WITHOUT"
bash "$merge" "$conf" "$work/release" "" "$LAST_WITHOUT" >/dev/null
[ "$(wc -l <"$work/release/SHA256SUMS" | tr -d ' ')" -eq 2 ] \
  || {
    echo "merge-release-bundles-controls: FAIL an older release's sums changed"
    exit 1
  }
echo "merge-release-bundles-controls: a release up to $LAST_WITHOUT needs no bundle"
# the threshold decides by version order, not by text
bundles_required 0.9.0 && {
  echo "merge-release-bundles-controls: FAIL 0.9.0 requires bundles"
  exit 1
}
bundles_required 0.13.0 || {
  echo "merge-release-bundles-controls: FAIL 0.13.0 does not require bundles"
  exit 1
}
bundles_required 0.100.0 || {
  echo "merge-release-bundles-controls: FAIL 0.100.0 does not require bundles"
  exit 1
}
echo "merge-release-bundles-controls: the threshold follows version order"
echo "merge-release-bundles-controls: PASS"
