#!/usr/bin/env bash
# The public-indexer readback (demo1_readback.sh), against a local indexer that
# answers with the shapes the public services return.
#
# usage: demo1_readback_check.sh READBACK_SCRIPT
#
# One honest answer per provider must hold. Each alteration a reviewer cares
# about must fail for its own reason, never the honest answer's: another
# output, another datum (with its hash left alone, then with its hash
# recomputed), an indexer behind the node, no output, two outputs, two of the
# asset, an unreachable indexer and, for blockfrost, no credential. The
# credential is a marked value in a file: the indexer must have received it,
# and no output, standard output or standard error may contain it. That search
# is shown able to find it, in the indexer's own log of what it received.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 READBACK_SCRIPT" >&2
  exit 2
}
readback="$1"
work="$(mktemp -d)"
server_pid=""
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$work"' EXIT
fail() {
  echo "readback-check: FAIL: $*" >&2
  exit 1
}
say() { echo "readback-check: $*"; }

policy="$(printf 'ab%.0s' $(seq 1 28))"
name="64656d6f"
unit="$policy$name"
cbor="d8799f4164ff"
blake() { printf '%s' "$1" | xxd -r -p | b2sum -l 256 | cut -d' ' -f1; }
hash="$(blake "$cbor")"
other_cbor="d8799f4165ff"
other_hash="$(blake "$other_cbor")"
tx="$(printf '3c%.0s' $(seq 1 32))"
address="addr_test1wqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"
node_slot=135000000

mkdir -p "$work/fx"
# The inspect receipt an ordinary `singular registry inspect` prints, in the
# fields the readback compares.
jq -n --arg tx "$tx" --arg cbor "$cbor" --arg hash "$hash" --arg slot "$node_slot" \
  '{command: "inspect", outcome: "success", leaf: "active", chainPoint: ($slot + ".aa"),
    applicationOutput: {output: ($tx + "#0"), datumCbor: $cbor, datumHash: $hash}}' >"$work/inspect.json"

# answers KIND VARIANT: write the indexer's answers into $work/fx.
koios_answers() {
  local variant="$1" tip_slot="$node_slot" txin="$tx" bytes="$cbor" given="$hash" qty=1 n=1
  case "$variant" in
    behind) tip_slot=$((node_slot - 10000)) ;;
    other-output) txin="$(printf '4d%.0s' $(seq 1 32))" ;;
    datum-hash-left) bytes="$other_cbor" ;;
    datum-changed)
      bytes="$other_cbor"
      given="$other_hash"
      ;;
    none) n=0 ;;
    two) n=2 ;;
    two-of-asset) qty=2 ;;
    honest) ;;
  esac
  jq -n --argjson s "$tip_slot" '[{hash: "aa", epoch_no: 316, abs_slot: $s, block_height: 5238460, block_time: 1790796096}]' >"$work/fx/tip"
  jq -n --arg tx "$txin" --arg b "$bytes" --arg h "$given" --arg p "$policy" --arg n "$name" --argjson q "$qty" --argjson count "$n" --arg a "$address" \
    '[range(0; $count) | {tx_hash: $tx, tx_index: 0, address: $a, value: "2000000", block_height: 5179950, block_time: 1789478771,
      datum_hash: $h, inline_datum: {bytes: $b, value: {}},
      asset_list: [{policy_id: $p, asset_name: $n, quantity: ($q | tostring)}]}]' >"$work/fx/asset_utxos"
}
blockfrost_answers() {
  local variant="$1" tip_slot="$node_slot" txin="$tx" bytes="$cbor" given="$hash" qty=1
  case "$variant" in
    behind) tip_slot=$((node_slot - 10000)) ;;
    other-output) txin="$(printf '4d%.0s' $(seq 1 32))" ;;
    datum-changed)
      bytes="$other_cbor"
      given="$other_hash"
      ;;
    honest) ;;
  esac
  jq -n --argjson s "$tip_slot" '{time: 1790796096, height: 5238460, hash: "aa", slot: $s}' >"$work/fx/blocks_latest"
  jq -n --arg a "$address" '[{address: $a, quantity: "1"}]' >"$work/fx/assets_addresses"
  jq -n --arg tx "$txin" --arg b "$bytes" --arg h "$given" --arg u "$unit" --argjson q "$qty" --arg a "$address" \
    '[{address: $a, tx_hash: $tx, tx_index: 0, amount: [{unit: "lovelace", quantity: "2000000"}, {unit: $u, quantity: ($q | tostring)}],
      block: "bb", data_hash: $h, inline_datum: $b, reference_script_hash: null}]' >"$work/fx/addresses_utxos"
  jq -n '{hash: "t", block: "bb", block_height: 5179950, block_time: 1789478771, slot: 100}' >"$work/fx/txs"
}

# The local indexer: maps each path the readback may ask to one file, and logs
# the project key of every request it receives.
cat >"$work/server.py" <<'PY'
import http.server, os, sys
fx, log, portfile = sys.argv[1:4]
routes = {"/tip": "tip", "/asset_utxos": "asset_utxos", "/blocks/latest": "blocks_latest"}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_any(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        key = self.headers.get("project_id")
        with open(log, "a") as f:
            f.write("%s %s project_id=%s\n" % (self.command, self.path, key))
        path = self.path
        if path.startswith("/assets/") and path.endswith("/addresses"): name = "assets_addresses"
        elif path.startswith("/addresses/") and "/utxos/" in path: name = "addresses_utxos"
        elif path.startswith("/txs/"): name = "txs"
        else: name = routes.get(path)
        f = os.path.join(fx, name) if name else None
        if not f or not os.path.exists(f):
            self.send_response(404); self.end_headers(); return
        body = open(f, "rb").read()
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = do_any
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
PY
python3 "$work/server.py" "$work/fx" "$work/received.log" "$work/port" &
server_pid=$!
for _ in $(seq 1 50); do
  [ -s "$work/port" ] && break
  sleep 0.1
done
[ -s "$work/port" ] || fail "the local indexer never started"
base="http://127.0.0.1:$(cat "$work/port")"

marker="CRED-$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$marker" >"$work/credential"

run() { # run PROVIDER EXPECTED_STATUS OUTNAME [extra args]: status and outputs kept
  local provider="$1" want="$2" outname="$3" got=0
  shift 3
  bash "$readback" --provider "$provider" --policy "$policy" --name "$name" \
    --inspect "$work/inspect.json" --out "$work/$outname.json" --base-url "$base" "$@" \
    >"$work/$outname.stdout" 2>"$work/$outname.stderr" || got=$?
  [ "$got" -eq "$want" ] || {
    cat "$work/$outname.stderr" >&2
    fail "$provider $outname: exit $got, expected $want"
  }
}
# expect_reason OUTNAME TEXT: the failure names TEXT, and only a failing run gets here.
expect_reason() {
  grep -qF "$2" "$work/$1.stderr" || {
    cat "$work/$1.stderr" >&2
    fail "$1 did not fail for: $2"
  }
  jq -e '.holds == false' "$work/$1.json" >/dev/null || fail "$1 wrote no failing record"
}

for provider in koios blockfrost; do
  extra=()
  [ "$provider" = blockfrost ] && extra=(--credential-file "$work/credential")
  "${provider}_answers" honest
  run "$provider" 0 "$provider-honest" "${extra[@]}"
  jq -e '.holds == true and .comparisons.sameOutput and .comparisons.sameDatumBytes and .comparisons.sameDatumHash and .comparisons.withinLag and .lagSlots == 0' \
    "$work/$provider-honest.json" >/dev/null || fail "$provider: the honest record does not hold every comparison"
  "${provider}_answers" other-output
  run "$provider" 1 "$provider-other-output" "${extra[@]}"
  expect_reason "$provider-other-output" "is not the node's"
  "${provider}_answers" datum-changed
  run "$provider" 1 "$provider-datum-changed" "${extra[@]}"
  expect_reason "$provider-datum-changed" "datum bytes are not the node's"
  "${provider}_answers" behind
  run "$provider" 1 "$provider-behind" "${extra[@]}"
  expect_reason "$provider-behind" "slots behind the node"
  say "$provider: the honest answer holds; another output, another datum and a lagging indexer each fail for their own reason"
done

# Koios shapes with no blockfrost counterpart.
koios_answers datum-hash-left
run koios 1 koios-hash-left
expect_reason koios-hash-left "is not the hash of the datum it returns"
koios_answers none
run koios 1 koios-none
expect_reason koios-none "finds 0 outputs"
koios_answers two
run koios 1 koios-two
expect_reason koios-two "finds 2 outputs"
koios_answers two-of-asset
run koios 1 koios-two-of-asset
expect_reason koios-two-of-asset "holds 2 of the asset"
say "koios: a datum whose hash is left alone, no output, two outputs and two of the asset each fail for their own reason"

# A setup failure is never a verdict.
run koios 3 unreachable --base-url "http://127.0.0.1:1"
run blockfrost 3 no-credential
grep -qF "needs --credential-file" "$work/no-credential.stderr" || fail "no-credential did not say why"
[ ! -e "$work/no-credential.json" ] || fail "a setup failure wrote a verdict"
say "an unreachable indexer and a missing credential are setup failures (exit 3), never a verdict"

# The credential: received by the indexer, found nowhere the reader may look.
grep -qF "project_id=$marker" "$work/received.log" || fail "control: the indexer never received the credential, so a search proves nothing"
leaks=0
for f in "$work"/*.json "$work"/*.stdout "$work"/*.stderr; do
  case "$f" in "$work/inspect.json") continue ;; esac
  if grep -qF "$marker" "$f"; then
    leaks=$((leaks + 1))
    echo "readback-check: credential found in $f" >&2
  fi
done
[ "$leaks" -eq 0 ] || fail "the credential appears in $leaks outputs"
# the search can fire: the indexer's own log holds it
grep -rqF "$marker" "$work/received.log" || fail "control: the leak search cannot find the credential where it is"
say "the credential reached the indexer and appears in no output, standard output or standard error; the search finds it in the indexer's log"
echo "readback-check: PASS"
