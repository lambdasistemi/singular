#!/usr/bin/env bash
# Verify the pinned script identities against the compiled blueprints
# carried in this archive — from the artifact alone, with nothing but
# bash and jq. No clone, no Nix, no network.
#
# This is the same two-directional comparison CI enforces
# (onchain/flake.nix checks.script-identity, and its naming-onchain
# counterpart): every blueprint validator must be pinned with the same
# hash and parameter count, every pin must have a counterpart in the
# blueprint, no side may be empty, and the compiler string must agree.
set -euo pipefail
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status=0
for partition in onchain naming-onchain; do
  blueprint="$here/$partition/plutus.json"
  manifest="$here/$partition/script-identity.json"
  for file in "$blueprint" "$manifest"; do
    if [ ! -f "$file" ]; then
      echo "FAIL: $partition: missing $(basename "$file")" >&2
      status=1
    fi
  done
  [ "$status" -eq 0 ] || continue
  if ! problems="$(jq -r -n \
    --slurpfile bp "$blueprint" \
    --slurpfile man "$manifest" \
    '
      ($bp[0].validators | map({key: .title, value: .hash}) | from_entries) as $built
      | ($man[0].validators | map({key: .title, value: .hash}) | from_entries) as $pinned
      | ($man[0].validators | map({key: .title, value: ((.parameters // 0) | tostring)}) | from_entries) as $pinnedParams
      | ($bp[0].validators | map({key: .title, value: ((.parameters // []) | length | tostring)}) | from_entries) as $builtParams
      | (if ($built | length) == 0
         then ["FAIL: the blueprint reports zero validators"] else [] end)
        + (if ($pinned | length) == 0
         then ["FAIL: the manifest records zero validators"] else [] end)
        + (if $man[0].compiler != $bp[0].preamble.compiler.version then
             ["FAIL: compiler moved: manifest records \($man[0].compiler), blueprint reports \($bp[0].preamble.compiler.version)"]
           else [] end)
        + [$built | to_entries[] | .key as $k |
             if ($pinned | has($k) | not) then
               "FAIL: validator \($k) is missing from the manifest (built hash \(.value))"
             elif $pinned[$k] != .value then
               "FAIL: validator \($k) moved: manifest expects \($pinned[$k]), archive carries \(.value)"
             elif $pinnedParams[$k] != $builtParams[$k] then
               "FAIL: validator \($k) parameter count moved: manifest expects \($pinnedParams[$k]), archive carries \($builtParams[$k])"
             else empty end]
        + [$pinned | to_entries[] | .key as $k |
             if ($built | has($k) | not) then
               "FAIL: manifest entry \($k) (hash \(.value)) has no counterpart in the carried blueprint"
             else empty end]
      | .[]
    ')"; then
    echo "FAIL: $partition: jq could not parse the blueprint or the manifest" >&2
    status=1
    continue
  fi
  if [ -n "$problems" ]; then
    echo "$partition identity check FAILED:" >&2
    printf '%s\n' "$problems" >&2
    status=1
  else
    echo "$partition identity: OK — $(jq '.validators | length' "$manifest") validators pinned with parameter counts, manifest matches the carried compiled blueprint (compiler $(jq -r '.compiler' "$manifest"))"
  fi
done
if [ "$status" -ne 0 ]; then
  echo "identity verification FAILED" >&2
else
  echo "identity verification: PASS (both partitions, from this archive alone)"
fi
exit "$status"
