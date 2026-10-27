#!/usr/bin/env bash
# Recovery partition census: every scenario part runs in exactly one hosted
# partition, with nonempty discovery and no unknown parts.
#
# usage: cli_recovery_partition_check.sh REPO-ROOT PARTITIONS_JSON
#
# REPO-ROOT is the checkout holding tools/cli_recovery_controls.sh and
# offchain/cli. PARTITIONS_JSON is the discovery app's list:
# [{"key":...,"name":...,"parts":"..."}]. The known parts come from the
# controls script (CLI_RECOVERY_CONTROLS overrides it, so a scratch copy
# with a dummy part exercises the unknown-part refusal).
# Exit 0 when every scenario part is judged exactly once, 1 for a census
# defect, 2 for unreadable inputs. No node starts here.
set -uo pipefail

setup_fail() {
  echo "partition check: SETUP: $*" >&2
  exit 2
}
verdict_fail() {
  echo "partition check: FAIL: $*" >&2
  failed=1
}

[ "$#" -eq 2 ] || {
  echo "usage: $0 REPO-ROOT PARTITIONS_JSON" >&2
  exit 2
}
root="$(cd "$1" && pwd)" || setup_fail "no repository at $1"
json="$2"
[ -f "$json" ] || setup_fail "no partitions file at $json"
controls="${CLI_RECOVERY_CONTROLS:-$root/tools/cli_recovery_controls.sh}"
[ -f "$controls" ] || setup_fail "no controls script at $controls"

known_line="$(grep '^known_parts=' "$controls")" || setup_fail "no known_parts line in $controls"
known="${known_line#known_parts=\"}"
known="${known%\"}"
[ -n "$known" ] || setup_fail "known_parts is empty in $controls"
read -ra known_tokens <<<"$known"

entries_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cli-recovery-partition-check.XXXXXX")" || setup_fail "cannot create scratch directory"
trap 'rm -rf "$entries_tmp"' EXIT
entries_file="$entries_tmp/entries.txt"
jq -c 'if type=="object" and has("partition") then .partition[] else .[] end' "$json" >"$entries_file" || setup_fail "partitions file is not a JSON array: $json"
[ -s "$entries_file" ] || setup_fail "the partition list is empty: nothing is hosted"
mapfile -t entries <"$entries_file"
rm -rf "$(dirname "$entries_file")"

failed=0
declare -A seen=()
declare -A seen_in=()
declare -A keys=()

entry_no=0
for entry in "${entries[@]}"; do
  entry_no=$((entry_no + 1))
  key="$(jq -r '.key // empty' <<<"$entry")"
  parts="$(jq -r '.parts // empty' <<<"$entry")"
  [ -n "$key" ] || {
    verdict_fail "entry $entry_no has no key"
    continue
  }
  [ -n "$parts" ] || {
    verdict_fail "partition $key lists no parts"
    continue
  }
  if [ -n "${keys[$key]+x}" ]; then
    verdict_fail "partition $key is listed twice"
    continue
  fi
  keys[$key]=1
  read -ra toks <<<"$parts"
  [ "${#toks[@]}" -gt 0 ] || {
    verdict_fail "partition $key lists no parts"
    continue
  }
  for token in "${toks[@]}"; do
    known_hit=0
    for known_token in "${known_tokens[@]}"; do
      [ "$token" = "$known_token" ] || continue
      known_hit=1
      break
    done
    if [ "$known_hit" -eq 0 ]; then
      verdict_fail "partition $key names unknown part $token"
    else
      seen[$token]=$((${seen[$token]:-0} + 1))
      seen_in[$token]="${seen_in[$token]:-} $key"
    fi
  done
done

for known_token in "${known_tokens[@]}"; do
  count=${seen[$known_token]:-0}
  [ "$count" -eq 1 ] || verdict_fail "scenario part $known_token is in $count partitions (${seen_in[$known_token]:-none}), expected exactly one"
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "partition check: every retained scenario part in exactly one nonempty partition list"
for entry in "${entries[@]}"; do
  echo "partition check: $(jq -r '.key' <<<"$entry"): $(jq -r '.parts' <<<"$entry")"
done
