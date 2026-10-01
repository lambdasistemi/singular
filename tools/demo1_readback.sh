#!/usr/bin/env bash
# Read a key's token output back from a public preprod indexer, starting from
# its policy id and asset name alone, and compare it with what the node read.
#
# usage: demo1_readback.sh --provider koios|blockfrost --policy HEX --name HEX
#          --inspect RECEIPT.json --out FILE
#          [--credential-file PATH] [--base-url URL] [--max-lag SLOTS]
#
# RECEIPT.json is the ordinary `singular registry inspect` receipt for the key:
# its chain point, its live output and the inline datum the ledger holds. The
# indexer is asked only for the asset. The output file records each request (the
# method and URL, never a credential), the complete response, the exact output
# the indexer says holds the asset (reference, address, block, time), its inline
# datum and that datum's hash recomputed here, the indexer's own tip and the
# node's chain point, the lag between them in slots, and each comparison. The exit
# status is 0 only when the indexer finds exactly one output holding exactly one of
# the asset, that output is the node's, its datum bytes and hash are the node's,
# and the indexer is no more than --max-lag slots behind the node.
#
# A provider that needs a key (blockfrost) reads it from --credential-file, a
# reference to a file the caller holds. The value is read into this process, handed
# to curl on standard input and never placed in an argument, the environment, the
# output or a log.
#
# Exit 0 holds; 1 a comparison or lookup failed; 2 a usage error; 3 the
# request could not be made (no credential, no network): never a verdict.
set -euo pipefail

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

provider="" policy="" name="" inspect="" out="" credfile="" base="" maxlag=600
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --provider) provider="$2" ;;
    --policy) policy="$2" ;;
    --name) name="$2" ;;
    --inspect) inspect="$2" ;;
    --out) out="$2" ;;
    --credential-file) credfile="$2" ;;
    --base-url) base="$2" ;;
    --max-lag) maxlag="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$provider" ] && [ -n "$policy" ] && [ -n "$name" ] && [ -n "$inspect" ] && [ -n "$out" ] || usage
[[ "$policy" =~ ^[0-9a-f]{56}$ ]] || {
  echo "readback: --policy is not a 28-byte hex policy id" >&2
  exit 2
}
[[ "$name" =~ ^([0-9a-f]{2}){0,32}$ ]] || {
  echo "readback: --name is not hex of at most 32 bytes" >&2
  exit 2
}
[[ "$maxlag" =~ ^[0-9]+$ ]] || {
  echo "readback: --max-lag is not a number of slots" >&2
  exit 2
}
[ -f "$inspect" ] || {
  echo "readback: no inspect receipt at $inspect" >&2
  exit 2
}
case "$provider" in
  koios) base="${base:-https://preprod.koios.rest/api/v1}" ;;
  blockfrost) base="${base:-https://cardano-preprod.blockfrost.io/api/v0}" ;;
  *) usage ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
: >"$tmp/requests.ndjson"

key=""
if [ "$provider" = blockfrost ]; then
  [ -n "$credfile" ] && [ -r "$credfile" ] || {
    echo "readback: blockfrost needs --credential-file, a reference to the file holding its project key; none was given or readable" >&2
    exit 3
  }
  key="$(tr -d '\n\r ' <"$credfile")"
  [ -n "$key" ] || {
    echo "readback: the credential file is empty" >&2
    exit 3
  }
fi

# call METHOD PATH [BODY]: one request; the response is kept whole beside its
# request. A credential travels on standard input as curl configuration.
call() {
  local method="$1" path="$2" body="${3:-}" resp="$tmp/resp.$RANDOM" status
  local args=(--silent --show-error --max-time 60 --write-out '%{http_code}' --output "$resp" --request "$method" "$base$path")
  [ -z "$body" ] || args+=(--header 'content-type: application/json' --data "$body")
  if [ -n "$key" ]; then
    status="$(printf 'header = "project_id: %s"\n' "$key" | curl --config - "${args[@]}")" || return 3
  else
    status="$(curl "${args[@]}")" || return 3
  fi
  jq -c -n --arg m "$method" --arg u "$base$path" --arg b "$body" --argjson s "$status" --slurpfile r "$resp" \
    '{method: $m, url: $u, body: (if $b == "" then null else ($b | fromjson) end), status: $s, response: $r[0]}' >>"$tmp/requests.ndjson" 2>/dev/null \
    || jq -c -n --arg m "$method" --arg u "$base$path" --argjson s "$status" \
      '{method: $m, url: $u, status: $s, response: "not JSON"}' >>"$tmp/requests.ndjson"
  [ "$status" = 200 ] || return 1
  cat "$resp"
}

fail() {
  echo "readback: FAIL: $*" >&2
  finish false "$*"
  exit 1
}

# What the node read, from the inspect receipt.
node_output="$(jq -r '.applicationOutput.output // empty' "$inspect")"
node_cbor="$(jq -r '.applicationOutput.datumCbor // empty' "$inspect")"
node_hash="$(jq -r '.applicationOutput.datumHash // empty' "$inspect")"
node_point="$(jq -r '.chainPoint // empty' "$inspect")"
node_slot="${node_point%%.*}"
[ -n "$node_output" ] && [ -n "$node_cbor" ] && [ -n "$node_hash" ] && [[ "$node_slot" =~ ^[0-9]+$ ]] \
  || {
    echo "readback: the inspect receipt carries no live output, datum and chain point to compare with" >&2
    exit 2
  }

unit="$policy$name"
tip_json="" resp="" latest="" holders="" tx="" given_hash="" utxo="" address="" block_height="" block_time="" cbor="" dhash="" tip_slot="" tip_time="" qty=""

finish() {
  local holds="$1" why="${2:-}"
  jq -n \
    --arg provider "$provider" --arg policy "$policy" --arg name "$name" --arg base "$base" \
    --slurpfile requests "$tmp/requests.ndjson" --arg holds "$holds" --arg why "$why" \
    --arg nodeOutput "$node_output" --arg nodeCbor "$node_cbor" --arg nodeHash "$node_hash" \
    --arg nodePoint "$node_point" --arg nodeSlot "$node_slot" \
    --arg utxo "$utxo" --arg address "$address" --arg blockHeight "$block_height" --arg blockTime "$block_time" \
    --arg cbor "$cbor" --arg dhash "$dhash" --arg tipSlot "$tip_slot" --arg tipTime "$tip_time" --arg maxLag "$maxlag" \
    '{
       provider: $provider, policy: $policy, assetName: $name, baseUrl: $base,
       credential: (if $provider == "blockfrost" then "read from the named credential file; never recorded" else "none needed" end),
       requests: $requests,
       indexer: {output: $utxo, address: $address, blockHeight: $blockHeight, blockTime: $blockTime,
                 datumCbor: $cbor, datumHashRecomputed: $dhash, tipSlot: $tipSlot, tipTime: $tipTime},
       node: {output: $nodeOutput, datumCbor: $nodeCbor, datumHash: $nodeHash, chainPoint: $nodePoint},
       lagSlots: (if ($tipSlot | length) > 0 then (($nodeSlot | tonumber) - ($tipSlot | tonumber)) else null end),
       maxLagSlots: ($maxLag | tonumber),
       comparisons: {
         sameOutput: ($utxo == $nodeOutput),
         sameDatumBytes: ($cbor == $nodeCbor and ($cbor | length) > 0),
         sameDatumHash: ($dhash == $nodeHash and ($dhash | length) > 0),
         withinLag: (($tipSlot | length) > 0 and ((($nodeSlot | tonumber) - ($tipSlot | tonumber)) <= ($maxLag | tonumber)))
       },
       holds: ($holds == "true"), reason: (if $why == "" then null else $why end)
     }' >"$out"
}

# blake2b256 of hex bytes, independently of the indexer.
blake() { printf '%s' "$1" | xxd -r -p | b2sum -l 256 | cut -d' ' -f1; }

# fetch VAR METHOD PATH [BODY]: VAR holds the response; a request that could
# not be made ends the run as setup (3), one answered otherwise than 200 as a
# failed lookup (1).
fetch() {
  local var="$1" got rc=0
  got="$(call "${@:2}")" || rc=$?
  case "$rc" in
    0) printf -v "$var" '%s' "$got" ;;
    3)
      echo "readback: the indexer could not be reached" >&2
      exit 3
      ;;
    *) fail "$2 $3 did not answer 200" ;;
  esac
}

if [ "$provider" = koios ]; then
  fetch tip_json GET /tip
  tip_slot="$(jq -r '.[0].abs_slot' <<<"$tip_json")"
  tip_time="$(jq -r '.[0].block_time' <<<"$tip_json")"
  fetch resp POST /asset_utxos "$(jq -cn --arg p "$policy" --arg n "$name" '{_asset_list: [[$p, $n]], _extended: true}')"
  count="$(jq 'length' <<<"$resp")"
  [ "$count" = 1 ] || fail "the indexer finds $count outputs holding the asset; exactly one must"
  utxo="$(jq -r '.[0].tx_hash + "#" + (.[0].tx_index | tostring)' <<<"$resp")"
  address="$(jq -r '.[0].address' <<<"$resp")"
  block_height="$(jq -r '.[0].block_height' <<<"$resp")"
  block_time="$(jq -r '.[0].block_time' <<<"$resp")"
  cbor="$(jq -r '.[0].inline_datum.bytes // empty' <<<"$resp")"
  given_hash="$(jq -r '.[0].datum_hash // empty' <<<"$resp")"
  qty="$(jq -r --arg p "$policy" --arg n "$name" '[.[0].asset_list[] | select(.policy_id == $p and .asset_name == $n) | .quantity | tonumber] | add // 0' <<<"$resp")"
else
  fetch latest GET /blocks/latest
  tip_slot="$(jq -r '.slot' <<<"$latest")"
  tip_time="$(jq -r '.time' <<<"$latest")"
  fetch holders GET "/assets/$unit/addresses"
  [ "$(jq 'length' <<<"$holders")" = 1 ] || fail "the indexer finds $(jq 'length' <<<"$holders") addresses holding the asset; exactly one must"
  address="$(jq -r '.[0].address' <<<"$holders")"
  fetch resp GET "/addresses/$address/utxos/$unit"
  count="$(jq 'length' <<<"$resp")"
  [ "$count" = 1 ] || fail "the indexer finds $count outputs holding the asset at its address; exactly one must"
  utxo="$(jq -r '.[0].tx_hash + "#" + ((.[0].tx_index // .[0].output_index) | tostring)' <<<"$resp")"
  cbor="$(jq -r '.[0].inline_datum // empty' <<<"$resp")"
  given_hash="$(jq -r '.[0].data_hash // empty' <<<"$resp")"
  qty="$(jq -r --arg u "$unit" '[.[0].amount[] | select(.unit == $u) | .quantity | tonumber] | add // 0' <<<"$resp")"
  fetch tx GET "/txs/$(jq -r '.[0].tx_hash' <<<"$resp")"
  block_height="$(jq -r '.block_height' <<<"$tx")"
  block_time="$(jq -r '.block_time' <<<"$tx")"
fi

[ "$qty" = 1 ] || fail "the output holds $qty of the asset; exactly one must"
[ -n "$cbor" ] || fail "the indexer returns no inline datum for the output"
dhash="$(blake "$cbor")"
[ "$dhash" = "$given_hash" ] || fail "the indexer's datum hash $given_hash is not the hash of the datum it returns ($dhash)"
[ "$utxo" = "$node_output" ] || fail "the indexer's output $utxo is not the node's $node_output"
[ "$cbor" = "$node_cbor" ] || fail "the indexer's datum bytes are not the node's"
[ "$dhash" = "$node_hash" ] || fail "the indexer's datum hash is not the node's"
lag=$((node_slot - tip_slot))
[ "$lag" -le "$maxlag" ] || fail "the indexer is $lag slots behind the node, beyond the $maxlag allowed"
finish true
echo "readback: PASS — $provider finds $utxo holding the asset, datum $dhash, $lag slots behind the node ($out)"
