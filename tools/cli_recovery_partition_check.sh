#!/usr/bin/env bash
# Recovery partition census: every scenario part runs in exactly one hosted
# partition, and every partition that ran real commands ends with the
# trie-capability observation over its own run.
#
# usage: cli_recovery_partition_check.sh REPO-ROOT PARTITIONS_JSON
#
# REPO-ROOT is the checkout holding tools/cli_recovery_controls.sh and
# offchain/cli. PARTITIONS_JSON is the discovery app's list:
# [{"key":...,"name":...,"parts":"..."}]. The known parts come from the
# controls script (CLI_RECOVERY_CONTROLS overrides it, so a scratch copy
# with a dummy part exercises the unknown-part refusal); the cross-wallet
# cases come from the fold path's own hold census, read here without
# starting any node. Exit 0 when every scenario part is judged exactly once
# and every partition ends with the observation; exit 1 naming the offender
# otherwise; exit 2 when the inputs cannot be read (setup, never a verdict).
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
[ -d "$root/offchain/cli" ] || setup_fail "no fold path at $root/offchain/cli"

known_line="$(grep '^known_parts=' "$controls")" || setup_fail "no known_parts line in $controls"
known="${known_line#known_parts=\"}"
known="${known%\"}"
[ -n "$known" ] || setup_fail "known_parts is empty in $controls"
read -ra known_tokens <<<"$known"

holds_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cli-recovery-partition-check.XXXXXX")" || setup_fail "cannot create scratch directory"
holds_file="$holds_tmp/holds.txt"
grep -rhoE 'harnessHoldAt[[:space:]]+"SINGULAR_HARNESS_HOLD_[A-Z_]+"' "$root/offchain/cli" >"$holds_file" || true
[ -s "$holds_file" ] || setup_fail "the fold path declares no hold points"
holds="$(sed -E 's/.*"([^"]+)".*/\1/' "$holds_file" | sort -u)"
rm -rf "$(dirname "$holds_file")"
[ -n "$holds" ] || setup_fail "the fold path declares no hold points"

entries_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cli-recovery-partition-check.XXXXXX")" || setup_fail "cannot create scratch directory"
entries_file="$entries_tmp/entries.txt"
jq -c 'if type=="object" and has("partition") then .partition[] else .[] end' "$json" >"$entries_file" || setup_fail "partitions file is not a JSON array: $json"
[ -s "$entries_file" ] || setup_fail "the partition list is empty: nothing is hosted"
mapfile -t entries <"$entries_file"
rm -rf "$(dirname "$entries_file")"

failed=0
declare -A seen=()
declare -A seen_in=()
declare -A keys=()

is_cross_case() {
  local token="$1"
  local hold
  [[ "$token" == cross-wallet:* ]] || return 1
  local point="${token#cross-wallet:}"
  [ "$point" = "SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer" ] && return 0
  while IFS= read -r hold; do
    [ "$point" = "$hold" ] || continue
    return 0
  done <<<"$holds"
  return 1
}

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
  last_index=$((${#toks[@]} - 1))
  trie_count=0
  pos=0
  declare -A pos_of=()
  for token in "${toks[@]}"; do
    if [ "$token" = trie-capability ]; then
      trie_count=$((trie_count + 1))
    elif [ "$token" = cross-wallet ]; then
      verdict_fail "partition $key names the cross-wallet aggregate: each discovered case runs in its own partition"
    elif is_cross_case "$token"; then
      seen[$token]=$((${seen[$token]:-0} + 1))
      seen_in[$token]="${seen_in[$token]:-} $key"
    else
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
    fi
    if [ -z "${pos_of[$token]+x}" ]; then
      pos_of[$token]=$pos
    fi
    pos=$((pos + 1))
  done
  unset pos_of
  if [ "$trie_count" -ne 1 ] || [ "${toks[$last_index]}" != trie-capability ]; then
    verdict_fail "partition $key does not end with exactly one trie-capability observation"
  fi
  needs_before() {
    local later="$1" earlier="$2"
    local later_pos="" earlier_pos=""
    local i=0
    local token
    for token in "${toks[@]}"; do
      [ "$token" = "$later" ] && [ -z "$later_pos" ] && later_pos=$i
      [ "$token" = "$earlier" ] && [ -z "$earlier_pos" ] && earlier_pos=$i
      i=$((i + 1))
    done
    [ -z "$later_pos" ] && return 0
    [ -n "$earlier_pos" ] && [ "$earlier_pos" -lt "$later_pos" ] && return 0
    verdict_fail "partition $key runs $later without $earlier before it in the same partition"
  }
  needs_before killed accepting
  needs_before never-sent killed
  needs_before whole-journal accepting
done

for known_token in "${known_tokens[@]}"; do
  [ "$known_token" = trie-capability ] && continue
  if [ "$known_token" = cross-wallet ]; then
    while IFS= read -r hold; do
      case_token="cross-wallet:$hold"
      count=${seen[$case_token]:-0}
      [ "$count" -eq 1 ] || verdict_fail "discovered case $case_token is in $count partitions (${seen_in[$case_token]:-none}), expected exactly one"
    done <<<"$holds"
    lost_token="cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer"
    count=${seen[$lost_token]:-0}
    [ "$count" -eq 1 ] || verdict_fail "discovered case $lost_token is in $count partitions (${seen_in[$lost_token]:-none}), expected exactly one"
  else
    count=${seen[$known_token]:-0}
    [ "$count" -eq 1 ] || verdict_fail "scenario part $known_token is in $count partitions (${seen_in[$known_token]:-none}), expected exactly one"
  fi
done

if [ "$failed" -ne 0 ]; then
  exit 1
fi
echo "partition check: every scenario part in exactly one partition, every partition closed by the observation"
for entry in "${entries[@]}"; do
  echo "partition check: $(jq -r '.key' <<<"$entry"): $(jq -r '.parts' <<<"$entry")"
done
