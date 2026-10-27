#!/usr/bin/env bash
# Recovery receipts stay under 50 MiB (52428800 bytes). The evidence file
# holds the original command records. A receipts directory over that cap
# fails the check; a directory exactly at it passes.
#
# usage: cli_recovery_receipt_cap.test.sh RECOVERY-SCRIPT
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 RECOVERY-SCRIPT" >&2
  exit 2
}
script="$1"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cli-recovery-receipt-cap.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "cli-recovery-receipt-cap.test: FAIL: $*" >&2
  exit 1
}

over="$scratch/over"
mkdir -p "$over"
dd if=/dev/zero of="$over/blob" bs=1048576 count=51 status=none
status=0
bash "$script" --receipt-cap "$over" >"$scratch/over.out" 2>"$scratch/over.err" || status=$?
[ "$status" -eq 1 ] || fail "a directory over the cap exited $status, expected 1: $(cat "$scratch/over.err")"
[[ "$(cat "$scratch/over.err")" == *exceed* ]] || fail "the over-cap failure does not name the cap: $(cat "$scratch/over.err")"
echo "cli-recovery-receipt-cap.test: $((51 * 1048576)) bytes of receipts exit 1"

under="$scratch/under"
mkdir -p "$under"
dd if=/dev/zero of="$under/blob" bs=1048576 count=50 status=none
bash "$script" --receipt-cap "$under"
echo "cli-recovery-receipt-cap.test: receipts at the cap pass"
echo "cli-recovery-receipt-cap.test: all cases passed"
