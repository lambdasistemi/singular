#!/usr/bin/env bash
# The node backend is named only where it is composed.
#
# `singular` commands and the transaction builders consume capabilities —
# the read interface, the signed-only write and the confirmation — and
# never the backend behind them: the mode, the session, the socket client,
# the process-wide follower, the raw submitter. Those are named only by
# the modules listed in tools/node-confinement.allow, each with its reason.
#
# Supporting evidence, not proof. This reads source text, so it establishes
# that no other module NAMES the backend; what a command does with the
# capabilities it is given is settled by the cage-tests write rows and the
# DevNet journey, not here. What it adds is extent: every Haskell source
# under the scanned roots, discovered, not listed.
#
# Three refusals:
#   * a confined identifier or module import outside the allowlist;
#   * an allowlist entry with no reason, or naming a file that is gone;
#   * an allowlist entry that names no confined identifier — an exemption
#     nothing needs is a hole waiting for a use.
#
# Usage: tools/node_confinement_check.sh [repo-root]
#        tools/node_confinement_check.sh --roots   (print the scanned roots)
set -euo pipefail

# Every consumer of the capabilities: the singular commands and the
# library, the runners (journeys, deployment, insert-active,
# update-terminal, the devnet tool), the end-to-end suite and the
# conformance harness.
scanned=(
  offchain/cli offchain/lib
  offchain/journey offchain/deployment offchain/insert-active
  offchain/update-terminal offchain/devnet offchain/e2e-test
  conformance/app conformance/app-cli conformance/app-default conformance/lib
)
if [ "${1:-}" = --roots ]; then
  printf '%s\n' "${scanned[@]}"
  exit 0
fi

root=${1:-.}
allow="$root/tools/node-confinement.allow"

# The backend's vocabulary: session and mode with their fields, socket clients, the
# process-wide follower and open session, the raw submitter, and the
# adapter constructors. Matched as whole words.
identifiers=(
  NodeMode NodeSession NodeReads ExternalNode
  nsProvider nsSubmitter nsMagic nsNetwork nsTipSlot nsMode nrProvider
  withNode withNodeMode withNodeReads withNodeSocket withNodeForPlannedFunding
  nodeModeFromArgs nodeModeFromEnvironment runMode nodeIsExternal devnetGenesis
  withDevnetIndexer followedProvider followChain currentFollower awaitIndexed
  nodeAddressReads adaptProvider sessionFor withOpenSession currentTipSlot
  awaitConnection awaitTx awaitTxId awaitTxWindow
  runNodeClient newLSQChannel newLTxSChannel mkN2CProvider mkN2CSubmitter
  nodeProvider Submitter submitTx signedSubmitter boundedSubmitter
)
# Modules whose import alone names the backend.
modules='Singular\.Registry\.Node\.(Session|Options|Indexer|View|Confirmation)|Cardano\.Node\.Client\.(N2C|Provider)'

word_re="\\b($(
  IFS='|'
  echo "${identifiers[*]}"
))\\b"
import_re="^import[[:space:]]+(qualified[[:space:]]+)?($modules)\\b"

if [ ! -f "$allow" ]; then
  echo "SETUP-FAIL: no allowlist at $allow" >&2
  exit 2
fi

status=0

# Retired components are not scanned: the rows the component inventory
# classifies `unverified` (built nowhere, no workflow runs them), each
# resolved to its source directories through the Cabal file. A retired
# directory may not hold a built component's sources.
inventory="$root/offchain/nix/component-inventory.nix"
cabal="$root/offchain/singular-registry.cabal"
for f in "$inventory" "$cabal"; do
  [ -f "$f" ] || {
    echo "SETUP-FAIL: no $f" >&2
    exit 2
  }
done
mapfile -t retired < <(awk '
  /^  unverified = \[/ { u = 1 }
  u && /name = "/ { match($0, /name = "[^"]+"/); n = substr($0, RSTART + 8, RLENGTH - 9) }
  u && /issue = "/ { match($0, /issue = "[^"]+"/); print n, substr($0, RSTART + 9, RLENGTH - 10) }
  u && /^  \];/ { u = 0 }
' "$inventory")
# Component name and source directories, one component per line.
mapfile -t components < <(awk '
  /^(library|executable|test-suite)( |$)/ { name = ($2 == "" ? "singular-registry" : $2) }
  $1 == "hs-source-dirs:" { $1 = ""; print name $0 }
' "$cabal")
excluded=()
declare -A retiredName=()
for row in "${retired[@]}"; do
  read -r name issue <<<"$row"
  retiredName[$name]=1
  dirs=""
  for c in "${components[@]}"; do
    read -r cname cdirs <<<"$c"
    [ "$cname" = "$name" ] && dirs="$cdirs"
  done
  if [ -z "$dirs" ]; then
    echo "retired: inventory row '$name' names no Cabal component" >&2
    status=1
    continue
  fi
  for d in $dirs; do
    excluded+=("offchain/$d")
    echo "excluded offchain/$d: $name, retired ($issue)"
  done
done
for c in "${components[@]}"; do
  read -r cname cdirs <<<"$c"
  [ -n "${retiredName[$cname]:-}" ] && continue
  for d in $cdirs; do
    for e in "${excluded[@]}"; do
      case "offchain/$d/" in "$e"/*)
        echo "retired: $e holds the sources of built component '$cname'" >&2
        status=1
        ;;
      esac
    done
  done
done

sources=()
for dir in "${scanned[@]}"; do
  mapfile -t found < <(find "$root/$dir" -name '*.hs' -not -path '*/dist-newstyle/*' 2>/dev/null | sort)
  if [ ${#found[@]} -eq 0 ]; then
    echo "EMPTY EXTENT: no Haskell sources under $root/$dir" >&2
    exit 2
  fi
  for file in "${found[@]}"; do
    rel=${file#"$root"/}
    keep=1
    for e in "${excluded[@]}"; do
      case "$rel" in "$e"/*) keep="" ;; esac
    done
    [ -n "$keep" ] && sources+=("$file")
  done
done

declare -A allowed=() ownTest=()
while IFS= read -r line; do
  case "$line" in '' | '#'*) continue ;; esac
  path=${line%%:*}
  reason=${line#*:}
  reason=${reason#"${reason%%[![:space:]]*}"}
  if [ "$path" = "$line" ] || [ -z "$reason" ]; then
    echo "allowlist: '$path' carries no reason" >&2
    status=1
  elif [ ! -f "$root/$path" ]; then
    echo "allowlist: '$path' does not exist" >&2
    status=1
  elif ! grep -qE -e "$word_re" -e "$import_re" "$root/$path"; then
    echo "allowlist: '$path' names no confined identifier; drop its exemption" >&2
    status=1
  fi
  allowed[$path]=1
  case "$reason" in "own test of "*)
    subject=${reason#own test of }
    ownTest[$path]=${subject%%[[:space:]]*}
    ;;
  esac
done <"$allow"

# A spec is exempt only as a backend's own test: its entry reads
# "own test of <module path> — <why>". The module it names must be one of
# the backend's own session or adapter modules — a node-internal module
# whose import alone names the backend (the module vocabulary above) —
# never a composition root, facade or fixture; and the spec must name a
# confined identifier that module defines.
for path in "${!ownTest[@]}"; do
  subject=${ownTest[$path]}
  module=""
  case "$subject" in offchain/node-internal/*)
    [ -f "$root/$subject" ] &&
      module=$(sed -nE 's/^module[[:space:]]+([A-Z][A-Za-z0-9_.]*)([[:space:]]|\(|$).*/\1/p' "$root/$subject" | head -1)
    ;;
  esac
  if [ -z "$module" ] || ! grep -qE "^($modules)\$" <<<"$module"; then
    echo "allowlist: '$path' is an own test of '$subject', which is not a backend session or adapter module" >&2
    status=1
    continue
  fi
  linked=""
  for id in "${identifiers[@]}"; do
    if grep -qE "^(data |newtype |type )?$id\\b" "$root/$subject" &&
      grep -qwE "$id" "$root/$path"; then
      linked=1
      break
    fi
  done
  if [ -z "$linked" ]; then
    echo "allowlist: '$path' names nothing $module defines, the backend module it claims to test" >&2
    status=1
  fi
done

for file in "${sources[@]}"; do
  rel=${file#"$root"/}
  [ -n "${allowed[$rel]:-}" ] && continue
  if grep -nE -e "$word_re" -e "$import_re" "$file" | sed "s|^|$rel:|"; then
    echo "  ^ $rel names the node backend; take the capability from composition" >&2
    status=1
  fi
done

if [ $status -ne 0 ]; then
  echo "FAIL node-confinement: see the lines above" >&2
  exit 1
fi

echo "PASS node-confinement: ${#sources[@]} Haskell sources under ${scanned[*]} (${#excluded[@]} retired directories excluded); the backend is named only in ${#allowed[@]} allowlisted modules"
