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

sources=()
for dir in "${scanned[@]}"; do
  mapfile -t found < <(find "$root/$dir" -name '*.hs' -not -path '*/dist-newstyle/*' 2>/dev/null | sort)
  if [ ${#found[@]} -eq 0 ]; then
    echo "EMPTY EXTENT: no Haskell sources under $root/$dir" >&2
    exit 2
  fi
  sources+=("${found[@]}")
done

declare -A allowed=()
status=0
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
done <"$allow"

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

echo "PASS node-confinement: ${#sources[@]} Haskell sources under ${scanned[*]}; the backend is named only in ${#allowed[@]} allowlisted modules"
