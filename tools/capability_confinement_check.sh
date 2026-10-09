#!/usr/bin/env bash
# The raw session capabilities are named only at the command boundary.
#
# Main-library builders and singular commands consume the safe surface —
# the abstract session, fixed-query named reads, opaque wallet funding and
# plain types (Singular.Registry.Surface) — and never the raw capability
# modules behind it: the provider, session IO/services/evidence, wallet
# reads, or the kernel-independent plumbing those modules define. The two
# boundary modules tools/capability-confinement.allow lists, each with its
# reason, assemble providers and acquisitions for commands.
#
# Supporting evidence, not proof. This reads source text, so it establishes
# that no other module NAMES the capabilities; what a builder does with the
# surface it is given is settled by component-build (the production
# closures: main builds without local-services, koios-http without main),
# the cage-tests rows and the DevNet journey, not here. What it adds is
# extent: every Haskell source under the scanned roots, discovered, not
# listed.
#
# Three refusals:
#   * a confined module import or identifier outside the allowlist;
#   * an allowlist entry with no reason, or naming a file that is gone;
#   * an allowlist entry that names no confined identifier — an exemption
#     nothing needs is a hole waiting for a use.
#
# Usage: tools/capability_confinement_check.sh [repo-root]
#        tools/capability_confinement_check.sh --roots   (print the scanned roots)
set -euo pipefail

# Every production builder and command: the main library and the singular
# commands. Tests, harness fixtures, providers, journeys and exes keep raw
# dependencies by ruling and are not scanned.
scanned=(
  offchain/lib offchain/cli/src
)
if [ "${1:-}" = --roots ]; then
  printf '%s\n' "${scanned[@]}"
  exit 0
fi

root=${1:-.}
allow="$root/tools/capability-confinement.allow"

# Raw capability modules: importing one outside the boundary names the
# capability. Kernel plain modules (Evidence, Ledger, NetworkTime,
# Signing, Trace) are not confined: builders may name plain types.
modules='Singular\.Registry\.(LedgerProvider|SessionIO|SessionServices|SessionEvidence|WalletOutputs|Wallet|ProviderSettings|ProviderTrace|TimeSource|TraceRender|WaitTypes|LocalEvaluation|NetworkTime|Capabilities)'

# Raw capability vocabulary that no fixed-query named read exposes:
# acquisition, session fields, the generic output queries, the provider
# pair readers. Matched as whole words. Deliberately absent: Latest (a
# user-facing receipt string names it) and any (..) spelling (legal
# through the Surface re-export; the import above carries the ban).
identifiers=(
  withLatest acquire sessionTracer sessionNetwork sessionFunding
  mintRecord tipObservation
  AtAddress AtTxIn HoldingAsset CarryingReferenceScript OutputQuery
  capReads capSubmit capConfirm capFacts capTrace
)

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
    echo "  ^ $rel names a raw capability; take the named read from the surface" >&2
    status=1
  fi
done

if [ $status -ne 0 ]; then
  echo "FAIL capability-confinement: see the lines above" >&2
  exit 1
fi

echo "PASS capability-confinement: ${#sources[@]} Haskell sources under ${scanned[*]}; raw capabilities named only in ${#allowed[@]} allowlisted modules"
