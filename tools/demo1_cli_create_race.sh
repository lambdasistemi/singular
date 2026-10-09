#!/usr/bin/env bash
# Two creates race for one seed (#299). A second boot of the same seed by the
# same wallet is held after its pre-lock checks while the first create
# completes. Once it takes the target's lock it must re-check the target and
# refuse: RegistryExists, with the first create's journal byte-identical, no
# identity file written, and nothing submitted. Different seeds boot different
# registries in different managed partitions, so cross-seed concurrency is
# two registries, not a race.
#
# usage: demo1_cli_create_race.sh SINGULAR BLUEPRINT KOIOS_URL NETWORK_TIME MAGIC FIRST_SKEY LATE_SKEY WORKDIR
#
# Exit 0: the control holds. Exit 1: it does not, with the reason. Exit 3:
# setup failed before the race was reached; that is never a verdict.
set -euo pipefail

[ "$#" -eq 8 ] || {
  echo "usage: $0 SINGULAR BLUEPRINT KOIOS_URL NETWORK_TIME MAGIC FIRST_SKEY LATE_SKEY WORKDIR" >&2
  exit 2
}
singular="$1"
blueprint="$2"
provider_url="$3"
time_directory="$4"
network_magic="$5"
first_key="$6"
late_key="$7"
work="$8"
mkdir -p "$work/receipts"
receipts="$work/receipts"
target="$work/raced"

fail() {
  echo "create-race: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "create-race: SETUP: $*" >&2
  exit 3
}
say() { echo "create-race: $*"; }

node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
# preview NAME SKEY [SEED]: an identity read that writes nothing; with a
# seed it succeeds only while that seed is an unspent output of the wallet.
preview() {
  local name="$1" skey="$2" seed="${3:-}"
  local args=(registry create --process-time 45000 --retract-time 15000 --preview --state-dir "$work/probe-$name" --blueprint "$blueprint"
    "${node[@]}" --wallet-skey "$skey")
  [ -z "$seed" ] || args+=(--seed "$seed")
  local status=0
  "$singular" "${args[@]}" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  [ ! -e "$work/probe-$name" ] || fail "$name: a preview created its target"
  return "$status"
}
# shellcheck source=tools/managed_state.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/managed_state.sh"

digest() {
  local found
  mapfile -t found < <(managed_find "$target" journal.jsonl)
  [ "${#found[@]}" -eq 1 ] || return 1
  (cd "$target" && sha256sum "${found[0]}" && ls -A)
}

preview preview-first "$first_key" || setup_fail "the first wallet's preview failed"
seed_first="$(jq -r .seed "$receipts/preview-first.json")"
[ "$late_key" = "$first_key" ] \
  || setup_fail "the double-boot race needs one wallet for one seed"
# The late create boots the same seed: under the managed layout that is the
# same identity partition, so the under-lock existence check refuses it.
# Its pre-lock checks passed with the seed live: it reached its hold point
# (asserted below) after validating the seed and before the first create
# consumed it, so the race is real.

SINGULAR_HARNESS_HOLD_BEFORE_LOCK="$work/go" "$singular" registry create --process-time 45000 --retract-time 15000 --seed "$seed_first" \
  --state-dir "$target" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$first_key" \
  >"$receipts/create-late.json" 2>"$receipts/create-late.err" &
late=$!
for _ in $(seq 1 300); do
  [ -e "$work/go.waiting" ] && break
  sleep 0.1
done
[ -e "$work/go.waiting" ] || setup_fail "the late create never reached its hold point"

status=0
"$singular" registry create --process-time 45000 --retract-time 15000 --seed "$seed_first" --state-dir "$target" --blueprint "$blueprint" \
  "${node[@]}" --wallet-skey "$first_key" >"$receipts/create-first.json" 2>"$receipts/create-first.err" \
  || status=$?
[ "$status" -eq 0 ] && [ "$(jq -r .outcome "$receipts/create-first.json")" = success ] \
  || setup_fail "the first create did not complete (exit $status)"
jq -e '.processTime == 45000 and .retractTime == 15000' "$receipts/create-first.json" >/dev/null \
  || fail "the first registry did not read back the short CI windows"
before="$(digest)"
winner_found=()
mapfile -t winner_found < <(managed_find "$target" journal.jsonl)
[ "${#winner_found[@]}" -eq 1 ] && [ -s "${winner_found[0]}" ] \
  || setup_fail "the first create left no single journal"
[ -z "$(managed_find "$target" registry.json)" ] && [ -z "$(managed_find "$target" registry.pending.json)" ] \
  || fail "the first create left an identity file"
# The late create reached its hold after validating the live seed and before
# the first create consumed it; that ordering is the race. The winner spends
# the raced seed, so a preview of it must now refuse.
preview seed-first-spent "$first_key" "$seed_first" \
  && fail "the raced seed is still live after the winning boot"

touch "$work/go"
status=0
wait "$late" || status=$?
outcome="$(jq -r .outcome "$receipts/create-late.json" 2>/dev/null || echo none)"
reason="$(jq -r .reason "$receipts/create-late.json" 2>/dev/null || echo none)"
expected="$(managed_partition "$target" "$(jq -r .stateToken "$receipts/create-first.json")" "$(jq -r .walletKeyHash "$receipts/create-first.json")" "$network_magic") already holds your state or its journal; create never overwrites one"
[ "$outcome" = client-refusal ] && [ "$status" -eq 10 ] \
  || fail "the late create was not refused (outcome $outcome, exit $status): $reason"
[ "$reason" = "$expected" ] \
  || fail "the late create was refused for another reason than RegistryExists: $reason"
[ "$(digest)" = "$before" ] \
  || fail "the first create's journal or directory changed"
say "the late double boot of one seed was refused RegistryExists under the lock; the first registry is byte-identical"
