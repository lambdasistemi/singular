#!/usr/bin/env bash
# Two creates race for one target (#299). The late create belongs to a
# different, independently funded wallet with its own live seed, and is
# held after its pre-lock checks while the first create completes. Once
# it takes the target's lock it must re-check the target and refuse:
# RegistryExists, with the first registry's saved and pending identity,
# state, mirror and journal byte-identical and its own seed still unspent.
#
# usage: demo1_cli_create_race.sh SINGULAR BLUEPRINT SOCKET FIRST_SKEY LATE_SKEY WORKDIR
#
# Exit 0: the control holds. Exit 1: it does not, with the reason. Exit 3:
# setup failed before the race was reached; that is never a verdict.
set -euo pipefail

[ "$#" -eq 6 ] || {
  echo "usage: $0 SINGULAR BLUEPRINT SOCKET FIRST_SKEY LATE_SKEY WORKDIR" >&2
  exit 2
}
singular="$1"
blueprint="$2"
sock="$3"
first_key="$4"
late_key="$5"
work="$6"
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

node=(--node-socket "$sock" --network-magic 42)
# preview NAME SKEY [SEED]: an identity read that writes nothing; with a
# seed it succeeds only while that seed is an unspent output of the wallet.
preview() {
  local name="$1" skey="$2" seed="${3:-}"
  local args=(registry create --process-time 45000 --retract-time 15000 --preview --registry "$work/probe-$name" --blueprint "$blueprint"
    "${node[@]}" --wallet-skey "$skey")
  [ -z "$seed" ] || args+=(--seed "$seed")
  local status=0
  "$singular" "${args[@]}" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  [ ! -e "$work/probe-$name" ] || fail "$name: a preview created its target"
  return "$status"
}
digest() {
  (cd "$target" && sha256sum registry.json registry.pending.json state.json registry.mirror.json journal.jsonl)
}

preview preview-first "$first_key" || setup_fail "the first wallet's preview failed"
preview preview-late "$late_key" || setup_fail "the late wallet's preview failed"
seed_first="$(jq -r .seed "$receipts/preview-first.json")"
seed_late="$(jq -r .seed "$receipts/preview-late.json")"
[ "$(jq -r .walletKeyHash "$receipts/preview-first.json")" != "$(jq -r .walletKeyHash "$receipts/preview-late.json")" ] \
  || setup_fail "the two creates sign with the same wallet"
[ "$seed_first" != "$seed_late" ] || setup_fail "the two creates name the same seed"

SINGULAR_HARNESS_HOLD_BEFORE_LOCK="$work/go" "$singular" registry create --process-time 45000 --retract-time 15000 --seed "$seed_late" \
  --registry "$target" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$late_key" \
  >"$receipts/create-late.json" 2>"$receipts/create-late.err" &
late=$!
for _ in $(seq 1 300); do
  [ -e "$work/go.waiting" ] && break
  sleep 0.1
done
[ -e "$work/go.waiting" ] || setup_fail "the late create never reached its hold point"

status=0
"$singular" registry create --process-time 45000 --retract-time 15000 --seed "$seed_first" --registry "$target" --blueprint "$blueprint" \
  "${node[@]}" --wallet-skey "$first_key" >"$receipts/create-first.json" 2>"$receipts/create-first.err" \
  || status=$?
[ "$status" -eq 0 ] && [ "$(jq -r .outcome "$receipts/create-first.json")" = success ] \
  || setup_fail "the first create did not complete (exit $status)"
jq -e '.processTime == 45000 and .retractTime == 15000' "$receipts/create-first.json" >/dev/null \
  || fail "the first registry did not read back the short CI windows"
before="$(digest)"
[ -e "$target/registry.json" ] || setup_fail "the first create saved no registry"

# The late create's seed is still live while it waits: the race is real.
preview seed-late-held "$late_key" "$seed_late" \
  || setup_fail "the late seed is not live before the release; the race would not reach the target check"

touch "$work/go"
status=0
wait "$late" || status=$?
outcome="$(jq -r .outcome "$receipts/create-late.json" 2>/dev/null || echo none)"
reason="$(jq -r .reason "$receipts/create-late.json" 2>/dev/null || echo none)"
expected="$target already holds a registry or its journal; create never overwrites one"
[ "$outcome" = client-refusal ] && [ "$status" -eq 10 ] \
  || fail "the late create was not refused (outcome $outcome, exit $status): $reason"
[ "$reason" = "$expected" ] \
  || fail "the late create was refused for another reason than RegistryExists: $reason"
[ "$(digest)" = "$before" ] \
  || fail "the first registry's identity, state, mirror or journal changed"
preview seed-late-after "$late_key" "$seed_late" \
  || fail "the late seed is spent: the late create submitted something"
say "the late create, on a live seed of another wallet, was refused RegistryExists under the lock; the first registry is byte-identical"
