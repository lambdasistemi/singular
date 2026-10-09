#!/usr/bin/env bash
# application-boundary-check: the registry library and the registry-cli
# command-line library name no application but the named temporary arrow.
#
# Slice 3 scope (#528): the slice-1 library scope (lib, naming/src) plus
# every command-line module under cli/src, now held by the public sublibrary
# registry-cli, with four named exceptions that stay open-datum code until
# slice 4 (Command, Plan, Entry, InsertEnvelope) — slice 4 moves them into
# open-datum-application and removes the exception. The check names each
# offender and exits nonzero while one remains. The proof of the boundary
# is the build graph (no registry-side stanza but registry-cli lists
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

# Slice 3: the registry-cli modules under cli/src name no application but
# the four named exceptions, which stay open-datum code until slice 4
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

# Slice 3: the dependency side of the boundary, quantified over every
# library stanza. registry-cli's build-depends on open-datum-application is
# the temporary arrow slice 4 removes (named here, not hidden): the check
# requires it present and names everything else that lists the package. The
# bare library, local-services and koios-http must not list it.
dep_holders=$(awk '
    /^library[ \t]*$/ { stanza = "lib:singular-registry"; indep = 0; next }
    /^library[ \t]+/ { stanza = "sublib:" $2; indep = 0; next }
    /^executable[ \t]+/ { stanza = "exe:" $2; indep = 0; next }
    /^test-suite[ \t]+/ { stanza = "test:" $2; indep = 0; next }
    /^[^ \t]/ { stanza = ""; indep = 0; next }
    stanza != "" && /^[ \t]*build-depends:/ {
        if ($0 ~ /open-datum-application/) print stanza ": " $0
        indep = 1; next
    }
    stanza != "" && indep && /^[ \t]*[a-zA-Z0-9-]+:/ { indep = 0; next }
    stanza != "" && indep && /open-datum-application/ { print stanza ": " $0 }
' "$cabal" | grep -E '^(lib|sublib):' || true)
if ! printf '%s\n' "$dep_holders" | grep -q '^sublib:registry-cli:'; then
    echo "application-boundary-check: library registry-cli lacks the temporary open-datum-application dependency slice 4 removes" >&2
    fail=1
fi
others=$(printf '%s\n' "$dep_holders" | grep -v '^sublib:registry-cli:' | grep -v '^$' || true)
if [ -n "$others" ]; then
    echo "application-boundary-check: registry-side library lists open-datum-application (only sublib:registry-cli may, until slice 4):" >&2
    printf '%s\n' "$others" >&2
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "application-boundary-check: $count files, no offender"
fi
exit "$fail"
