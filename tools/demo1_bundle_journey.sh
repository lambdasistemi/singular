#!/usr/bin/env bash
# demo1-bundle-journey (#707): the Demo 1 journey from the unpacked Linux
# release bundle alone. `singular`, `open-datum` and the development node all
# come out of the tarball, and the journey runs on a PATH that holds ordinary
# tools and no Nix, the way a user without Nix runs the development node page.
#
# usage: demo1_bundle_journey.sh TARBALL BLUEPRINT
#
# TARBALL is singular-VERSION-SYSTEM.tar.gz; BLUEPRINT the registry
# partition's plutus.json (a user takes it from the on-chain archive).
# DEMO1_JOURNEY names demo1_cli_journey.sh and DEMO1_BUNDLE_TOOLS a directory
# of ordinary tools (bash, coreutils, grep, sed, jq, procps and the like),
# which becomes the whole PATH. The journey is the same one the release
# archive's check runs: Alice and Bob, every command a separate process
# against one node, every refusal at its boundary.
#
# Exit 0 and a `demo1-bundle-journey: PASS` line, or exit 1 and one FAIL line.
set -euo pipefail

fail() {
  echo "demo1-bundle-journey: FAIL: $*" >&2
  exit 1
}
[ "$#" -eq 2 ] || {
  echo "usage: $0 TARBALL BLUEPRINT" >&2
  exit 2
}
tarball="$1"
blueprint="$2"
journey="${DEMO1_JOURNEY:?demo1-bundle-journey needs DEMO1_JOURNEY}"
tools="${DEMO1_BUNDLE_TOOLS:?demo1-bundle-journey needs DEMO1_BUNDLE_TOOLS}"
[ -f "$tarball" ] || fail "no tarball at $tarball"
[ -f "$blueprint" ] || fail "no blueprint at $blueprint"
[ -d "$tools" ] || fail "no tool directory at $tools"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-bundle.XXXXXX")"
# shellcheck disable=SC2329 # the EXIT trap below invokes this
release_scratch() {
  local code=$?
  trap - EXIT
  # a node of this run never outlives it
  pkill -f "cardano-node run --config $scratch/" >/dev/null 2>&1 || true
  chmod -R u+rwx "$scratch" 2>/dev/null || true
  rm -rf "$scratch" || true
  exit "$code"
}
trap release_scratch EXIT

mkdir -p "$scratch/tree" "$scratch/home" "$scratch/tmp"
tar -xzf "$tarball" -C "$scratch/tree"
bundle="$scratch/tree/$(ls "$scratch/tree")"
for program in singular open-datum devnet; do
  [ -x "$bundle/bin/$program" ] || fail "the tarball carries no bin/$program"
done
# the blueprint as the on-chain archive lays it out: onchain/plutus.json with
# the release number beside it, which the journey requires
mkdir -p "$scratch/onchain"
cp "$blueprint" "$scratch/onchain/plutus.json"
cp "$bundle/VERSION" "$scratch/onchain/version.txt"
blueprint="$scratch/onchain/plutus.json"

# the route holds no Nix: the PATH is the ordinary tools, and a Nix on it
# would make the run say nothing about a user without one
if PATH="$tools" command -v nix >/dev/null 2>&1; then
  fail "the tool directory $tools holds a nix"
fi
for tool in bash jq timeout seq; do
  PATH="$tools" command -v "$tool" >/dev/null 2>&1 || fail "the tool directory holds no $tool"
done

echo "demo1-bundle-journey: $(env -i PATH="$tools" "$bundle/bin/singular" --version)"
echo "demo1-bundle-journey: $(env -i PATH="$tools" "$bundle/bin/devnet" --version)"
# the journey is a bash script and its own shebang names the host's env, so it
# is started by the tool directory's bash
env -i HOME="$scratch/home" TMPDIR="$scratch/tmp" PATH="$tools" \
  "$tools/bash" "$journey" "$bundle/bin/singular" "$bundle/bin/open-datum" "$bundle/bin/devnet" \
  "$blueprint" "$scratch/journey" ordinary
echo "demo1-bundle-journey: PASS — Demo 1 from $(basename "$tarball"), no Nix on the PATH"
