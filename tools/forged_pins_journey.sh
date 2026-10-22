#!/usr/bin/env bash
# The forged-pins journey (#730): a registry whose datum pins a policy the
# release does not derive is refused by every command of the packaged programs,
# on a real development network, and an honest registry made the same way
# proceeds through the same commands.
#
# usage: forged_pins_journey.sh SINGULAR OPEN_DATUM HARNESS DEVNET VAULT_SEAL \
#          BLUEPRINT VERSION READER_VIEW WORKDIR
#
# SINGULAR, OPEN_DATUM, HARNESS, DEVNET and VAULT_SEAL are executables; BLUEPRINT
# is the open-datum deployment blueprint and VERSION the release's version file;
# READER_VIEW is the program that reads the chain independently of every command
# (tools/forged_pins_reader_view.py); WORKDIR is the run's scratch. ONE
# development node is started once, funding one generated wallet, and every
# command is a separate process of a packaged binary against it.
#
# The legs, in this order, each recorded in WORKDIR/legs.tsv with its verdict:
#
#   forged-registry-made        the harness boots a registry whose datum pins the
#                               always-true script as its active policy and mints
#                               a token named alice under it; the chain, read
#                               through the facade's independent record, shows a
#                               datum-trusting reader that token under that policy
#   honest-registry-made        the same boot with the honest active pin
#   forged-registry-refused     singular inspect, describe, fold, reject, reclaim
#                               and submit, open-datum inspect, insert, update,
#                               terminate and fold: each ends in the refusal naming
#                               the active policy, prints no registry content and
#                               adds no transaction to the chain
#   honest-registry-proceeds    the same commands on the honest registry proceed
#   genuine-witness-evidence    whether the honest witness policy of the forged
#                               registry can be minted in a fold of that registry:
#                               recorded whatever the answer
#   fold-cannot-alter-a-pin     a fold that swaps the active pin in the new state
#                               datum is refused by the node; the same fold without
#                               the swap is accepted
#   assertions-can-fail         each assertion above, run on altered input, fails
#
# The number of transactions on the chain is read from the facade's own record of
# every block, never from a command's receipt. A run with FORGED_PINS_SURVEY=1
# records every verdict and continues past a failure: the run against the
# binaries of an older revision, which shows which legs those binaries already
# answer. FORGED_PINS_SUBMIT_TAKES_NO_RELEASE=1 leaves out the
# release flag of singular submit, which a revision from before that gate does not
# have. Setup failures (no node, no provider) exit 3, never as a result.
# shellcheck disable=SC2016 # single quotes keep each jq program's variables for jq
set -euo pipefail

[ "$#" -eq 9 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM HARNESS DEVNET VAULT_SEAL BLUEPRINT VERSION READER_VIEW WORKDIR" >&2
  exit 2
}
singular="$1"
open_datum="$2"
harness="$3"
devnet="$4"
vault_seal="$5"
blueprint_source="$6"
version_source="$7"
reader_view="$8"
work="$9"
survey="${FORGED_PINS_SURVEY:-0}"

rm -rf "$work"
mkdir -p "$work/receipts" "$work/release" "$work/state"
receipts="$work/receipts"
legs="$work/legs.tsv"
: >"$legs"

say() { echo "forged-pins journey: $*"; }
fail() {
  echo "forged-pins journey: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "forged-pins journey: SETUP: $*" >&2
  exit 3
}

# The pids of this run's own node: the one whose config directory is this run's
# cardano-e2e. Only these pids, found under this run's unique scratch, are ever
# signalled.
node_pids() {
  pgrep -f "cardano-node run --config $work/cardano-e2e" 2>/dev/null || true
}

release_work() {
  local code=$?
  local pid _wait
  trap - EXIT
  [ -n "${devnet_pid:-}" ] && kill "$devnet_pid" 2>/dev/null || true
  for pid in $(node_pids); do
    kill "$pid" 2>/dev/null || true
  done
  for _wait in $(seq 1 100); do
    [ -z "$(node_pids)" ] && break
    sleep 0.1
  done
  # The facade's record of the chain is large and is read only while the node
  # runs; the receipts keep what was read from it.
  rm -rf "$work"/private-facade-sources-* "$work/cardano-e2e" || true
  if [ -e "$work/cardano-e2e" ]; then
    echo "forged-pins journey: scratch remains: $work/cardano-e2e" >&2
    code=1
  fi
  exit "$code"
}

export TMPDIR="$work"

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/alice.skey"

"$devnet" --fund-skey "$work/alice.skey" --fund-outputs 8 --fund-lovelace 2000000000 \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
trap release_work EXIT

provider_url=""
time_directory=""
network_magic=""
probe_socket=""
evidence_directory=""
for _ in $(seq 1 900); do
  settings="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  probe_socket="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
  provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
  time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
  network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
  evidence_directory="$(jq -er '.independentSourceDirectory' <<<"$settings" 2>/dev/null || true)"
  [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$probe_socket" ] \
    && [ -r "$time_directory/time-manifest.json" ] && [ -n "$evidence_directory" ] && break
  kill -0 "$devnet_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -S "$probe_socket" ] \
  || [ ! -r "$time_directory/time-manifest.json" ] || [ -z "$evidence_directory" ]; then
  tail -40 "$work/devnet.err" >&2 || true
  setup_fail "the private devnet never printed usable provider, time, probe and record settings"
fi
evidence="$evidence_directory/independent-facade-sources.jsonl"
say "one private development source at $provider_url; the chain's own record is read from $evidence"

# The release as an archive lays it: the blueprint as plutus.json with the
# version file beside it.
cp "$blueprint_source" "$work/release/plutus.json"
cp "$version_source" "$work/release/version.txt"
blueprint="$work/release/plutus.json"

node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
release=(--blueprint "$blueprint")
state=(--state-dir "$work/state")
alice=(--wallet-skey "$work/alice.skey")
harness_flags=("${node[@]}" "${alice[@]}" "${release[@]}")
# 'singular submit' takes the release a bundle that names a registry was created
# under; a revision from before that gate has no such flag.
submit_release=("${release[@]}")
[ "${FORGED_PINS_SUBMIT_TAKES_NO_RELEASE:-0}" = 1 ] && submit_release=()

# ------------------------------------------------------------------
# What the chain says, read independently of every command
# ------------------------------------------------------------------

chain_blocks() { grep -c '"kind":"chain-sync-full-block"' "$evidence" || true; }

# Wait until the chain has moved on by a few blocks, so that a transaction a
# command sent just before it exited is in the record before it is counted.
settle() {
  local start
  start="$(chain_blocks)"
  for _ in $(seq 1 600); do
    [ "$(chain_blocks)" -ge $((start + 4)) ] && return 0
    sleep 0.5
  done
  setup_fail "the chain produced no further block"
}

# The transactions on the chain: every block's own list, summed. Empty blocks
# are filtered out first only to keep the count fast.
chain_transactions() {
  settle
  { grep '"kind":"chain-sync-full-block"' "$evidence" || true; } \
    | { grep -v '"transactions":\[\]' || true; } \
    | jq -c '.block.transactions | length' \
    | awk '{ total += $1 } END { print total + 0 }'
}

# The chain does not hold this transaction (the node refused it).
chain_lacks_transaction() { ! chain_has_transaction "$1"; }

# The chain holds this transaction as one of its own.
chain_has_transaction() {
  settle
  { grep '"kind":"chain-sync-full-block"' "$evidence" || true; } \
    | { grep -F "\"tx_hash\":\"$1\"" || true; } \
    | jq -e --arg id "$1" '.block.transactions[] | select(.material.tx_hash == $id)' >/dev/null 2>&1
}

# ------------------------------------------------------------------
# Assertions, as functions of files and numbers so that a control can
# hand each one altered input
# ------------------------------------------------------------------

failures=0

# check LEG WHAT COMMAND...: the verdict is recorded; a strict run stops at the
# first failure.
check() {
  local leg="$1" what="$2"
  shift 2
  if "$@" >/dev/null; then
    printf '%s\tPASS\t%s\n' "$leg" "$what" >>"$legs"
    say "PASS [$leg] $what"
  else
    printf '%s\tFAIL\t%s\n' "$leg" "$what" >>"$legs"
    say "FAIL [$leg] $what"
    failures=$((failures + 1))
    [ "$survey" = 1 ] || exit 1
  fi
}

# observed LEG TEXT: what a run saw where it is not a verdict.
observed() { printf '%s\tSEEN\t%s\n' "$1" "$2" >>"$legs"; }

# run NAME COMMAND...: one process; its standard output, standard error and exit
# status are kept under the receipts.
run() {
  local name="$1" status=0
  shift
  timeout 900 "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" </dev/null || status=$?
  printf '%s\n' "$status" >"$receipts/$name.status"
}

status_is() { [ "$(cat "$receipts/$1.status")" = "$2" ]; }
numbers_equal() { [ "$1" = "$2" ]; }
number_is_greater() { [ "$1" -gt "$2" ]; }

# The receipt is the refusal naming this pinned policy.
receipt_is_pin_refusal() {
  jq -e --arg field "$2" \
    '.outcome == "client-refusal"
     and (.reason | type == "string" and startswith("registry-pin-mismatch " + $field + ":"))' \
    "$1" >/dev/null 2>&1
}

# The receipt and the narration show nothing of the registry: the receipt holds
# only the command, the outcome, the reason and an empty list of submissions,
# and none of the registry's pinned policies is spelled in either.
receipt_has_no_registry_content() {
  jq -e '(keys - ["cause", "command", "outcome", "reason", "submissions"]) == []
         and ((.submissions // []) | length == 0)' "$1" >/dev/null 2>&1 \
    && ! grep -q -F -f "$3" "$1" "$2"
}

# The receipt names this outcome (a command that proceeded).
receipt_outcome_is() { jq -e --arg want "$2" '.outcome == $want' "$1" >/dev/null 2>&1; }

# The receipt is not the pin refusal and not a usage error: the command got
# past the registry's identity and said something of its own.
receipt_went_past_the_gate() {
  jq -e '(.reason // "") | startswith("registry-pin-mismatch") | not' "$1" >/dev/null 2>&1 \
    && jq -e 'has("outcome")' "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------
# 1. The forged registry and the honest one
# ------------------------------------------------------------------

run boot-forged "$harness" boot --mode forged "${harness_flags[@]}"
[ "$(cat "$receipts/boot-forged.status")" = 0 ] || {
  tail -20 "$receipts/boot-forged.err" >&2
  setup_fail "the harness could not boot the forged registry"
}
forged_token="$(jq -er .stateToken "$receipts/boot-forged.json")"
forged_policy="$(jq -er .forgedActivePolicy "$receipts/boot-forged.json")"
honest_active_of_forged="$(jq -er .honestActivePolicy "$receipts/boot-forged.json")"
wallet_address="$(jq -er .walletAddress "$receipts/boot-forged.json")"
say "forged registry $forged_token pins active policy $forged_policy"

key="alice"
key_hex="$(printf '%s' "$key" | od -An -tx1 | tr -d ' \n')"
run mint "$harness" mint --key "$key" "${harness_flags[@]}"
[ "$(cat "$receipts/mint.status")" = 0 ] || {
  tail -20 "$receipts/mint.err" >&2
  setup_fail "the harness could not mint under the forged policy"
}
minted_output="$(jq -er .output "$receipts/mint.json")"

run boot-honest "$harness" boot --mode genuine "${harness_flags[@]}"
[ "$(cat "$receipts/boot-honest.status")" = 0 ] || {
  tail -20 "$receipts/boot-honest.err" >&2
  setup_fail "the harness could not boot the honest registry"
}
honest_token="$(jq -er .stateToken "$receipts/boot-honest.json")"
say "honest registry $honest_token"

# The pinned policies of the forged registry, and the honest one's: what no
# refusal may print, and what a shown page does print.
jq -r '.pins[], .forgedActivePolicy, .honestActivePolicy' "$receipts/boot-forged.json" | sort -u >"$work/forged-pins.txt"
jq -r '.pins[]' "$receipts/boot-honest.json" | sort -u >"$work/honest-pins.txt"

# What a reader that trusts the datum sees: the chain's own record, with no
# command of this journey in the way.
read_chain() {
  settle
  { grep '"kind":"chain-sync-full-block"' "$evidence" || true; } \
    | { grep -v '"transactions":\[\]' || true; } \
    | python3 -I "$reader_view" "${forged_token%%.*}" "${forged_token##*.}" "$key_hex"
}
read_chain >"$receipts/reader-view.json" || setup_fail "the reader view could not read the chain's record"
"$devnet" probe --node-socket "$probe_socket" --network-magic "$network_magic" --tx-in "$minted_output" \
  >"$receipts/token-probe.json" 2>/dev/null </dev/null || setup_fail "the node probe failed"

check forged-registry-made "the datum, read from the chain's own record, pins the always-true policy as the active policy" \
  jq -e --arg forged "$forged_policy" '.pins.active == $forged' "$receipts/reader-view.json"
check forged-registry-made "the datum's other pinned policies are the honest derivation for this registry" \
  jq -e --slurpfile boot "$receipts/boot-forged.json" \
  '.pins.application == $boot[0].pins.pinApplication and .pins.absent == $boot[0].pins.pinAbsent and .pins.terminal == $boot[0].pins.pinTerminal and .pins.active != $boot[0].honestActivePolicy' \
  "$receipts/reader-view.json"
check forged-registry-made "a token named alice under the datum's active policy is on the chain at the wallet" \
  jq -e --arg address "$wallet_address" --arg output "$minted_output" \
  '.tokens | length == 1 and .[0].assetName == "616c696365" and .[0].address == $address and .[0].output == $output' \
  "$receipts/reader-view.json"
check forged-registry-made "the node says that token's output is unspent" \
  jq -e --arg output "$minted_output" '.live | index($output) != null' "$receipts/token-probe.json"
check honest-registry-made "the honest registry is a registry of the same state policy as the forged one" \
  test "${forged_token%%.*}" = "${honest_token%%.*}"

# ------------------------------------------------------------------
# 2. The forged registry, refused by every command
# ------------------------------------------------------------------

bogus_request="0000000000000000000000000000000000000000000000000000000000000000#0"
printf '%s\n' '{"owner": "mallory"}' >"$work/payload.json"
printf '%s\n' '{"owner": "mallory", "version": 2}' >"$work/payload-two.json"

# refused_everywhere NAME PINS COMMAND...: the command runs on a forged registry
# and must end in the refusal that names the active policy, show nothing of the
# registry (none of the policies in the PINS file is spelled), and add no
# transaction to the chain.
refused_everywhere() {
  local name="$1" pins="$2" before after
  shift 2
  before="$(chain_transactions)"
  run "$name" "$@"
  after="$(chain_transactions)"
  observed forged-registry-refused "$name: exit $(cat "$receipts/$name.status"), $(jq -r '[.outcome // "no outcome", (.reason // "" | .[0:70])] | join(": ")' "$receipts/$name.json" 2>/dev/null || echo "no receipt"), chain $before -> $after"
  check forged-registry-refused "$name ends with the client refusal status" status_is "$name" 10
  check forged-registry-refused "$name is the refusal naming the active policy" receipt_is_pin_refusal "$receipts/$name.json" active
  check forged-registry-refused "$name shows nothing of the registry" \
    receipt_has_no_registry_content "$receipts/$name.json" "$receipts/$name.err" "$pins"
  check forged-registry-refused "$name adds no transaction to the chain" numbers_equal "$before" "$after"
}

forged=(--state-token "$forged_token")
refused_everywhere forged-singular-inspect "$work/forged-pins.txt" "$singular" registry inspect --key "$key" "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
refused_everywhere forged-singular-inspect-wallet "$work/forged-pins.txt" "$singular" registry inspect --key "$key" --wallet-address "$wallet_address" \
  "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
refused_everywhere forged-singular-describe "$work/forged-pins.txt" "$singular" registry describe "${forged[@]}" "${node[@]}" "${release[@]}"
refused_everywhere forged-singular-fold "$work/forged-pins.txt" "$singular" registry fold "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
refused_everywhere forged-singular-reject "$work/forged-pins.txt" "$singular" registry reject "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
refused_everywhere forged-singular-reclaim "$work/forged-pins.txt" "$singular" registry reclaim --request "$bogus_request" \
  "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
refused_everywhere forged-open-datum-inspect "$work/forged-pins.txt" "$open_datum" inspect --key "$key" "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
refused_everywhere forged-open-datum-insert "$work/forged-pins.txt" "$open_datum" insert --key "$key" --payload "$work/payload.json" \
  "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
refused_everywhere forged-open-datum-update "$work/forged-pins.txt" "$open_datum" update --key "$key" --payload "$work/payload-two.json" \
  "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
refused_everywhere forged-open-datum-terminate "$work/forged-pins.txt" "$open_datum" terminate --key "$key" \
  "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
refused_everywhere forged-open-datum-fold "$work/forged-pins.txt" "$open_datum" fold "${forged[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"

# The registry named by its address, the one word create prints, in place of the
# state token: the address decodes to the same token before any command runs, so
# the gate must still run first. The address is made offline from the token.
run forged-address "$singular" registry address "${forged[@]}" --network-magic "$network_magic"
forged_address="$(jq -er .registry "$receipts/forged-address.json")" \
  || setup_fail "the address of the forged registry could not be made"
by_address=(--registry "$forged_address")
refused_everywhere forged-singular-inspect-by-address "$work/forged-pins.txt" "$singular" registry inspect --key "$key" \
  "${by_address[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
refused_everywhere forged-singular-describe-by-address "$work/forged-pins.txt" "$singular" registry describe \
  "${by_address[@]}" "${node[@]}" "${release[@]}"
refused_everywhere forged-open-datum-inspect-by-address "$work/forged-pins.txt" "$open_datum" inspect --key "$key" \
  "${by_address[@]}" "${node[@]}" "${release[@]}" "${state[@]}"

# A forged registry of open-datum's closed mode: its datum pins the closed
# application and the always-true active policy. An update on a registry the
# datum classes as closed used to be answered with the closed text before any
# pin was compared; now the pin refusal comes first, with or without a preview.
run boot-forged-closed "$harness" boot --mode forged --application closed "${harness_flags[@]}"
[ "$(cat "$receipts/boot-forged-closed.status")" = 0 ] || {
  tail -20 "$receipts/boot-forged-closed.err" >&2
  setup_fail "the harness could not boot the forged closed registry"
}
forged_closed_token="$(jq -er .stateToken "$receipts/boot-forged-closed.json")"
jq -r '.pins[], .forgedActivePolicy, .honestActivePolicy' "$receipts/boot-forged-closed.json" | sort -u >"$work/forged-closed-pins.txt"
forged_closed=(--state-token "$forged_closed_token")
refused_everywhere forged-closed-open-datum-inspect "$work/forged-closed-pins.txt" "$open_datum" inspect --key "$key" \
  "${forged_closed[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
refused_everywhere forged-closed-open-datum-update "$work/forged-closed-pins.txt" "$open_datum" update --key "$key" \
  --payload "$work/payload-two.json" "${forged_closed[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
refused_everywhere forged-closed-open-datum-update-preview "$work/forged-closed-pins.txt" "$open_datum" update --key "$key" \
  --payload "$work/payload-two.json" --preview --wallet-address "$wallet_address" \
  "${forged_closed[@]}" "${node[@]}" "${release[@]}" "${state[@]}"

# The bundle: made for the honest registry by an external signer's run, signed
# in the wallet's vault, and then given the forged registry's name, which is its
# writer's statement. It is built here and not earlier because a bundle that
# waits for signatures stops the next write of its registry by the same wallet.
honest=(--state-token "$honest_token")
passphrase="journey-passphrase"
printf '%s\n' "$passphrase" | "$vault_seal" "$work/alice.skey" "$work/vault" \
  || setup_fail "the vault could not be sealed"
run bundle-made "$open_datum" insert --key bundle-key --payload "$work/payload.json" --wallet-address "$wallet_address" \
  --bundle "$work/bundle-honest.json" "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
[ "$(cat "$receipts/bundle-made.status")" = 19 ] || {
  tail -5 "$receipts/bundle-made.json" >&2
  setup_fail "the bundle was not made"
}
jq --arg token "$forged_token" '.stateToken = $token' "$work/bundle-honest.json" >"$work/bundle-forged.json"
printf '%s\n' "$passphrase" | timeout 300 "$singular" wallet sign --vault "$work/vault" --passphrase-fd 0 \
  --out "$work/witnesses" "$work/bundle-honest.json" >"$receipts/bundle-signed.json" 2>"$receipts/bundle-signed.err" \
  || setup_fail "the bundle could not be signed"
refused_everywhere forged-singular-submit "$work/forged-pins.txt" "$singular" submit --witnesses "$work/witnesses" "${node[@]}" "${submit_release[@]}" "$work/bundle-forged.json"

# The same bundle under the honest registry's own name: past the gate it is sent, and lands.
bundle_before="$(chain_transactions)"
run honest-singular-submit "$singular" submit --witnesses "$work/witnesses" "${node[@]}" "${submit_release[@]}" "$work/bundle-honest.json"
bundle_after="$(chain_transactions)"
check honest-registry-proceeds "singular submit sends the bundle that names the honest registry" \
  receipt_outcome_is "$receipts/honest-singular-submit.json" success
check honest-registry-proceeds "the chain's own record shows that bundle's transaction" \
  number_is_greater "$bundle_after" "$bundle_before"

# ------------------------------------------------------------------
# 3. The honest registry, through the same commands
# ------------------------------------------------------------------

# proceeds NAME COMMAND...: the command runs on the honest registry; it must
# succeed, and the chain's own record must show how many transactions it added.
proceeds() {
  local name="$1" before after added
  shift
  before="$(chain_transactions)"
  run "$name" "$@"
  after="$(chain_transactions)"
  added=$((after - before))
  check honest-registry-proceeds "$name succeeds" receipt_outcome_is "$receipts/$name.json" success
  printf '%s\n' "$added" >"$receipts/$name.added"
}

proceeds honest-singular-inspect "$singular" registry inspect --key "$key" "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
check honest-registry-proceeds "singular inspect prints the registry's root and no refusal" \
  jq -e '.command == "inspect" and (.root | type == "string") and (has("reason") | not)' "$receipts/honest-singular-inspect.json"
proceeds honest-singular-describe "$singular" registry describe "${honest[@]}" "${node[@]}" "${release[@]}"
check honest-registry-proceeds "singular describe prints the registry page with this registry's pinned policies" \
  jq -e --arg token "$honest_token" '.registry.stateToken == $token and (.registry.activeScript | type == "string")' "$receipts/honest-singular-describe.json"
check assertions-can-fail "the search for a registry's pinned policies in an output finds them where a page shows them" \
  grep -q -F -f "$work/honest-pins.txt" "$receipts/honest-singular-describe.json"
proceeds honest-open-datum-inspect "$open_datum" inspect --key "$key" "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
proceeds honest-open-datum-insert "$open_datum" insert --key "$key" --payload "$work/payload.json" \
  "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
check honest-registry-proceeds "open-datum insert is accepted: the chain's own record shows its booking" \
  number_is_greater "$(cat "$receipts/honest-open-datum-insert.added")" 0

# reject and reclaim have nothing the registry owes yet: each answers with its
# own refusal, which is the proof that it got past the registry's identity.
run honest-singular-reject "$singular" registry reject "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
check honest-registry-proceeds "singular reject reaches the registry's requests: a pending request is still inside its window" \
  receipt_went_past_the_gate "$receipts/honest-singular-reject.json"
check honest-registry-proceeds "singular reject names the pending request, which only a resolved registry has" \
  jq -e '.reason | test("pending request")' "$receipts/honest-singular-reject.json"
run honest-singular-reclaim "$singular" registry reclaim --request "$bogus_request" \
  "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
check honest-registry-proceeds "singular reclaim reaches the registry's requests: the named request is not pending" \
  jq -e '.reason | test("not pending")' "$receipts/honest-singular-reclaim.json"
proceeds honest-singular-fold "$singular" registry fold "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
check honest-registry-proceeds "singular fold settles the booked key's insertion" \
  jq -e --arg key "$key_hex" '.settled | map(.key) | index($key) != null' "$receipts/honest-singular-fold.json"
run honest-open-datum-active "$open_datum" inspect --key "$key" "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
check honest-registry-proceeds "open-datum inspect reads the key active after the fold" \
  jq -e '.leaf == "active"' "$receipts/honest-open-datum-active.json"
proceeds honest-open-datum-update "$open_datum" update --key "$key" --payload "$work/payload-two.json" \
  "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
proceeds honest-open-datum-terminate "$open_datum" terminate --key "$key" \
  "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
proceeds honest-open-datum-fold "$open_datum" fold "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}" "${alice[@]}"
run honest-open-datum-terminal "$open_datum" inspect --key "$key" "${honest[@]}" "${node[@]}" "${release[@]}" "${state[@]}"
check honest-registry-proceeds "open-datum inspect reads the key terminal after the termination's fold" \
  jq -e '.leaf == "terminal"' "$receipts/honest-open-datum-terminal.json"

# ------------------------------------------------------------------
# 4. Evidence for the on-chain hardening: the honest witness policy of the
#    forged registry, minted in a fold of that registry
# ------------------------------------------------------------------

forged_seed="$(jq -er .seed "$receipts/boot-forged.json")"
run fold-evidence "$harness" fold-evidence --seed "$forged_seed" "${harness_flags[@]}"
[ "$(cat "$receipts/fold-evidence.status")" = 0 ] || {
  tail -20 "$receipts/fold-evidence.err" >&2
  setup_fail "the harness could not build the evidence folds"
}
for answer in honestInsteadOfPinned pinnedAndHonestBeside; do
  outcome="$(jq -er --arg a "$answer" '.[$a].outcome' "$receipts/fold-evidence.json")"
  transaction="$(jq -r --arg a "$answer" '.[$a].transaction // ""' "$receipts/fold-evidence.json")"
  observed genuine-witness-evidence "$answer: $outcome $transaction"
  check genuine-witness-evidence "$answer has an answer recorded" \
    jq -e --arg a "$answer" '.[$a].outcome | IN("accepted", "refused", "not-submitted")' "$receipts/fold-evidence.json"
  case "$outcome" in
    accepted) check genuine-witness-evidence "$answer: the chain's own record holds the fold the node accepted" chain_has_transaction "$transaction" ;;
    refused) check genuine-witness-evidence "$answer: the chain's own record does not hold the fold the node refused" \
      chain_lacks_transaction "$transaction" ;;
  esac
done
{ read_chain || true; } >"$receipts/reader-view-after-evidence.json"
check genuine-witness-evidence "the reader view lists what the chain holds under the honest witness policy named alice" \
  jq -e --arg honest "$honest_active_of_forged" --arg outcome "$(jq -r .pinnedAndHonestBeside.outcome "$receipts/fold-evidence.json")" \
  '(([.namedAfterTheKey[] | select(.policy == $honest)] | length) == 1) == ($outcome == "accepted")' \
  "$receipts/reader-view-after-evidence.json"

# ------------------------------------------------------------------
# 5. A fold cannot alter a pinned policy
# ------------------------------------------------------------------

run fold-altering-a-pin "$harness" fold-altering-a-pin "${harness_flags[@]}"
[ "$(cat "$receipts/fold-altering-a-pin.status")" = 0 ] || {
  tail -20 "$receipts/fold-altering-a-pin.err" >&2
  setup_fail "the harness could not build the pin-altering fold"
}
altering="$receipts/fold-altering-a-pin.json"
altering_state_hash="$(jq -er '.stateToken | split(".")[0]' "$altering")"
check fold-cannot-alter-a-pin "the node refuses the fold that swaps the active pin" \
  jq -e '.alteredPin.outcome == "refused"' "$altering"
check fold-cannot-alter-a-pin "the node names the state script as the script that failed it" \
  jq -e --arg hash "$altering_state_hash" '.alteredPin.answer | test("script hash is:ScriptHash [^0-9a-f]*" + $hash) and test("SpendingScript")' "$altering"
check fold-cannot-alter-a-pin "the chain's own record does not hold the refused fold" \
  chain_lacks_transaction "$(jq -er .alteredPin.transaction "$altering")"
check fold-cannot-alter-a-pin "the same fold without the swap is accepted" \
  jq -e '.unalteredFold.outcome == "accepted"' "$altering"
check fold-cannot-alter-a-pin "the chain's own record holds the accepted fold" \
  chain_has_transaction "$(jq -er .unalteredFold.transaction "$altering")"
check fold-cannot-alter-a-pin "the same fold with an extra mint under the registry's own active policy does not evaluate" \
  jq -e '.extraMintOnHonestRegistry.outcome != "accepted"' "$altering"
observed fold-cannot-alter-a-pin "the deployed scripts carry no trace: the node's answer names the failing script, not the check; the check is named by the contract's own tests of the same alteration"

# ------------------------------------------------------------------
# 6. The assertions, each shown failing on altered input
# ------------------------------------------------------------------

# control WHAT COMMAND...: the assertion is handed input it must refuse.
control() {
  local what="$1"
  shift
  if "$@" >/dev/null; then
    printf '%s\tFAIL\t%s\n' assertions-can-fail "control: $what passed on altered input" >>"$legs"
    say "FAIL [assertions-can-fail] control: $what passed on altered input"
    failures=$((failures + 1))
    [ "$survey" = 1 ] || exit 1
  else
    printf '%s\tPASS\t%s\n' assertions-can-fail "control: $what failed on altered input, as it must" >>"$legs"
    say "PASS [assertions-can-fail] control: $what failed on altered input, as it must"
  fi
}

forged_receipt="$receipts/forged-open-datum-inspect.json"
forged_narration="$receipts/forged-open-datum-inspect.err"
# a refusal that shows the registry's root
jq '. + {root: "0000000000000000000000000000000000000000000000000000000000000000"}' "$forged_receipt" >"$work/control-root.json"
# a refusal that spells a pinned policy of the registry in its narration
{
  cat "$forged_narration"
  head -n1 "$work/forged-pins.txt"
} >"$work/control-narration.err"
# a refusal that names another pinned policy
control "the check of the policy a refusal names, given another policy" receipt_is_pin_refusal "$forged_receipt" absent
# the same command altered to name the honest registry
control "the check of the policy a refusal names, given the receipt of a command that names the honest registry" \
  receipt_is_pin_refusal "$receipts/honest-open-datum-inspect.json" active
control "the check of the exit status, given the status of a command that proceeded" status_is honest-open-datum-inspect 10
control "the check that a refusal shows nothing, given a refusal that shows the root" \
  receipt_has_no_registry_content "$work/control-root.json" "$forged_narration" "$work/forged-pins.txt"
control "the check that a refusal shows nothing, given narration that spells a pinned policy" \
  receipt_has_no_registry_content "$forged_receipt" "$work/control-narration.err" "$work/forged-pins.txt"
control "the check that no transaction was added, given a count that moved" numbers_equal 31 32
control "the check that a command proceeded, given a refusal" receipt_outcome_is "$forged_receipt" success
control "the check that a command got past the registry's identity, given the pin refusal" \
  receipt_went_past_the_gate "$forged_receipt"
control "the independent record of the chain, asked for a transaction that was never sent" \
  chain_has_transaction "0000000000000000000000000000000000000000000000000000000000000001"

echo
echo "forged-pins journey: verdicts"
awk -F'\t' '{ print "  " $2 "\t[" $1 "]\t" $3 }' "$legs"
[ "$failures" -eq 0 ] || fail "$failures assertions failed"
say "the forged registry is refused by every command, the honest one proceeds through the same commands, and each assertion fails when its input is altered"
