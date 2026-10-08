#!/usr/bin/env bash
# demo1-cli-attach (#300): the demonstration's four refusals — an update that
# needs another wallet's signature, a release outside any fold, a second
# insertion of an Active key and an insertion of a Terminal key — each beside
# its accepting control, on ONE registry that already exists and two fresh keys,
# on one fresh development node, from the release archive with no checkout in
# sight.
#
# usage: demo1_cli_attach_check.sh REPO-ROOT
#
# The normal release archive is assembled from REPO-ROOT by the `release-artifacts`
# app CI runs and extracted OUTSIDE the checkout. The archive carries its own
# source, so its `singular`, the development node and the controls runner are
# built from the extraction — Nix reads a flake from a Git tree, so the build is
# done in a scratch copy of the extracted tree that is given a Git index, and the
# archive itself is not touched. The blueprint is the archive's, the bound
# statements are the archive's statement ledger, and the take is the archive's own
# tools/demo1_cli_attach.sh, which must be the one this checkout holds. The
# verdict sections are printed. The scratch is removed on exit.
# DEMO1_KEEP_SCRATCH=1 keeps it and prints its path.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$(cd "$1" && pwd)"
fail() {
  echo "demo1-cli-attach: FAIL: $*" >&2
  exit 1
}

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-attach.XXXXXX")"
# Stop the node before removing the tree. A mode-000 directory left by the
# run is made writable first. DEMO1_KEEP_SCRATCH=1 keeps the tree and names it.
# shellcheck disable=SC2329 # the EXIT trap below invokes this
release_scratch() {
  local code=$?
  local _wait
  trap - EXIT
  if [ -n "${scratch:-}" ] && [ -e "$scratch" ]; then
    if command -v pkill >/dev/null 2>&1; then
      pkill -f "cardano-node run --config ${scratch}/" >/dev/null 2>&1 || true
    fi
    for _wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
      if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -f "cardano-node run --config ${scratch}/" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
      echo "kept scratch: $scratch" >&2
    else
      chmod -R u+rwx "$scratch" 2>/dev/null || true
      rm -rf "$scratch" || true
      if [ -e "$scratch" ]; then
        echo "scratch remains: $scratch" >&2
        code=1
      fi
    fi
  fi
  exit "$code"
}
trap release_scratch EXIT
release_dir="$scratch/release"
mkdir -p "$release_dir"
(cd "$root" && nix run --quiet .#release-artifacts -- "$release_dir")
version="$(cat "$root/version.txt")"
extracted="$scratch/extracted"
mkdir -p "$extracted"
tar -C "$extracted" -xzf "$release_dir/singular-onchain-$version.tar.gz"
test ! -e "$extracted/.git" || fail "the archive carries a git checkout"
for carried in tools/demo1_cli_attach.sh tools/demo1_readback.sh tools/demo1_mock_indexer.py tools/demo1_readback_tamper.sh conformance/app-cli/Main.hs \
  applications/open-datum/ledgers.json specs/299-singular-cli/spec.md onchain/plutus.json; do
  test -f "$extracted/$carried" || fail "the archive does not carry $carried"
done
cmp "$extracted/tools/demo1_cli_attach.sh" "$root/tools/demo1_cli_attach.sh" \
  || fail "the archive's take differs from this checkout's"

# A Git index for Nix, on a copy: the archive stays as downloaded.
built="$scratch/built"
cp -r "$extracted" "$built"
git -C "$built" init --quiet
git -C "$built" add -A
git -C "$built" -c user.name=archive -c user.email=archive@invalid -c commit.gpgsign=false commit --quiet -m archive
build() { nix build --quiet --no-link --print-out-paths "$@"; }
cd "$built/offchain"
singular="$(build .#singular)/bin/singular"
devnet="$(build .#devnet)/bin/devnet"
controls="$(build ../conformance#cli-controls)/bin/cli-controls"

status=0
bash "$extracted/tools/demo1_cli_attach.sh" "$singular" "$devnet" "$controls" \
  "$extracted/onchain/plutus.json" "$extracted/applications/open-datum/ledgers.json" \
  "$scratch/run" || status=$?
cat "$scratch/run/one.md" "$scratch/run/two.md" 2>/dev/null || true
echo "demo1-cli-attach: receipts in $scratch/run (exit $status)"
exit "$status"
