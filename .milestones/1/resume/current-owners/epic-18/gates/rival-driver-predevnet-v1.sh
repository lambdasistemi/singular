#!/usr/bin/env bash
set -euo pipefail

src_root=${1:-/tmp/t80e-rival-witness}
ledger_command=${2:-/tmp/t80e-rival-witness/handoffs/rival-ledger-command.sh}
offchain="$src_root/offchain"
driver="$offchain/journey/retirement/Main.hs"
logic="$offchain/journey/retirement/RivalDriverLogic.hs"
check_src="$offchain/journey/retirement/RivalDriverPredevnetCheck.hs"
cabal_file="$offchain/cardano-mpfs-cage.cabal"

for required in "$driver" "$logic" "$check_src" "$cabal_file" "$ledger_command"; do
  test -f "$required" || { echo "PREDEVNET RED: missing $required" >&2; exit 1; }
done

for fn in planMode selectAnchor checkRefusalLiveness checkCopiedSuccessor selectLiveFunding; do
  rg -q "^[[:space:]]*$fn[[:space:]]" "$logic" || {
    echo "PREDEVNET RED: shared logic does not define $fn" >&2; exit 1; }
  rg -q "RivalDriverLogic\.$fn|[^[:alnum:]_]$fn[[:space:]]" "$driver" || {
    echo "PREDEVNET RED: driver does not call shared $fn" >&2; exit 1; }
  rg -q "RivalDriverLogic\.$fn|[^[:alnum:]_]$fn[[:space:]]" "$check_src" || {
    echo "PREDEVNET RED: offline check does not call shared $fn" >&2; exit 1; }
done

rg -q '^import .*RivalDriverLogic' "$driver" || {
  echo 'PREDEVNET RED: driver does not import shared RivalDriverLogic' >&2; exit 1; }
rg -q '^import .*RivalDriverLogic' "$check_src" || {
  echo 'PREDEVNET RED: check does not import shared RivalDriverLogic' >&2; exit 1; }
rg -q '^executable rival-driver-predevnet-check$' "$cabal_file" || {
  echo 'PREDEVNET RED: offline executable is not declared' >&2; exit 1; }

json_out=$(mktemp)
build_out=$(mktemp)
trap 'rm -f "$json_out" "$build_out"' EXIT

(
  cd "$offchain"
  nix develop --command cabal build exe:rival-driver-predevnet-check -O0
) >"$build_out" 2>&1 || {
  tail -n 40 "$build_out" >&2
  echo 'PREDEVNET RED: offline check build failed' >&2
  exit 1
}

check_bin=$(
  cd "$offchain"
  nix develop --command cabal list-bin exe:rival-driver-predevnet-check
)
test -x "$check_bin" || { echo "PREDEVNET RED: check binary not executable: $check_bin" >&2; exit 1; }

RIVAL_OFFLINE_ONLY=1 CARDANO_NODE_SOCKET_PATH=/definitely-not-present/rival-predevnet.socket \
  "$check_bin" >"$json_out"

python3 - "$json_out" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    doc = json.load(handle)

required_cases = {
    "normal-single-path", "own-terminal-no-fallthrough",
    "copied-terminal-no-fallthrough", "forged-terminal-no-fallthrough",
    "forged-no-rivalctx-reaches-submit", "own-authentic-anchor",
    "copied-authentic-anchor", "refusal-both-inputs-live",
    "refusal-record-missing", "refusal-anchor-missing", "successor-exact",
    "successor-wrong-policy", "successor-wrong-token",
    "successor-wrong-quantity", "successor-a-token-present",
    "successor-wrong-txid", "successor-wrong-address",
    "successor-wrong-root", "successor-old-anchor-live",
    "funding-live-clean", "funding-stale-input", "funding-consumed-b-seed",
}
required_mutants = {
    "drop-terminal-separation", "ignore-record-liveness",
    "ignore-anchor-liveness", "ignore-successor-identity",
    "accept-stale-funding",
}

if doc.get("schema") != "rival-driver-predevnet-v1" or doc.get("offline") is not True:
    raise SystemExit("PREDEVNET RED: wrong schema or offline marker")

def indexed(rows, verdict):
    result = {}
    for row in rows:
        ident = row.get("id")
        if not isinstance(ident, str) or ident in result:
            raise SystemExit(f"PREDEVNET RED: missing/duplicate id {ident!r}")
        if row.get(verdict) is not True:
            raise SystemExit(f"PREDEVNET RED: {ident} did not set {verdict}=true")
        result[ident] = row
    return result

cases = indexed(doc.get("cases", []), "passed")
mutants = indexed(doc.get("mutants", []), "rejected")
if set(cases) != required_cases:
    raise SystemExit(f"PREDEVNET RED: case denominator differs missing={sorted(required_cases-set(cases))} extra={sorted(set(cases)-required_cases)}")
if set(mutants) != required_mutants:
    raise SystemExit(f"PREDEVNET RED: mutant denominator differs missing={sorted(required_mutants-set(mutants))} extra={sorted(set(mutants)-required_mutants)}")
print(f"PREDEVNET CASES PASS: {len(cases)}/{len(required_cases)}")
print(f"PREDEVNET MUTANTS REJECTED: {len(mutants)}/{len(required_mutants)}")
PY

printf 'driver_sha256=%s\n' "$(sha256sum "$driver" | cut -d' ' -f1)"
printf 'logic_sha256=%s\n' "$(sha256sum "$logic" | cut -d' ' -f1)"
printf 'check_source_sha256=%s\n' "$(sha256sum "$check_src" | cut -d' ' -f1)"
printf 'cabal_sha256=%s\n' "$(sha256sum "$cabal_file" | cut -d' ' -f1)"
printf 'check_binary_sha256=%s\n' "$(sha256sum "$check_bin" | cut -d' ' -f1)"
printf 'result_sha256=%s\n' "$(sha256sum "$json_out" | cut -d' ' -f1)"
printf 'ledger_command_sha256=%s\n' "$(sha256sum "$ledger_command" | cut -d' ' -f1)"
printf 'PREDEVNET GREEN: offline driver logic only; devnet fence remains\n'
