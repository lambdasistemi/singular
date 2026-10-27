#!/usr/bin/env bash
# Exercise the census over the discovery artifact, including empty, missing,
# duplicate and unknown scenarios. No node and no authored expected member list.
set -euo pipefail
[ "$#" -eq 3 ] || exit 2
checker="$1" root="$2" discovery="$3"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/recovery-census.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
bash "$checker" "$root" "$discovery"
refuses() {
  local name="$1" reason="$2" status=0
  bash "$checker" "$root" "$scratch/$name.json" >"$scratch/$name.log" 2>&1 || status=$?
  if [ "$status" -eq 0 ] || ! grep -qF "$reason" "$scratch/$name.log"; then
    cat "$scratch/$name.log" >&2
    echo "partition controls: $name was not refused for $reason (exit $status)" >&2
    exit 1
  fi
  echo "partition controls: $name refused ($reason), exit $status"
}
jq '.partition = []' "$discovery" >"$scratch/empty.json"
refuses empty 'partition list is empty'
jq '.partition |= .[1:]' "$discovery" >"$scratch/missing.json"
refuses missing 'is in 0 partitions'
jq '.partition += [.partition[0]]' "$discovery" >"$scratch/duplicate-key.json"
refuses duplicate-key 'is listed twice'
jq '.partition[0].parts += (" " + .partition[0].parts)' "$discovery" >"$scratch/duplicate-part.json"
refuses duplicate-part 'is in 2 partitions'
jq '.partition[0].parts += " unknown-scenario"' "$discovery" >"$scratch/unknown.json"
refuses unknown 'names unknown part unknown-scenario'
jq '.partition[0].parts = ""' "$discovery" >"$scratch/no-parts.json"
refuses no-parts 'lists no parts'
echo 'partition controls: all six refusals discriminated over actual discovery'
