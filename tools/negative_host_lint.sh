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

echo "negative-host-lint: PASS"
