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
# Part 3 of #491 adds the legs of `update`, of the termination from a wallet
# of tokens alone, and of approval tokens above quantity one: Iris updates her
# own key from the rehearsal wallet after three rounds of rejects have left two
# approval kinds above quantity one in it; Hank terminates his key from the
# rehearsal wallet; Frank's single output now also carries an update; Bob's
# funded update makes no preparation.
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
hexkey >"$work/dave.skey"
hexkey >"$work/frank.skey"
hexkey >"$work/iris.skey"
hexkey >"$work/hank.skey"

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
dave=(--wallet-skey "$work/dave.skey")
frank=(--wallet-skey "$work/frank.skey")
iris=(--wallet-skey "$work/iris.skey")
hank=(--wallet-skey "$work/hank.skey")

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

# --- check helpers (each negative-controlled: a corrupted copy fed to
# the same check fails, see the run's handoffs) ---

# prep_wellformed NAME FILE: NAME's receipt carries a preparation object
# whose every member is typed and well-formed — a 64-hex transaction, an
# output that is that transaction plus #index, numeric lovelace and fee.
prep_wellformed() {
  jq -e '
    .preparation as $p |
    ($p | type) == "object"
    and ($p | has("transaction") and has("output") and has("lovelace") and has("fee"))
    and ($p.transaction | type == "string" and test("^[0-9a-f]{64}$"))
    and ($p.output | type == "string" and test("^[0-9a-f]{64}#[0-9]+$"))
    and ($p.output | startswith($p.transaction))
    and ($p.lovelace | type == "number")
    and ($p.fee | type == "number")
  ' "$2" >/dev/null \
    || fail "$1 names no well-formed preparation: $(cat "$2")"
}

# subs_exact NAME FILE WANT: NAME's submissions are an array of objects
# with string step and tx members, whose [step, tx] pairs equal WANT in
# order.
subs_exact() {
  jq -e --argjson want "$3" '
    (.submissions | type == "array")
    and (all(.submissions[]; (.step | type == "string") and (.tx | type == "string")))
    and ([.submissions[] | [.step, .tx]] == $want)
  ' "$2" >/dev/null \
    || fail "$1 submissions are not $3: $(jq -c .submissions "$2")"
}

# refs_wellformed NAME FILE: NAME's create receipt published exactly six
# reference entries — an ARRAY of objects, the six roles each once, every
# output a distinct well-formed reference.
refs_wellformed() {
  jq -e '
    (.references | type) == "array"
    and (.references | length) == 6
    and (all(.references[]; type == "object"))
    and ([.references[] | .role] | sort == ["application","request","state","witness-absent","witness-active","witness-terminal"])
    and ([.references[] | .output] | unique | length) == 6
    and (all(.references[]; .output | type == "string" and test("^[0-9a-f]{64}#[0-9]+$")))
  ' "$2" >/dev/null \
    || fail "$1 did not publish six distinct references: $(jq -c .references "$2")"
}

# state_digest ROOT: the sorted `path<TAB>sha256` of every file under the
# registry state root, paths relative to that root — the byte identity a
# refusal that submits nothing must leave.
state_digest() {
  (
    cd "$1" || exit 3
    find . -type f -print | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\t%s\n' "${f#./}" "$(sha256sum "$f" | awk '{print $1}')"
    done
  )
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

# journal_of_tx ROOT TX: the one journal file under ROOT that names the
# transaction.
journal_of_tx() {
  local f
  local -a hits=()
  while IFS= read -r f; do
    grep -q "$2" "$f" && hits+=("$f")
  done < <(managed_find "$1" journal.jsonl)
  [ "${#hits[@]}" -eq 1 ] || return 1
  printf '%s\n' "${hits[0]}"
}

# asset_totals ADDR UTXOFILE: the wallet's assets, one entry per policy and
# asset name with its quantity added over every output, sorted: the exact
# quantities a leg compares before and after.
asset_totals() {
  jq -c --arg a "$1" '
    [.[] | select(.address == $a) | (.asset_list // [])[]
      | {k: "\(.policy_id):\(.asset_name)", q: (.quantity | tonumber)}]
    | group_by(.k) | map({k: .[0].k, q: (map(.q) | add)}) | sort_by(.k)' "$2"
}

# assert_refs_live NAME CREATE_RECEIPT: every reference output the create
# receipt names is live now, and the receipt names some.
assert_refs_live() {
  local name="$1" file="$2" count probed=0 ref
  count="$(jq -r '.references | length' "$file")"
  [ "$count" -ge 1 ] || fail "$name: the create receipt names no reference output"
  for ref in $(jq -r '.references[] | .output' "$file"); do
    "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ref" >"$work/ref-probe.json"
    jq -e --arg r "$ref" 'any(.live[]; . == $r)' "$work/ref-probe.json" >/dev/null \
      || fail "$name: reference $ref is not live"
    probed=$((probed + 1))
  done
  [ "$probed" -eq "$count" ] || fail "$name: probed $probed of $count references"
  say "$name: its $count references are live"
}

# wait_for_windows RETRACT_MS RECEIPT...: sleep until the latest fold deadline
# the named booking receipts carry, plus the retract window, has passed.
wait_for_windows() {
  local retract_ms="$1" deadline=0 d wait_ms name
  shift
  for name in "$@"; do
    d="$(jq -er .foldDeadline.posixMs "$receipts/$name.json")"
    [ "$d" -gt "$deadline" ] && deadline="$d"
  done
  wait_ms=$((deadline + retract_ms + 3000 - $(date +%s%3N)))
  if [ "$wait_ms" -gt 0 ]; then
    say "waiting $((wait_ms / 1000 + 1)) s for the retract window to close"
    sleep $((wait_ms / 1000 + 1))
  fi
}

# assert_through_preparation NAME STEP MEMBER ADDR JOURNAL: the command's
# receipt names one well-formed preparation, its submissions are exactly the
# preparation then the command (the receipt's MEMBER) under STEP, the journal
# holds the preparation's four phases with the funding expectation for ADDR
# (when ADDR is given) and the command's four phases, and the provider shows
# the command spending the made output. A ledger that accepted the command
# also accepted its collateral: the made output is ada only.
assert_through_preparation() {
  local name="$1" step="$2" member="$3" addr="$4" journal="$5"
  local file="$receipts/$name.json" prep_tx prep_out cmd_tx
  prep_wellformed "$name" "$file"
  prep_tx="$(field "$name" .preparation.transaction)"
  prep_out="$(field "$name" .preparation.output)"
  [ "$prep_out" = "${prep_tx}#0" ] \
    || fail "$name: the made output $prep_out is not the first output of $prep_tx"
  cmd_tx="$(field "$name" ".$member")"
  [ -n "$cmd_tx" ] && [ "$cmd_tx" != null ] || fail "$name names no $member: $(cat "$file")"
  subs_exact "$name" "$file" \
    "$(jq -cn --arg s "$step" --arg p "$prep_tx" --arg c "$cmd_tx" '[[$s, $p], [$s, $c]]')"
  [ -f "$journal" ] || fail "$name left no journal at $journal"
  jq -se --arg t "$prep_tx" \
    '[map(select(.journalTxId == $t) | .journalEvent)] | .[0] == ["prepared","submitted","confirmed","observed"]' \
    "$journal" >/dev/null \
    || fail "$name: the journal lacks the preparation's four phases in order for $prep_tx"
  if [ -n "$addr" ]; then
    jq -se --arg t "$prep_tx" --arg e "funding:$addr" \
      '[.[] | select(.journalTxId == $t and .journalEvent == "prepared") | .journalExpect] | any(. == $e)' \
      "$journal" >/dev/null \
      || fail "$name: the journal's prepared preparation for $prep_tx expects no funding:$addr"
  fi
  jq -se --arg t "$cmd_tx" \
    '[map(select(.journalTxId == $t) | .journalEvent)] | .[0] == ["prepared","submitted","confirmed","observed"]' \
    "$journal" >/dev/null \
    || fail "$name: the journal lacks the command's four phases in order for $cmd_tx"
  curl -s -X POST "$provider_url/tx_info" \
    -H "Content-Type: application/json" \
    -d "{\"_tx_hashes\":[\"$cmd_tx\"]}" >"$work/$name-cmd-info.json" \
    || fail "$name: the provider did not answer tx_info for $cmd_tx"
  jq -e --arg r "$prep_out" --arg t "$cmd_tx" \
    '[.[] | select(.tx_hash == $t) | .inputs[] | "\(.tx_hash)#\(.tx_index)"] | any(. == $r)' \
    "$work/$name-cmd-info.json" >/dev/null \
    || fail "$name: $cmd_tx does not spend the made $prep_out"
  say "$name made $prep_out and ran through it"
}

# assert_preview_equals NAME PREVIEW: NAME's preparation figures (transaction,
# output, lovelace, fee) are the preview's, read from the two receipts.
assert_preview_equals() {
  local name="$1" preview="$2" member
  for member in transaction output lovelace fee; do
    [ "$(jq -r ".preparation.$member" "$receipts/$name.json")" = "$(jq -r ".preparation.$member" "$receipts/$preview.json")" ] \
      || fail "$name: the preparation's $member differs from $preview's"
  done
}

# ------------------------------------------------------------------
# Rehearsal: one-output create, a booking by Bob, Carol's reject,
# Bob's termination booking, Carol's termination fold
# ------------------------------------------------------------------
start_devnet devnet-rehearsal --fund "$work/carol.skey:1:500000000" \
  --fund "$work/bob.skey:2:2000000000" --fund "$work/eve.skey:1:2000000" \
  --fund "$work/dave.skey:1:500000000" --fund "$work/frank.skey:1:40000000" \
  --fund "$work/iris.skey:1:500000000" --fund "$work/hank.skey:1:500000000"
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
refs_wellformed "carol's create" "$receipts/carol-create.json"
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
# Name an ada-only output of the wallet, the smallest. All named at run time
# from the provider, never typed. This leg observes that the named output is
# accepted, is the submitted input and is spent; when the wallet holds a single
# eligible output (as here) the natural choice is that same output, so the leg
# does not tell a final named choice from the natural one: that discrimination
# is carried by the in-process row "an explicit funding choice is final: the
# smaller named output funds the update, not the natural one", which two
# eligible outputs and the mutant that ignores the named output turn red.
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
# from it. What is observed is that the named output is the submitted input
# and is spent afterwards; whether it differs from the natural choice is not.
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

# ------------------------------------------------------------------
# The booking's own legs (#491 remainder, pull request 2b): a token-only
# wallet books through one preparation, the faucet's single output books
# with no hand step, a short wallet is refused before signing, and a
# funded wallet books with no preparation member.
# ------------------------------------------------------------------

# Dave reaches the rehearsal shape in his own registry: he creates from
# his single funded output, Bob books two insertions, Dave rejects both,
# and his change carries the approvals beside his ada with no ada-only
# output left. His registry keeps Carol's untouched.
orun dave-create success -- create --process-time 120000 --retract-time 60000 \
  --state-dir "$reg" --blueprint "$blueprint" "${node[@]}" "${dave[@]}"
dave_token="$(field dave-create .stateToken)"
[ -n "$dave_token" ] && [ "$dave_token" != null ] || fail "dave's create named no token"
dave_addr="$(field dave-create .wallet)"
davekey="$(field dave-create .walletKeyHash)"
say "dave's one-output create made registry $dave_token"
davecommon=(--state-dir "$reg" --blueprint "$blueprint" --state-token "$dave_token")
orun dave-bob-insert-k success -- insert --key keyPrepareK --payload "$work/payload-insert.json" \
  "${davecommon[@]}" "${node[@]}" "${bob[@]}"
orun dave-bob-insert-l success -- insert --key keyPrepareL --payload "$work/payload-insert.json" \
  "${davecommon[@]}" "${node[@]}" "${bob[@]}"
say "bob booked keyPrepareK and keyPrepareL in dave's registry"
deadline_k_ms="$(jq -er .foldDeadline.posixMs "$receipts/dave-bob-insert-k.json")"
deadline_l_ms="$(jq -er .foldDeadline.posixMs "$receipts/dave-bob-insert-l.json")"
[ "$deadline_l_ms" -gt "$deadline_k_ms" ] && deadline_k_ms="$deadline_l_ms"
dave_retract_ms="$(jq -er .retractTime "$receipts/dave-create.json")"
dave_retract_ends=$((deadline_k_ms + dave_retract_ms))
dave_wait_ms=$((dave_retract_ends + 3000 - $(date +%s%3N)))
if [ "$dave_wait_ms" -gt 0 ]; then
  say "waiting $((dave_wait_ms / 1000 + 1)) s for dave's retract window to close"
  sleep $((dave_wait_ms / 1000 + 1))
fi
srun dave-reject success -- registry reject "${davecommon[@]}" "${node[@]}" "${dave[@]}"
say "dave rejected: $(field dave-reject .reject)"
wallet_utxos "$dave_addr" "$work/dave-utxos.json" >"$work/dave-utxo-lines.txt"
dave_ada_only="$(awk '$3 == 0 && $4 == "none"' "$work/dave-utxo-lines.txt" | wc -l)"
[ "$dave_ada_only" -eq 0 ] || fail "dave's wallet holds $dave_ada_only ada-only outputs, expected none: $(cat "$work/dave-utxo-lines.txt")"
jq -e --arg a "$dave_addr" '[.[] | select(.address == $a)] | (length > 0) and all(.[]; .asset_list != null)' \
  "$work/dave-utxos.json" >/dev/null \
  || fail "the provider's answer for dave names no assets on some output: $(jq -c --arg a "$dave_addr" '[.[] | select(.address == $a) | {output: "\(.tx_hash)#\(.tx_index)", assets: .asset_list}]' "$work/dave-utxos.json")"
jq -e --arg a "$dave_addr" '[.[] | select(.address == $a) | .asset_list[] | "\(.policy_id).\(.asset_name)"] | unique | length > 1' \
  "$work/dave-utxos.json" >/dev/null \
  || fail "dave's wallet does not hold both approval kinds: $(jq -c --arg a "$dave_addr" '[.[] | select(.address == $a) | {output: "\(.tx_hash)#\(.tx_index)", assets: [.asset_list[] | "\(.policy_id).\(.asset_name)x\(.quantity)"]}]' "$work/dave-utxos.json")"
say "dave's wallet is token-only, holding both approval kinds"

# The booking preview from the token-only wallet: it plans the
# preparation without submitting anything; the journal and the wallet
# stand still around it.
dave_state_before_preview="$(state_digest "$reg")"
dave_preview_status=0
"$open_datum" insert --key keyPrepare2b --payload "$work/payload-insert.json" \
  --preview --wallet-address "$dave_addr" "${davecommon[@]}" "${node[@]}" \
  >"$receipts/dave-insert-preview.json" 2>"$receipts/dave-insert-preview.err" || dave_preview_status=$?
[ "$dave_preview_status" -eq 0 ] \
  || fail "dave insert preview exits $dave_preview_status, wanted success ($(jq -r .reason "$receipts/dave-insert-preview.json" 2>/dev/null || head -n 3 "$receipts/dave-insert-preview.err"))"
prep_wellformed "dave insert preview" "$receipts/dave-insert-preview.json"
jq -r .preparation "$receipts/dave-insert-preview.json" >"$work/dave-preview-prep.json"
jq -e 'tostring | contains("send one self-payment") | not' "$receipts/dave-insert-preview.json" >/dev/null \
  || fail "dave insert preview still prints the self-payment instruction: $(cat "$receipts/dave-insert-preview.json")"
say "dave insert preview plans $(jq -r .preparation.output "$receipts/dave-insert-preview.json")"
wallet_utxos "$dave_addr" "$work/dave-utxos-after-preview.json" >"$work/dave-utxo-after-preview-lines.txt"
[ "$(cat "$work/dave-utxo-after-preview-lines.txt")" = "$(cat "$work/dave-utxo-lines.txt")" ] \
  || fail "dave's outputs moved across his preview"
[ "$(state_digest "$reg")" = "$dave_state_before_preview" ] \
  || fail "the registry state changed across dave's preview (byte-identity of every file)"
say "dave's preview submitted and journalled nothing"

# The booking itself: it completes through ONE preparation, whose figures
# equal the preview's on the same wallet.
jq -c --arg a "$dave_addr" '[.[] | select(.address == $a) | .asset_list[] | "\(.policy_id):\(.asset_name):\(.quantity)"] | sort' \
  "$work/dave-utxos.json" >"$work/dave-assets-before.json"
orun dave-insert success -- insert --key keyPrepare2b --payload "$work/payload-insert.json" \
  "${davecommon[@]}" "${node[@]}" "${dave[@]}"
prep_wellformed "dave insert" "$receipts/dave-insert.json"
prep_wellformed "dave insert (figure equality)" "$receipts/dave-insert.json"
jq -e '(.transaction | type == "string") and (.lovelace | type == "number") and (.fee | type == "number")' \
  "$work/dave-preview-prep.json" >/dev/null \
  || fail "the preview's preparation figures are not typed: $(cat "$work/dave-preview-prep.json")"
[ "$(jq -r '.preparation.transaction' "$receipts/dave-insert.json")" = "$(jq -r .transaction "$work/dave-preview-prep.json")" ] \
  || fail "the preview's preparation transaction differs from the insert's"
[ "$(jq -r '.preparation.output' "$receipts/dave-insert.json")" = "$(jq -r .output "$work/dave-preview-prep.json")" ] \
  || fail "the preview's made output differs from the insert's"
[ "$(jq -r '.preparation.lovelace' "$receipts/dave-insert.json")" = "$(jq -r .lovelace "$work/dave-preview-prep.json")" ] \
  || fail "the preview's funding lovelace differs from the insert's"
[ "$(jq -r '.preparation.fee' "$receipts/dave-insert.json")" = "$(jq -r .fee "$work/dave-preview-prep.json")" ] \
  || fail "the preview's preparation fee differs from the insert's"
dave_prep_tx="$(field dave-insert .preparation.transaction)"
dave_prep_out="$(field dave-insert .preparation.output)"
[ "$dave_prep_out" = "${dave_prep_tx}#0" ] \
  || fail "dave's made output $dave_prep_out is not the first output of $dave_prep_tx"
dave_booking_tx="$(field dave-insert .booking)"
[ -n "$dave_booking_tx" ] && [ "$dave_booking_tx" != null ] \
  || fail "dave's insert names no booking: $(cat "$receipts/dave-insert.json")"
dave_subs_want="$(jq -cn --arg p "$dave_prep_tx" --arg b "$dave_booking_tx" '[["book",$p],["book",$b]]')"
subs_exact "dave's insert" "$receipts/dave-insert.json" "$dave_subs_want"
dave_journal="$(managed_journal "$reg" "$dave_token" "$davekey")"
[ -f "$dave_journal" ] || fail "dave's insert left no journal"
jq -se --arg t "$dave_prep_tx" \
  '[map(select(.journalTxId == $t) | .journalEvent)] | .[0] == ["prepared","submitted","confirmed","observed"]' \
  "$dave_journal" >/dev/null \
  || fail "the journal lacks the preparation's four phases in order for $dave_prep_tx"
jq -se --arg t "$dave_prep_tx" --arg e "funding:$dave_addr" \
  '[.[] | select(.journalTxId == $t and .journalEvent == "prepared") | .journalExpect] | any(. == $e)' \
  "$dave_journal" >/dev/null \
  || fail "the journal's prepared preparation for $dave_prep_tx expects no funding:$dave_addr"
dave_booking_tx="$(field dave-insert .booking)"
[ -n "$dave_booking_tx" ] && [ "$dave_booking_tx" != null ] \
  || fail "dave's insert names no booking: $(cat "$receipts/dave-insert.json")"
curl -s -X POST "$provider_url/tx_info" \
  -H "Content-Type: application/json" \
  -d "{\"_tx_hashes\":[\"$dave_booking_tx\"]}" >"$work/dave-booking-info.json" \
  || fail "the provider did not answer tx_info for $dave_booking_tx"
jq -e --arg r "$dave_prep_out" --arg t "$dave_booking_tx" \
  '[.[] | select(.tx_hash == $t) | .inputs[] | "\(.tx_hash)#\(.tx_index)"] | any(. == $r)' \
  "$work/dave-booking-info.json" >/dev/null \
  || fail "the booking $dave_booking_tx does not spend the made $dave_prep_out"
say "dave's insert made $dave_prep_out and booked through it"
wallet_utxos "$dave_addr" "$work/dave-utxos-after.json" >"$work/dave-utxo-after-lines.txt"
jq -e --arg a "$dave_addr" '[.[] | select(.address == $a)] | all(.[]; .asset_list != null)' \
  "$work/dave-utxos-after.json" >/dev/null \
  || fail "the provider's answer for dave names no assets on some output after his insert"
jq -c --arg a "$dave_addr" '[.[] | select(.address == $a) | .asset_list[] | "\(.policy_id):\(.asset_name):\(.quantity)"] | sort' \
  "$work/dave-utxos-after.json" >"$work/dave-assets-after.json"
[ "$(cat "$work/dave-assets-after.json")" = "$(cat "$work/dave-assets-before.json")" ] \
  || fail "dave's tokens changed across his insert: before $(cat "$work/dave-assets-before.json") after $(cat "$work/dave-assets-after.json")"
say "dave still holds his approvals in exact quantities after his insert"
refs_wellformed "dave's create" "$receipts/dave-create.json"
dave_ref_count="$(jq -r '.references | length' "$receipts/dave-create.json")"
dave_refs_probed=0
for ref_out in $(jq -r '.references[] | .output' "$receipts/dave-create.json"); do
  probe_one="$work/dave-ref-after.json"
  "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ref_out" >"$probe_one"
  jq -e --arg r "$ref_out" 'any(.live[]; . == $r)' "$probe_one" >/dev/null \
    || fail "dave's reference $ref_out is not live after his insert"
  dave_refs_probed=$((dave_refs_probed + 1))
done
[ "$dave_refs_probed" -eq "$dave_ref_count" ] \
  || fail "probed $dave_refs_probed references, the create receipt names $dave_ref_count"
say "dave's $dave_ref_count references are live after his insert"

# The faucet's single output: Frank holds exactly one ada-only output
# (what the faucet pays). His insert and his terminate complete with no
# hand step; each receipt says whether a preparation was made, and the
# leg asserts what it says.
orun frank-insert success -- insert --key keyFaucet1 --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${frank[@]}"
if jq -e 'has("preparation")' "$receipts/frank-insert.json" >/dev/null; then
  prep_wellformed "frank's insert" "$receipts/frank-insert.json"
  frank_prep_tx="$(field frank-insert .preparation.transaction)"
  frank_booking_tx="$(field frank-insert .booking)"
  frank_subs_want="$(jq -cn --arg p "$frank_prep_tx" --arg b "$frank_booking_tx" '[["book",$p],["book",$b]]')"
  subs_exact "frank's insert" "$receipts/frank-insert.json" "$frank_subs_want"
  say "frank's insert prepared $(field frank-insert .preparation.output) from the single output"
else
  frank_tx="$(field frank-insert .booking)"
  frank_subs_want="$(jq -cn --arg b "$frank_tx" '[["book",$b]]')"
  subs_exact "frank's insert" "$receipts/frank-insert.json" "$frank_subs_want"
  say "frank's insert needed no preparation: the single output funded and collateralised it"
fi
orun frank-fold-bob success -- fold --request "$(field frank-insert .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
say "bob folded keyFaucet1 active for frank"
jq -n '{int: 43}' >"$work/payload-update.json"
orun frank-update success -- update --key keyFaucet1 --payload "$work/payload-update.json" \
  "${common[@]}" "${node[@]}" "${frank[@]}"
frank_update_tx="$(field frank-update .update)"
[ -n "$frank_update_tx" ] && [ "$frank_update_tx" != null ] \
  || fail "frank's update names no transaction: $(cat "$receipts/frank-update.json")"
if jq -e 'has("preparation")' "$receipts/frank-update.json" >/dev/null; then
  frank_journal="$(journal_of_tx "$reg" "$frank_update_tx")" \
    || fail "no single journal names frank's update $frank_update_tx"
  assert_through_preparation frank-update update update "" "$frank_journal"
  say "frank's update prepared $(field frank-update .preparation.output) from the single output"
else
  subs_exact "frank's update" "$receipts/frank-update.json" \
    "$(jq -cn --arg u "$frank_update_tx" '[["update", $u]]')"
  say "frank's update needed no preparation: the single output funded and collateralised it"
fi
jq -e '.payload == {"int": 43}' "$receipts/frank-update.json" >/dev/null \
  || fail "frank's update receipt does not carry the new payload: $(jq -c .payload "$receipts/frank-update.json")"
orun frank-terminate success -- terminate --key keyFaucet1 \
  "${common[@]}" "${node[@]}" "${frank[@]}"
if jq -e 'has("preparation")' "$receipts/frank-terminate.json" >/dev/null; then
  prep_wellformed "frank's terminate" "$receipts/frank-terminate.json"
  frank_t_prep_tx="$(field frank-terminate .preparation.transaction)"
  frank_t_booking_tx="$(field frank-terminate .booking)"
  frank_t_subs_want="$(jq -cn --arg p "$frank_t_prep_tx" --arg b "$frank_t_booking_tx" '[["book",$p],["book",$b]]')"
  subs_exact "frank's terminate" "$receipts/frank-terminate.json" "$frank_t_subs_want"
  say "frank's terminate prepared $(field frank-terminate .preparation.output)"
else
  frank_t_tx="$(field frank-terminate .booking)"
  frank_t_subs_want="$(jq -cn --arg b "$frank_t_tx" '[["book",$b]]')"
  subs_exact "frank's terminate" "$receipts/frank-terminate.json" "$frank_t_subs_want"
  say "frank's terminate needed no preparation"
fi

# A short wallet is refused before signing: Eve's insert, nothing
# submitted, the journal unchanged, her outputs all still there.
eve_state_before_insert="$(state_digest "$reg")"
wallet_utxos "$(jq -r '.wallet' "$receipts/eve-fold-short.json")" "$work/eve-utxos-insert.json" >"$work/eve-utxo-insert-lines.txt"
orun eve-insert-short client-refusal -- insert --key keyEveShort --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${eve[@]}"
case "$(jq -r .reason "$receipts/eve-insert-short.json")" in
  "the wallet holds "*" lovelace but "*" is required for fold reserve (client policy)") ;;
  *) fail "eve's short insert lacks the fold-reserve framing: $(cat "$receipts/eve-insert-short.json")" ;;
esac
[ "$(jq -r .requiredIs "$receipts/eve-insert-short.json")" = "fold reserve" ] \
  || fail "eve's short insert does not name the fold reserve as what is required: $(cat "$receipts/eve-insert-short.json")"
jq -e 'has("preparation") | not' "$receipts/eve-insert-short.json" >/dev/null \
  || fail "eve's refused insert carries a preparation member: $(cat "$receipts/eve-insert-short.json")"
jq -e '.submissions | type == "array" and length == 0' "$receipts/eve-insert-short.json" >/dev/null \
  || fail "eve's refused insert lacks an empty submissions array: $(cat "$receipts/eve-insert-short.json")"
wallet_utxos "$(jq -r '.wallet' "$receipts/eve-insert-short.json")" "$work/eve-utxos-after-insert.json" >"$work/eve-utxo-after-insert-lines.txt"
[ "$(cat "$work/eve-utxo-after-insert-lines.txt")" = "$(cat "$work/eve-utxo-insert-lines.txt")" ] \
  || fail "eve's outputs changed across her refused insert"
[ "$(state_digest "$reg")" = "$eve_state_before_insert" ] \
  || fail "the registry state changed across eve's refused insert (byte-identity of every file)"
jq -e '(.held | type == "number") and (.required | type == "number") and (.shortfall | type == "number")' \
  "$receipts/eve-insert-short.json" >/dev/null \
  || fail "eve's refusal figures are not all numbers: $(cat "$receipts/eve-insert-short.json")"
eve_i_held="$(jq -r .held "$receipts/eve-insert-short.json")"
eve_i_required="$(jq -r .required "$receipts/eve-insert-short.json")"
eve_i_shortfall="$(jq -r .shortfall "$receipts/eve-insert-short.json")"
[ "$((eve_i_required - eve_i_held))" -eq "$eve_i_shortfall" ] \
  || fail "eve's refusal arithmetic: required $eve_i_required - held $eve_i_held is not the shortfall $eve_i_shortfall"
eve_i_addr="$(jq -r .wallet "$receipts/eve-insert-short.json")"
[ "$(jq -r --arg a "$eve_i_addr" '[.[] | select(.address == $a) | .value] | add' "$work/eve-utxos-insert.json")" -eq "$eve_i_held" ] \
  || fail "eve's on-chain total differs from the receipt's held $eve_i_held"
say "eve's short insert was refused before signing: $(jq -r .reason "$receipts/eve-insert-short.json")"

# A funded wallet books with no preparation member: every booking Bob
# made in this run (inserts and the termination) lacked one, and each
# submitted exactly its own transaction.
for r in bob-insert bob-insert-b bob-insert-t bob-insert-e bob-insert-f bob-terminate; do
  jq -e 'has("preparation") | not' "$receipts/$r.json" >/dev/null \
    || fail "$r carries a preparation member: $(cat "$receipts/$r.json")"
  b_tx="$(field "$r" .booking)"
  [ -n "$b_tx" ] && [ "$b_tx" != null ] \
    || fail "$r names no booking: $(cat "$receipts/$r.json")"
  b_want="$(jq -cn --arg b "$b_tx" '[["book",$b]]')"
  subs_exact "$r" "$receipts/$r.json" "$b_want"
done
say "bob's funded bookings made no preparation"

# ------------------------------------------------------------------
# `update`, the termination from a wallet of tokens alone, and approval
# tokens above quantity one (#491, part 3). Iris and Hank each create a
# registry of their own with short windows, make a live key of their own while
# they still hold an ada-only output, and become token-only by rejecting what
# Bob books: Hank once, Iris in three rounds, Bob booking the same keys again
# each time, so her approvals end above quantity one.
# ------------------------------------------------------------------
orun iris-create success -- create --process-time 60000 --retract-time 20000 \
  --state-dir "$reg" --blueprint "$blueprint" "${node[@]}" "${iris[@]}"
iris_token="$(field iris-create .stateToken)"
[ -n "$iris_token" ] && [ "$iris_token" != null ] || fail "iris's create named no token"
iris_addr="$(field iris-create .wallet)"
iriskey="$(field iris-create .walletKeyHash)"
iris_retract_ms="$(jq -er .retractTime "$receipts/iris-create.json")"
iriscommon=(--state-dir "$reg" --blueprint "$blueprint" --state-token "$iris_token")
orun hank-create success -- create --process-time 60000 --retract-time 20000 \
  --state-dir "$reg" --blueprint "$blueprint" "${node[@]}" "${hank[@]}"
hank_token="$(field hank-create .stateToken)"
[ -n "$hank_token" ] && [ "$hank_token" != null ] || fail "hank's create named no token"
hank_addr="$(field hank-create .wallet)"
hankkey="$(field hank-create .walletKeyHash)"
hank_retract_ms="$(jq -er .retractTime "$receipts/hank-create.json")"
[ "$hank_retract_ms" = "$iris_retract_ms" ] \
  || fail "the two registries have different retract windows ($iris_retract_ms, $hank_retract_ms): one wait cannot cover both"
hankcommon=(--state-dir "$reg" --blueprint "$blueprint" --state-token "$hank_token")
say "iris made registry $iris_token and hank registry $hank_token"

# each makes a live key of their own while an ada-only output is still theirs
orun iris-insert-u success -- insert --key keyIrisU --payload "$work/payload-insert.json" \
  "${iriscommon[@]}" "${node[@]}" "${iris[@]}"
orun iris-fold-u success -- fold --request "$(field iris-insert-u .request)" \
  "${iriscommon[@]}" "${node[@]}" "${bob[@]}"
orun hank-insert-t success -- insert --key keyHankT --payload "$work/payload-insert.json" \
  "${hankcommon[@]}" "${node[@]}" "${hank[@]}"
orun hank-fold-t success -- fold --request "$(field hank-insert-t .request)" \
  "${hankcommon[@]}" "${node[@]}" "${bob[@]}"
say "iris and hank each hold a live key of their own"

# round one for both: Bob books, one wait covers both registries
orun iris-bob-a-1 success -- insert --key keyIrisA --payload "$work/payload-insert.json" \
  "${iriscommon[@]}" "${node[@]}" "${bob[@]}"
orun iris-bob-b-1 success -- insert --key keyIrisB --payload "$work/payload-insert.json" \
  "${iriscommon[@]}" "${node[@]}" "${bob[@]}"
orun hank-bob-a success -- insert --key keyHankA --payload "$work/payload-insert.json" \
  "${hankcommon[@]}" "${node[@]}" "${bob[@]}"
wait_for_windows "$iris_retract_ms" iris-bob-a-1 iris-bob-b-1 hank-bob-a
srun iris-reject-1 success -- registry reject "${iriscommon[@]}" "${node[@]}" "${iris[@]}"
srun hank-reject success -- registry reject "${hankcommon[@]}" "${node[@]}" "${hank[@]}"
say "round one: iris and hank rejected what bob booked"

# Iris, rounds two and three: the same keys, the same booker, the same
# destination: the same approvals, so each kind's quantity grows by one
orun iris-bob-a-2 success -- insert --key keyIrisA --payload "$work/payload-insert.json" \
  "${iriscommon[@]}" "${node[@]}" "${bob[@]}"
orun iris-bob-b-2 success -- insert --key keyIrisB --payload "$work/payload-insert.json" \
  "${iriscommon[@]}" "${node[@]}" "${bob[@]}"
wait_for_windows "$iris_retract_ms" iris-bob-a-2 iris-bob-b-2
srun iris-reject-2 success -- registry reject "${iriscommon[@]}" "${node[@]}" "${iris[@]}"
orun iris-bob-a-3 success -- insert --key keyIrisA --payload "$work/payload-insert.json" \
  "${iriscommon[@]}" "${node[@]}" "${bob[@]}"
wait_for_windows "$iris_retract_ms" iris-bob-a-3
srun iris-reject-3 success -- registry reject "${iriscommon[@]}" "${node[@]}" "${iris[@]}"
say "iris rejected three rounds"

# --- Hank: the termination of his own key from the rehearsal wallet
wallet_utxos "$hank_addr" "$work/hank-utxos.json" >"$work/hank-utxo-lines.txt"
[ "$(awk '$3 == 0 && $4 == "none"' "$work/hank-utxo-lines.txt" | wc -l)" -eq 0 ] \
  || fail "hank's wallet holds an ada-only output, expected none: $(cat "$work/hank-utxo-lines.txt")"
asset_totals "$hank_addr" "$work/hank-utxos.json" >"$work/hank-assets-before.json"
[ "$(jq -r length "$work/hank-assets-before.json")" -ge 1 ] \
  || fail "hank's wallet holds no approval: $(cat "$work/hank-utxo-lines.txt")"
say "hank's wallet is token-only: $(cat "$work/hank-assets-before.json")"
hank_state_before="$(state_digest "$reg")"
orun hank-terminate-preview success -- terminate --key keyHankT --preview --wallet-address "$hank_addr" \
  "${hankcommon[@]}" "${node[@]}"
prep_wellformed "hank terminate preview" "$receipts/hank-terminate-preview.json"
jq -e 'tostring | contains("send one self-payment") | not' "$receipts/hank-terminate-preview.json" >/dev/null \
  || fail "hank's terminate preview prints the self-payment instruction"
wallet_utxos "$hank_addr" "$work/hank-utxos-after-preview.json" >"$work/hank-utxo-after-preview-lines.txt"
[ "$(cat "$work/hank-utxo-after-preview-lines.txt")" = "$(cat "$work/hank-utxo-lines.txt")" ] \
  || fail "hank's outputs moved across his terminate preview"
[ "$(state_digest "$reg")" = "$hank_state_before" ] \
  || fail "the registry state changed across hank's terminate preview"
orun hank-terminate success -- terminate --key keyHankT \
  "${hankcommon[@]}" "${node[@]}" "${hank[@]}"
assert_preview_equals hank-terminate hank-terminate-preview
assert_through_preparation hank-terminate book booking "$hank_addr" \
  "$(managed_journal "$reg" "$hank_token" "$hankkey")"
wallet_utxos "$hank_addr" "$work/hank-utxos-after.json" >/dev/null
[ "$(asset_totals "$hank_addr" "$work/hank-utxos-after.json")" = "$(cat "$work/hank-assets-before.json")" ] \
  || fail "hank's approvals changed across his terminate: before $(cat "$work/hank-assets-before.json") after $(asset_totals "$hank_addr" "$work/hank-utxos-after.json")"
say "hank still holds his approvals in exact quantities after his terminate"
assert_refs_live "hank" "$receipts/hank-create.json"

# --- Iris: approval tokens above quantity one, then her update
wallet_utxos "$iris_addr" "$work/iris-utxos.json" >"$work/iris-utxo-lines.txt"
[ "$(awk '$3 == 0 && $4 == "none"' "$work/iris-utxo-lines.txt" | wc -l)" -eq 0 ] \
  || fail "iris's wallet holds an ada-only output, expected none: $(cat "$work/iris-utxo-lines.txt")"
asset_totals "$iris_addr" "$work/iris-utxos.json" >"$work/iris-assets-before.json"
# three kinds: the approval of her own live key's insert (one), and the approvals
# of Bob's two keys, each equal to the number of times Bob's booking of that key
# was rejected, so two kinds above quantity one and different. Every quantity is
# counted from the receipts of the commands that made it, not typed
iris_a_rounds="$(find "$receipts" -name 'iris-bob-a-*.json' | wc -l)"
iris_b_rounds="$(find "$receipts" -name 'iris-bob-b-*.json' | wc -l)"
iris_own_inserts="$(find "$receipts" -name 'iris-insert-u.json' | wc -l)"
iris_want="$(printf '%s\n%s\n%s\n' "$iris_a_rounds" "$iris_b_rounds" "$iris_own_inserts" | sort -n | jq -cs .)"
jq -e --argjson want "$iris_want" '
    length == 3
    and ([.[] | .q] | sort) == $want
    and ([.[] | select(.q > 1)] | length) == 2
    and ([.[] | select(.q > 1) | .q] | unique | length) == 2' "$work/iris-assets-before.json" >/dev/null \
  || fail "iris's approvals are not three kinds at the quantities $iris_want: $(cat "$work/iris-assets-before.json")"
say "iris's wallet holds two approval kinds above quantity one and her own insert's: $(cat "$work/iris-assets-before.json")"
iris_state_before="$(state_digest "$reg")"
orun iris-update-preview success -- update --key keyIrisU --payload "$work/payload-update.json" \
  --preview --wallet-address "$iris_addr" "${iriscommon[@]}" "${node[@]}"
prep_wellformed "iris update preview" "$receipts/iris-update-preview.json"
jq -e 'tostring | contains("send one self-payment") | not' "$receipts/iris-update-preview.json" >/dev/null \
  || fail "iris's update preview prints the self-payment instruction"
iris_outlay="$(jq -er .outlay.total "$receipts/iris-update-preview.json")"
iris_prep_fee="$(jq -er .preparation.fee "$receipts/iris-update-preview.json")"
wallet_utxos "$iris_addr" "$work/iris-utxos-after-preview.json" >"$work/iris-utxo-after-preview-lines.txt"
[ "$(cat "$work/iris-utxo-after-preview-lines.txt")" = "$(cat "$work/iris-utxo-lines.txt")" ] \
  || fail "iris's outputs moved across her update preview"
[ "$(state_digest "$reg")" = "$iris_state_before" ] \
  || fail "the registry state changed across iris's update preview"
say "iris's update preview plans $(field iris-update-preview .preparation.output) and submitted nothing"
# the allowance judges the update with its preparation fee, before signing
iris_whole=$((iris_outlay + iris_prep_fee))
for allowance in $((iris_whole - 1)) "$iris_outlay"; do
  orun "iris-update-allowance-$allowance" client-refusal -- update --key keyIrisU \
    --payload "$work/payload-update.json" --max-outlay "$allowance" \
    "${iriscommon[@]}" "${node[@]}" "${iris[@]}"
  [ "$(field "iris-update-allowance-$allowance" .reason)" = "the measured outlay of $iris_outlay lovelace with the preparation fee of $iris_prep_fee lovelace passes the approved allowance of $allowance (client policy); nothing was submitted" ] \
    || fail "iris's update past an allowance of $allowance was not refused with the exact text: $(cat "$receipts/iris-update-allowance-$allowance.json")"
  jq -e 'has("preparation") | not' "$receipts/iris-update-allowance-$allowance.json" >/dev/null \
    || fail "iris's refused update carries a preparation member"
  jq -e '.submissions | type == "array" and length == 0' "$receipts/iris-update-allowance-$allowance.json" >/dev/null \
    || fail "iris's refused update lacks an empty submissions array"
done
wallet_utxos "$iris_addr" "$work/iris-utxos-after-refusals.json" >"$work/iris-utxo-after-refusals-lines.txt"
[ "$(cat "$work/iris-utxo-after-refusals-lines.txt")" = "$(cat "$work/iris-utxo-lines.txt")" ] \
  || fail "iris's outputs moved across her refused updates"
[ "$(state_digest "$reg")" = "$iris_state_before" ] \
  || fail "the registry state changed across iris's refused updates"
say "iris's update past the whole outlay less one lovelace, and past the command's alone, was refused before signing"
orun iris-update success -- update --key keyIrisU --payload "$work/payload-update.json" \
  "${iriscommon[@]}" "${node[@]}" "${iris[@]}"
assert_preview_equals iris-update iris-update-preview
assert_through_preparation iris-update update update "$iris_addr" \
  "$(managed_journal "$reg" "$iris_token" "$iriskey")"
jq -e '.payload == {"int": 43}' "$receipts/iris-update.json" >/dev/null \
  || fail "iris's update receipt does not carry the new payload: $(jq -c .payload "$receipts/iris-update.json")"
wallet_utxos "$iris_addr" "$work/iris-utxos-after.json" >/dev/null
[ "$(asset_totals "$iris_addr" "$work/iris-utxos-after.json")" = "$(cat "$work/iris-assets-before.json")" ] \
  || fail "iris's approvals changed across her update: before $(cat "$work/iris-assets-before.json") after $(asset_totals "$iris_addr" "$work/iris-utxos-after.json")"
say "iris still holds her approvals in exact quantities after her update"
assert_refs_live "iris" "$receipts/iris-create.json"

# --- Bob's funded update makes no preparation
orun bob-insert-u success -- insert --key keyBobU --payload "$work/payload-insert.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
orun bob-fold-u success -- fold --request "$(field bob-insert-u .request)" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
orun bob-update success -- update --key keyBobU --payload "$work/payload-update.json" \
  "${common[@]}" "${node[@]}" "${bob[@]}"
jq -e 'has("preparation") | not' "$receipts/bob-update.json" >/dev/null \
  || fail "bob's funded update carries a preparation member: $(cat "$receipts/bob-update.json")"
bob_update_tx="$(field bob-update .update)"
subs_exact "bob's update" "$receipts/bob-update.json" \
  "$(jq -cn --arg u "$bob_update_tx" '[["update", $u]]')"
say "bob's funded update made no preparation"

say "prepare funding: PASS"
