#!/usr/bin/env bash
# registry-cli-build-graph-check: the command line is its own library.
#
# Slice 3 (#528): every module under cli/src is exposed by the public
# sublibrary registry-cli under its unchanged module name; the singular
# executable and the cage-tests suite compile no cli/src source themselves
# and depend on the library. Cleanup only: no behaviour change.
#
# The proof is the build graph. Leg 1 reads the solver's own plan
# (cabal build --dry-run --offline, --offline so the plan never touches the
# network), so a component the plan does not know cannot satisfy it. Legs 2
# to 4 read the stanza structure the solver builds from, in the same awk
# shape the component-inventory gate uses, quantified over every stanza, so
# a new offender is named without anyone editing this script.
#
# Usage: registry-cli-build-graph-check [SRCDIR] (default: the working tree).
# Requires cabal on PATH: run under nix develop from offchain/
# (nix develop --quiet -c bash nix/registry-cli-build-graph-check.sh).
# A throwaway copy under test needs cabal.project, singular-registry.cabal,
# cli/src and dist-newstyle/src (the pinned git sources the offline solver
# reads); see registry-cli-build-graph-controls.sh.
# Exit 0: the graph holds. Exit 1: a leg names its offender. Exit 2: the
# harness failed (missing tree, no cabal, solver setup failure, empty
# extent) — a setup failure, never a verdict.
set -euo pipefail

root="${1:-$PWD}"
cabal="$root/singular-registry.cabal"
cli="$root/cli/src"

[ -f "$cabal" ] || {
  echo "registry-cli-build-graph-check: no singular-registry.cabal under $root" >&2
  exit 2
}
[ -f "$root/cabal.project" ] || {
  echo "registry-cli-build-graph-check: no cabal.project under $root" >&2
  exit 2
}
[ -d "$cli" ] || {
  echo "registry-cli-build-graph-check: no cli/src under $root" >&2
  exit 2
}
command -v cabal >/dev/null 2>&1 || {
  echo "registry-cli-build-graph-check: cabal not on PATH (run under nix develop)" >&2
  exit 2
}

# Fail closed on the extent: a scope that discovers no source proves nothing.
count=$(find "$cli" -name '*.hs' | wc -l)
[ "$count" -gt 0 ] || {
  echo "registry-cli-build-graph-check: empty cli/src extent under $root" >&2
  exit 2
}

fail=0

# One token per line: commas and blank runs never survive to a comparison.
split_names() {
  sed 's/,/ /g' | awk '{ for (i = 1; i <= NF; i++) print $i }'
}

# Leg 1: the solver's own plan knows the sublibrary.
plan="$(cd "$root" && cabal build --dry-run --offline all 2>&1)" || {
  echo "registry-cli-build-graph-check: cabal dry-run failed (setup, not a verdict):" >&2
  printf '%s\n' "$plan" >&2
  exit 2
}
[ -n "$plan" ] || {
  echo "registry-cli-build-graph-check: empty solver plan (setup, not a verdict)" >&2
  exit 2
}
if ! printf '%s\n' "$plan" | grep -q '(lib:registry-cli)'; then
  echo "registry-cli-build-graph-check: solver plan has no lib:registry-cli" >&2
  fail=1
fi

# Leg 2: exactly one stanza compiles cli/src — the new sublibrary.
# Every column-0 stanza header is examined; common/if/else and package
# fields name no component and are skipped, anything else is an offender
# only if it lists cli/src.
holders=$(awk '
    /^library[ \t]*$/ { stanza = "lib:singular-registry"; next }
    /^library[ \t]+/ { stanza = "sublib:" $2; next }
    /^executable[ \t]+/ { stanza = "exe:" $2; next }
    /^test-suite[ \t]+/ { stanza = "test:" $2; next }
    /^benchmark[ \t]+/ { stanza = "bench:" $2; next }
    /^foreign-library[ \t]+/ { stanza = "flib:" $2; next }
    /^[^ \t]/ { stanza = ""; next }
    stanza != "" && /^[ \t]*hs-source-dirs:/ {
        line = $0; sub(/^[^:]*:[ \t]*/, "", line)
        n = split(line, dirs, /[ \t]+/)
        for (i = 1; i <= n; i++) if (dirs[i] == "cli/src") print stanza
    }
' "$cabal" | sort -u)
[ -n "$holders" ] || holders="(none)"
if [ "$holders" != "sublib:registry-cli" ]; then
  echo "registry-cli-build-graph-check: cli/src is compiled by (want exactly sublib:registry-cli):" >&2
  printf '%s\n' "$holders" >&2
  fail=1
fi

# Leg 3: the sublibrary exposes every cli/src module under its unchanged name.
expected=$(cd "$cli" && find . -name '*.hs' | sed 's|^\./||; s|\.hs$||; s|/|.|g' | sort -u)
got=$(awk '
    /^library[ \t]+registry-cli([ \t]|$)/ { inlib = 1; next }
    /^[^ \t]/ { if (inlib) exit; next }
    inlib && /^[ \t]*exposed-modules:/ { inmods = 1; line = $0; sub(/^[^:]*:/, "", line); print line; next }
    inlib && inmods && /^[ \t]*[a-zA-Z0-9-]+:/ { inmods = 0; next }
    inlib && inmods { print $0 }
' "$cabal" | split_names | { grep -v '^$' || true; } | sort -u)
if [ -z "$got" ]; then
  echo "registry-cli-build-graph-check: library registry-cli exposes nothing (missing stanza or empty exposed-modules)" >&2
  fail=1
elif [ "$expected" != "$got" ]; then
  echo "registry-cli-build-graph-check: registry-cli exposed-modules differ from the cli/src files:" >&2
  comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$got") | sed 's/^/  missing from stanza: /' >&2
  comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$got") | sed 's/^/  in stanza but no such file: /' >&2
  fail=1
fi

# One stanza-block reader for leg 4: print the raw lines of one key of one
# stanza, so callers grep the solver's own structure, not a guess.
key_lines() { # $1 = stanza header regex, $2 = key
  awk -v hdr="$1" -v key="$2" '
        $0 ~ hdr { instanza = 1; next }
        /^[^ \t]/ { if (instanza) exit; next }
        instanza && $0 ~ ("^[ \t]*" key ":") { inkey = 1; line = $0; sub(/^[^:]*:/, "", line); print line; next }
        instanza && inkey && /^[ \t]*[a-zA-Z0-9-]+:/ { inkey = 0; next }
        instanza && inkey { print $0 }
    ' "$cabal"
}

# Leg 4: singular and cage-tests depend on the library and recompile nothing.
for stanza in "executable singular" "test-suite cage-tests"; do
  deps=$(key_lines "^$stanza([ \t]|$)" "build-depends")
  if ! printf '%s\n' "$deps" | grep -q 'singular-registry:registry-cli'; then
    echo "registry-cli-build-graph-check: $stanza does not build-depend on singular-registry:registry-cli" >&2
    fail=1
  fi
done
exe_mods=$(key_lines "^executable singular([ \t]|$)" "other-modules" | split_names | grep '^Singular\.CLI' || true)
if [ -n "$exe_mods" ]; then
  echo "registry-cli-build-graph-check: executable singular still compiles command-line modules:" >&2
  printf '%s\n' "$exe_mods" >&2
  fail=1
fi
suite_mods=$(key_lines "^test-suite cage-tests([ \t]|$)" "other-modules" | split_names | grep '^Singular\.CLI' | grep -v 'Spec$' || true)
if [ -n "$suite_mods" ]; then
  echo "registry-cli-build-graph-check: test-suite cage-tests still compiles command-line modules (non-Spec):" >&2
  printf '%s\n' "$suite_mods" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "registry-cli-build-graph-check: $count files, solver plan and stanzas agree on registry-cli"
fi
exit "$fail"
