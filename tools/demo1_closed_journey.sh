#!/usr/bin/env bash
# Alice's closed-datum story through the packaged `singular` and `open-datum`
# commands (#660), from the extracted release archive on one development node.
#
# usage: demo1_closed_journey.sh SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR [ordinary|test-harness]
#
# SINGULAR, OPEN_DATUM and DEVNET are executables; BLUEPRINT is the registry
# partition's plutus.json. ONE development node is started once, funding by
# address two wallets made with `singular wallet create` (alice, bob), and every
# registry command is a separate process against it. Alice signs in one command:
# `--vault FILE --passphrase-fd FD` opens her vault, builds the run's bundle,
# signs it, sends it and lands it. Bob signs the external way: his write names
# his address and a new bundle file instead of a key file, builds its whole run
# as one bundle, signs and sends nothing and exits 19; he signs the bundle with
# `singular wallet sign --vault` and sends it with `singular submit`. Each step
# then checks what it always checked over the landed receipt and the chain reads:
#
#   create --closed -> page read -> insert -> fold -> inspect
#       -> chain reads -> refused update -> same chain reads
#       -> terminate -> chain reads -> fold -> inspect
#
# An insert or a terminate books and leaves its request pending; `open-datum
# fold` folds it, signed by a wallet other than the booking's. The update on
# the closed registry is refused by the executable before anything is signed
# and before any bundle is written, and two chain reads taken before and after it must be equal: the
# controller's wallet outputs and the name's own output. The controller read
# taken after the termination booking must differ, which shows it can see a
# submission; the booking moves all of the custody value into the request and the fold
# settles the termination, donating strictly between nothing and the transfer.
#
# Each process leaves one JSON receipt. Assertions read those receipts and
# chain reads, and nothing else. A refusal control names the outcome class it
# expects and requires the target's journal to be exactly as it was: nothing
# submitted. Setup failures (no node, no socket) are reported as setup, never
# as a result.
#
# Helper functions are read by name from the open journey beside this file at
# run time (see read_fn below); only the devnet start, the exit stop and the
# page read are top-level blocks this file carries itself.
set -euo pipefail

[ "$#" -ge 5 ] && [ "$#" -le 6 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR [ordinary|test-harness]" >&2
  exit 2
}
singular="$1"
open_datum="$2"
devnet="$3"
blueprint="$4"
work="$5"
mode="${6:-ordinary}"
case "$mode" in
  ordinary | test-harness) ;;
  *)
    echo "journey: unknown build mode $mode" >&2
    exit 2
    ;;
esac
rm -rf "$work"
mkdir -p "$work"
receipts="$work/receipts"
mkdir -p "$receipts"
# These launcher identities accompany the receipts. The release verifier
# separately binds the compiled ordinary bytes and actual component flags.
jq -n --arg mode "$mode" --arg singular "$singular" --arg openDatum "$open_datum" \
  --arg singularSha256 "$(sha256sum "$singular" | cut -d' ' -f1)" \
  --arg openDatumSha256 "$(sha256sum "$open_datum" | cut -d' ' -f1)" \
  '{mode:$mode, singular:$singular, openDatum:$openDatum,
    singularSha256:$singularSha256, openDatumSha256:$openDatumSha256}' >"$work/build-identity.json"
reg="$work/registry"
# shellcheck source=tools/managed_state.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/managed_state.sh"

fail() {
  echo "journey: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "journey: SETUP: $*" >&2
  exit 3
}
say() { echo "journey: $*"; }

# Helpers read out of the open journey by name: the function bodies are
# self-contained, so this file refuses a second copy. A one-line helper ends
# on its opening line; a longer one ends at the next closing brace at the
# start of a line. A bare sed range would swallow the code after a one-line
# helper, so the read stops at the opening line when it already closes.
open_journey="$(dirname "$0")/demo1_cli_journey.sh"
[ -f "$open_journey" ] || setup_fail "the open journey is not beside this file: $open_journey"
read_fn() {
  awk -v fn="$1" '
    !printing && $0 ~ ("^" fn "\\(\\) \\{") { printing=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next }
    printing && /^\}$/ { print; exit }
    printing { print }
  ' "$open_journey"
}
helpers="exit_of trace_disagreements trace_agrees run journal_lines refused field hexof holds_envelope release_work require_archive_layout booking_receipt_ok termination_booking_receipt_ok booked booked_termination booking_only journal_count local_files payload story_who story_stage story_settle story_vault fold_receipt_ok fold_landed_ok story_fold_ok"
for helper in $helpers; do
  code="$(read_fn "$helper")"
  [ -n "$code" ] || fail "the open journey names no helper $helper"
  eval "$code"
done
for helper in $helpers; do
  declare -F "$helper" >/dev/null || fail "helper $helper is not defined"
done
say "helpers ${helpers} read from the open journey"

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/dave.skey" # named only by the malformed funding control below

# Alice and Bob make their wallets with `singular wallet create`, each in a
# directory of their own that stands for their own machine, name their
# passphrase through an inherited descriptor, and are funded by the address
# `singular wallet address` prints: no key file of theirs exists.
story="$work/story"
mkdir -p "$story/alice" "$story/bob" "$story/bundles"
alice_pass="alice's demo passphrase"
bob_pass="bob's demo passphrase"
for who in alice bob; do
  pass_var="${who}_pass"
  "$singular" wallet create --vault "$story/$who/$who.vault" --network-magic 42 --passphrase-fd 3 \
    3<<<"${!pass_var}" >"$story/$who/create.out" 2>"$story/$who/create.err" \
    || setup_fail "singular wallet create failed for $who: $(tail -n 3 "$story/$who/create.err" | tr '\n' ' ')"
done
vault_alice_addr="$("$singular" wallet address --vault "$story/alice/alice.vault" --network-magic 42 --passphrase-fd 3 3<<<"$alice_pass")"
vault_bob_addr="$("$singular" wallet address --vault "$story/bob/bob.vault" --network-magic 42 --passphrase-fd 3 3<<<"$bob_pass")"
case "$vault_alice_addr$vault_bob_addr" in
  addr_test1*addr_test1*) ;;
  *) setup_fail "singular wallet address printed no test-network addresses: $vault_alice_addr $vault_bob_addr" ;;
esac
[ "$vault_alice_addr" != "$vault_bob_addr" ] || setup_fail "Alice and Bob made the same wallet"

export TMPDIR="$work"

# ------------------------------------------------------------------
# One persistent development node, funding two wallets by address
# ------------------------------------------------------------------
"$devnet" --fund-address "$vault_alice_addr:6:2000000000" --fund-address "$vault_bob_addr:6:2000000000" \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
# The per-wallet funding group is parsed before any node starts: a
# malformed one is refused by name, so no second node appears for it.
bad_fund="$work/bad-fund.out"
bad_status=0
"$devnet" --fund "$work/dave.skey:two:4000000" >"$bad_fund" 2>&1 || bad_status=$?
[ "$bad_status" -ne 0 ] || fail "the devnet accepted a malformed funding group"
grep -q '^devnet: --fund expects FILE:N:LOVELACE' "$bad_fund" \
  || fail "the malformed funding group was not refused by name: $(head -n 1 "$bad_fund")"
say "the devnet refuses a malformed per-wallet funding group by name"
# The node is the devnet runner's child: reap both, so no node of this
# run outlives it holding the development network's ports.
trap release_work EXIT
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

node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
common=(--state-dir "$reg" --blueprint "$blueprint")
say "the closed-datum story: Alice and Bob keep no signing key on disk. Alice signs from her vault: her command opens the vault, builds its whole run as one bundle, signs it, sends it and lands it in one step. Bob signs the external way: his write names the wallet's address and a new bundle file, signs nothing, sends nothing and exits with status 19, the outcome waiting-for-signatures; he then signs the bundle from his vault with singular wallet sign and sends it with singular submit."

# ------------------------------------------------------------------
# 1. the closed and open previews of one seed derive different hashes
# ------------------------------------------------------------------
run closed-preview success -- create --registration-cost 0 --booking-width 60000 --process-time 120000 --retract-time 30000 --preview --closed "${common[@]}" "${node[@]}" --wallet-address "$vault_alice_addr"
[ ! -e "$reg" ] || fail "a closed preview created the target $reg"
seed="$(field closed-preview .seed)"
run open-preview success -- create --registration-cost 0 --booking-width 60000 --process-time 120000 --retract-time 30000 --preview --seed "$seed" "${common[@]}" "${node[@]}" --wallet-address "$vault_alice_addr"
[ ! -e "$reg" ] || fail "an open preview created the target $reg"
[ "$(field open-preview .seed)" = "$seed" ] || fail "the open preview names another seed than the closed one"
closed_hash="$(field closed-preview .pins.pinApplication)"
open_hash="$(field open-preview .pins.pinApplication)"
[ -n "$closed_hash" ] && [ "$closed_hash" != "null" ] || fail "the closed preview names no application hash"
[ -n "$open_hash" ] && [ "$open_hash" != "null" ] || fail "the open preview names no application hash"
[ "$closed_hash" != "$open_hash" ] || fail "the closed and open previews derive the same application hash"
say "the closed and open previews of one seed derive different application hashes"

# Bob's preview names his key hash without writing; his folds are signed by his vault.
run bob-preview success -- create --registration-cost 0 --booking-width 60000 --process-time 120000 --retract-time 30000 --preview --state-dir "$work/bob-preview" \
  --blueprint "$blueprint" "${node[@]}" --wallet-address "$vault_bob_addr"
[ ! -e "$work/bob-preview" ] || fail "bob's preview created its target"
bobkey="$(field bob-preview .walletKeyHash)"

# ------------------------------------------------------------------
# 2. create with the closed switch
# ------------------------------------------------------------------
process_time=120000
retract_time=60000
story_vault create alice -- create --registration-cost 0 --booking-width 60000 --process-time "$process_time" --retract-time "$retract_time" --seed "$seed" --closed "${common[@]}" "${node[@]}"
[ "$(field create .application)" = "open_datum.closed_datum" ] \
  || fail "create names $(field create .application), not the closed application"
state="$(field create .pins.pinState)"
token="$(field create .token)"
# shellcheck disable=SC2034 # read at run time by the open journey's holds_envelope
active="$(field create .pins.pinActive)"
alicekey="$(field create .walletKeyHash)"
alice_addr="$(field create .wallet)"
[ "$alice_addr" = "$vault_alice_addr" ] || fail "create names another wallet than Alice's vault address"
[ "$(field create .seed)" = "$seed" ] || fail "create booted from another seed"
state_token="$(field create .stateToken)"
[ "$state_token" = "$state.$token" ] || fail "create did not print the state token $state.$token"
# Every later command names the registry by its token; the directory is only
# the actor's journal.
common+=(--state-token "$state_token")
say "registry $token booted closed from $seed"

# ------------------------------------------------------------------
# 3. the registry page right after create, from the receipt's command
# ------------------------------------------------------------------
# The create receipt prints the working describe command; run it as printed,
# with only the program name resolving to this archive's singular, and print
# the page text to the journey log. The read leaves the actor's state
# directory exactly as it was.
page_steps_run=0
if require_archive_layout "$blueprint" "$mode"; then
  page_steps_run=1
  describe_cmd="$(jq -r .describeCommand "$receipts/create.json")"
  [ "$describe_cmd" != "null" ] && [ -n "$describe_cmd" ] || fail "create printed no describe command"
  mkdir -p "$work/archive-bin"
  ln -sf "$singular" "$work/archive-bin/singular"
  describe_tree_before="$(cd "$reg" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  path_before="$PATH"
  PATH="$work/archive-bin:$PATH"
  describe_status=0
  eval "$describe_cmd" >"$receipts/describe-after-create.txt" 2>"$receipts/describe-after-create.err" || describe_status=$?
  PATH="$path_before"
  [ "$describe_status" -eq 0 ] || fail "the printed describe command failed after create: $(tail -n 3 "$receipts/describe-after-create.txt" "$receipts/describe-after-create.err" | tr '\n' ' ')"
  [ -s "$receipts/describe-after-create.txt" ] || fail "the page after create is empty"
  cat "$receipts/describe-after-create.txt"
  path_before="$PATH"
  PATH="$work/archive-bin:$PATH"
  describe_status=0
  eval "$describe_cmd --json" >"$receipts/describe-after-create.json" 2>"$receipts/describe-after-create.err" || describe_status=$?
  PATH="$path_before"
  [ "$describe_status" -eq 0 ] || fail "the printed describe command failed as JSON after create"
  jq -e '.command == "describe" and .outcome == "success"' "$receipts/describe-after-create.json" >/dev/null \
    || fail "the page after create is no success page"
  describe_tree_after="$(cd "$reg" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  [ "$describe_tree_after" = "$describe_tree_before" ] || fail "a page read changed the actor's state directory"
  say "the registry page reads after create from the receipt's command"
elif [ "$mode" = test-harness ]; then
  say "the page steps belong to the archive journey; skipped in this mode"
else
  # Ordinary without the layout never skips: the function named the missing
  # file above, and the same name fails the journey here.
  fail "the archive's blueprint has no version.txt beside it"
fi

# The mode is read from the chain: the page's recorded application hash is
# the closed preview's and the create receipt's, never the open preview's.
if [ "$page_steps_run" = 1 ]; then
  recorded="$(jq -r .registry.applicationScript "$receipts/describe-after-create.json")"
  create_hash="$(field create .pins.pinApplication)"
  [ "$recorded" = "$closed_hash" ] || fail "the page records $recorded, not the closed preview's $closed_hash"
  [ "$recorded" = "$create_hash" ] || fail "the page records $recorded, not the create receipt's $create_hash"
  [ "$recorded" != "$open_hash" ] || fail "the page records the open hash"
  say "the page reads the closed application hash from the chain"
fi

# ------------------------------------------------------------------
# 4. insert, folded by another wallet, read back with payload and deposit
# ------------------------------------------------------------------
key=closedA
payload "$work/closed-payload.json"
insert_journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
insert_before="$(journal_count "$insert_journal")"
files_before="$(local_files)"
story_vault insert alice -- insert --key "$key" --payload "$work/closed-payload.json" \
  "${common[@]}" "${node[@]}"
# Alice's vault booking leaves, for its own transaction, one waiting-for-signatures
# line and the landed line after it, beside the landed lines that record an
# earlier bundle's transactions found on chain, and no retired trie file: the
# key-file booking's four phases belong to a writer that signs and sends.
tail -n +"$((insert_before + 1))" "$insert_journal" \
  | jq -s -e '[.[] | select(.journalStep == "book") | .journalEvent] == ["waiting-for-signatures", "landed"] and all(.[]; .journalEvent | IN("waiting-for-signatures", "landed"))' >/dev/null \
  || fail "the vault booking did not leave exactly its waiting-for-signatures and landed lines"
[ "$(local_files)" = "$files_before" ] || fail "a vault booking created retired trie files"
booked insert
[ "$(field insert .requester)" = "$alicekey" ] || fail "the booking's requester is not alice's key"
holds_envelope insert .envelope "$alicekey" "$key" "$work/closed-payload.json" \
  || fail "the insert receipt's envelope is not the one the sources make"
story_stage fold bob -- fold --request "$(field insert .request)" \
  "${common[@]}" "${node[@]}"
story_settle fold bob
story_fold_ok fold insert insertActive
[ "$(field fold .folder)" = "$bobkey" ] || fail "alice's request was not folded with bob's key"
jq -e --slurpfile b "$receipts/insert.json" \
  '(.settled | length == 1) and .settled[0].request == $b[0].request and .settled[0].edge == "insertActive"
    and .folder != $b[0].requester and .settled[0].settlement.envelope == $b[0].envelope' \
  "$receipts/fold.json" >/dev/null || fail "the fold does not settle alice's insertion"
run inspect-active success -- inspect --key "$key" "${common[@]}" "${node[@]}"
[ "$(field inspect-active .leaf)" = active ] || fail "inspect after insert is not active"
# Every read-back field is bound to what the booking reported, obtained at
# run time: the payload and the deposit to the insert receipt's own
# envelope, the controller to the booking's requester, the output to the
# fold's delivered output with the deposit as its floor. No literal, no
# mere positivity.
jq -e --slurpfile b "$receipts/insert.json" --slurpfile f "$receipts/fold.json" '
    .applicationOutput.payload == $b[0].envelope.fields[1]
    and .applicationOutput.controller == $b[0].requester
    and .applicationOutput.deposit == $b[0].envelope.fields[0].fields[5].int
    and .applicationOutput.output == $f[0].settled[0].settlement.liveOutput
    and .applicationOutput.lovelace >= $b[0].envelope.fields[0].fields[5].int' \
  "$receipts/inspect-active.json" >/dev/null \
  || fail "the holding does not read back the booking's payload, controller, deposit and output"
holds_envelope inspect-active .applicationOutput.envelope "$alicekey" "$key" "$work/closed-payload.json" \
  || fail "the holding's envelope is not the one the sources make"
say "the name is active with its payload and deposit"

# ------------------------------------------------------------------
# 5. two chain reads, taken before and after the refused update
# ------------------------------------------------------------------
# The executable reads another address's outputs only at a key-hash
# enterprise address, so a script address is out of reach (stated limit):
# the reads are the controller's wallet and the name's own output.
# canon RECEIPT KIND: the stable projection a chain read is compared by.
canon() {
  case "$2" in
    controller)
      jq -S -c '.outputsAt.outputs | sort_by(.output)' "$receipts/$1.json" >"$work/canon-$1.json"
      ;;
    key)
      jq -S -c '{leaf, root, applicationOutput, pendingRequests}' "$receipts/$1.json" >"$work/canon-$1.json"
      ;;
  esac
}
# read_controller SUFFIX: the controller wallet's outputs, with its receipt.
read_controller() {
  run "chain-controller-$1" success -- inspect --key "$key" --outputs-at "$alice_addr" "${common[@]}" "${node[@]}"
  [ "$(jq -r .outputsAt.address "$receipts/chain-controller-$1.json")" = "$alice_addr" ] \
    || fail "chain-controller-$1 read another address than the controller"
  canon "chain-controller-$1" controller
}
# read_key SUFFIX: the name's output with its datum and value, with its receipt.
read_key() {
  run "chain-key-$1" success -- inspect --key "$key" "${common[@]}" "${node[@]}"
  canon "chain-key-$1" key
}
read_controller before
read_key before
[ "$(jq 'length' "$work/canon-chain-controller-before.json")" -gt 0 ] \
  || fail "the controller's address holds nothing"
say "two chain reads: the controller's wallet and the name's output"

# ------------------------------------------------------------------
# 6. update is refused before anything is signed; the reads are equal
# ------------------------------------------------------------------
jq -n '{constructor:3, fields:[{bytes:"626f62"},{int:123456789012345678901234567890}]}' >"$work/payload-update.json"
refused update-refused client-refusal -- update --key "$key" \
  --payload "$work/payload-update.json" "${common[@]}" "${node[@]}" \
  --vault "$story/alice/alice.vault" --passphrase-fd 3 3<<<"$alice_pass"
jq -e --arg t "$state_token" '.reason | contains($t) and contains("is closed") and contains("written once")' \
  "$receipts/update-refused.json" >/dev/null \
  || fail "the refusal does not name the closed registry: $(field update-refused .reason)"
read_controller after
read_key after
cmp -s "$work/canon-chain-controller-before.json" "$work/canon-chain-controller-after.json" \
  || fail "the controller's address moved across the refused update"
cmp -s "$work/canon-chain-key-before.json" "$work/canon-chain-key-after.json" \
  || fail "the name's read moved across the refused update"
say "the refused update submitted nothing: the two chain reads are equal"

# ------------------------------------------------------------------
# 7. terminate books; the controller read differs, so it can see a submission
# ------------------------------------------------------------------
term_journal="$(managed_journal "$reg" "$state_token" "$alicekey")"
term_before="$(journal_count "$term_journal")"
files_before="$(local_files)"
story_vault terminate alice -- terminate --key "$key" "${common[@]}" "${node[@]}"
tail -n +"$((term_before + 1))" "$term_journal" \
  | jq -s -e '[.[] | select(.journalStep == "book") | .journalEvent] == ["waiting-for-signatures", "landed"] and all(.[]; .journalEvent | IN("waiting-for-signatures", "landed"))' >/dev/null \
  || fail "the vault termination did not leave exactly its waiting-for-signatures and landed lines"
[ "$(local_files)" = "$files_before" ] || fail "a vault termination created retired trie files"
booked_termination terminate
jq -e '(.custody | test("^[0-9a-f]{64}#[0-9]+$")) and (.deposit | type == "number" and . > 0) and (.transfer | type == "number" and . > 0)' \
  "$receipts/terminate.json" >/dev/null \
  || fail "the termination booking does not name the custody output it spends and the lovelace it transfers into the request"
# All of the custody value enters the request (the booking adds nothing of its own here):
# the lovelace transferred is the live holding's, read after the insert; the closed
# registry takes no update, so the holding is the one the insert delivered.
jq -e --slurpfile i "$receipts/inspect-active.json" '.transfer == $i[0].applicationOutput.lovelace' \
  "$receipts/terminate.json" >/dev/null \
  || fail "the booking did not move all of the custody value into the request: transfer $(field terminate .transfer), holding $(field inspect-active .applicationOutput.lovelace)"
read_controller booked
cmp -s "$work/canon-chain-controller-before.json" "$work/canon-chain-controller-booked.json" \
  && fail "the controller's reads cannot see the termination booking"
say "the controller read sees the booking"

# ------------------------------------------------------------------
# 8. the fold settles it and inspect reads terminal: the donation is bounded by the transfer
# ------------------------------------------------------------------
story_stage terminate-fold bob -- fold --request "$(field terminate .request)" \
  "${common[@]}" "${node[@]}"
story_settle terminate-fold bob
story_fold_ok terminate-fold terminate updateTerminal
[ "$(field terminate-fold .folder)" = "$bobkey" ] || fail "the termination was not folded with bob's key"
jq -e --slurpfile b "$receipts/terminate.json" \
  '(.settled | length == 1) and .settled[0].request == $b[0].request and .settled[0].edge == "updateTerminal"
    and .settled[0].settlement.terminated == $b[0].request
    and (.donation | type == "number") and .donation > 0 and .donation < $b[0].transfer' \
  "$receipts/terminate-fold.json" >/dev/null || fail "the fold does not settle the termination the booking named, with a donation strictly between nothing and the transfer"
run inspect-terminal success -- inspect --key "$key" --outputs-at "$alice_addr" "${common[@]}" "${node[@]}"
[ "$(field inspect-terminal .leaf)" = terminal ] || fail "the key is not terminal after the fold"
jq -e '.applicationOutput.absent' "$receipts/inspect-terminal.json" >/dev/null \
  || fail "the holding is still live"
say "the name is terminal; all of the custody entered the request and the fold donated within its bounds"

# ------------------------------------------------------------------
# 9. every step leaves a receipt
# ------------------------------------------------------------------
steps="closed-preview open-preview bob-preview create insert fold-staged fold inspect-active chain-controller-before chain-key-before update-refused chain-controller-after chain-key-after terminate chain-controller-booked terminate-fold-staged terminate-fold inspect-terminal"
for step in $steps; do
  [ -f "$receipts/$step.json" ] || fail "$step left no receipt"
  printf 'receipt %s: %s\n' "$step" "$(jq -r .outcome "$receipts/$step.json")"
done
[ -s "$receipts/describe-after-create.txt" ] || fail "the page read left no text receipt"
[ -s "$receipts/describe-after-create.json" ] || fail "the page read left no JSON receipt"
echo "receipt describe-after-create: success"
say "every step leaves a receipt"
say "JOURNEY-OK (closed-datum; $mode build evidence)"
