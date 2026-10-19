#!/usr/bin/env bash
# demo1-closed-check (#660): the closed-datum journey from the extracted release
# archive, with no checkout in sight.
#
# usage: demo1_closed_check.sh REPO-ROOT
#
# 1. The normal release archive is assembled from REPO-ROOT by the same
#    `release-artifacts` app CI runs.
# 2. Those assets are verified by `verify-release` (#326) exactly as a
#    published release is, presented as its download input: the sums, the
#    stated model revision, the archive members, and the closed journey
#    (demo1_closed_journey.sh) — `singular`, `open-datum` and the development
#    node built from the archive's own offchain flake and the application's
#    offchain flake, extracted OUTSIDE the checkout, and the commands run as
#    separate processes against ONE node: create with the closed switch, the
#    page reading, insert, fold, inspect, the refused update with its
#    no-transaction reads, terminate, fold, inspect and the deposit read,
#    with the archive's own blueprint.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$1"
verify="${DEMO1_VERIFY_RELEASE:?demo1-closed-check needs DEMO1_VERIFY_RELEASE}"
fail() {
  echo "demo1-closed-check: FAIL: $*" >&2
  exit 1
}

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-closed.XXXXXX")"
# Stop the node before removing the tree: a live node makes a plain removal fail.
# DEMO1_KEEP_SCRATCH=1 keeps the tree and names it.
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
# The bundles are built and run by their own workflow, so the release staged
# here carries none: the verifier is told so, and then refuses any it finds.
"$verify" --assets "$release_dir" --without-bundles --work "$scratch/verify" "v$version"
extracted="$scratch/verify/extracted"
# The archive itself carries no git checkout: assert on the tarball's member
# list, not on the extraction directory. The listing goes to a file first so a
# failed `tar` fails the check with its own message instead of reading as
# absent, and `grep` never closes the producer early (pipefail/SIGPIPE).
members="$scratch/tar-members.txt"
tar -tzf "$release_dir/singular-onchain-$version.tar.gz" >"$members" 2>"$scratch/tar-members.err" \
  || fail "the archive does not list its members: $(tail -n 3 "$scratch/tar-members.err" | tr '\n' ' ')"
if grep -qE '(^|/)\.git($|/)' "$members"; then
  fail "the archive carries a git checkout"
fi
test -f "$extracted/DEMO1.md" || fail "the archive carries no DEMO1.md run page"

echo "demo1-closed-check: PASS from $extracted — the release verified as published (sums, model revision, members, the closed-datum journey as separate processes on one node)"
