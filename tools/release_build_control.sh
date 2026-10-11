#!/usr/bin/env bash
# Inspect the actual ordinary and explicitly enabled test executable closures.
set -euo pipefail
[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$(cd "$1" && pwd)"
check="${RELEASE_BINARY_CHECK:?compiled binary checker required}"
scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/release-build.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
build() { nix build --quiet --no-write-lock-file --no-link --print-out-paths "$1"; }
ordinary_registry="$(build "$root/offchain#singular")/bin/singular"
test_registry="$(build "$root/offchain#singular-test-harness")/bin/singular"
ordinary_application="$(build "$root/applications/open-datum/offchain#open-datum")/bin/open-datum"
test_application="$(build "$root/applications/open-datum/offchain#open-datum-test-harness")/bin/open-datum"
for binary in "$ordinary_registry" "$ordinary_application"; do
  python3 "$check" "$binary"
  status=0
  python3 "$check" --test-harness "$binary" >"$scratch/polarity.log" 2>&1 || status=$?
  cat "$scratch/polarity.log"
  if [ "$status" -ne 1 ] || ! grep -q 'actual registry-cli flag must be test-harness' "$scratch/polarity.log"; then
    echo 'release-build-control: REFUSED: wrong flag polarity was not rejected' >&2
    exit 1
  fi
done
for binary in "$test_registry" "$test_application"; do
  python3 "$check" --test-harness "$binary"
  status=0
  python3 "$check" "$binary" >"$scratch/hooks.log" 2>&1 || status=$?
  cat "$scratch/hooks.log"
  if [ "$status" -ne 1 ] || ! grep -q 'stripped executable contains SINGULAR_HARNESS_' "$scratch/hooks.log"; then
    echo 'release-build-control: REFUSED: compiled hook-bearing artifact was not rejected' >&2
    exit 1
  fi
done
echo 'release-build-control: PASS: both stripped ordinary closures exclude hooks; actual flags disable them; opposite polarity and compiled test artifacts refused'
