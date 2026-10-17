#!/usr/bin/env bash
# The registry writes' two staged signer modes, end to end on a fresh devnet,
# by the packaged commands only (#641).
#
# 1. Bob creates a registry naming only his address and a bundle file: exit
#    19, the bundle written. A second create from the same wallet, before
#    the first bundle is sent, is stopped at 19, naming the pending bundle.
#    Bob signs the bundle with `singular wallet sign` and sends it with
#    `singular submit`; `registry describe` then reads the registry.
# 2. Carol creates an open-datum registry with her key file (open-datum's
#    writes take only a key file until issue 642) and books a request in it
#    with `open-datum insert`.
# 3. Alice folds it from her vault, the passphrase through a descriptor: the
#    bundle is signed from the vault and sent through the submit core, every
#    member is journalled landed, and the receipt states the fold as fact.
# 4. Alice stages a fold of a second request and never sends it. Once the
#    request's processing deadline has passed, her next fold (of a third
#    request, from the vault) builds, and its receipt and her journal name
#    the unsent bundle dead: "expired, rebuild".
#
# usage: registry_bundle_control.sh SINGULAR OPEN_DATUM DEVNET VAULT_SEAL BLUEPRINT VERSION WORKDIR
#
# VERSION is the release's version.txt, laid beside the blueprint. VAULT_SEAL
# is the test-harness tool that seals a devnet key file into a
# vault; it is a tool, and nothing it prints is evidence. Every assertion
# reads receipts, the bundle files and the actors' own journals.
#
# Exit 0: the control holds. Exit 1: it does not, with the reason. Exit 3:
# setup failed before a checked step was reached; that is never a verdict.
set -euo pipefail

[ "$#" -eq 7 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM DEVNET VAULT_SEAL BLUEPRINT VERSION WORKDIR" >&2
  exit 2
}
singular="$1"
open_datum="$2"
devnet="$3"
vault_seal="$4"
blueprint_in="$5"
version_file="$6"
work="$7"
rm -rf "$work"
mkdir -p "$work"
receipts="$work/receipts"
mkdir -p "$receipts"
# The blueprint laid out as a release archive lays it out, its version label
# beside it, so `registry describe` reads the page as a user's archive does.
mkdir -p "$work/release"
cp "$blueprint_in" "$work/release/plutus.json"
cp "$version_file" "$work/release/version.txt"
blueprint="$work/release/plutus.json"
# shellcheck source=tools/managed_state.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/managed_state.sh"

fail() {
  echo "bundle-control: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "bundle-control: SETUP: $*" >&2
  exit 3
}
say() { echo "bundle-control: $*"; }

devnet_pid=""
# shellcheck disable=SC2329 # the EXIT trap invokes this
release_work() {
  local code=$?
  trap - EXIT
  if [ -n "${devnet_pid:-}" ]; then
    kill "$devnet_pid" 2>/dev/null || true
    wait "$devnet_pid" 2>/dev/null || true
  fi
  if [ -n "${work:-}" ] && [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
    echo "kept scratch: $work" >&2
  fi
  exit "$code"
}
trap release_work EXIT

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/bob.skey"
hexkey >"$work/alice.skey"
hexkey >"$work/carol.skey"
passphrase="$work/passphrase"
printf 'the control passphrase, never an argument\n' >"$passphrase"

export TMPDIR="$work"
[ "$((${#work} + 22))" -le 100 ] \
  || setup_fail "the work directory is too long for the node's socket path: $((${#work} + 22)) characters"

# The tool seals each devnet key into a vault, as `wallet create` would have.
"$vault_seal" "$work/bob.skey" "$work/bob.vault" <"$passphrase" \
  || setup_fail "the harness could not seal bob's key"
"$vault_seal" "$work/alice.skey" "$work/alice.vault" <"$passphrase" \
  || setup_fail "the harness could not seal alice's key"

"$devnet" --fund "$work/bob.skey:2:300000000" --fund "$work/alice.skey:3:300000000" \
  --fund "$work/carol.skey:2:300000000" --fund "$work/carol.skey:4:100000000" \
  >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
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
  setup_fail "the private devnet never printed usable provider/time settings"
fi
node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
say "one private development source at $provider_url"

exit_of() {
  case "$1" in
    success) echo 0 ;; client-refusal) echo 10 ;; ledger-refusal) echo 11 ;;
    node-unavailable) echo 12 ;; timeout) echo 13 ;; stale-state) echo 14 ;;
    partial) echo 15 ;; concurrent-writer) echo 16 ;; proof-missing) echo 17 ;;
    proof-inconsistent) echo 18 ;; waiting-for-signatures) echo 19 ;;
    *) fail "no exit status for class $1" ;;
  esac
}
field() { jq -r "$2" "$receipts/$1.json"; }
# run NAME WANT BIN -- ARGS...: the command's receipt in NAME.json, its
# exit status and outcome both the wanted class.
run() {
  local name="$1" want="$2" bin="$3"
  shift 3
  [ "${1:-}" = "--" ] && shift
  local status=0
  "$bin" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  local detail
  detail="$(jq -r .reason "$receipts/$name.json" 2>/dev/null || head -n 3 "$receipts/$name.err")"
  [ "$status" -eq "$(exit_of "$want")" ] || fail "$name: exit $status, wanted $want ($detail)"
  [ "$(jq -r .outcome "$receipts/$name.json")" = "$want" ] \
    || fail "$name: outcome $(jq -r .outcome "$receipts/$name.json"), wanted $want"
}
address_of() {
  "$singular" wallet address --vault "$1" --network-magic "$network_magic" --passphrase-fd 3 3<"$passphrase"
}
payload() {
  jq -n '{map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}' >"$1"
}
payload "$work/payload.json"

bob_addr="$(address_of "$work/bob.vault")" || setup_fail "bob's vault names no address"
alice_addr="$(address_of "$work/alice.vault")" || setup_fail "alice's vault names no address"
say "bob is $bob_addr, alice is $alice_addr, both from their vaults"

# ------------------------------------------------------------------
# 1. Bob creates with an external signer, is stopped once, signs and sends
# ------------------------------------------------------------------
# Bob's registry pins a fixed application policy, as `singular registry
# create` does for an application whose script does not depend on the
# registry; the open-datum registry the folds use is Carol's, below,
# because open-datum's own writes take only a key file (issue 642).
bob_dir="$work/bob"
policy="$(printf '07%.0s' {1..28})"
create_line=(registry create --process-time 120000 --retract-time 30000 --application-policy "$policy"
  --state-dir "$bob_dir" --blueprint "$blueprint" "${node[@]}" --wallet-address "$bob_addr")
run bob-create waiting-for-signatures "$singular" -- "${create_line[@]}" --bundle "$work/create.bundle"
[ -s "$work/create.bundle" ] || fail "bob's create wrote no bundle file"
create_hash="$(field bob-create .bundle.hash)"
bob_token="$(field bob-create .expected.stateToken)"
[ -n "$create_hash" ] && [ "$create_hash" != null ] || fail "bob's create receipt names no bundle"
[ -n "$bob_token" ] && [ "$bob_token" != null ] || fail "bob's create receipt names no state token under expected"
cmp -s "$work/create.bundle" "$(field bob-create .bundle.saved)" \
  || fail "the saved bundle beside bob's journal is not the bundle file"
say "on bob's neutral registry: his create wrote bundle $create_hash for token $bob_token, signing nothing"

run bob-create-again waiting-for-signatures "$singular" -- "${create_line[@]}" --bundle "$work/create-again.bundle"
[ "$(field bob-create-again .pendingBundle.hash)" = "$create_hash" ] \
  || fail "the second create was not stopped by the first one's bundle: $(field bob-create-again .reason)"
[ ! -e "$work/create-again.bundle" ] || fail "the stopped create wrote a bundle file"
say "on bob's neutral registry: a second create from his wallet is stopped at 19, naming bundle $create_hash"

"$singular" wallet sign --vault "$work/bob.vault" --passphrase-fd 3 --out "$work/create-witnesses" \
  "$work/create.bundle" 3<"$passphrase" >"$receipts/bob-sign.out" 2>"$receipts/bob-sign.err" \
  || fail "bob could not sign his bundle: $(head -n 2 "$receipts/bob-sign.err")"
run bob-submit success "$singular" -- submit --witnesses "$work/create-witnesses" "$work/create.bundle" "${node[@]}"
[ "$(field bob-submit .bundleHash)" = "$create_hash" ] || fail "bob's submission names another bundle"
jq -e 'all(.submissions[]; .how == "sent")' "$receipts/bob-submit.json" >/dev/null \
  || fail "bob's submission did not send every transaction"
"$singular" registry describe --blueprint "$blueprint" --state-token "$bob_token" "${node[@]}" --json \
  >"$receipts/bob-describe.json" 2>"$receipts/bob-describe.err" \
  || fail "the created registry cannot be described: $(head -n 2 "$receipts/bob-describe.err")"
say "on bob's neutral registry: he signed elsewhere, sent the bundle, and the registry reads back"

# ------------------------------------------------------------------
# 2. and 3. Carol creates and books; Alice folds from her vault
# ------------------------------------------------------------------
run carol-create success "$open_datum" -- create --process-time 120000 --retract-time 30000 \
  --state-dir "$work/carol" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$work/carol.skey"
token="$(field carol-create .stateToken)"
say "carol created the open-datum registry $token with her key file"
carol=(--state-dir "$work/carol" --blueprint "$blueprint" --state-token "$token" "${node[@]}"
  --wallet-skey "$work/carol.skey")
alice=(--state-dir "$work/alice" --blueprint "$blueprint" --state-token "$token" "${node[@]}")
run carol-insert-1 success "$open_datum" -- insert --key keyA --payload "$work/payload.json" "${carol[@]}"
request1="$(field carol-insert-1 .request)"
run alice-fold success "$singular" -- registry fold --request "$request1" "${alice[@]}" \
  --vault "$work/alice.vault" --passphrase-fd 3 3<"$passphrase"
jq -e 'has("expected") | not' "$receipts/alice-fold.json" >/dev/null \
  || fail "alice's landed fold still states its fields as expected"
jq -e '.bundle.hash and (.submissions | length > 0) and all(.submissions[]; .how == "sent")' \
  "$receipts/alice-fold.json" >/dev/null || fail "alice's fold receipt names no bundle sent in full"
fold_hash="$(field alice-fold .bundle.hash)"
alice_key="$(field alice-fold .folder)"
alice_journal="$(managed_journal "$work/alice" "$token" "$alice_key")"
[ -f "$alice_journal" ] || fail "alice's fold left no journal at $alice_journal"
for member in $(jq -r '.bundle.transactions[].identity' "$receipts/alice-fold.json"); do
  jq -se --arg m "$member" 'any(.[]; .journalTxId == $m and .journalEvent == "landed")' "$alice_journal" >/dev/null \
    || fail "alice's journal has no landed line for $member"
done
for secret in "$(head -n 1 "$passphrase")" "$(cat "$work/alice.skey")"; do
  ! grep -qF -- "$secret" "$receipts/alice-fold.json" "$alice_journal" \
    || fail "a secret of alice's vault appears in her receipt or journal"
done
say "on carol's open-datum registry: alice folded $request1 from her vault, bundle $fold_hash landed, no secret printed"

# ------------------------------------------------------------------
# 4. An unsent fold bundle dies past its deadline; the next fold builds
# ------------------------------------------------------------------
run carol-insert-2 success "$open_datum" -- insert --key keyB --payload "$work/payload.json" "${carol[@]}"
request2="$(field carol-insert-2 .request)"
deadline_ms="$(field carol-insert-2 .foldDeadline.posixMs)"
run alice-fold-staged waiting-for-signatures "$singular" -- registry fold --request "$request2" "${alice[@]}" \
  --wallet-address "$alice_addr" --bundle "$work/fold-unsent.bundle"
unsent_hash="$(field alice-fold-staged .bundle.hash)"
[ -s "$work/fold-unsent.bundle" ] || fail "alice's staged fold wrote no bundle file"
say "on carol's open-datum registry: alice staged bundle $unsent_hash for $request2 and does not send it"
for _ in $(seq 1 60); do
  [ "$(date +%s%3N)" -gt "$deadline_ms" ] && break
  sleep 5
done
[ "$(date +%s%3N)" -gt "$deadline_ms" ] || setup_fail "the request's processing deadline never passed"
run carol-insert-3 success "$open_datum" -- insert --key keyC --payload "$work/payload.json" "${carol[@]}"
request3="$(field carol-insert-3 .request)"
# The tip reaches the bound a little after the wall clock: until then the
# unsent bundle is pending, and the fold is stopped at 19 having built nothing.
stopped=0
next_status=19
for attempt in $(seq 1 24); do
  next_status=0
  "$singular" registry fold --request "$request3" "${alice[@]}" --vault "$work/alice.vault" \
    --passphrase-fd 3 3<"$passphrase" >"$receipts/alice-fold-next.json" 2>"$receipts/alice-fold-next.err" \
    || next_status=$?
  [ "$next_status" -eq 19 ] || break
  [ "$(field alice-fold-next .pendingBundle.hash)" = "$unsent_hash" ] \
    || fail "attempt $attempt was stopped by another bundle than $unsent_hash"
  stopped=$((stopped + 1))
  sleep 5
done
[ "$next_status" -eq 0 ] || fail "alice's next fold: exit $next_status ($(field alice-fold-next .reason))"
[ "$(field alice-fold-next .outcome)" = success ] || fail "alice's next fold did not succeed"
jq -e --arg h "$unsent_hash" 'any(.reconciled.bundles[]; .hash == $h and .state == "dead" and .reason == "expired, rebuild")' \
  "$receipts/alice-fold-next.json" >/dev/null \
  || fail "alice's next fold does not report bundle $unsent_hash dead (expired, rebuild)"
unsent_member="$(jq -r '.bundle.transactions[0].identity' "$receipts/alice-fold-staged.json")"
jq -se --arg m "$unsent_member" 'any(.[]; .journalTxId == $m and .journalEvent == "dead" and .journalDetail == "expired, rebuild")' \
  "$alice_journal" >/dev/null || fail "alice's journal has no dead line for $unsent_member"
say "on carol's open-datum registry: past its deadline the unsent bundle is dead (expired, rebuild) and the next fold built, after $stopped stop(s) at 19"

say "bundle control: PASS"
