#!/usr/bin/env bash
# The ledger client core depends only on reviewed packages, and on no Singular
# component and no file, process, POSIX or network package.
#
# `library ledger-client` in offchain/singular-registry.cabal holds the
# provider-independent part of the ledger client: evidence, network time,
# typed read traces and local script evaluation. An application that reads
# Cardano through the provider interface depends on it, so it must stay
# free of signing, wallet, file, process and network code, and of the
# transaction-building package, or it cannot move out unchanged.
#
# What is judged is the set of direct dependencies Cabal itself resolves for
# that stanza (a small program run with runghc, which uses Cabal's own
# parser): imported common stanzas, continued fields and conditionals included.
# This script reads no Cabal text of its own, so a spelling it does not model
# cannot hide a dependency.
#
# Refuses (exit 1, naming the offender):
#   * a dependency that tools/ledger-client-dependencies.allow does not list:
#     whether a package belongs to a forbidden category cannot be enumerated
#     by name, so each addition is a reviewed edit of the allowlist;
#   * any `singular-registry` component, and any of the packages below, even
#     when the allowlist lists them: the allowlist cannot admit them;
#   * an allowlist entry with no reason, or that names no dependency of the
#     library: an exemption nothing needs is a hole waiting for a use.
# Exit 2 on a setup failure: no Cabal file or allowlist, no runghc, Cabal
# cannot resolve the stanza (not found, file does not parse), no dependencies.
#
# This judges the dependencies the library declares directly; what a
# transitive dependency links is the package solver's business, not read here.
#
# Usage: tools/ledger_client_dependencies_check.sh [repo-root]
set -euo pipefail

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

forbidden=(
  directory filepath unix process network
  http-client http-client-tls wai warp
  cardano-tx-tools
)

root=${1:-.}
cabal="$root/offchain/singular-registry.cabal"
allow="$root/tools/ledger-client-dependencies.allow"
for f in "$cabal" "$allow"; do
  if [ ! -f "$f" ]; then
    echo "SETUP-FAIL: no $f" >&2
    exit 2
  fi
done

if ! command -v runghc >/dev/null 2>&1; then
  echo "SETUP-FAIL: runghc is not on PATH; run through nix run ./offchain#ledger-client-dependencies-check" >&2
  exit 2
fi

# Cabal's own parser expands imported common stanzas, continued fields and
# every field spelling, and the description is flattened over both sides of
# every conditional. The program below only prints what Cabal resolved, one
# package (or package:component) per line; it decides nothing.
resolver="$scratch/resolve.hs"
cat >"$resolver" <<'HASKELL'
{- |
Module      : Main
Description : The direct dependencies Cabal resolves for one sublibrary
License     : Apache-2.0

Prints, one per line, the packages (@package@ or @package:component@) that
Cabal itself lists as direct dependencies of the named sublibrary of a Cabal
file. The check script judges the result; this program decides nothing.

Usage: runghc resolve.hs CABAL-FILE SUBLIBRARY
Exit 2 when the file does not parse or the sublibrary does not exist.
-}
module Main (main) where

import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.List (nub, sort)
import Distribution.Package (unPackageName)
import Distribution.PackageDescription
    ( BuildInfo (targetBuildDepends)
    , Library (libBuildInfo, libName)
    , PackageDescription (subLibraries)
    )
import Distribution.PackageDescription.Configuration
    ( flattenPackageDescription
    )
import Distribution.PackageDescription.Parsec
    ( parseGenericPackageDescriptionMaybe
    )
import Distribution.Types.Dependency (Dependency, depLibraries, depPkgName)
import Distribution.Types.LibraryName (LibraryName (..))
import Distribution.Types.UnqualComponentName
    ( mkUnqualComponentName
    , unUnqualComponentName
    )
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [file, name] -> do
            parsed <-
                parseGenericPackageDescriptionMaybe <$> BS.readFile file
            description <- case parsed of
                Just generic -> pure (flattenPackageDescription generic)
                Nothing -> do
                    hPutStrLn stderr (file <> " does not parse as a Cabal file")
                    exitWith (ExitFailure 2)
            case [ lib
                 | lib <- subLibraries description
                 , libName lib == LSubLibName (mkName name)
                 ] of
                [lib] ->
                    mapM_ putStrLn . sort . nub $
                        concatMap
                            render
                            (targetBuildDepends (libBuildInfo lib))
                _ -> do
                    hPutStrLn stderr $
                        "no sublibrary " <> name <> " in " <> file
                    exitWith (ExitFailure 2)
        _ -> do
            hPutStrLn stderr "usage: CABAL-FILE SUBLIBRARY"
            exitWith (ExitFailure 2)
  where
    mkName = mkUnqualComponentName

render :: Dependency -> [String]
render dependency =
    [ package <> case component of
        LMainLibName -> ""
        LSubLibName sub -> ":" <> unUnqualComponentName sub
    | component <- toList (depLibraries dependency)
    ]
  where
    package = unPackageName (depPkgName dependency)

HASKELL

if ! resolved=$(runghc "$resolver" "$cabal" ledger-client 2>"$scratch/err"); then
  echo "SETUP-FAIL: Cabal cannot resolve 'library ledger-client' in $cabal: $(cat "$scratch/err")" >&2
  exit 2
fi

status=0
declare -A used=()
count=0
while IFS= read -r dep; do
  [ -n "$dep" ] || continue
  count=$((count + 1))
  used[$dep]=1
done <<<"$resolved"

if [ "$count" -eq 0 ]; then
  echo "SETUP-FAIL: 'library ledger-client' resolves to no build-depends in $cabal" >&2
  exit 2
fi

declare -A allowed=()
while IFS= read -r line; do
  case "$line" in '' | '#'*) continue ;; esac
  pkg=${line%%:*}
  rest=${line#"$pkg":}
  # A qualified entry "pkg:component: reason" keeps its component.
  case "$rest" in
    [A-Za-z]*:*)
      comp=${rest%%:*}
      if [[ $comp != *[[:space:]]* ]]; then
        pkg="$pkg:$comp"
        rest=${rest#"$comp":}
      fi
      ;;
  esac
  reason=${rest#"${rest%%[![:space:]]*}"}
  if [ -z "$reason" ] || [ "$rest" = "$line" ]; then
    echo "allowlist: '$pkg' carries no reason" >&2
    status=1
  fi
  allowed[$pkg]=1
done <"$allow"

for pkg in "${!allowed[@]}"; do
  if [ -z "${used[$pkg]:-}" ]; then
    echo "allowlist: '$pkg' is no dependency of ledger-client; drop its entry" >&2
    status=1
  fi
done

for name in "${!used[@]}"; do
  case "$name" in
    singular-registry | singular-registry:*)
      echo "ledger-client depends on $name: the Singular component $name may not be a dependency" >&2
      status=1
      continue
      ;;
  esac
  for bad in "${forbidden[@]}"; do
    if [ "${name%%:*}" = "$bad" ]; then
      echo "ledger-client depends on $name: $bad is forbidden in the ledger client core" >&2
      status=1
    fi
  done
  if [ -z "${allowed[$name]:-}" ]; then
    echo "ledger-client depends on $name: $name is not in tools/ledger-client-dependencies.allow" >&2
    status=1
  fi
done

if [ $status -ne 0 ]; then
  echo "FAIL ledger-client-dependencies: see the lines above" >&2
  exit 1
fi

echo "PASS ledger-client-dependencies: $count direct dependencies resolved by Cabal, all allowlisted, none a Singular component or a forbidden package"
