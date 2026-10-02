#!/usr/bin/env bash
# The four refusals of the demonstration, on one registry that already exists
# and a fresh key per take (#300): an update that needs another wallet's
# signature, a release outside any fold, a second insertion of an Active key
# and an insertion of a Terminal key, each beside its accepting control, through
# a node the script starts and then only reads from and submits to.
#
# usage: demo1_cli_attach.sh SINGULAR DEVNET CLI_CONTROLS BLUEPRINT LEDGER WORKDIR
#
# The registry is created once by the ordinary `singular registry create`,
# as a person runs it, from a wallet holding two large ada-only outputs: the
# seed, which stays unspent until the boot, and the output that pays the
# first publication meanwhile (a wallet holding one output is refused before
# anything is submitted). Two takes then run on that one
# registry with two fresh keys: `cli-controls attach` creates no registry and
# never stops or resets the node, runs the ordinary commands itself, and
# judges every clause from the receipts it leaves. The second take can only
# succeed if the first left its registry usable: the first take's refused
# insertions leave pending requests that it must retract, or the second take's
# fold would take them with it. Two continuation controls follow: a take with no
# collateral allowance is refused before it writes, and a take over its allowance
# stops at that refusal with nothing after it run. Setup failures exit 3 and are
# never a verdict.
set -euo pipefail

[ "$#" -eq 6 ] || {
  echo "usage: $0 SINGULAR DEVNET CLI_CONTROLS BLUEPRINT LEDGER WORKDIR" >&2
  exit 2
}
singular="$1"
devnet="$2"
controls="$3"
blueprint="$4"
ledger="$5"
work="$6"
[ ! -e "$work" ] || {
  echo "attach: $work exists; every run takes a fresh directory" >&2
  exit 2
}
mkdir -p "$work"

setup_fail() {
  echo "attach: SETUP: $*" >&2
  exit 3
}
say() { echo "attach: $*"; }
fail_control() {
  echo "attach: CONTROL FAILED: $*" >&2
  exit 1
}

od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$work/wallet.skey"
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$work/stranger.skey"
# What a take asks the public indexers through: the readback script and the
# generated indexer stand-in that sit beside this script, and a credential file
# that is only a marked value, since the stand-in checks that one was sent.
here="$(cd "$(dirname "$0")" && pwd)"
readback="$here/demo1_readback.sh"
mock="$here/demo1_mock_indexer.py"
[ -f "$readback" ] && [ -f "$mock" ] || setup_fail "the readback script and the indexer stand-in are not beside this script"
printf 'mock-project-key\n' >"$work/blockfrost.key"
indexer_pid=""

export TMPDIR="$work"
"$devnet" --fund-skey "$work/wallet.skey" --fund-skey "$work/stranger.skey" \
  --fund-outputs 80 --fund-lovelace 5000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
trap 'kill "$devnet_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
sock=""
for _ in $(seq 1 900); do
  sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  [ -n "$sock" ] && [ -S "$sock" ] && break
  kill -0 "$devnet_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$sock" ] || [ ! -S "$sock" ]; then
  tail -40 "$work/devnet.err" >&2 || true
  setup_fail "the development node never printed a usable socket"
fi
say "one development node at $sock"

node=(--node-socket "$sock" --network-magic 42)
registry="$work/registry"
common=(--registry "$registry" --blueprint "$blueprint")
receipts="$work/receipts"
mkdir -p "$receipts"

# The registry, created once by the ordinary commands.
"$singular" registry create --preview "${common[@]}" "${node[@]}" --wallet-skey "$work/wallet.skey" \
  >"$receipts/preview.json"
address="$(jq -r .wallet "$receipts/preview.json")"
"$singular" registry create --preview "${common[@]}" "${node[@]}" --wallet-address "$address" \
  >"$receipts/preview-public.json"
jq -e --slurpfile k "$receipts/preview.json" '.seed == $k[0].seed and .pins == $k[0].pins' \
  "$receipts/preview-public.json" >/dev/null || setup_fail "the public preview names another registry"
"$singular" registry create --seed "$(jq -r .seed "$receipts/preview.json")" \
  "${common[@]}" "${node[@]}" --wallet-skey "$work/wallet.skey" >"$receipts/create.json"
jq -e '.outcome == "success"' "$receipts/create.json" >/dev/null || setup_fail "the registry was not created"
say "registry $(jq -r .token "$receipts/create.json") created once, from its seed beside one funding output"

# One indexer stand-in per take, serving the receipts that take writes.
start_indexer() { # NAME MODE
  local name="$1" mode="$2"
  mkdir -p "$work/$name/receipts"
  rm -f "$work/$name.port"
  python3 "$mock" "$mode" "$work/$name/receipts" "$work/$name.port" "$work/$name.indexer.log" &
  indexer_pid=$!
  for _ in $(seq 1 50); do
    [ -s "$work/$name.port" ] && break
    sleep 0.1
  done
  [ -s "$work/$name.port" ] || setup_fail "the indexer stand-in never started"
  indexer_url="http://127.0.0.1:$(cat "$work/$name.port")"
}
stop_indexer() { kill "$indexer_pid" 2>/dev/null || true; }
indexer_args() { echo --readback "$readback" --blockfrost-credential-file "$work/blockfrost.key" --max-lag 600; }

take() {
  local name="$1" key="$2" status=0
  start_indexer "$name" honest
  # shellcheck disable=SC2046
  "$controls" attach \
    --singular "$singular" --blueprint "$blueprint" --ledger "$ledger" \
    "${node[@]}" --wallet-skey "$work/wallet.skey" --stranger-skey "$work/stranger.skey" \
    --registry "$registry" --key "$key" \
    --collateral-allowance 10000000 --max-outlay 40000000 \
    --koios-base-url "$indexer_url" --blockfrost-base-url "$indexer_url" $(indexer_args) \
    --work "$work/$name" >"$work/$name.md" 2> >(tee "$work/$name.err" >&2) || status=$?
  stop_indexer
  tail -1 "$work/$name.md"
  [ "$status" -eq 0 ] || fail_control "take $name did not hold (exit $status)"
  grep -m3 "uncovered" "$work/$name.md" >&2 || true
  # The key ends Terminal by the ordinary inspect, and no request is left pending.
  "$singular" registry inspect --key "$key" \
    "${common[@]}" "${node[@]}" >"$receipts/inspect-$name.json"
  [ "$(jq -r .leaf "$receipts/inspect-$name.json")" = terminal ] \
    || fail_control "take $name: the key is not Terminal afterwards"
  [ "$(grep -c 'read-indexer' "$work/$name.err")" -ge 2 ] \
    || fail_control "take $name did not ask both indexers"
  grep -q 'project_id=mock-project-key' "$work/$name.indexer.log" \
    || fail_control "take $name: the credential reference never reached the indexer"
  say "take $name held: four refusals, each beside its accepting control, and the key read from two indexers while Active"
}

take one demo1-take-one
before="$(wc -l <"$registry/journal.jsonl")"
take two demo1-take-two
[ "$(wc -l <"$registry/journal.jsonl")" -gt "$before" ] || fail_control "the second take wrote nothing to the registry"
say "the registry created once served two takes with two fresh keys"

# The verdict rests on the retained bytes: on copies of the first take's
# receipts, the honest copy holds; the retraction's body removed, or the bound
# lowered below the collateral a refusal states, each fails for its reason.
copies="$work/artifact-controls"
mkdir -p "$copies"
copy() {
  rm -rf "${copies:?}/$1"
  mkdir -p "$copies/$1"
  cp -r "$work/one/receipts" "$work/one/evidence" "$copies/$1/"
  jq -r '.submissions[]?.bodyFile' "$work"/one/receipts/*.json | while read -r kept; do
    (cd "$work/one" && cp --parents "$kept" "$copies/$1/")
  done
  jq -r '(.journal // empty | .file), (.process // empty | .journal, (.filesAfter[]?[0]))' "$work"/one/receipts/*.json \
    | sort -u | while read -r kept; do
    (cd "$work/one" && cp --parents "$kept" "$copies/$1/")
  done
}
expect() {
  local s=0
  "$controls" render --attach-key demo1-take-one "$copies/$1/receipts" >"$copies/$1.md" 2>"$copies/$1.err" || s=$?
  if [ -z "$2" ]; then
    [ "$s" -eq 0 ] || fail_control "$1: the unchanged copy does not hold (exit $s)"
  else
    [ "$s" -ne 0 ] || fail_control "$1: the changed copy still holds"
    grep -qF "$2" "$copies/$1.md" || fail_control "$1: no clause fails for: $2"
  fi
  say "artifact control $1: as expected"
}
copy honest
expect honest ""
reclaim="$(grep -l '"action": "reclaim"' "$work"/one/receipts/*.json || true)"
reclaim="${reclaim%%$'\n'*}"
[ -n "$reclaim" ] || fail_control "the first take left no retraction receipt"
body="$(jq -r .bodyFile "$reclaim")"
copy retraction-body-missing
rm "$copies/retraction-body-missing/$body"
expect retraction-body-missing "the retained body $body is missing"
refusal="$(grep -l '"action": "fold-unevaluated"' "$work"/one/receipts/*.json || true)"
refusal="${refusal%%$'\n'*}"
copy bound-lowered
jq '.allowance = 1' "$refusal" >"$copies/bound-lowered/receipts/$(basename "$refusal")"
expect bound-lowered "over the bound of 1"
say "artifact controls: the honest copy holds; each changed copy fails for its reason"
# The indexer verdict rests on the record's facts, not on what it says of them:
# on copies of the first take's receipts, the Koios record changed in one raw
# fact at a time, every stated comparison left true and its digest renewed in the
# receipt, each fails for that fact.
tamper="$here/demo1_readback_tamper.sh"
read_receipt="$(grep -l '"action": "read-indexer koios"' "$work"/one/receipts/*.json || true)"
read_receipt="${read_receipt%%$'\n'*}"
[ -n "$read_receipt" ] || fail_control "the first take left no koios read receipt"
record="$(jq -r .readbackFile "$read_receipt")"
for fact in datum lag census quantity index entry; do
  copy "record-$fact"
  TAMPER="$fact" bash "$tamper" --record "$copies/record-$fact/$record"
  digest="$(sha256sum "$copies/record-$fact/$record" | cut -d' ' -f1)"
  jq --arg d "$digest" '.readbackSha256 = $d' "$read_receipt" \
    >"$copies/record-$fact/receipts/$(basename "$read_receipt")"
done
expect record-datum "the indexer's datum bytes are not the node's"
expect record-lag "slots behind the node, beyond the 600 allowed"
expect record-census "counts 2 outputs holding the token"
expect record-quantity "is 1.4, not an exact whole number"
expect record-index ", not an exact output index"
expect record-entry "is \"0.5\", not an exact whole number"
say "artifact controls: a record whose raw datum, tip or token census contradicts its stated verdict, or whose quantity or output index of the token is not an exact whole number, fails for that fact"
# Continuation controls. They run last because the stopped takes leave their key
# Active (and the over-allowance take leaves a request pending, by design: a take
# that stops does not retract).
# (1) A take with no collateral allowance, or none that says how to read the
# indexers, is refused before it writes anything.
# (2) A take whose indexer disagrees with the node, and (3) one whose indexer
# cannot be reached, stop at that read, before the termination: the key is still
# Active afterwards and no later action ran.
# (4) A take whose refusal states more collateral than its allowance stops at
# that refusal: nothing is signed for it, and no later action runs.
node_args=("${node[@]}" --wallet-skey "$work/wallet.skey" --stranger-skey "$work/stranger.skey")
attach_with() { # NAME KEY [extra options]
  local name="$1" key="$2"
  shift 2
  "$controls" attach --singular "$singular" --blueprint "$blueprint" --ledger "$ledger" \
    "${node_args[@]}" --registry "$registry" --key "$key" --work "$work/$name" "$@" \
    >"$work/$name.md" 2>"$work/$name.err"
}
journal_lines() { wc -l <"$registry/journal.jsonl"; }
expect_refused_before_writing() { # NAME WORDS
  [ "$status" -ne 0 ] || fail_control "$1: the take ran"
  grep -qF -- "$2" "$work/$1.err" || fail_control "$1: the refusal does not say why ($2)"
  [ "$(journal_lines)" -eq "$before" ] || fail_control "$1: the take wrote to the registry"
  [ -z "$(ls "$work/$1/receipts" 2>/dev/null)" ] || fail_control "$1: the take left receipts"
  say "continuation control $1: refused before any write"
}
actions_of() { jq -r .action "$work/$1"/receipts/*.json; }
last_receipt() { find "$work/$1/receipts" -name "*.json" | sort | tail -n1; }

before="$(journal_lines)"
start_indexer controls honest
status=0
# shellcheck disable=SC2046
attach_with no-allowance demo1-take-none --max-outlay 40000000 \
  --koios-base-url "$indexer_url" --blockfrost-base-url "$indexer_url" $(indexer_args) || status=$?
expect_refused_before_writing no-allowance "--collateral-allowance is required"
status=0
attach_with no-readback demo1-take-none --collateral-allowance 10000000 --max-outlay 40000000 || status=$?
expect_refused_before_writing no-readback "--readback is required"
stop_indexer

# An indexer that cannot honestly confirm the key stops the take before its termination.
indexer_stop() { # NAME KEY OUTCOME MODE KOIOS_URL_OR_EMPTY
  local name="$1" key="$2" outcome="$3" mode="$4" koios="$5" status=0
  start_indexer "$name" "$mode"
  [ -n "$koios" ] || koios="$indexer_url"
  # shellcheck disable=SC2046
  attach_with "$name" "$key" --collateral-allowance 10000000 --max-outlay 40000000 \
    --koios-base-url "$koios" --blockfrost-base-url "$indexer_url" $(indexer_args) || status=$?
  stop_indexer
  [ "$status" -ne 0 ] || fail_control "$name: the take went on past an indexer it could not confirm with"
  grep -qF "read-indexer koios ended $outcome" "$work/$name/stopped.txt" \
    || fail_control "$name: the take did not stop at the koios read with $outcome: $(cat "$work/$name/stopped.txt" 2>/dev/null)"
  last="$(last_receipt "$name")"
  [ "$(jq -r .action "$last")" = "read-indexer koios" ] \
    || fail_control "$name: the take went on past its stop: its last receipt is $(jq -r .action "$last")"
  [ "$(jq -r .outcome "$last")" = "$outcome" ] || fail_control "$name: the read ended $(jq -r .outcome "$last"), not $outcome"
  [ "$(actions_of "$name" | grep -cE '^(read-indexer blockfrost|craft early-withdrawal|run terminate)' || true)" -eq 0 ] \
    || fail_control "$name: an action ran after the take had to stop"
  "$singular" registry inspect --key "$key" \
    "${common[@]}" "${node[@]}" >"$receipts/inspect-$name.json"
  [ "$(jq -r .leaf "$receipts/inspect-$name.json")" = active ] \
    || fail_control "$name: the key is not still Active, so something was written after the stop"
  say "continuation control $name: stopped at the koios read ($outcome), the key still Active, no later action ran"
}
indexer_stop mismatch demo1-take-mismatch provider-mismatch datum-changed ""
indexer_stop unreachable demo1-take-unreachable provider-unavailable honest "http://127.0.0.1:1"

# A record that holds by its stated verdict but not by its facts stops the take at
# that read, before its next write: the readback runs as given, then one raw fact
# of its Koios record changes with every stated comparison left true.
tampered_stop() { # NAME KEY FACT NEEDLE
  local name="$1" key="$2" fact="$3" needle="$4" status=0
  start_indexer "$name" honest
  export TAMPER="$fact"
  attach_with "$name" "$key" --collateral-allowance 10000000 --max-outlay 40000000 \
    --koios-base-url "$indexer_url" --blockfrost-base-url "$indexer_url" \
    --readback "$tamper" --blockfrost-credential-file "$work/blockfrost.key" --max-lag 600 || status=$?
  unset TAMPER
  stop_indexer
  [ "$status" -ne 0 ] || fail_control "$name: the take went on past a record its facts contradict"
  grep -qF "IndexerAgrees does not hold" "$work/$name/stopped.txt" \
    || fail_control "$name: the take did not stop on the indexer's verdict: $(cat "$work/$name/stopped.txt" 2>/dev/null)"
  grep -qF "$needle" "$work/$name/stopped.txt" || fail_control "$name: the stop does not name the fact ($needle)"
  last="$(last_receipt "$name")"
  [ "$(jq -r .action "$last")" = "read-indexer koios" ] \
    || fail_control "$name: the take went on past its stop: its last receipt is $(jq -r .action "$last")"
  [ "$(jq -r .outcome "$last")" = success ] || fail_control "$name: the tampered read did not end success, so it tests nothing"
  [ "$(actions_of "$name" | grep -cE '^(read-indexer blockfrost|craft early-withdrawal|run terminate)' || true)" -eq 0 ] \
    || fail_control "$name: an action ran after the take had to stop"
  "$singular" registry inspect --key "$key" \
    "${common[@]}" "${node[@]}" >"$receipts/inspect-$name.json"
  [ "$(jq -r .leaf "$receipts/inspect-$name.json")" = active ] \
    || fail_control "$name: the key is not still Active, so something was written after the stop"
  say "continuation control $name: a koios record whose $fact contradicts its stated verdict stopped the take before its next write"
}
tampered_stop tampered-datum demo1-take-datum datum "the indexer's datum bytes are not the node's"
tampered_stop tampered-lag demo1-take-lag lag "slots behind the node, beyond the 600 allowed"
tampered_stop tampered-census demo1-take-census census "counts 2 outputs holding the token"
tampered_stop tampered-quantity demo1-take-quantity quantity "is 1.4, not an exact whole number"
tampered_stop tampered-index demo1-take-index index ", not an exact output index"
tampered_stop tampered-entry demo1-take-entry entry "is \"0.5\", not an exact whole number"

# Last, because it leaves a request pending by design: a take that stops does not
# retract, and the next take's fold would take it.
start_indexer controls honest
status=0
# shellcheck disable=SC2046
attach_with stopped demo1-take-three --collateral-allowance 1 --max-outlay 40000000 \
  --koios-base-url "$indexer_url" --blockfrost-base-url "$indexer_url" $(indexer_args) || status=$?
stop_indexer
[ "$status" -ne 0 ] || fail_control "a take over its collateral allowance did not stop"
[ -s "$work/stopped/stopped.txt" ] || fail_control "the stopped take recorded no reason"
grep -qF "fold-unevaluated ended client-error" "$work/stopped/stopped.txt" \
  || fail_control "the take stopped, but not at the refusal over its allowance: $(cat "$work/stopped/stopped.txt")"
grep -qF "over the bound of 1" "$work/stopped/stopped.txt" \
  || fail_control "the stop does not say the collateral was over the bound"
last="$(last_receipt stopped)"
[ "$(jq -r .action "$last")" = fold-unevaluated ] \
  || fail_control "the take went on past its stop: its last receipt is $(jq -r .action "$last")"
[ "$(jq -r .txId "$last")" = null ] || fail_control "something was signed for the refusal over the allowance"
[ "$(actions_of stopped | grep -cE '^(reclaim|craft |run terminate|read-indexer)' || true)" -eq 0 ] \
  || fail_control "an action ran after the take had to stop"
say "continuation control over-allowance: stopped at the refusal, nothing signed, nothing after it ran"

echo "attach: PASS — two takes on one registry, four refusals and two indexer reads each, every verdict from retained receipts"
