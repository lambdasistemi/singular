#!/usr/bin/env bash
# application-boundary-check: the registry library and the migrated
# command-line modules name no application.
#
# Slice 2 scope (#528): the slice-1 library scope (lib, naming/src) plus
# every other command-line module under cli/src, with four named exceptions
# that stay open-datum code until slice 4 (Command, Plan, Entry,
# InsertEnvelope) — slice 4 removes the exception. The check names each
# offender and exits nonzero while one remains. The proof of the boundary
# is the build graph (the library stanza does not list
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
cli="$root/cli/src"
cabal="$root/singular-registry.cabal"

[ -d "$lib" ] || { echo "application-boundary-check: no lib/ under $root" >&2; exit 2; }
[ -d "$naming" ] || { echo "application-boundary-check: no naming/src under $root" >&2; exit 2; }
[ -d "$cli" ] || { echo "application-boundary-check: no cli/src under $root" >&2; exit 2; }
[ -f "$cabal" ] || { echo "application-boundary-check: no singular-registry.cabal under $root" >&2; exit 2; }

# Fail closed on the extent: a scope that discovers no source proves nothing.
count=$(find "$lib" "$naming" "$cli" -name '*.hs' | wc -l)
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

# Slice 2: every other command-line module under cli/src names no
# application. Four named exceptions stay open-datum code until slice 4
# (Command, Plan, Entry, InsertEnvelope) — slice 4 removes the exception.
# All other cli modules (Create, Fold, FoldRules, Live, Reconcile, Inspect,
# Preview and the rest) must not import the open-datum package.
cli_hits=$(grep -rn --include='*.hs' -E '^[[:space:]]*import[[:space:]]+(qualified[[:space:]]+)?Singular\.Application\.OpenDatum' "$cli" || true)
# Exclude the four named exceptions by path; every other importer is an offender.
cli_outside=$(printf '%s' "$cli_hits" | grep -v 'cli/src/Singular/CLI/Command\.hs' | grep -v 'cli/src/Singular/CLI/Plan\.hs' | grep -v 'cli/src/Singular/CLI/Entry\.hs' | grep -v 'cli/src/Singular/CLI/InsertEnvelope\.hs' || true)
if [ -n "$cli_outside" ]; then
    echo "application-boundary-check: migrated command-line modules import the open-datum package (four named exceptions allowed until slice 4: Command, Plan, Entry, InsertEnvelope):" >&2
    printf '%s\n' "$cli_outside" >&2
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
