#!/usr/bin/env bash
# application-boundary-controls: the check catches what it claims to catch.
#
# The controls plant an import in the library, an import in a registry-cli
# module, a build-depends entry in the bare library, and a build-depends
# entry in local-services, each in a throwaway copy, and the check must fail
# there (the check exits nonzero naming the plant); they never edit the
# tracked tree. The fourth plant proves the dependency rule quantifies over
# every library stanza instead of looking only at the bare library; the
# temporary registry-cli arrow itself is covered by the clean-tree pass and
# by the missing-arrow failure on a tree without the stanza. Each plant
# verifies its own application first: a plant that silently failed to apply
# would report "caught" while testing nothing. Exit 0: all plants caught.
# Exit 1: the check missed a plant. Exit 2: the harness failed.
#
# Usage: application-boundary-controls [SRCDIR] (default: the working tree).
# Requires $check to name the application-boundary-check binary (wired in
# nix/checks.nix); a direct run without it exits 2.
set -euo pipefail

root="${1:-$PWD}"
: "${check:?application-boundary-controls: \$check is not wired (run through the flake app)}"
[ -x "$check" ] || {
  echo "application-boundary-controls: check binary not executable: $check" >&2
  exit 2
}
[ -f "$root/singular-registry.cabal" ] || {
  echo "application-boundary-controls: no singular-registry.cabal under $root" >&2
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

copy_tree() {
  mkdir -p "$work/$1"
  cp -r "$root/lib" "$work/$1/lib"
  mkdir -p "$work/$1/naming"
  cp -r "$root/naming/src" "$work/$1/naming/src"
  mkdir -p "$work/$1/cli"
  cp -r "$root/cli/src" "$work/$1/cli/src"
  cp "$root/singular-registry.cabal" "$work/$1/singular-registry.cabal"
}

# Plant 1: an import of the open-datum package in a registry library module.
copy_tree plant-import
probe="module Singular.Registry.BoundaryProbe (probe) where

import Singular.Application.OpenDatum.Envelope ()
"
printf '%s' "$probe" >"$work/plant-import/lib/Singular/Registry/BoundaryProbe.hs"
grep -q 'import Singular.Application.OpenDatum.Envelope' "$work/plant-import/lib/Singular/Registry/BoundaryProbe.hs" \
  || {
    echo "application-boundary-controls: import plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-import" 2>&1); then
  echo "application-boundary-controls: check MISSED the planted import" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'BoundaryProbe' \
  || {
    echo "application-boundary-controls: check failed but did not name the planted import:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-boundary-controls: planted import caught" >&2

# Plant 2: a build-depends entry on the open-datum sublibrary.
copy_tree plant-dep
sed -i '/^library$/,/^[^ \t]/ s/^\([ \t]*build-depends:\)$/\1\n    , singular-registry:open-datum-application/' "$work/plant-dep/singular-registry.cabal"
grep -q 'singular-registry:open-datum-application' "$work/plant-dep/singular-registry.cabal" \
  || {
    echo "application-boundary-controls: build-depends plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-dep" 2>&1); then
  echo "application-boundary-controls: check MISSED the planted build-depends entry" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'open-datum-application' \
  || {
    echo "application-boundary-controls: check failed but did not name the planted build-depends entry:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-boundary-controls: planted build-depends entry caught" >&2

# Plant 3 (slices 2 and 3): an import of the open-datum package in a
# registry-cli module (Fold, outside the four named exceptions Command,
# Plan, Entry, InsertEnvelope which stay until slice 4).
copy_tree plant-cli-import
printf '%s\n' "import Singular.Application.OpenDatum.Envelope ()" >>"$work/plant-cli-import/cli/src/Singular/CLI/Fold.hs"
grep -q 'import Singular.Application.OpenDatum.Envelope' "$work/plant-cli-import/cli/src/Singular/CLI/Fold.hs" \
  || {
    echo "application-boundary-controls: cli import plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-cli-import" 2>&1); then
  echo "application-boundary-controls: check MISSED the planted cli import" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'CLI/Fold.hs' \
  || {
    echo "application-boundary-controls: check failed but did not name the planted cli import:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-boundary-controls: planted cli import caught" >&2

# Plant 4 (slice 3): a build-depends entry on the open-datum sublibrary in
# local-services, which must never list it. local-services is clean at every
# head, so the plant is genuine and distinctly named: catching it proves the
# dependency rule quantifies over every library stanza instead of looking
# only at the bare library, while the temporary registry-cli arrow stays
# the one named exception.
copy_tree plant-sublib-dep
ls_start=$(grep -n '^library local-services$' "$work/plant-sublib-dep/singular-registry.cabal" | cut -d: -f1)
[ -n "$ls_start" ] || {
  echo "application-boundary-controls: no library local-services stanza to plant in" >&2
  exit 2
}
dep_at=$(awk -v s="$ls_start" 'NR > s && /^[^ \t]/ { exit } NR > s && /^[ \t]*build-depends:/ { print NR; exit }' "$work/plant-sublib-dep/singular-registry.cabal")
[ -n "$dep_at" ] || {
  echo "application-boundary-controls: no build-depends header in the local-services stanza" >&2
  exit 2
}
sed -i "${dep_at}a\\    , singular-registry:open-datum-application" "$work/plant-sublib-dep/singular-registry.cabal"
awk -v s="$ls_start" 'NR > s && /^[^ \t]/ { exit } NR > s { print }' "$work/plant-sublib-dep/singular-registry.cabal" | grep -q 'singular-registry:open-datum-application' \
  || {
    echo "application-boundary-controls: sublib build-depends plant did not apply" >&2
    exit 2
  }
if out=$("$check" "$work/plant-sublib-dep" 2>&1); then
  echo "application-boundary-controls: check MISSED the planted sublib build-depends entry" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -q 'sublib:local-services' \
  || {
    echo "application-boundary-controls: check failed but did not name the planted sublib:" >&2
    printf '%s\n' "$out" >&2
    exit 1
  }
echo "application-boundary-controls: planted sublib build-depends entry caught" >&2

echo "application-boundary-controls: planted imports and build-depends entries all caught"
