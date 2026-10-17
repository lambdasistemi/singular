#!/usr/bin/env bash
# Carol prepares a funding output when none suits (#491 remainder, pull request 1).
# From a one-output wallet, by the real commands, reach the rehearsal wallet
# (create, a booking by another actor, `reject`), assert at run time that the
# creator's wallet holds no ada-only output and both approval kinds, then run
# the termination `fold`.
#
# usage: demo1_cli_prepare_funding.sh SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR
#
# SINGULAR, OPEN_DATUM and DEVNET are executables; BLUEPRINT is the registry
# partition's plutus.json. Carol funds one output (provisional: 500 tADA; the
# pull request settles amounts from receipts); Bob funds two outputs for the
# bookings. Carol creates (chained, no seed flag), Bob books two insertions,
# Carol rejects both, Bob books a termination, Carol folds it:
# on base the fold exits 10 with the "no ada-only UTxO" refusal; green, the
# folds, naming the preparation in its receipt and journal. On base it exits
# 10 with the "no ada-only UTxO" refusal. Short-wallet and allowance legs land
# in phase 2 with the judgement.
# Every assertion reads receipts, the target directory's own journal and files,
# and the chain probe or the provider — never a typed value.
#
# Exit 0: the control holds. Exit 1: it does not, with the reason. Exit 3:
# setup failed before the target check was reached; that is never a verdict.
set -euo pipefail

[ "$#" -eq 5 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR" >&2
  exit 2
}
singular="$1"
open_datum="$2"
devnet="$3"
blueprint="$4"
work="$5"
: "$singular"
rm -rf "$work"
mkdir -p "$work"
receipts="$work/receipts"
mkdir -p "$receipts"
# shellcheck source=tools/managed_state.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/managed_state.sh"

fail() {
  echo "prepare-funding: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "prepare-funding: SETUP: $*" >&2
  exit 3
}
say() { echo "prepare-funding: $*"; }

devnet_pid=""
stop_devnet() {
  if [ -n "${devnet_pid:-}" ]; then
    kill "$devnet_pid" 2>/dev/null || true
    wait "$devnet_pid" 2>/dev/null || true
    devnet_pid=""
  fi
  chmod -R u+rwx "$work/cardano-e2e" 2>/dev/null || true
  rm -rf "$work/cardano-e2e" || true
}
# shellcheck disable=SC2329 # the EXIT trap invokes this
release_work() {
  local code=$?
  trap - EXIT
  stop_devnet
  if [ -n "${work:-}" ] && [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
    echo "kept scratch: $work" >&2
  fi
  exit "$code"
}
trap release_work EXIT

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/carol.skey"
hexkey >"$work/bob.skey"
hexkey >"$work/eve.skey"

export TMPDIR="$work"
# The node binds `$TMPDIR/cardano-e2e/node.sock` (22 characters after TMPDIR)
# and a Unix socket path over 107 bytes cannot be bound: refuse a too-long
# work directory with its length before any node starts.
[ "$((${#work} + 22))" -le 100 ] \
  || setup_fail "the work directory is too long for the node's socket path: $((${#work} + 22)) characters"

start_devnet() {
  local log="$1"
  shift
  stop_devnet
  "$devnet" "$@" >"$work/$log.out" 2>"$work/$log.err" &
  devnet_pid=$!
  sock=""
  provider_url=""
  time_directory=""
  network_magic=""
  for _ in $(seq 1 900); do
    settings="$(head -n1 "$work/$log.out" 2>/dev/null || true)"
    sock="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
    provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
    time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
    network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
    [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_directory/time-manifest.json" ] && break
    kill -0 "$devnet_pid" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -S "$sock" ] || [ ! -r "$time_directory/time-manifest.json" ]; then
    tail -40 "$work/$log.err" >&2 || true
    setup_fail "the private devnet never printed usable provider/time settings ($log)"
  fi
  node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
  say "one private development source at $provider_url ($log)"
}

carol=(--wallet-skey "$work/carol.skey")
bob=(--wallet-skey "$work/bob.skey")
eve=(--wallet-skey "$work/eve.skey")

exit_of() {
  case "$1" in
    success) echo 0 ;; client-refusal) echo 10 ;; ledger-refusal) echo 11 ;;
    node-unavailable) echo 12 ;; timeout) echo 13 ;; stale-state) echo 14 ;;
    partial) echo 15 ;; concurrent-writer) echo 16 ;; proof-missing) echo 17 ;;
    proof-inconsistent) echo 18 ;; waiting-for-signatures) echo 19 ;;
    *) fail "no exit status for class $1" ;;
  esac
}
field() { jq -r "$2" "$receipts/$1.json"; }
orun() {
  local name="$1" want="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  local status=0
  "$open_datum" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  [ "$status" -eq "$(exit_of "$want")" ] || fail "$name: exit $status, wanted $want ($(head -n 3 "$receipts/$name.err" || true))"
  [ "$(jq -r .outcome "$receipts/$name.json")" = "$want" ] || fail "$name: outcome $(jq -r .outcome "$receipts/$name.json"), wanted $want"
}
srun() {
  local name="$1" want="$2"
  shift 2
  [ "${1:-}" = "--" ] && shift
  local status=0
  "$singular" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  [ "$status" -eq "$(exit_of "$want")" ] || fail "$name: exit $status, wanted $want ($(head -n 3 "$receipts/$name.err" || true))"
  [ "$(jq -r .outcome "$receipts/$name.json")" = "$want" ] || fail "$name: outcome $(jq -r .outcome "$receipts/$name.json"), wanted $want"
}

# wallet_utxos ADDR OUT: every unspent output at ADDR, one per line as
# `TXID#IX COIN ASSETS REFDATUM` where ASSETS is the asset count and REFDATUM
# is `script` or `none`. Read from the provider's `address_utxos`, never typed.
wallet_utxos() {
  local addr="$1" out="$2"
  curl -s -X POST "$provider_url/address_utxos" \
    -H "Content-Type: application/json" \
    -d "{\"_addresses\":[\"$addr\"],\"_extended\":true}" >"$out" \
    || setup_fail "the provider did not answer address_utxos for $addr"
  jq -er '.[] | "\(.tx_hash)#\(.tx_index) \(.value) \((.asset_list // []) | length) \(if .reference_script != null then "script" else "none" end)"' "$out" 2>/dev/null \
    || fail "the provider's address_utxos for $addr did not decode: $(head -c 300 "$out")"
}

# ------------------------------------------------------------------
# Rehearsal: one-output create, a booking by Bob, Carol's reject,
# Bob's termination booking, Carol's termination fold
# ------------------------------------------------------------------
start_devnet devnet-rehearsal --fund "$work/carol.skey:1:500000000" \
  --fund "$work/bob.skey:2:2000000000" --fund "$work/eve.skey:1:2000000"
reg="$work/registry"
common=(--state-dir "$reg" --blueprint "$blueprint")

jq -n '{map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}' >"$work/payload-insert.json"

orun carol-create success -- create --process-time 120000 --retract-time 60000 \
  "${common[@]}" "${node[@]}" "${carol[@]}"
token="$(field carol-create .stateToken)"
[ -n "$token" ] && [ "$token" != null ] || fail "carol's create named no token"
carolkey="$(field carol-create .walletKeyHash)"
carol_addr="$(field carol-create .wallet)"
say "carol's one-output create made registry $token"
common+=(--state-token "$token")
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"]' \
  "$receipts/carol-create.json" >/dev/null || fail "carol's create did not publish the six references"
for ref_out in $(jq -r '.references[] | .output' "$receipts/carol-create.json"); do
  probe_one="$work/carol-ref-probe.json"
  "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ref_out" >"$probe_one"
  jq -e --arg r "$ref_out" 'any(.live[]; . == $r)' "$probe_one" >/dev/null \
    || fail "carol's reference $ref_out is not live"
done
say "carol's six references are live"

orun bob-insert success -- insert --key keyPrepareA --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob booked keyPrepareA: $(field bob-insert .request)"
orun bob-insert-b success -- insert --key keyPrepareB --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob booked keyPrepareB: $(field bob-insert-b .request)"

# A reject takes every pending request, so one still inside a window blocks
# it: wait past both windows, as the journey does, before carol rejects.
deadline_ms="$(jq -er .foldDeadline.posixMs "$receipts/bob-insert.json")"
deadline_b_ms="$(jq -er .foldDeadline.posixMs "$receipts/bob-insert-b.json")"
[ "$deadline_b_ms" -gt "$deadline_ms" ] && deadline_ms="$deadline_b_ms"
retract_ms="$(jq -er .retractTime "$receipts/carol-create.json")"
retract_ends=$((deadline_ms + retract_ms))
wait_ms=$((retract_ends + 3000 - $(date +%s%3N)))
if [ "$wait_ms" -gt 0 ]; then
  say "waiting $((wait_ms / 1000 + 1)) s for the booking's retract window to close"
  sleep $((wait_ms / 1000 + 1))
fi

srun carol-reject success -- registry reject "${common[@]}" "${node[@]}" "${carol[@]}"
say "carol rejected: $(field carol-reject .reject)"

# The rehearsal wallet: carol's outputs hold no ada-only output and both
# approval kinds. Read from the provider at run time, never typed.
wallet_utxos "$carol_addr" "$work/carol-utxos.json" >"$work/carol-utxo-lines.txt"
ada_only="$(awk '$3 == 0 && $4 == "none"' "$work/carol-utxo-lines.txt" | wc -l)"
[ "$ada_only" -eq 0 ] || fail "carol's wallet holds $ada_only ada-only outputs, expected none: $(cat "$work/carol-utxo-lines.txt")"
with_assets="$(awk '$3 > 0' "$work/carol-utxo-lines.txt" | wc -l)"
[ "$with_assets" -ge 1 ] || fail "carol's wallet holds no token-carrying output"
say "carol's wallet holds no ada-only output and $with_assets token-carrying outputs"
jq -e '[.[] | select(.address == "'"$carol_addr"'") | .asset_list // [] | length] | add > 1' \
  "$work/carol-utxos.json" >/dev/null \
  || fail "carol's wallet does not hold both approval kinds: $(jq -c '[.[] | select(.address == "'"$carol_addr"'") | {output: "\(.tx_hash)#\(.tx_index)", assets: [.asset_list // [] | .[] | "\(.policy_id).\(.asset_name)x\(.quantity)"]}]' "$work/carol-utxos.json")"
say "carol's wallet holds both approval kinds beside her ada"

orun bob-insert-t success -- insert --key keyPrepareT --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob booked keyPrepareT: $(field bob-insert-t .request)"
orun bob-fold-t success -- fold --request "$(field bob-insert-t .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob folded keyPrepareT active"
orun bob-terminate success -- terminate --key keyPrepareT \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob booked the termination: $(field bob-terminate .request)"

# Snapshot what carol holds before her fold: the multiset of assets, so the
# legs compare exact quantities after, never a typed value.
jq -c '[.[] | select(.address == "'"$carol_addr"'") | .asset_list // [] | .[] | "\(.policy_id):\(.asset_name):\(.quantity)" ] | sort' \
  "$work/carol-utxos.json" >"$work/carol-assets-before.json"
[ "$(jq -r 'length' "$work/carol-assets-before.json")" -ge 2 ] \
  || fail "carol holds fewer than two approval assets before her fold"

# The termination fold: green, it prepares one funding output first and then
# folds, naming the preparation in its receipt and journal. On base it exits
# 10 with the "no ada-only UTxO" refusal.
orun carol-fold success -- fold --request "$(field bob-terminate .request)" \
  "${common[@]}" "${node[@]}" "${carol[@]}"
jq -e '.preparation != null' "$receipts/carol-fold.json" >/dev/null \
  || fail "carol's fold names no preparation: $(jq -c .preparation "$receipts/carol-fold.json")"
say "carol's fold prepared $(field carol-fold .preparation.output) and folded $(field carol-fold .fold)"
carol_journal="$(managed_journal "$reg" "$token" "$carolkey")"
[ -f "$carol_journal" ] || fail "carol's fold left no journal"
prep_tx="$(field carol-fold .preparation.transaction)"
prep_out="$(field carol-fold .preparation.output)"
[ "$prep_out" = "${prep_tx}#0" ] \
  || fail "the preparation's made output $prep_out is not the first output of $prep_tx"
jq -se --arg t "$prep_tx" \
  '[map(select(.journalTxId == $t) | .journalEvent) | sort] | .[0] == ["confirmed","observed","prepared","submitted"]' \
  "$carol_journal" >/dev/null \
  || fail "the journal lacks the preparation's four phases for $prep_tx"
jq -se --arg t "$prep_tx" --arg e "funding:$carol_addr" \
  '[.[] | select(.journalTxId == $t and .journalEvent == "prepared") | .journalExpect] | any(. == $e)' \
  "$carol_journal" >/dev/null \
  || fail "the journal's prepared preparation for $prep_tx expects no funding:$carol_addr"
say "the preparation is journalled under carol's command"
for ref_out in $(jq -r '.references[] | .output' "$receipts/carol-create.json"); do
  probe_one="$work/carol-ref-after.json"
  "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ref_out" >"$probe_one"
  jq -e --arg r "$ref_out" 'any(.live[]; . == $r)' "$probe_one" >/dev/null \
    || fail "carol's reference $ref_out is not live after her fold"
done
say "the six references are live after carol's fold"

# Tokens never stranded: every token of the spent outputs is in the
# preparation's remainder; after the fold carol still holds them in exact
# quantities compared with the values read before.
wallet_utxos "$carol_addr" "$work/carol-utxos-after.json" >"$work/carol-utxo-after-lines.txt"
jq -c '[.[] | select(.address == "'"$carol_addr"'") | .asset_list // [] | .[] | "\(.policy_id):\(.asset_name):\(.quantity)" ] | sort' \
  "$work/carol-utxos-after.json" >"$work/carol-assets-after.json"
[ "$(cat "$work/carol-assets-after.json")" = "$(cat "$work/carol-assets-before.json")" ] \
  || fail "carol's tokens changed across her fold: before $(cat "$work/carol-assets-before.json") after $(cat "$work/carol-assets-after.json")"
say "carol still holds her approvals in exact quantities after her fold"

# No needless preparation: a wallet whose natural build succeeds today gets
# no preparation transaction, no preparation field, one submission only.
# Bob folds from plenty (two 2000 tADA outputs); Carol rejected while she
# still held an ada-only output. Both receipts must LACK the preparation
# member entirely (membership, not value: a null member fails too).
jq -e 'has("preparation") | not' "$receipts/bob-fold-t.json" >/dev/null \
  || fail "bob's funded fold carries a preparation member: $(cat "$receipts/bob-fold-t.json")"
[ "$(jq -r '.submissions | length' "$receipts/bob-fold-t.json")" -eq 1 ] \
  || fail "bob's funded fold submitted more than its own transaction"
say "bob's funded fold made no preparation"
jq -e 'has("preparation") | not' "$receipts/carol-reject.json" >/dev/null \
  || fail "carol's funded reject carries a preparation member: $(cat "$receipts/carol-reject.json")"
[ "$(jq -r '.submissions | length' "$receipts/carol-reject.json")" -eq 1 ] \
  || fail "carol's funded reject submitted more than its own transaction"
say "carol's funded reject made no preparation"

# Explicit choice final: --fund-input on a token-carrying output is refused
# with today's text; a named ada-only output is used as today. Bob books a
# fresh insertion; Carol folds it twice: first naming her token-carrying
# remainder (refused before signing, nothing submitted), then naming her
# ada-only fold change (used, no preparation). All outputs named at run
# time from the provider, never typed.
orun bob-insert-e success -- insert --key keyPrepareE --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob booked keyPrepareE: $(field bob-insert-e .request)"
wallet_utxos "$carol_addr" "$work/carol-utxos-explicit.json" >"$work/carol-utxo-explicit-lines.txt"
token_out="$(awk '$3 > 0 && $4 == "none" {print $1; exit}' "$work/carol-utxo-explicit-lines.txt")"
# Name the SMALLEST ada-only output: the natural choice is the largest, so a
# seam that ignores --fund-input spends another output and the spent probe
# below fails it. All named at run time from the provider, never typed.
ada_eligible="$(awk '$3 == 0 && $4 == "none"' "$work/carol-utxo-explicit-lines.txt" | wc -l)"
ada_out="$(awk '$3 == 0 && $4 == "none" {print $2, $1}' "$work/carol-utxo-explicit-lines.txt" | sort -n | head -n 1 | awk '{print $2}')"
[ -n "${token_out:-}" ] || fail "carol holds no token-carrying output to name: $(cat "$work/carol-utxo-explicit-lines.txt")"
[ -n "${ada_out:-}" ] || fail "carol holds no ada-only output to name: $(cat "$work/carol-utxo-explicit-lines.txt")"
say "carol names $token_out (token-carrying) and $ada_out (ada-only, smallest of $ada_eligible eligible)"
# Today's refusal text for an explicit token-carrying choice, pinned: Fold.hs
# refuses with "the wallet cannot fund the fold: <why>" and Edges.hs
# selectFunding reports "the chosen funding output is not an ada-only output
# of the payer". A frozen pin of the unchanged wording is the point.
pinned_token_refusal="the wallet cannot fund the fold: the chosen funding output is not an ada-only output of the payer"
carol_before_token="$(cat "$work/carol-utxo-explicit-lines.txt")"
journal_before_token="$(journal_lines_root "$reg")"
orun carol-fold-token client-refusal -- fold --request "$(field bob-insert-e .request)" \
  --fund-input "$token_out" "${common[@]}" "${node[@]}" "${carol[@]}"
[ "$(field carol-fold-token .reason)" = "$pinned_token_refusal" ] \
  || fail "carol's token-funded fold was not refused with today's exact text: $(cat "$receipts/carol-fold-token.json")"
jq -e 'has("preparation") | not' "$receipts/carol-fold-token.json" >/dev/null \
  || fail "carol's refused token choice carries a preparation member: $(cat "$receipts/carol-fold-token.json")"
jq -e '.submissions | type == "array" and length == 0' "$receipts/carol-fold-token.json" >/dev/null \
  || fail "carol's refused token choice lacks an empty submissions array: $(cat "$receipts/carol-fold-token.json")"
say "carol's token-carrying choice was refused with today's exact text"
wallet_utxos "$carol_addr" "$work/carol-utxos-after-token.json" >"$work/carol-utxo-after-token-lines.txt"
[ "$(cat "$work/carol-utxo-after-token-lines.txt")" = "$carol_before_token" ] \
  || fail "carol's outputs changed across her refused token choice"
[ "$(journal_lines_root "$reg")" = "$journal_before_token" ] \
  || fail "the journal grew across carol's refused token choice"
say "carol's wallet and the journal are unchanged across her refused choice"
orun carol-fold-named success -- fold --request "$(field bob-insert-e .request)" \
  --fund-input "$ada_out" "${common[@]}" "${node[@]}" "${carol[@]}"
jq -e 'has("preparation") | not' "$receipts/carol-fold-named.json" >/dev/null \
  || fail "carol's named ada-only fold carries a preparation member: $(cat "$receipts/carol-fold-named.json")"
[ "$(jq -r '.submissions | length' "$receipts/carol-fold-named.json")" -eq 1 ] \
  || fail "carol's named ada-only fold submitted more than its own transaction"
# Observe the spent input: the submitted transaction (read back from the
# provider's tx_info, never typed) must spend the named output, and the node
# must show it spent afterwards. The collateral half stays with the
# in-process row, which reads the saved hash-bound body; here the narrowed
# view shows only the named output, so both funding and collateral come
# from it, and spending the smallest eligible output proves the flag was
# honored (the natural choice is the largest).
named_tx="$(jq -r '.submissions[0].tx' "$receipts/carol-fold-named.json")"
[ -n "${named_tx:-}" ] && [ "$named_tx" != null ] \
  || fail "carol's named fold names no submitted transaction: $(cat "$receipts/carol-fold-named.json")"
curl -s -X POST "$provider_url/tx_info" \
  -H "Content-Type: application/json" \
  -d "{\"_tx_hashes\":[\"$named_tx\"]}" >"$work/named-tx-info.json" \
  || fail "the provider did not answer tx_info for $named_tx"
jq -e --arg r "$ada_out" --arg t "$named_tx" \
  '[.[] | select(.tx_hash == $t) | .inputs[] | "\(.tx_hash)#\(.tx_index)"] | any(. == $r)' \
  "$work/named-tx-info.json" >/dev/null \
  || fail "the submitted $named_tx does not spend the named $ada_out: $(jq -c --arg t "$named_tx" '[.[] | select(.tx_hash == $t) | {inputs: [.inputs[] | "\(.tx_hash)#\(.tx_index)"]}]' "$work/named-tx-info.json")"
probe_named="$work/carol-named-probe.json"
"$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ada_out" >"$probe_named"
jq -e --arg r "$ada_out" 'any(.live[]; . == $r) | not' "$probe_named" >/dev/null \
  || fail "carol's named $ada_out is still live after her fold"
say "carol's named ada-only output funded her fold with no preparation"

# Short wallet: Eve holds too little to pay for preparation plus command.
# Bob books a fresh termination; Eve's fold is refused before signing with
# the stable text (what is needed, what she may spend, ends nothing was
# submitted); nothing is submitted, the journal is unchanged, her outputs
# are all still there in run-time numbers from the receipt itself.
orun bob-insert-f success -- insert --key keyPrepareF --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob booked keyPrepareF: $(field bob-insert-f .request)"
orun bob-fold-f success -- fold --request "$(field bob-insert-f .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob folded keyPrepareF active"
orun bob-terminate-f success -- terminate --key keyPrepareF \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob booked the termination for eve: $(field bob-terminate-f .request)"
journal_before="$(journal_lines_root "$reg")"
orun eve-fold-short client-refusal -- fold --request "$(field bob-terminate-f .request)" \
  "${common[@]}" "${node[@]}" "${eve[@]}"
# The stable framing is exact (prefix and suffix); the numbers inside are the
# producer's and are checked against its fields and the wallet below, never
# typed: held against Eve's on-chain total, required against its fee and
# remainder-floor parts, each part against the reason text itself.
eve_reason="$(jq -r .reason "$receipts/eve-fold-short.json")"
[ -n "${eve_reason:-}" ] && [ "$eve_reason" != null ] || fail "eve's refusal names no reason: $(cat "$receipts/eve-fold-short.json")"
case "$eve_reason" in
  "preparation-unfunded:"*"(client policy); nothing was submitted") ;;
  *) fail "eve's short fold lacks the stable framing: $(cat "$receipts/eve-fold-short.json")" ;;
esac
jq -e 'has("preparation") | not' "$receipts/eve-fold-short.json" >/dev/null \
  || fail "eve's refused fold carries a preparation member: $(cat "$receipts/eve-fold-short.json")"
jq -e '.submissions | type == "array" and length == 0' "$receipts/eve-fold-short.json" >/dev/null \
  || fail "eve's refused fold lacks an empty submissions array: $(cat "$receipts/eve-fold-short.json")"
say "eve's short fold was refused before signing: $eve_reason"
eve_addr="$(jq -r '.wallet' "$receipts/eve-fold-short.json")"
[ -n "${eve_addr:-}" ] && [ "$eve_addr" != null ] \
  || fail "eve's refusal names no wallet: $(cat "$receipts/eve-fold-short.json")"
eve_held="$(jq -r '.held' "$receipts/eve-fold-short.json")"
eve_required="$(jq -r '.required' "$receipts/eve-fold-short.json")"
eve_fee="$(jq -r '.fee' "$receipts/eve-fold-short.json")"
eve_floor="$(jq -r '.remainderMin' "$receipts/eve-fold-short.json")"
eve_count="$(jq -r '.utxoCount' "$receipts/eve-fold-short.json")"
for f in held:$eve_held required:$eve_required fee:$eve_fee floor:$eve_floor count:$eve_count; do
  v="${f#*:}"
  [ -n "${v:-}" ] && [ "$v" != null ] || fail "eve's refusal names no ${f%%:*}: $(cat "$receipts/eve-fold-short.json")"
done
# The reason's own numbers must match the receipt's fields: held, required,
# and the command/fee/floor decomposition inside the parentheses.
reason_held="$(printf '%s' "$eve_reason" | grep -o 'holds [0-9]* lovelace' | grep -o '[0-9]*')"
reason_required="$(printf '%s' "$eve_reason" | grep -o '[0-9]* is required' | grep -o '[0-9]*')"
reason_cmd="$(printf '%s' "$eve_reason" | grep -o '([0-9]* for the command' | grep -o '[0-9]*')"
reason_fee="$(printf '%s' "$eve_reason" | grep -o '[0-9]* fee' | grep -o '[0-9]*')"
reason_floor="$(printf '%s' "$eve_reason" | grep -o '[0-9]* remainder floor' | grep -o '[0-9]*')"
[ "$reason_held" = "$eve_held" ] || fail "reason holds $reason_held, field held $eve_held"
[ "$reason_required" = "$eve_required" ] || fail "reason requires $reason_required, field required $eve_required"
[ "$reason_fee" = "$eve_fee" ] || fail "reason fee $reason_fee, field fee $eve_fee"
[ "$reason_floor" = "$eve_floor" ] || fail "reason floor $reason_floor, field remainderMin $eve_floor"
[ "$((reason_cmd + reason_fee + reason_floor))" -eq "$eve_required" ] \
  || fail "reason parts $reason_cmd+$reason_fee+$reason_floor do not sum to required $eve_required"
wallet_utxos "$eve_addr" "$work/eve-utxos.json" >"$work/eve-utxo-lines.txt"
[ "$(wc -l <"$work/eve-utxo-lines.txt")" -eq "$eve_count" ] \
  || fail "eve holds $(wc -l <"$work/eve-utxo-lines.txt") outputs, receipt says $eve_count"
[ "$(jq -r '[.[] | select(.address == "'"$eve_addr"'") | .value] | add' "$work/eve-utxos.json")" -eq "$eve_held" ] \
  || fail "eve's on-chain total differs from the receipt's held $eve_held"
say "eve still holds $eve_held lovelace in $eve_count outputs: nothing moved"
# The refused attempt learned Eve's address, so a second identical attempt
# carries a full before/after read: wallet refs and journal lines equal.
eve_before_refs="$(cat "$work/eve-utxo-lines.txt")"
journal_before_second="$(journal_lines_root "$reg")"
orun eve-fold-short-2 client-refusal -- fold --request "$(field bob-terminate-f .request)" \
  "${common[@]}" "${node[@]}" "${eve[@]}"
[ "$(jq -r .reason "$receipts/eve-fold-short-2.json")" = "$eve_reason" ] \
  || fail "eve's second refusal differs: $(cat "$receipts/eve-fold-short-2.json")"
jq -e 'has("preparation") | not' "$receipts/eve-fold-short-2.json" >/dev/null \
  || fail "eve's second refusal carries a preparation member"
jq -e '.submissions | type == "array" and length == 0' "$receipts/eve-fold-short-2.json" >/dev/null \
  || fail "eve's second refusal lacks an empty submissions array"
wallet_utxos "$eve_addr" "$work/eve-utxos-after.json" >"$work/eve-utxo-after-lines.txt"
[ "$(cat "$work/eve-utxo-after-lines.txt")" = "$eve_before_refs" ] \
  || fail "eve's outputs changed across her second refused fold"
[ "$(journal_lines_root "$reg")" = "$journal_before" ] \
  || fail "the journal grew across eve's refused folds"
[ "$journal_before_second" = "$journal_before" ] \
  || fail "the journal grew across eve's first refused fold"
say "the journal is unchanged across eve's refused folds"

say "prepare funding: PASS"
