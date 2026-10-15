#!/usr/bin/env bash
# The ledger client core links no Singular component and no file, process,
# POSIX or network package.
#
# `library ledger-client` in offchain/singular-registry.cabal holds the
# provider-independent part of the ledger client: evidence, network time,
# typed read traces and local script evaluation. An application that reads
# Cardano through the provider interface depends on it, so it must stay
# free of signing, wallet, file, process and network code, and of the
# transaction-building package, or it cannot move out unchanged.
#
# This reads the direct `build-depends` of that one stanza. It names the
# dependencies the library declares; what a transitive dependency links is
# the package solver's business, not read here.
#
# Refuses (exit 1, naming the offender):
#   * any `singular-registry` component, the main library included;
#   * any of the forbidden packages listed below.
# Exit 2 on a setup failure: no Cabal file, no such stanza, no dependencies.
#
# Usage: tools/ledger_client_dependencies_check.sh [repo-root]
set -euo pipefail

forbidden=(
  directory filepath unix process network
  http-client http-client-tls wai warp
  cardano-tx-tools
)

root=${1:-.}
cabal="$root/offchain/singular-registry.cabal"
if [ ! -f "$cabal" ]; then
  echo "SETUP-FAIL: no $cabal" >&2
  exit 2
fi

# One dependency per line: the stanza's build-depends field, from its
# keyword to the next field or the next stanza, commas split, versions and
# component qualifiers kept for the diagnostic.
mapfile -t deps < <(awk '
  /^library ledger-client[[:space:]]*$/ { in_stanza = 1; next }
  in_stanza && /^[^[:space:]-]/ { exit }
  in_stanza && /^[[:space:]]+build-depends:/ {
    in_deps = 1
    sub(/^[[:space:]]+build-depends:/, "")
  }
  in_stanza && in_deps && /^[[:space:]]+[A-Za-z][A-Za-z-]*:/ { in_deps = 0 }
  in_stanza && in_deps {
    n = split($0, parts, ",")
    for (i = 1; i <= n; i++) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
      if (parts[i] != "") print parts[i]
    }
  }
' "$cabal")

if ! grep -qE '^library ledger-client[[:space:]]*$' "$cabal"; then
  echo "SETUP-FAIL: no 'library ledger-client' stanza in $cabal" >&2
  exit 2
fi
if [ ${#deps[@]} -eq 0 ]; then
  echo "SETUP-FAIL: 'library ledger-client' declares no build-depends in $cabal" >&2
  exit 2
fi

status=0
for dep in "${deps[@]}"; do
  name=${dep%%[[:space:]<>=^]*}
  case "$name" in
    singular-registry | singular-registry:*)
      echo "ledger-client depends on $name: the Singular component $name may not be a dependency" >&2
      status=1
      continue
      ;;
  esac
  for bad in "${forbidden[@]}"; do
    if [ "$name" = "$bad" ] || [ "${name%%:*}" = "$bad" ]; then
      echo "ledger-client depends on $name: $bad is forbidden in the ledger client core" >&2
      status=1
    fi
  done
done

if [ $status -ne 0 ]; then
  echo "FAIL ledger-client-dependencies: see the lines above" >&2
  exit 1
fi

echo "PASS ledger-client-dependencies: ${#deps[@]} direct dependencies, none a Singular component or a forbidden package"
