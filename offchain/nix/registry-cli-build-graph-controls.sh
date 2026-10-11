#!/usr/bin/env bash
# registry-cli-build-graph-controls: the check catches what it claims to catch.
#
# The controls plant a cli/src source directory in a suite that must not
# list it, and a command-line module in the test suite that compiles only
# its specs, each plant verified applied before the check runs, and require
# the check to fail naming the plant; they never edit the tracked tree.
# Both anchors hold at every head — the base, where the suite still compiles
# the command line, and the compliant tree, where it compiles only specs —
# so each plant stays evaluable after the move. Each plant verifies its own
# application first: a plant that silently failed to apply would report
# "caught" while testing nothing. Exit 0: all plants caught. Exit 1: the
# check missed a plant. Exit 2: the harness failed.
#
# Usage: registry-cli-build-graph-controls [SRCDIR] (default: the working tree).
# Requires cabal on PATH: run under nix develop from offchain/
# (nix develop --quiet -c bash nix/registry-cli-build-graph-controls.sh).
set -euo pipefail

root="${1:-$PWD}"
check="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/registry-cli-build-graph-check.sh"
[ -x "$check" ] || {
  echo "registry-cli-build-graph-controls: check not executable: $check" >&2
  exit 2
}
[ -f "$root/singular-registry.cabal" ] || {
  echo "registry-cli-build-graph-controls: no singular-registry.cabal under $root" >&2
  exit 2
}
[ -f "$root/cabal.project" ] || {
  echo "registry-cli-build-graph-controls: no cabal.project under $root" >&2
  exit 2
}
[ -d "$root/cli/src" ] || {
  echo "registry-cli-build-graph-controls: no cli/src under $root" >&2
  exit 2
}
[ -d "$root/cli/ordinary" ] || {
  echo "registry-cli-build-graph-controls: no cli/ordinary under $root" >&2
  exit 2
}
[ -d "$root/cli/test-harness" ] || {
  echo "registry-cli-build-graph-controls: no cli/test-harness under $root" >&2
  exit 2
}
[ -d "$root/dist-newstyle/src" ] || {
  echo "registry-cli-build-graph-controls: no dist-newstyle/src under $root (the pinned git sources the offline solver reads)" >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

copy_tree() {
  mkdir -p "$work/$1"
  cp "$root/singular-registry.cabal" "$root/cabal.project" "$work/$1/"
  mkdir -p "$work/$1/cli"
  cp -r "$root/cli/src" "$root/cli/ordinary" "$root/cli/test-harness" "$work/$1/cli/"
  mkdir -p "$work/$1/dist-newstyle"
  cp -r "$root/dist-newstyle/src" "$work/$1/dist-newstyle/src"
}

# Plant 1: a cli/src source directory in a suite that must never list it.
# record-value-tests is clean at every head, so the plant is genuine and
# distinctly named: catching it proves the check quantifies over every
# stanza instead of looking only at cage-tests.
copy_tree plant-suite-dirs
sed -i 's|record-value-test test-tags|record-value-test test-tags cli/src|' "$work/plant-suite-dirs/singular-registry.cabal"
grep -q 'record-value-test test-tags cli/src' "$work/plant-suite-dirs/singular-registry.cabal" \
  || {
    echo "registry-cli-build-graph-controls: suite-dirs plant did not apply" >&2
    exit 2
  }
code=0
out=$(bash "$check" "$work/plant-suite-dirs" 2>&1) || code=$?
if [ "$code" -eq 0 ]; then
  echo "registry-cli-build-graph-controls: check MISSED the planted suite source directory" >&2
  exit 1
fi
if [ "$code" -ne 1 ]; then
  echo "registry-cli-build-graph-controls: check errored instead of naming the plant (exit $code):" >&2
  printf '%s\n' "$out" >&2
  exit 2
fi
printf '%s\n' "$out" | grep -q 'test:record-value-tests' \
  || {
    echo "registry-cli-build-graph-controls: check failed but did not name the planted suite:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "registry-cli-build-graph-controls: planted suite source directory caught" >&2

# Plant 2: a command-line module compiled by the test suite, which compiles
# only its specs. The anchor (CommandRunSpec) lives in the suite stanza at
# every head and the probe's non-Spec name is distinct from every genuine
# entry, so the plant is genuine, distinctly named, and evaluable both at
# the base and on the compliant tree.
copy_tree plant-suite-module
anchor_at=$(grep -n '^    Singular.CLI.CommandRunSpec$' "$work/plant-suite-module/singular-registry.cabal" | cut -d: -f1)
[ -n "$anchor_at" ] || {
  echo "registry-cli-build-graph-controls: no Singular.CLI.CommandRunSpec anchor in the suite stanza" >&2
  exit 2
}
sed -i "${anchor_at}a\\    Singular.CLI.PlantProbe" "$work/plant-suite-module/singular-registry.cabal"
grep -q 'Singular.CLI.PlantProbe' "$work/plant-suite-module/singular-registry.cabal" \
  || {
    echo "registry-cli-build-graph-controls: suite-module plant did not apply" >&2
    exit 2
  }
code=0
out=$(bash "$check" "$work/plant-suite-module" 2>&1) || code=$?
if [ "$code" -eq 0 ]; then
  echo "registry-cli-build-graph-controls: check MISSED the planted suite module" >&2
  exit 1
fi
if [ "$code" -ne 1 ]; then
  echo "registry-cli-build-graph-controls: check errored instead of naming the plant (exit $code):" >&2
  printf '%s\n' "$out" >&2
  exit 2
fi
printf '%s\n' "$out" | grep -q 'Singular.CLI.PlantProbe' \
  || {
    echo "registry-cli-build-graph-controls: check failed but did not name the planted module:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "registry-cli-build-graph-controls: planted suite module caught" >&2

# Plant 3: a cli/src module demoted from exposed to private. Singular.CLI.Root
# lives in cli/src, so the original protected obligation (every cli/src module
# exposed) must fail naming it. A check that subtracts other-modules from the
# whole extent would hide this demotion and miss the plant.
copy_tree plant-src-demotion
sed -i '/^    Singular.CLI.Root$/d' "$work/plant-src-demotion/singular-registry.cabal"
sed -i 's|^  other-modules: Singular.CLI.Harness$|  other-modules: Singular.CLI.Harness\n    Singular.CLI.Root|' "$work/plant-src-demotion/singular-registry.cabal"
# Verify the move: Root present in other-modules, absent from exposed-modules.
exposed_has=$(awk '
    /^library[ \t]+registry-cli([ \t]|$)/ { inlib = 1; next }
    /^[^ \t]/ { if (inlib) exit; next }
    inlib && /^[ \t]*exposed-modules:/ { inmods = 1; next }
    inlib && inmods && /^[ \t]*[a-zA-Z0-9-]+:/ { inmods = 0; next }
    inlib && inmods && /^    Singular\.CLI\.Root$/ { print "yes"; exit }
' "$work/plant-src-demotion/singular-registry.cabal")
other_has=$(awk '
    /^library[ \t]+registry-cli([ \t]|$)/ { inlib = 1; next }
    /^[^ \t]/ { if (inlib) exit; next }
    inlib && /^[ \t]*other-modules:/ { inmods = 1; next }
    inlib && inmods && /^[ \t]*[a-zA-Z0-9-]+:/ { inmods = 0; next }
    inlib && inmods && /^    Singular\.CLI\.Root$/ { print "yes"; exit }
' "$work/plant-src-demotion/singular-registry.cabal")
[ "$exposed_has" != "yes" ] || {
  echo "registry-cli-build-graph-controls: src-demotion plant did not apply (Root still exposed)" >&2
  exit 2
}
[ "$other_has" = "yes" ] || {
  echo "registry-cli-build-graph-controls: src-demotion plant did not apply (Root not private)" >&2
  exit 2
}
code=0
out=$(bash "$check" "$work/plant-src-demotion" 2>&1) || code=$?
if [ "$code" -eq 0 ]; then
  echo "registry-cli-build-graph-controls: check MISSED the demoted src module" >&2
  exit 1
fi
if [ "$code" -ne 1 ]; then
  echo "registry-cli-build-graph-controls: check errored instead of naming the plant (exit $code):" >&2
  printf '%s\n' "$out" >&2
  exit 2
fi
printf '%s\n' "$out" | grep -q 'Singular.CLI.Root' \
  || {
    echo "registry-cli-build-graph-controls: check failed but did not name the demoted module:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "registry-cli-build-graph-controls: demoted src module caught" >&2

echo "registry-cli-build-graph-controls: planted suite source directory, suite module and demoted src module all caught"
