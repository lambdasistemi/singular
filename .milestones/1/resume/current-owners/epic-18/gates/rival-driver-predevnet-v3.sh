#!/usr/bin/env bash
set -euo pipefail

if test "$#" -ne 4; then
  echo 'PREDEVNET RED: usage: rival-driver-predevnet-v3.sh SRC_ROOT LEDGER_COMMAND ABSOLUTE_PYTHON3 NEW_RECEIPT_DIR' >&2
  exit 2
fi

src_root=$1
ledger_command=$2
python3_bin=$3
receipt_dir=$4

case "$python3_bin" in
  /*) ;;
  *) echo 'PREDEVNET RED: JSON parser must be an explicit absolute python3 path' >&2; exit 2 ;;
esac
test -x "$python3_bin" || {
  echo "PREDEVNET RED: declared JSON parser is not executable: $python3_bin" >&2
  exit 2
}
test ! -e "$receipt_dir" || {
  echo "PREDEVNET RED: receipt directory already exists: $receipt_dir" >&2
  exit 2
}
mkdir -p "$receipt_dir"

offchain="$src_root/offchain"
driver="$offchain/journey/retirement/Main.hs"
logic="$offchain/journey/retirement/RivalDriverLogic.hs"
check_src="$offchain/journey/retirement/RivalDriverPredevnetCheck.hs"
cabal_file="$offchain/cardano-mpfs-cage.cabal"

for required in "$driver" "$logic" "$check_src" "$cabal_file" "$ledger_command"; do
  test -f "$required" || { echo "PREDEVNET RED: missing $required" >&2; exit 1; }
done
test -x "$ledger_command" || {
  echo "PREDEVNET RED: later ledger command is not executable: $ledger_command" >&2; exit 1; }
bash -n "$ledger_command" >"$receipt_dir/ledger-command-bash-n.stdout" \
  2>"$receipt_dir/ledger-command-bash-n.stderr" || {
  echo 'PREDEVNET RED: later ledger command is not bash syntax clean' >&2; exit 1; }

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

"$python3_bin" --version >"$receipt_dir/python3-version.stdout" \
  2>"$receipt_dir/python3-version.stderr" || {
  echo 'PREDEVNET RED: declared JSON parser could not execute' >&2; exit 1; }
sha256sum "$python3_bin" >"$receipt_dir/python3-sha256.txt"

(
  cd "$offchain"
  nix develop --command cabal build exe:retirement-rows exe:rival-driver-predevnet-check -O0
) >"$receipt_dir/build.stdout" 2>"$receipt_dir/build.stderr" || {
  tail -n 40 "$receipt_dir/build.stderr" >&2
  tail -n 40 "$receipt_dir/build.stdout" >&2
  echo 'PREDEVNET RED: real driver/offline check build failed' >&2
  exit 1
}

(
  cd "$offchain"
  nix develop --command cabal list-bin exe:retirement-rows -O0
) >"$receipt_dir/driver-list-bin.stdout" 2>"$receipt_dir/driver-list-bin.stderr" || {
  echo 'PREDEVNET RED: could not resolve -O0 driver binary' >&2; exit 1; }
(
  cd "$offchain"
  nix develop --command cabal list-bin exe:rival-driver-predevnet-check -O0
) >"$receipt_dir/check-list-bin.stdout" 2>"$receipt_dir/check-list-bin.stderr" || {
  echo 'PREDEVNET RED: could not resolve -O0 check binary' >&2; exit 1; }

driver_bin=$(tail -n 1 "$receipt_dir/driver-list-bin.stdout")
check_bin=$(tail -n 1 "$receipt_dir/check-list-bin.stdout")
test -x "$driver_bin" || { echo "PREDEVNET RED: -O0 driver binary not executable: $driver_bin" >&2; exit 1; }
test -x "$check_bin" || { echo "PREDEVNET RED: -O0 check binary not executable: $check_bin" >&2; exit 1; }
case "$driver_bin" in
  "$offchain"/dist-newstyle/*) ;;
  *) echo "PREDEVNET RED: driver binary escaped the declared build tree: $driver_bin" >&2; exit 1 ;;
esac
case "$check_bin" in
  "$offchain"/dist-newstyle/*) ;;
  *) echo "PREDEVNET RED: check binary escaped the declared build tree: $check_bin" >&2; exit 1 ;;
esac

for offline_value in absent 0; do
  set +e
  if test "$offline_value" = absent; then
    env -u RIVAL_OFFLINE_ONLY CARDANO_NODE_SOCKET_PATH=/definitely-not-present/rival-predevnet.socket \
      "$check_bin" >"$receipt_dir/refusal-$offline_value.stdout" \
      2>"$receipt_dir/refusal-$offline_value.stderr"
  else
    RIVAL_OFFLINE_ONLY="$offline_value" CARDANO_NODE_SOCKET_PATH=/definitely-not-present/rival-predevnet.socket \
      "$check_bin" >"$receipt_dir/refusal-$offline_value.stdout" \
      2>"$receipt_dir/refusal-$offline_value.stderr"
  fi
  refusal_rc=$?
  set -e
  printf '%s\n' "$refusal_rc" >"$receipt_dir/refusal-$offline_value.exit"
  test "$refusal_rc" -ne 0 || {
    echo "PREDEVNET RED: offline check accepted RIVAL_OFFLINE_ONLY=$offline_value" >&2; exit 1; }
  rg -Fxq 'RIVAL_OFFLINE_ONLY=1 required' "$receipt_dir/refusal-$offline_value.stderr" || {
    echo "PREDEVNET RED: offline-mode refusal marker absent for $offline_value" >&2; exit 1; }
done

set +e
RIVAL_OFFLINE_ONLY=1 CARDANO_NODE_SOCKET_PATH=/definitely-not-present/rival-predevnet.socket \
  "$check_bin" >"$receipt_dir/result.json" 2>"$receipt_dir/result.stderr"
result_rc=$?
set -e
printf '%s\n' "$result_rc" >"$receipt_dir/result.exit"
test "$result_rc" -eq 0 || {
  echo "PREDEVNET RED: offline check exited $result_rc" >&2; exit 1; }

set +e
"$python3_bin" - "$receipt_dir/result.json" \
  >"$receipt_dir/json-validation.stdout" 2>"$receipt_dir/json-validation.stderr" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
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
    if not isinstance(rows, list):
        raise SystemExit("PREDEVNET RED: result denominator is not an array")
    result = {}
    for row in rows:
        if not isinstance(row, dict):
            raise SystemExit("PREDEVNET RED: result row is not an object")
        ident = row.get("id")
        if not isinstance(ident, str) or ident in result:
            raise SystemExit(f"PREDEVNET RED: missing/duplicate id {ident!r}")
        if row.get(verdict) is not True:
            raise SystemExit(f"PREDEVNET RED: {ident} did not set {verdict}=true")
        result[ident] = row
    return result

cases = indexed(doc.get("cases"), "passed")
mutants = indexed(doc.get("mutants"), "rejected")
if set(cases) != required_cases:
    raise SystemExit(f"PREDEVNET RED: case denominator differs missing={sorted(required_cases-set(cases))} extra={sorted(set(cases)-required_cases)}")
if set(mutants) != required_mutants:
    raise SystemExit(f"PREDEVNET RED: mutant denominator differs missing={sorted(required_mutants-set(mutants))} extra={sorted(set(mutants)-required_mutants)}")
print(f"PREDEVNET CASES PASS: {len(cases)}/{len(required_cases)}")
print(f"PREDEVNET MUTANTS REJECTED: {len(mutants)}/{len(required_mutants)}")
PY
validation_rc=$?
set -e
printf '%s\n' "$validation_rc" >"$receipt_dir/json-validation.exit"
test "$validation_rc" -eq 0 || {
  cat "$receipt_dir/json-validation.stderr" >&2
  echo 'PREDEVNET RED: JSON validation failed' >&2
  exit 1
}

{
  printf 'gate_sha256=%s\n' "$(sha256sum "$0" | cut -d' ' -f1)"
  printf 'driver_source_sha256=%s\n' "$(sha256sum "$driver" | cut -d' ' -f1)"
  printf 'logic_sha256=%s\n' "$(sha256sum "$logic" | cut -d' ' -f1)"
  printf 'check_source_sha256=%s\n' "$(sha256sum "$check_src" | cut -d' ' -f1)"
  printf 'cabal_sha256=%s\n' "$(sha256sum "$cabal_file" | cut -d' ' -f1)"
  printf 'driver_binary=%s\n' "$driver_bin"
  printf 'driver_binary_sha256=%s\n' "$(sha256sum "$driver_bin" | cut -d' ' -f1)"
  printf 'check_binary=%s\n' "$check_bin"
  printf 'check_binary_sha256=%s\n' "$(sha256sum "$check_bin" | cut -d' ' -f1)"
  printf 'python3=%s\n' "$python3_bin"
  printf 'python3_sha256=%s\n' "$(sha256sum "$python3_bin" | cut -d' ' -f1)"
  printf 'result_sha256=%s\n' "$(sha256sum "$receipt_dir/result.json" | cut -d' ' -f1)"
  printf 'ledger_command_sha256=%s\n' "$(sha256sum "$ledger_command" | cut -d' ' -f1)"
} >"$receipt_dir/identities.txt"

cat "$receipt_dir/json-validation.stdout"
cat "$receipt_dir/identities.txt"
printf 'receipt_dir=%s\n' "$receipt_dir"
printf 'PREDEVNET GREEN: offline driver logic only; devnet fence remains\n'
