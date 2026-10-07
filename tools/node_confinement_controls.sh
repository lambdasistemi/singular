#!/usr/bin/env bash
# Controls for tools/node_confinement_check.sh: it passes on this tree and
# fails, with its named diagnostic, on each defect it exists to refuse.
#
# Every control runs on a scratch copy of the scanned roots and the
# allowlist; the tree itself is never touched. The scanned roots are the
# check's own (--roots), and a backend name is planted in every one of
# them as a new nested module, so the controls cover a root added to the
# check without being edited.
set -euo pipefail

repo=${1:-.}
check="$repo/tools/node_confinement_check.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

mapfile -t roots < <(bash "$check" --roots)
[ ${#roots[@]} -gt 0 ] || {
  echo "SETUP-FAIL: the check names no scanned root" >&2
  exit 2
}

fresh() {
  rm -rf "$scratch/t"
  mkdir -p "$scratch/t/tools"
  for r in "${roots[@]}"; do
    mkdir -p "$scratch/t/$(dirname "$r")"
    cp -r "$repo/$r" "$scratch/t/$r"
  done
  find "$scratch/t" -name dist-newstyle -prune -exec rm -rf {} +
  cp "$repo/tools/node-confinement.allow" "$scratch/t/tools/"
  mkdir -p "$scratch/t/offchain/nix"
  cp "$repo/offchain/nix/component-inventory.nix" "$scratch/t/offchain/nix/"
  cp "$repo/offchain/singular-registry.cabal" "$scratch/t/offchain/"
  mkdir -p "$scratch/t/offchain/private-facade/Singular/Registry/Private"
  cp "$repo/offchain/private-facade/Singular/Registry/Private/RawFacts.hs" "$scratch/t/offchain/private-facade/Singular/Registry/Private/"
}

# retire NAME DIR: declare a component with sources under offchain/DIR in
# the scratch Cabal file and classify it `unverified` in the inventory.
retire() {
  printf '\nexecutable %s\n  hs-source-dirs:   %s\n  main-is:          Main.hs\n' "$1" "$2" \
    >>"$scratch/t/offchain/singular-registry.cabal"
  sed -i "0,/^  unverified = \\[/s//  unverified = [\\n    { kind = \"exe\"; name = \"$1\"; issue = \"#0\"; reason = \"control\"; }/" \
    "$scratch/t/offchain/nix/component-inventory.nix"
  grep -q "name = \"$1\"; issue" "$scratch/t/offchain/nix/component-inventory.nix" || {
    echo "SETUP-FAIL: the inventory row for $1 did not apply" >&2
    exit 2
  }
}

# expect NAME STATUS PATTERN: the check on the scratch tree exits STATUS
# and its output matches PATTERN.
expect() {
  local name="$1" want="$2" pattern="$3" got=0
  bash "$check" "$scratch/t" >"$scratch/out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ] || ! grep -qE -- "$pattern" "$scratch/out"; then
    cat "$scratch/out" >&2
    echo "FAIL node-confinement control '$name': exit $got (wanted $want), pattern '$pattern'" >&2
    exit 1
  fi
  echo "control $name: exit $got, $(grep -cE -- "$pattern" "$scratch/out") matching line(s)"
}

fresh
expect clean-tree 0 '^PASS node-confinement'

# The plant is a new module, nested one directory down in each root: the
# check must discover it, whatever the root's allowlisted modules are.
planted=0
for root in "${roots[@]}"; do
  target="$root/Planted/Consumer.hs"
  [ ! -e "$scratch/t/$target" ] || {
    echo "SETUP-FAIL: $target already exists" >&2
    exit 2
  }

  fresh
  mkdir -p "$scratch/t/$root/Planted"
  printf 'module Planted.Consumer where\n\nimport Data.List (sort)\nimport Singular.Registry.Node (NodeMode (..))\n' >"$scratch/t/$target"
  expect "planted-mode $root" 1 "^$target:[0-9]+:import Singular.Registry.Node \\(NodeMode"

  fresh
  mkdir -p "$scratch/t/$root/Planted"
  printf 'module Planted.Consumer where\n\nrawSend = submitTx\n' >"$scratch/t/$target"
  expect "planted-raw-submit $root" 1 "^$target:[0-9]+:rawSend = submitTx"
  planted=$((planted + 1))
done

# A retired component's sources drop out of the scan, and only through
# its inventory row: the same planted journey fails without the row.
fresh
mkdir -p "$scratch/t/offchain/journey/planted-retired"
printf 'module Main where\n\nrawSend = submitTx\n' >"$scratch/t/offchain/journey/planted-retired/Main.hs"
expect unretired-journey 1 '^offchain/journey/planted-retired/Main.hs:[0-9]+:rawSend = submitTx'
retire planted-retired journey/planted-retired
expect retired-journey 0 '^excluded offchain/journey/planted-retired: planted-retired, retired \(#0\)'

fresh
retire planted-built journey
expect retired-holds-built 1 "^retired: offchain/journey holds the sources of built component 'journey'"

fresh
sed -i "0,/^  unverified = \\[/s//  unverified = [\\n    { kind = \"exe\"; name = \"no-such-component\"; issue = \"#0\"; reason = \"control\"; }/" \
  "$scratch/t/offchain/nix/component-inventory.nix"
expect retired-unknown 1 "^retired: inventory row 'no-such-component' names no Cabal component"

# A spec is exempt only as the own test of a backend session or adapter
# module whose definitions it names: a consumer, a fixture or a facade
# named as the subject fails, and so does a spec naming nothing its
# subject defines.
own_test() {
  local name="$1" spec="$2" subject="$3" pattern="$4"
  fresh
  printf '\nrawSend = submitTx\n' >>"$scratch/t/$spec"
  printf '%s: own test of %s — control\n' "$spec" "$subject" >>"$scratch/t/tools/node-confinement.allow"
  expect "$name" 1 "^allowlist: '$spec' $pattern"
}
own_test own-test-of-consumer offchain/journey/Journey/Chain.hs \
  offchain/lib/Singular/Registry/Lifecycle.hs \
  "is an own test of 'offchain/lib/Singular/Registry/Lifecycle.hs', which is not a backend session or adapter module"
own_test own-test-of-fixture offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs \
  offchain/e2e-test/Singular/Registry/E2E/Fixture.hs \
  "is an own test of 'offchain/e2e-test/Singular/Registry/E2E/Fixture.hs', which is not a backend session or adapter module"
own_test own-test-of-facade offchain/journey/Journey/Chain.hs \
  offchain/lib/Singular/Registry/Capabilities.hs \
  "is an own test of 'offchain/lib/Singular/Registry/Capabilities.hs', which is not a backend session or adapter module"
own_test own-test-unlinked offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs \
  offchain/private-facade/Singular/Registry/Private/RawFacts.hs \
  "names nothing Singular.Registry.Private.RawFacts defines, the backend module it claims to test"

fresh
printf 'offchain/cli/Main.hs:\n' >>"$scratch/t/tools/node-confinement.allow"
expect reasonless-entry 1 "'offchain/cli/Main.hs' carries no reason"

fresh
printf 'offchain/cli/Gone.hs: a module that is not there\n' >>"$scratch/t/tools/node-confinement.allow"
expect stale-entry 1 "'offchain/cli/Gone.hs' does not exist"

fresh
printf 'offchain/cli/Main.hs: names nothing confined\n' >>"$scratch/t/tools/node-confinement.allow"
expect unneeded-entry 1 "'offchain/cli/Main.hs' names no confined identifier"

for root in "${roots[@]}"; do
  fresh
  rm -rf "${scratch:?}/t/$root"
  mkdir -p "$scratch/t/$root"
  expect "empty-extent $root" 2 "^EMPTY EXTENT: no Haskell sources under .*/$root\$"
done

echo "PASS node-confinement-controls: $((2 * planted + 12 + ${#roots[@]})) controls over ${#roots[@]} scanned roots, a backend name planted in each"
