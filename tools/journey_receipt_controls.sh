#!/usr/bin/env bash
# Receipt interpretation controls for the journeys' booking and fold helpers.
#
# The Demo 1 journey, the closed journey and the keri-stub journey read the
# receipts of a booking and of a fold with small helper functions. A
# registration has a processing window: its booking receipt names the deadline
# and its fold must land before it with a margin. A termination has no window:
# the producers print its deadline null, and its fold names no deadline and no
# margin. A helper that demands the registration shape of a termination rejects
# a conforming receipt before the fold is ever reached; a helper that drops a
# registration guard accepts a receipt that should be refused.
#
# This tool reads the helper functions out of the journey files themselves (the
# way the closed journey reads them), runs them over receipts built here in the
# shape the producers print, and requires each receipt to be accepted or
# refused as it deserves. Then it damages each helper in a copy of the journey,
# one change at a time, and requires the controls to notice. No node, no
# journey and no network: every receipt is a small JSON document made here, so
# a pass shows how the helpers read receipts, not that a node produced one.
#
# Usage: journey_receipt_controls.sh [REPOSITORY-ROOT]   (bash, awk, jq, perl)
# Environment: JOURNEY_RECEIPTS_DEMO1 and JOURNEY_RECEIPTS_KERI name other
# copies of the two journeys; JOURNEY_RECEIPTS_NO_MUTANTS=1 skips the damaged
# copies (the damaged-copy runs set it themselves); JOURNEY_RECEIPTS_KEEP names a
# directory that receives the receipts the controls built.
# Exit: 0 every case came out as expected and every damaged copy was caught;
# 1 a case came out otherwise or a damaged copy was not caught; 2 setup.
# shellcheck disable=SC2016  # the jq programs and the damaged-copy edits are single-quoted: nothing expands in them
# shellcheck disable=SC2034  # receipts is read by the helpers evaluated from the journeys
# shellcheck disable=SC2329  # fail is called by the helpers evaluated from the journeys
set -uo pipefail

root="${1:-$PWD}"
demo1="${JOURNEY_RECEIPTS_DEMO1:-$root/tools/demo1_cli_journey.sh}"
keri="${JOURNEY_RECEIPTS_KERI:-$root/tools/keri_stub_journey.sh}"
tmp="$(mktemp -d)"
# JOURNEY_RECEIPTS_KEEP names a directory that receives the receipts built here, for a reader of the run.
keep_and_clean() {
  if [ -n "${JOURNEY_RECEIPTS_KEEP:-}" ]; then
    mkdir -p "$JOURNEY_RECEIPTS_KEEP" && cp -R "$tmp"/. "$JOURNEY_RECEIPTS_KEEP"/
  fi
  rm -rf "$tmp"
}
trap keep_and_clean EXIT
receipts="$tmp"

setup_fail() {
  echo "journey receipt controls: $*" >&2
  exit 2
}
[ -f "$demo1" ] || setup_fail "no Demo 1 journey at $demo1"
[ -f "$keri" ] || setup_fail "no keri-stub journey at $keri"

# The journeys' own failure helper ends the script; here it ends the subshell
# a case runs in, so a helper that fails stops where it would in a journey.
fail() { exit 1; }

# read_fn FILE NAME: the text of a top-level function. A one-line helper ends
# on its opening line; a longer one ends at the next closing brace at the start
# of a line.
read_fn() {
  awk -v fn="$2" '
    !printing && $0 ~ ("^" fn "\\(\\) \\{") { printing=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next }
    printing && /^\}$/ { print; exit }
    printing { print }
  ' "$1"
}
load() { # FILE NAME...
  local file="$1" name code
  shift
  for name in "$@"; do
    code="$(read_fn "$file" "$name")"
    [ -n "$code" ] || setup_fail "$file defines no helper $name"
    eval "$code"
  done
}
load "$demo1" booking_receipt_ok termination_booking_receipt_ok booked booked_termination \
  fold_receipt_ok fold_selection_ok fold_landed_ok story_fold_ok
load "$keri" register_booking_ok convict_booking_ok

cases=0 accepted=0 refused=0 unexpected=0 groups=0
group="" group_cases=0 group_unexpected=0
group_start() {
  group="$1" group_cases=0 group_unexpected=0
  groups=$((groups + 1))
}
group_end() {
  echo "group $group: $group_cases cases, $group_unexpected unexpected"
}
# expect accept|refuse NAME COMMAND...: the command is a helper call; it runs in
# a subshell, so a failing helper ends there.
expect() {
  local want="$1" name="$2" got=refuse
  shift 2
  if ("$@") >/dev/null 2>&1; then got=accept; fi
  cases=$((cases + 1))
  group_cases=$((group_cases + 1))
  if [ "$want" = accept ]; then accepted=$((accepted + 1)); else refused=$((refused + 1)); fi
  if [ "$got" != "$want" ]; then
    unexpected=$((unexpected + 1))
    group_unexpected=$((group_unexpected + 1))
    echo "UNEXPECTED $group: $name: wanted $want, got $got"
  fi
}

# ------------------------------------------------------------------
# receipts, in the shape the producers print
# ------------------------------------------------------------------
req_tx="$(printf 'a%.0s' $(seq 64))"
fold_tx="$(printf 'b%.0s' $(seq 64))"
requester="$(printf 'c%.0s' $(seq 56))"
folder="$(printf 'd%.0s' $(seq 56))"
deadline_ms=1800000000000
clock_ms=1799999900000
unconverted="beyond the node's conversion horizon"

# put NAME JSON: a receipt file. derive BASE NAME EXPR: the same receipt with one change.
put() { printf '%s\n' "$2" >"$tmp/$1.json"; }
derive() { jq -c "$3" "$tmp/$1.json" >"$tmp/$2.json"; }

# A registration booking: a deadline as a time and a slot.
put reg-booking "$(jq -nc --arg t "$req_tx" --arg r "$requester" --argjson d "$deadline_ms" \
  '{booking: $t, request: ($t + "#0"), requester: $r, transfer: 0, foldDeadline: {posixMs: $d, slot: 450}}')"
# A termination booking: the producers print the deadline null.
put term-booking "$(jq -nc --arg t "$req_tx" --arg r "$requester" \
  '{booking: $t, request: ($t + "#0"), requester: $r, transfer: 4000000, foldDeadline: null}')"
# A registration fold: before the deadline, with the margin, the bound inside the deadline slot.
put reg-fold "$(jq -nc --arg t "$req_tx" --arg f "$fold_tx" --arg w "$folder" --argjson d "$deadline_ms" --argjson c "$clock_ms" \
  '{settled: [{request: ($t + "#0"), edge: "insertActive"}], foldDeadline: {posixMs: $d, slot: 450},
    folder: $w, fold: $f, validUntilSlot: 450, hostClockMs: $c, remainingMs: ($d - $c),
    postBuild: {check: "admitted", hostClockMs: $c, validUntilSlot: 450, validUntilMs: $d},
    landed: {transactions: [{identity: $f}]}}')"
# A termination fold: no deadline, no margin, no window to prove.
put term-fold "$(jq -nc --arg t "$req_tx" --arg f "$fold_tx" --arg w "$folder" --argjson c "$clock_ms" \
  '{settled: [{request: ($t + "#0"), edge: "updateTerminal"}], foldDeadline: null,
    folder: $w, fold: $f, validUntilSlot: 220, hostClockMs: $c, remainingMs: null,
    postBuild: {check: "admitted: no registration is settled, so there is no window", hostClockMs: $c, validUntilSlot: 220, validUntilMs: null},
    landed: {transactions: [{identity: $f}]}}')"

# ------------------------------------------------------------------
group_start "registration booking receipt"
expect accept "a booking with its deadline as a time and a slot" booking_receipt_ok "$tmp/reg-booking.json"
derive reg-booking reg-booking-unconverted \
  ".foldDeadline.slot = null | .foldDeadline.slotUnavailable = \"$unconverted\""
expect accept "a booking whose slot the node could not convert, saying so" booking_receipt_ok "$tmp/reg-booking-unconverted.json"
derive reg-booking reg-booking-silent-slot '.foldDeadline.slot = null'
expect refuse "a booking whose slot is null without saying why" booking_receipt_ok "$tmp/reg-booking-silent-slot.json"
derive reg-booking reg-booking-null '.foldDeadline = null'
expect refuse "a registration booking with no deadline" booking_receipt_ok "$tmp/reg-booking-null.json"
derive reg-booking reg-booking-text '.foldDeadline.posixMs = "soon"'
expect refuse "a registration booking whose deadline is not a number" booking_receipt_ok "$tmp/reg-booking-text.json"
derive reg-booking reg-booking-gone 'del(.foldDeadline)'
expect refuse "a registration booking whose receipt has no deadline field" booking_receipt_ok "$tmp/reg-booking-gone.json"
derive reg-booking reg-booking-folded '.fold = "x"'
expect refuse "a booking receipt that claims a fold" booking_receipt_ok "$tmp/reg-booking-folded.json"
derive reg-booking reg-booking-root '.root = "x"'
expect refuse "a booking receipt that claims a root" booking_receipt_ok "$tmp/reg-booking-root.json"
derive reg-booking reg-booking-request '.request = (.booking + "#1")'
expect refuse "a pending request that is not the booking's output 0" booking_receipt_ok "$tmp/reg-booking-request.json"
derive reg-booking reg-booking-requester '.requester = "abc"'
expect refuse "a requester that is not a key hash" booking_receipt_ok "$tmp/reg-booking-requester.json"
expect refuse "a termination booking read as a registration" booking_receipt_ok "$tmp/term-booking.json"
expect accept "the named registration booking helper accepts a registration booking" booked reg-booking
expect refuse "the named registration booking helper refuses a booking with no deadline" booked reg-booking-null
group_end

group_start "termination booking receipt"
expect accept "a termination booking whose deadline is null" termination_booking_receipt_ok "$tmp/term-booking.json"
derive term-booking term-booking-gone 'del(.foldDeadline)'
expect accept "a termination booking whose receipt has no deadline field" termination_booking_receipt_ok "$tmp/term-booking-gone.json"
derive term-booking term-booking-invented '.foldDeadline = {posixMs: 1800000000000, slot: 450}'
expect refuse "a termination booking with an invented deadline" termination_booking_receipt_ok "$tmp/term-booking-invented.json"
derive term-booking term-booking-zero '.foldDeadline = 0'
expect refuse "a termination booking whose deadline is zero" termination_booking_receipt_ok "$tmp/term-booking-zero.json"
derive term-booking term-booking-folded '.fold = "x"'
expect refuse "a termination booking receipt that claims a fold" termination_booking_receipt_ok "$tmp/term-booking-folded.json"
derive term-booking term-booking-request '.request = (.booking + "#1")'
expect refuse "a termination request that is not the booking's output 0" termination_booking_receipt_ok "$tmp/term-booking-request.json"
derive term-booking term-booking-requester '.requester = "abc"'
expect refuse "a termination requester that is not a key hash" termination_booking_receipt_ok "$tmp/term-booking-requester.json"
expect refuse "a registration booking read as a termination" termination_booking_receipt_ok "$tmp/reg-booking.json"
expect accept "the named termination booking helper accepts a termination booking" booked_termination term-booking
expect refuse "the named termination booking helper refuses an invented deadline" booked_termination term-booking-invented
group_end

group_start "registration fold receipt"
expect accept "a registration fold before its deadline with the margin" fold_receipt_ok "$tmp/reg-fold.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-null-deadline '.foldDeadline = null'
expect refuse "a registration fold that names no deadline" fold_receipt_ok "$tmp/reg-fold-null-deadline.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-other-deadline '.foldDeadline.posixMs += 1'
expect refuse "a registration fold whose deadline is not the booking's" fold_receipt_ok "$tmp/reg-fold-other-deadline.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-no-margin '.remainingMs = 30000'
expect refuse "a registration fold left with no more than the margin" fold_receipt_ok "$tmp/reg-fold-no-margin.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-no-remaining '.remainingMs = null'
expect refuse "a registration fold that names no remaining time" fold_receipt_ok "$tmp/reg-fold-no-remaining.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-late-clock ".hostClockMs = $((deadline_ms - 30000))"
expect refuse "a registration fold decided within the margin of the deadline" fold_receipt_ok "$tmp/reg-fold-late-clock.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-no-bound 'del(.validUntilSlot)'
expect refuse "a registration fold that names no validity bound" fold_receipt_ok "$tmp/reg-fold-no-bound.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-past-slot '.validUntilSlot = 451'
expect refuse "a registration fold whose bound is past the deadline slot" fold_receipt_ok "$tmp/reg-fold-past-slot.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-booker ".folder = \"$requester\""
expect refuse "a registration folded by the booker" fold_receipt_ok "$tmp/reg-fold-booker.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-other-request '.settled[0].request = (.settled[0].request + "x")'
expect refuse "a registration fold of another request" fold_receipt_ok "$tmp/reg-fold-other-request.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-two '.settled += .settled'
expect refuse "a registration fold that settles two requests" fold_receipt_ok "$tmp/reg-fold-two.json" "$tmp/reg-booking.json" insertActive
derive reg-fold reg-fold-fold-id '.fold = "abc"'
expect refuse "a registration fold with no transaction id" fold_receipt_ok "$tmp/reg-fold-fold-id.json" "$tmp/reg-booking.json" insertActive
expect refuse "a registration fold read as another edge" fold_receipt_ok "$tmp/reg-fold.json" "$tmp/reg-booking.json" updateActive
expect refuse "a registration fold read as a termination" fold_receipt_ok "$tmp/reg-fold.json" "$tmp/reg-booking.json" updateTerminal
expect accept "the named fold helper accepts a landed registration fold" story_fold_ok reg-fold reg-booking insertActive
derive reg-fold reg-fold-unlanded '.landed.transactions = []'
expect refuse "the named fold helper refuses a registration fold that did not land" story_fold_ok reg-fold-unlanded reg-booking insertActive
group_end

group_start "termination fold receipt"
expect accept "a termination fold with no deadline and no margin" fold_receipt_ok "$tmp/term-fold.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-deadline '.foldDeadline = {posixMs: 1800000000000, slot: 450}'
expect refuse "a termination fold with an invented deadline" fold_receipt_ok "$tmp/term-fold-deadline.json" "$tmp/term-booking.json" updateTerminal
expect refuse "a termination fold whose booking carries a deadline" fold_receipt_ok "$tmp/term-fold.json" "$tmp/reg-booking.json" updateTerminal
derive term-fold term-fold-margin '.remainingMs = 100000'
expect refuse "a termination fold with an invented margin" fold_receipt_ok "$tmp/term-fold-margin.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-no-bound 'del(.validUntilSlot)'
expect refuse "a termination fold that names no validity bound" fold_receipt_ok "$tmp/term-fold-no-bound.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-no-bounds 'del(.validUntilSlot) | .postBuild.validUntilSlot = null'
expect refuse "a termination fold that names no validity bound anywhere" fold_receipt_ok "$tmp/term-fold-no-bounds.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-no-clock 'del(.hostClockMs)'
expect refuse "a termination fold that names no host clock" fold_receipt_ok "$tmp/term-fold-no-clock.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-window '.postBuild.validUntilMs = 1800000000000'
expect refuse "a termination fold whose post-build record names a window" fold_receipt_ok "$tmp/term-fold-window.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-other-bound '.postBuild.validUntilSlot = 221'
expect refuse "a termination fold whose post-build bound is not its receipt's" fold_receipt_ok "$tmp/term-fold-other-bound.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-booker ".folder = \"$requester\""
expect refuse "a termination folded by the booker" fold_receipt_ok "$tmp/term-fold-booker.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-other-request '.settled[0].request = (.settled[0].request + "x")'
expect refuse "a termination fold of another request" fold_receipt_ok "$tmp/term-fold-other-request.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-two '.settled += .settled'
expect refuse "a termination fold that settles two requests" fold_receipt_ok "$tmp/term-fold-two.json" "$tmp/term-booking.json" updateTerminal
derive term-fold term-fold-fold-id '.fold = "abc"'
expect refuse "a termination fold with no transaction id" fold_receipt_ok "$tmp/term-fold-fold-id.json" "$tmp/term-booking.json" updateTerminal
expect refuse "a termination fold read as a registration" fold_receipt_ok "$tmp/term-fold.json" "$tmp/term-booking.json" insertActive
expect accept "the named fold helper accepts a landed termination fold" story_fold_ok term-fold term-booking updateTerminal
derive term-fold term-fold-unlanded '.landed.transactions = []'
expect refuse "the named fold helper refuses a termination fold that did not land" story_fold_ok term-fold-unlanded term-booking updateTerminal
derive term-fold term-fold-submitted '.landed = null | .submissions = [{identity: .fold}]'
expect accept "a fold that names its transaction among its submissions lands" fold_landed_ok "$tmp/term-fold-submitted.json"
expect refuse "a fold that names no landed transaction does not land" fold_landed_ok "$tmp/term-fold-unlanded.json"
group_end

# ------------------------------------------------------------------
# the validity bound a fold's own selection phase records
# ------------------------------------------------------------------
genesis() { jq -nc --argjson m "${1:-42}" '{networkMagic: $m, securityParam: 10, activeSlotsCoeff: 0.5, epochLength: 500, slotLength: 1}' >"$tmp/genesis.json"; }
phase() { # NAME JQ-OBJECT-EXPR: a phases file with one selection phase
  jq -nc "{phase: \"validityUpper\", tip: 100, horizon: 500, lower: 120, effectiveLower: 120, windowUpper: 450, upper: 450, minimumSlots: 10} | $2" >"$tmp/$1.phases.jsonl"
}
genesis
phase reg-phase '.'
phase term-phase '.lower = 100 | .effectiveLower = 101 | .windowUpper = 220 | .upper = 220'

group_start "validity bound of the fold's own selection"
expect accept "a registration whose bound is its deadline slot, capped at the horizon" fold_selection_ok "$tmp/reg-phase.phases.jsonl" "$tmp/reg-fold.json" "$tmp/genesis.json" insertActive
phase reg-phase-window '.windowUpper = 440 | .upper = 440'
expect refuse "a registration whose window ends before its deadline slot" fold_selection_ok "$tmp/reg-phase-window.phases.jsonl" "$tmp/reg-fold.json" "$tmp/genesis.json" insertActive
expect refuse "a registration receipt with no deadline" fold_selection_ok "$tmp/reg-phase.phases.jsonl" "$tmp/reg-fold-null-deadline.json" "$tmp/genesis.json" insertActive
expect accept "a termination whose bound is the one the clock chose" fold_selection_ok "$tmp/term-phase.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
expect refuse "a termination receipt that names a deadline" fold_selection_ok "$tmp/term-phase.phases.jsonl" "$tmp/term-fold-deadline.json" "$tmp/genesis.json" updateTerminal
# Each damaged selection below comes with a receipt that prints the same bound
# the selection records, so only the guard named by the case can refuse it.
term_fold_at() { derive term-fold "term-fold-at-$1" ".validUntilSlot = $1 | .postBuild.validUntilSlot = $1"; }
term_fold_at 230
term_fold_at 600
term_fold_at 105
phase term-phase-other '.lower = 100 | .effectiveLower = 101 | .windowUpper = 230 | .upper = 230'
expect refuse "a termination whose receipt prints another bound than the selection" fold_selection_ok "$tmp/term-phase-other.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
expect accept "the same selection against a receipt that prints its bound" fold_selection_ok "$tmp/term-phase-other.phases.jsonl" "$tmp/term-fold-at-230.json" "$tmp/genesis.json" updateTerminal
phase term-phase-horizon '.lower = 100 | .effectiveLower = 101 | .windowUpper = 600 | .upper = 600'
expect refuse "a termination whose bound is past the ledger horizon" fold_selection_ok "$tmp/term-phase-horizon.phases.jsonl" "$tmp/term-fold-at-600.json" "$tmp/genesis.json" updateTerminal
phase term-phase-short '.lower = 100 | .effectiveLower = 101 | .windowUpper = 105 | .upper = 105'
expect refuse "a termination whose usable interval is shorter than the minimum" fold_selection_ok "$tmp/term-phase-short.phases.jsonl" "$tmp/term-fold-at-105.json" "$tmp/genesis.json" updateTerminal
phase term-phase-lower '.lower = 100 | .effectiveLower = 100 | .windowUpper = 220 | .upper = 220'
expect refuse "a termination whose effective lower bound is not after the tip" fold_selection_ok "$tmp/term-phase-lower.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
phase term-phase-wrong-horizon '.lower = 100 | .effectiveLower = 101 | .windowUpper = 220 | .upper = 220 | .horizon = 600'
expect refuse "a termination whose recorded horizon is not the one the genesis gives" fold_selection_ok "$tmp/term-phase-wrong-horizon.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
phase term-phase-no-window '.lower = 100 | .effectiveLower = 101 | .windowUpper = null | .upper = 220'
expect refuse "a termination whose selection records no window bound" fold_selection_ok "$tmp/term-phase-no-window.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
: >"$tmp/no-phase.phases.jsonl"
expect refuse "a fold whose selection phase was never recorded" fold_selection_ok "$tmp/no-phase.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
cat "$tmp/term-phase.phases.jsonl" "$tmp/term-phase.phases.jsonl" >"$tmp/two-phase.phases.jsonl"
expect refuse "a fold whose selection phase was recorded twice" fold_selection_ok "$tmp/two-phase.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
genesis 7
expect refuse "a genesis of another network" fold_selection_ok "$tmp/term-phase.phases.jsonl" "$tmp/term-fold.json" "$tmp/genesis.json" updateTerminal
genesis
group_end

# ------------------------------------------------------------------
# the keri-stub journey's own booking receipts
# ------------------------------------------------------------------
key_hex="$(printf '%s' keri-key-one | od -An -tx1 | tr -d ' \n')"
evidence_hex="$(printf '0123456789abcdef%.0s' 1 2 3 4)"
custody="$(printf 'e%.0s' $(seq 64))#1"
put keri-register "$(jq -nc --arg k "$key_hex" --arg t "$req_tx" --arg r "$requester" --argjson d "$deadline_ms" \
  '{key: $k, booking: $t, request: ($t + "#0"), requester: $r, foldDeadline: {posixMs: $d, slot: 450}}')"
put keri-convict "$(jq -nc --arg k "$key_hex" --arg t "$req_tx" --arg r "$requester" --arg v "$evidence_hex" --arg c "$custody" \
  '{key: $k, booking: $t, request: ($t + "#0"), requester: $r, foldDeadline: null, transfer: 4000000,
    evidence: $v, custody: $c, held: 4000000}')"

group_start "keri-stub registration booking receipt"
expect accept "a register booking with its deadline" register_booking_ok "$tmp/keri-register.json" "$key_hex"
derive keri-register keri-register-null '.foldDeadline = null'
expect refuse "a register booking with no deadline" register_booking_ok "$tmp/keri-register-null.json" "$key_hex"
derive keri-register keri-register-text '.foldDeadline.posixMs = "soon"'
expect refuse "a register booking whose deadline is not a number" register_booking_ok "$tmp/keri-register-text.json" "$key_hex"
expect refuse "a register booking of another key" register_booking_ok "$tmp/keri-register.json" "00"
derive keri-register keri-register-request 'del(.request)'
expect refuse "a register booking that names no pending request" register_booking_ok "$tmp/keri-register-request.json" "$key_hex"
group_end

group_start "keri-stub termination booking receipt"
expect accept "a convict booking with no deadline" convict_booking_ok "$tmp/keri-convict.json" "$key_hex" "$evidence_hex" 4000000
derive keri-convict keri-convict-gone 'del(.foldDeadline)'
expect accept "a convict booking whose receipt has no deadline field" convict_booking_ok "$tmp/keri-convict-gone.json" "$key_hex" "$evidence_hex" 4000000
derive keri-convict keri-convict-invented '.foldDeadline = {posixMs: 1800000000000, slot: 450}'
expect refuse "a convict booking with an invented deadline" convict_booking_ok "$tmp/keri-convict-invented.json" "$key_hex" "$evidence_hex" 4000000
derive keri-convict keri-convict-transfer '.transfer = 3999999'
expect refuse "a convict booking that transfers less than it held" convict_booking_ok "$tmp/keri-convict-transfer.json" "$key_hex" "$evidence_hex" 4000000
expect refuse "a convict booking that held another value" convict_booking_ok "$tmp/keri-convict.json" "$key_hex" "$evidence_hex" 4000001
expect refuse "a convict booking of other evidence" convict_booking_ok "$tmp/keri-convict.json" "$key_hex" "00" 4000000
expect refuse "a convict booking of another key" convict_booking_ok "$tmp/keri-convict.json" "00" "$evidence_hex" 4000000
derive keri-convict keri-convict-custody '.custody = "abc"'
expect refuse "a convict booking whose custody is not an output" convict_booking_ok "$tmp/keri-convict-custody.json" "$key_hex" "$evidence_hex" 4000000
derive keri-convict keri-convict-requester 'del(.requester)'
expect refuse "a convict booking that names no requester" convict_booking_ok "$tmp/keri-convict-requester.json" "$key_hex" "$evidence_hex" 4000000
group_end

echo "journey receipt controls: $cases cases ($accepted accepted, $refused refused) in $groups groups, $unexpected unexpected"

# ------------------------------------------------------------------
# the controls must notice a damaged helper
# ------------------------------------------------------------------
mutants_run=0 mutants_missed=0
# mutant NAME FILE-KIND EXPECT FROM TO: copy the journey, change one piece of a
# helper, run these controls over the copy; they must exit as EXPECT says (1: a
# case came out otherwise; 2: the helper could not be read).
mutant() {
  local name="$1" kind="$2" want="$3" from="$4" to="$5" src copy status=0
  case "$kind" in demo1) src="$demo1" ;; *) src="$keri" ;; esac
  copy="$tmp/mutant-$name.sh"
  FROM="$from" TO="$to" perl -0pe 's/\Q$ENV{FROM}\E/$ENV{TO}/' "$src" >"$copy"
  mutants_run=$((mutants_run + 1))
  if cmp -s "$src" "$copy"; then
    echo "MISSED $name: the change did not apply to $kind"
    mutants_missed=$((mutants_missed + 1))
    return
  fi
  if [ "$kind" = demo1 ]; then
    JOURNEY_RECEIPTS_KEEP='' JOURNEY_RECEIPTS_NO_MUTANTS=1 JOURNEY_RECEIPTS_DEMO1="$copy" bash "$0" "$root" >"$tmp/mutant-$name.out" 2>&1 || status=$?
  else
    JOURNEY_RECEIPTS_KEEP='' JOURNEY_RECEIPTS_NO_MUTANTS=1 JOURNEY_RECEIPTS_KERI="$copy" bash "$0" "$root" >"$tmp/mutant-$name.out" 2>&1 || status=$?
  fi
  if [ "$status" = "$want" ]; then
    echo "caught $name ($(grep -c '^UNEXPECTED' "$tmp/mutant-$name.out") cases came out otherwise, exit $status)"
  else
    echo "MISSED $name: the controls exited $status, expected $want"
    mutants_missed=$((mutants_missed + 1))
  fi
}

if [ "${JOURNEY_RECEIPTS_NO_MUTANTS:-0}" != 1 ]; then
  mutant termination-booking-wants-a-deadline demo1 1 \
    'and (.foldDeadline == null)' \
    'and (.foldDeadline.posixMs | type == "number")'
  mutant termination-fold-wants-the-margin demo1 1 \
    'and .remainingMs == null' \
    'and (.remainingMs | type == "number" and . > 30000)'
  mutant termination-fold-wants-a-deadline demo1 1 \
    'and $b[0].foldDeadline == null and .foldDeadline == null' \
    'and (.foldDeadline.posixMs | type == "number") and .foldDeadline.posixMs == $b[0].foldDeadline.posixMs'
  mutant termination-selection-wants-a-deadline-slot demo1 1 \
    'then $r.foldDeadline == null' \
    'then $s.windowUpper == $r.foldDeadline.slot'
  mutant termination-fold-drops-the-validity-bound demo1 1 \
    'and (.validUntilSlot | type == "number")' \
    'and true'
  mutant termination-selection-drops-the-usable-interval demo1 1 \
    'and ($s.upper - $s.effectiveLower) >= $s.minimumSlots' \
    'and true'
  mutant selection-drops-the-horizon-cap demo1 1 \
    'and $s.upper == ([$s.windowUpper, ($s.horizon - 1)] | min)' \
    'and true'
  mutant selection-drops-the-bound-equality demo1 1 \
    'and $s.upper == $r.validUntilSlot' \
    'and true'
  mutant registration-fold-drops-the-validity-bound demo1 1 \
    'and (.validUntilSlot | type == "number")
          and (if .foldDeadline.slot' \
    'and (if .foldDeadline.slot'
  mutant registration-booking-drops-the-deadline demo1 1 \
    'and (.foldDeadline.posixMs | type == "number")
      and ((.foldDeadline.slot' \
    'and ((.foldDeadline.slot'
  mutant registration-fold-drops-the-margin demo1 1 \
    'and (.remainingMs | type == "number" and . > 30000)' \
    'and true'
  mutant fold-helper-drops-the-landed-check demo1 1 \
    '(.fold as $f | ((.landed.transactions // .submissions) | map(.identity) | index($f)) != null)' \
    'true'
  mutant termination-booking-helper-missing demo1 2 \
    'termination_booking_receipt_ok() {' \
    'termination_booking_receipt_check() {'
  mutant convict-booking-wants-a-deadline keri 1 \
    'and .foldDeadline == null' \
    'and (.foldDeadline.posixMs | type == "number")'
  mutant register-booking-drops-the-deadline keri 1 \
    'and (.foldDeadline.posixMs | type == "number")' \
    'and true'
  echo "journey receipt controls: $mutants_run damaged copies of the helpers, $mutants_missed not caught"
fi

if [ "$unexpected" -ne 0 ] || [ "$mutants_missed" -ne 0 ]; then
  exit 1
fi
exit 0
