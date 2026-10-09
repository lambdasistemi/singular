#!/usr/bin/env bash
# application-boundary-check: the registry library names no application.
#
# Slice 1 scope (#528): every module of the registry library (its
# hs-source-dirs `lib` and `naming/src`) and the registry's
# wire/builder/state sources, which all live under `lib`. The check names
# each offender and exits nonzero while one remains. The proof of the
# boundary is the build graph (the library stanza does not list
# `open-datum-application` in build-depends); this check reads the same
# graph so the violation is named.
#
# Usage: application-boundary-check [SRCDIR] (default: the working tree).
# Exit 0: clean. Exit 1: a violation is named. Exit 2: the harness failed
# (missing tree, empty extent) — a setup failure, never a verdict.
set -euo pipefail

root="${1:-$PWD}"
lib="$root/lib"
naming="$root/naming/src"
cabal="$root/singular-registry.cabal"

[ -d "$lib" ] || { echo "application-boundary-check: no lib/ under $root" >&2; exit 2; }
[ -d "$naming" ] || { echo "application-boundary-check: no naming/src under $root" >&2; exit 2; }
[ -f "$cabal" ] || { echo "application-boundary-check: no singular-registry.cabal under $root" >&2; exit 2; }

# Fail closed on the extent: a scope that discovers no source proves nothing.
count=$(find "$lib" "$naming" -name '*.hs' | wc -l)
[ "$count" -gt 0 ] || { echo "application-boundary-check: empty source extent under $root" >&2; exit 2; }

fail=0

# Modules outside the open-datum package that import it. The package's own
# modules (lib/Singular/Application/OpenDatum/) are its members, not its
# consumers, and are excluded by path.
hits=$(grep -rn --include='*.hs' -E '^[[:space:]]*import[[:space:]]+(qualified[[:space:]]+)?Singular\.Application\.OpenDatum' "$lib" "$naming" || true)
outside=$(printf '%s' "$hits" | grep -v '/Singular/Application/OpenDatum/' || true)
if [ -n "$outside" ]; then
    echo "application-boundary-check: registry library imports the open-datum package:" >&2
    printf '%s\n' "$outside" >&2
    fail=1
fi

# The bare `library` stanza (the registry library, not a named sublibrary)
# must not list the open-datum sublibrary in build-depends.
stanza=$(awk '/^library$/ { inlib = 1; next } /^[^ \t]/ { if (inlib) exit } inlib { print }' "$cabal")
[ -n "$stanza" ] || { echo "application-boundary-check: no bare library stanza in $cabal" >&2; exit 2; }
dep=$(printf '%s\n' "$stanza" | grep 'open-datum-application' || true)
if [ -n "$dep" ]; then
    echo "application-boundary-check: registry library build-depends lists open-datum-application:" >&2
    printf '%s\n' "$dep" >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "application-boundary-check: $count files, no offender"
fi
exit "$fail"
