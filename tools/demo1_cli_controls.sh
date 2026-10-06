#!/usr/bin/env bash
# The ordinary CLI's refusal controls (#299): a second insertion of an
# Active key and an insertion of a Terminal key, each beside an accepting
# control, against one generated development node.
#
# usage: demo1_cli_controls.sh SINGULAR DEVNET CLI_CONTROLS BLUEPRINT LEDGER WORKDIR
#
# This script only arranges processes: one node, one funded wallet, and
# one `cli-controls run`, which runs the story, leaves one receipt per
# action under WORKDIR/receipts and judges every clause from them. The
# verdict section is WORKDIR/controls.md. Setup failures (no node, no
# socket) exit 3 and are never a verdict.
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
  echo "controls: $work exists; every run takes a fresh directory" >&2
  exit 2
}
mkdir -p "$work"

setup_fail() {
  echo "controls: SETUP: $*" >&2
  exit 3
}
say() { echo "controls: $*"; }
fail_control() {
  echo "controls: CONTROL FAILED: $*" >&2
  exit 1
}

# The checks below read files whole, never through a pipe whose reader stops
# early: under pipefail a `| grep -q` or `| head` that has its answer closes
# the pipe, the writer dies of SIGPIPE, and a control that found its line
# fails anyway (CI, fda5e10: "grep: write error: Broken pipe").
# line_with FILE A B: some line of FILE contains both A and B.
line_with() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l == *"$2"* && $l == *"$3"* ]] && return 0
  done <"$1"
  return 1
}
# first_receipt ACTION [TARGET]: the first receipt, in name order, of ACTION
# (on TARGET when given); nothing when there is none.
first_receipt() {
  local f
  for f in "$work"/receipts/*.json; do
    grep -qF "\"action\": \"$1\"" "$f" || continue
    [ -z "${2:-}" ] || grep -qF "\"target\": \"$2\"" "$f" || continue
    printf '%s\n' "$f"
    return 0
  done
}
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$work/wallet.skey"
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$work/stranger.skey"

export TMPDIR="$work"
"$devnet" --fund-skey "$work/wallet.skey" --fund-skey "$work/stranger.skey" --fund-outputs 40 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
trap 'kill "$devnet_pid" 2>/dev/null || true; pkill -f "cardano-node run --config $work/" 2>/dev/null || true' EXIT
sock=""
provider_url=""
time_directory=""
network_magic=""
for _ in $(seq 1 900); do
  settings="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  sock="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
  provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
  time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
  network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
  [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_directory/time-manifest.json" ] && break
  kill -0 "$devnet_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -S "$sock" ] || [ ! -r "$time_directory/time-manifest.json" ]; then
  tail -40 "$work/devnet.err" >&2 || true
  setup_fail "the private devnet never printed usable provider/time and independent probe settings"
fi
say "one private development source at $provider_url"

status=0
"$controls" run \
  --singular "$singular" --blueprint "$blueprint" --ledger "$ledger" \
  --koios-url "$provider_url" --network-time "$time_directory" --node-socket "$sock" --network-magic "$network_magic" --wallet-skey "$work/wallet.skey" --stranger-skey "$work/stranger.skey" \
  --work "$work" >"$work/controls.md" 2> >(tee "$work/controls.err" >&2) || status=$?
tail -1 "$work/controls.md"
say "verdict section at $work/controls.md (exit $status)"
[ "$status" -eq 0 ] || exit "$status"

# The verdicts must rest on the retained bytes. On copies of this run's
# receipts and evidence, the honest copy must hold, and each copy with one
# retained artifact of the duplicate refusal removed or changed must fail that
# refusal for the admission reason named, and exit non-zero.
copies="$work/artifact-controls"
mkdir -p "$copies"
step="$(first_receipt fold-unevaluated duplicate)"
[ -n "$step" ] || fail_control "no refused fold receipt for the duplicate target"
name="$(basename "$step")"
rejection="$(jq -r .rejectionFile "$step")"
body="$(jq -r .bodyFile "$step")"
sha256sum "$controls" "$step" "$work/$rejection" "$work/$body" >"$copies/inputs.sha256"
# shellcheck disable=SC2016 # the backticks are the section's own Markdown
claim='| `OpenDatumApplication.Statements.duplicate_refused_by_registry` | that request'"'"'s fold, submitted without local evaluation, is refused by the registry'"'"'s state validator | '
copy() {
  rm -rf "${copies:?}/$1"
  mkdir -p "$copies/$1"
  cp -r "$work/receipts" "$work/evidence" "$copies/$1/"
  # the bodies ordinary commands journalled, each at its own relative path
  jq -r '.submissions[]?.bodyFile' "$work"/receipts/*.json | while read -r kept; do
    (cd "$work" && cp --parents "$kept" "$copies/$1/")
  done
  # the journals and saved files provoked commands' receipts read back
  jq -r '(.journal // empty | .file), (.process // empty | .journal, (.filesAfter[]?[0]))' "$work"/receipts/*.json \
    | sort -u | while read -r kept; do
    (cd "$work" && cp --parents "$kept" "$copies/$1/")
  done
}
# expect COPY CAUSE: COPY's render fails the claim for CAUSE (empty: holds).
expect() {
  local s=0
  "$controls" render "$copies/$1/receipts" >"$copies/$1.md" 2>"$copies/$1.err" || s=$?
  if [ -z "$2" ]; then
    [ "$s" -eq 0 ] || fail_control "$1: the unchanged copy does not hold (exit $s)"
  else
    [ "$s" -ne 0 ] || fail_control "$1: the changed copy still holds"
    line_with "$copies/$1.md" "$claim" "does not hold: $2" \
      || fail_control "$1: the duplicate refusal does not fail for: $2"
  fi
  say "artifact control $1: as expected"
}
copy honest
expect honest ""
copy rejection-missing
rm "$copies/rejection-missing/$rejection"
expect rejection-missing "the retained rejection $rejection is missing"
copy rejection-changed
printf changed >>"$copies/rejection-changed/$rejection"
expect rejection-changed "the retained rejection $rejection is not the bytes the receipt digests"
copy digest-changed
jq '.rejectionSha256 = "00"' "$step" >"$copies/digest-changed/receipts/$name"
expect digest-changed "the retained rejection $rejection is not the bytes the receipt digests"
copy body-missing
rm "$copies/body-missing/$body"
expect body-missing "the retained body $body is missing"
copy txid-mismatch
jq '.txId = "'"$(printf '0%.0s' $(seq 64))"'"' "$step" >"$copies/txid-mismatch/receipts/$name"
expect txid-mismatch "the retained body is transaction $(jq -r .txId "$step"), not the receipt's"
say "artifact controls: the honest copy holds; each changed copy fails the duplicate refusal for its reason"

# An ordinary command's claims rest on the bodies its journal kept. On copies,
# one journalled body of an insert, an update and a terminate is removed,
# changed or mis-identified: a claim must fail naming it, and exit non-zero.
# Removing the terminate that brings a registry to its terminal prefix must
# also leave that telling's later clauses uncovered for the same cause.
command_receipt() {
  first_receipt "run $1" "$2"
}
journalled() {
  local body
  body="$(jq -r '.submissions[0].bodyFile // empty' "$1")"
  [ -n "$body" ] || fail_control "$(basename "$1") journalled no submission"
  printf '%s' "$body"
}
# expect_command COPY CAUSE [premise]: a claim fails naming CAUSE; with
# premise, a later clause is also uncovered for it.
expect_command() {
  local s=0
  "$controls" render "$copies/$1/receipts" >"$copies/$1.md" 2>"$copies/$1.err" || s=$?
  [ "$s" -ne 0 ] || fail_control "$1: the changed copy still holds"
  line_with "$copies/$1.md" "does not hold: " "$2" \
    || fail_control "$1: no claim fails for: $2"
  if [ -n "${3:-}" ]; then
    line_with "$copies/$1.md" "uncovered: its premise does not hold: " "$2" \
      || fail_control "$1: no later clause is uncovered for: $2"
  fi
  say "command control $1: as expected"
}
insert="$(command_receipt insert lifecycle)"
update="$(command_receipt update lifecycle)"
terminate="$(command_receipt terminate lifecycle)"
reached="$(command_receipt terminate resurrection)"
for r in "$insert" "$update" "$terminate" "$reached"; do
  [ -n "$r" ] || fail_control "an ordinary command receipt of the controls is missing"
done
insert_body="$(journalled "$insert")"
update_body="$(journalled "$update")"
terminate_body="$(journalled "$terminate")"
reached_body="$(journalled "$reached")"
sha256sum "$insert" "$update" "$terminate" "$reached" \
  "$work/$insert_body" "$work/$update_body" "$work/$terminate_body" "$work/$reached_body" \
  >>"$copies/inputs.sha256"
copy insert-body-missing
rm "$copies/insert-body-missing/$insert_body"
expect_command insert-body-missing "the journalled body $insert_body is missing"
copy update-body-changed
printf changed >>"$copies/update-body-changed/$update_body"
expect_command update-body-changed "the journalled body $update_body is not the bytes the receipt digests"
copy terminate-misidentified
zeros="$(printf '0%.0s' $(seq 64))"
jq '.submissions[0].txId = "'"$zeros"'"' "$terminate" \
  >"$copies/terminate-misidentified/receipts/$(basename "$terminate")"
expect_command terminate-misidentified "the journalled body $terminate_body is transaction $(jq -r '.submissions[0].txId' "$terminate"), not $zeros"
copy reached-body-missing
rm "$copies/reached-body-missing/$reached_body"
expect_command reached-body-missing "the journalled body $reached_body is missing" premise
say "command controls: each changed copy fails the ordinary command's claim for its reason"

# A fresh submission cannot pass as a reference read back. The run's first
# create publishes every reference itself: for each of its submissions, boot
# included, a copy drops the submission, records it as read back and removes
# its body; the journal, which prepared it, must refuse that. The honest copy
# above holds the later creates, which read the state reference back.
first="$(command_receipt create duplicate-control)"
[ -n "$first" ] || fail_control "no create receipt of the first registry"
[ "$(jq '.submissions | length' "$first")" -ge 2 ] \
  || fail_control "the first create journalled fewer than two submissions"
jq -e '[.submissions[].step] | index("boot")' "$first" >/dev/null \
  || fail_control "the first create's submissions do not include its boot"
jq -e '.resolved == []' "$first" >/dev/null \
  || fail_control "the first create read a reference back instead of publishing it"
sha256sum "$first" "$work/$(jq -r .journal.file "$first")" >>"$copies/inputs.sha256"
jq -r '.submissions[] | [.step, .txId, .bodyFile] | @tsv' "$first" \
  | while IFS=$'\t' read -r step tx body; do
    copy "relabel-$step"
    jq --arg t "$tx" --arg s "$step" \
      '.submissions |= map(select(.txId != $t)) | .resolved += [{step: $s, txId: $t}]' \
      "$first" >"$copies/relabel-$step/receipts/$(basename "$first")"
    rm "$copies/relabel-$step/$body"
    expect_command "relabel-$step" "the journal prepared"
  done
say "relabel controls: no fresh submission of a create passes as a read-back"

# A provoked command's claims rest on what its process left. With the
# registry's journal cut back to before the killed terminate, the claim that
# it stopped at the node's acceptance must fail naming the journal.
killed="$(first_receipt "provoke terminate-killed")"
[ -n "$killed" ] || fail_control "no receipt of the killed terminate"
journal="$(jq -r .process.journal "$killed")"
kept="$(jq -r .process.journalBefore "$killed")"
sha256sum "$killed" "$work/$journal" >>"$copies/inputs.sha256"
copy journal-cut
head -n "$kept" "$work/$journal" >"$copies/journal-cut/$journal"
expect_command journal-cut "the journal has $kept lines"
say "process control: the cut journal fails the killed terminate's claim"
