#!/usr/bin/env bash
# Recovery receipts stay under 50 MiB (52428800 bytes). The evidence file
# keeps the journal fields the cross-wallet predicates read, not the
# snapshots. A receipts directory over that cap fails the check.
#
# usage: cli_recovery_receipt_cap.test.sh RECOVERY-SCRIPT
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 RECOVERY-SCRIPT" >&2
  exit 2
}
script="$1"
cap=52428800
scratch="$(mktemp -d "${TMPDIR:-/tmp}/cli-recovery-receipt-cap.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "cli-recovery-receipt-cap.test: FAIL: $*" >&2
  exit 1
}

booking_tx="$(printf 'ab%.0s' {1..32})"
other_tx="$(printf 'ff%.0s' {1..32})"
folder="$(printf 'cd%.0s' {1..28})"
requester="$(printf 'ef%.0s' {1..28})"
root="$(printf '01%.0s' {1..32})"
fixture="$scratch/fixture"
mkdir -p "$fixture"

# One journal line carrying a 1 MiB body the predicates never read.
# The body goes through a file: a 1 MiB shell argument exceeds the limit.
head -c 1048576 /dev/zero | tr '\0' x >"$fixture/body.txt"
jq -nc --arg id "$other_tx" --rawfile body "$fixture/body.txt" \
  '{journalTxId:$id,journalEvent:"prepared",journalCommand:"fold",journalBody:$body}' \
  >"$fixture/bulky.json"
{
  cat "$fixture/bulky.json"
  # Fifty-five copies: slurping them exceeds the cap. The four events below
  # are the booking the predicate reads; they carry the same unused body.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55; do
    cat "$fixture/bulky.json"
  done
  for event in prepared submitted confirmed observed; do
    jq -nc --arg id "$booking_tx" --arg event "$event" --rawfile body "$fixture/body.txt" \
      '{journalTxId:$id,journalEvent:$event,journalCommand:"insert",journalBody:$body,journalInputs:["kept"]}'
  done
} >"$fixture/booked.jsonl"
cp "$fixture/bulky.json" "$fixture/held.jsonl"
cp "$fixture/bulky.json" "$fixture/after.jsonl"
jq -nc --arg tx "$booking_tx" --arg requester "$requester" --rawfile body "$fixture/body.txt" \
  '{outcome:"success",request:($tx+"#0"),booking:$tx,requester:$requester,unused:$body}' \
  >"$fixture/booking.json"
jq -nc '{outcome:"success",reconciled:{observed:[]}}' >"$fixture/next.json"
jq -nc --arg root "$root" '{outcome:"success",leaf:"active",root:$root}' >"$fixture/inspect.json"
echo null >"$fixture/loss.json"
jq -nc --arg fold "$(printf '12%.0s' {1..32})" --arg key "6d01" --arg point hold \
  --arg folder "$folder" --arg root "$root" \
  '{fold:$fold,key:$key,point:$point,reached:0,folder:$folder,signers:[$folder],clean:0,exit:0,
    before:$root,booked:$root,held:$root,after:$root}' >"$scratch/meta-and-roots.json"
jq '{fold,key,point,reached,folder,signers,clean,exit}' "$scratch/meta-and-roots.json" >"$fixture/meta.json"
jq '{before,booked,held,after}' "$scratch/meta-and-roots.json" >"$fixture/roots.json"

evidence="$scratch/evidence.json"
bash "$script" --project-evidence "$fixture" "$evidence"
bytes="$(stat -c %s "$evidence")"
[ "$bytes" -le "$cap" ] || fail "projected evidence is $bytes bytes, cap is $cap"
jq -e '[.booked[].journalBody] | all(. == null)' "$evidence" >/dev/null \
  || fail "projected booked lines still carry journalBody"
# The booking predicate from the recovery controls, on the projected file.
# shellcheck disable=SC2016 # the predicate is a jq program, not a shell expansion
predicate='. as $e | .booking.outcome == "success" and .booking.request == (.booking.booking + "#0")
  and ([.booked[] | select(.journalTxId == $e.booking.booking) | .journalEvent] == ["prepared","submitted","confirmed","observed"])
  and .roots.before == .roots.booked'
jq -e "$predicate" "$evidence" >/dev/null || fail "the booking predicate does not hold on the projection"
status=0
jq '.booked += .booked' "$evidence" | jq -e "$predicate" >/dev/null 2>"$scratch/mutated.err" || status=$?
[ "$status" -eq 1 ] || fail "duplicating booked lines was not rejected (exit $status)"
echo "cli-recovery-receipt-cap.test: projected evidence $bytes bytes, under $cap, and the booking predicate still discriminates"

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
cp "$evidence" "$under/evidence.json"
bash "$script" --receipt-cap "$under"
echo "cli-recovery-receipt-cap.test: projected receipts pass the cap"
echo "cli-recovery-receipt-cap.test: all cases passed"
