#!/usr/bin/env bash
# Carol funds a fresh wallet with one ada-only output and runs create (#406).
# The story is the command with no seed flag. Each chained leg runs in a
# state where no carrier of the state script exists on the chain, and asserts
# the preview's `seedFrom` equals `publication-change` (on base the field is
# absent, so the leg is red; with a carrier present the chained claim cannot
# hold). One fresh devnet cannot hold every chained leg: the first successful
# create publishes the carrier, so the sub-script starts its devnet again for
# the next leg; the legs are ordered Gina, then pin, then Hank, each on its
# own fresh devnet with no carrier anywhere. Grace's reused-carrier legs
# (seedFrom `output`) live in the main journey, where Alice already published
# the carrier.
#
# usage: demo1_cli_one_output_create.sh SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR
#
# SINGULAR, OPEN_DATUM and DEVNET are executables; BLUEPRINT is the registry
# partition's plutus.json. Gina (one 200 tADA output) previews null and
# completes with no flag, naming the previewed token and the first
# publication's change as its seed; the pin pair on a second fresh wallet
# shows `--seed <previewed>` succeeds unchanged and is refused on a fresh
# directory after the wallet moved (no journal, no pending, moved output
# unspent); HankA (one 5 tADA output, below the first publication, which needs
# 53698530) previews with null seed fields and is refused with one verdict,
# HankB (one 105 tADA output, covering the first but not the whole run, which
# needs at least 162649217) previews the chained seed with one verdict; both
# in preview and in create, key and public previews agreeing.
# Every assertion reads receipts, the target directory's own journal and
# files, and the chain probe — never a typed value.
#
# Exit 0: the control holds. Exit 1: it does not, with the reason. Exit 3:
# setup failed before the target check was reached; that is never a verdict.
set -euo pipefail

[ "$#" -eq 5 ] || {
  echo "usage: $0 SINGULAR OPEN_DATUM DEVNET BLUEPRINT WORKDIR" >&2
  exit 2
}
singular="$1"
open_datum="$2"
devnet="$3"
blueprint="$4"
work="$5"
: "$singular"
rm -rf "$work"
mkdir -p "$work"
# Every setting the later commands use comes from the settings file or the
# command line below, never from a variable of this shell (#717).
unset SINGULAR_CONFIG SINGULAR_STATE_TOKEN SINGULAR_BLUEPRINT SINGULAR_KOIOS_URL SINGULAR_NETWORK_MAGIC SINGULAR_NETWORK_TIME SINGULAR_STATE_DIR
receipts="$work/receipts"
mkdir -p "$receipts"
# shellcheck source=tools/managed_state.sh
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
source "$(dirname "$0")/managed_state.sh"

fail() {
  echo "one-output-create: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "one-output-create: SETUP: $*" >&2
  exit 3
}
say() { echo "one-output-create: $*"; }

# The node of the current leg, if any. `release_work` (EXIT trap) stops it;
# `stop_devnet` stops it between legs and wipes the chain, keeping receipts,
# wallets and state directories.
devnet_pid=""
stop_devnet() {
  if [ -n "${devnet_pid:-}" ]; then
    kill "$devnet_pid" 2>/dev/null || true
    wait "$devnet_pid" 2>/dev/null || true
    devnet_pid=""
  fi
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "cardano-node run --config $work/" >/dev/null 2>&1 || true
  fi
  for _wait in $(seq 1 50); do
    if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -f "cardano-node run --config $work/" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  chmod -R u+rwx "$work/cardano-e2e" 2>/dev/null || true
  rm -rf "$work/cardano-e2e" || true
}
# shellcheck disable=SC2329 # the EXIT trap invokes this
release_work() {
  local code=$?
  trap - EXIT
  stop_devnet
  if [ -n "${work:-}" ] && [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
    echo "kept scratch: $work" >&2
  fi
  exit "$code"
}
trap release_work EXIT

hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/gina.skey"
hexkey >"$work/ginapin.skey"
hexkey >"$work/hanka.skey"
hexkey >"$work/hankb.skey"
hexkey >"$work/bob.skey"

export TMPDIR="$work"
# The node binds `$TMPDIR/cardano-e2e/node.sock` (22 characters after TMPDIR)
# and a Unix socket path over 107 bytes cannot be bound: refuse a too-long
# work directory with its length before any node starts, so it can never
# again look like a node that does not start.
[ "$((${#work} + 22))" -le 100 ] \
  || setup_fail "the work directory is too long for the node's socket path: $((${#work} + 22)) characters"

# Start one fresh devnet with no state carrier anywhere. Arguments are
# `--fund` groups for this leg's wallets; the chain is fresh, so no carrier
# from an earlier leg exists. Sets sock, provider_url, time_directory,
# network_magic and node[].
start_devnet() {
  local log="$1"
  shift
  stop_devnet
  "$devnet" "$@" >"$work/$log.out" 2>"$work/$log.err" &
  devnet_pid=$!
  sock=""
  provider_url=""
  time_directory=""
  network_magic=""
  for _ in $(seq 1 900); do
    settings="$(head -n1 "$work/$log.out" 2>/dev/null || true)"
    sock="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
    provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
    time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
    network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
    [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_directory/time-manifest.json" ] && break
    kill -0 "$devnet_pid" 2>/dev/null || break
    sleep 1
  done
  if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -S "$sock" ] || [ ! -r "$time_directory/time-manifest.json" ]; then
    tail -40 "$work/$log.err" >&2 || true
    setup_fail "the private devnet never printed usable provider/time settings ($log)"
  fi
  node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")
  say "one private development source at $provider_url ($log)"
}

gina=(--wallet-skey "$work/gina.skey")
ginapin=(--wallet-skey "$work/ginapin.skey")
hanka=(--wallet-skey "$work/hanka.skey")
hankb=(--wallet-skey "$work/hankb.skey")

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
run() {
  local name="$1" want="$2"
  shift 2
  # Call sites read `run NAME WANT -- CMD...`; strip the separator like the
  # journey's helper does, or the binary refuses `--` before anything is read.
  [ "${1:-}" = "--" ] && shift
  local status=0 detail=""
  "$open_datum" "$@" >"$receipts/$name.json" 2>"$receipts/$name.err" || status=$?
  if [[ -s "$receipts/$name.err" ]]; then
    detail="$(head -n 3 "$receipts/$name.err" || jq -r .reason "$receipts/$name.json" 2>/dev/null)"
  else
    detail="$(jq -r .reason "$receipts/$name.json" 2>/dev/null)"
  fi
  [ "$status" -eq "$(exit_of "$want")" ] || fail "$name: exit $status, wanted $want ($detail)"
  [ "$(jq -r .outcome "$receipts/$name.json")" = "$want" ] || fail "$name: outcome $(jq -r .outcome "$receipts/$name.json"), wanted $want"
}

# ------------------------------------------------------------------
# Gina: one 200 tADA output, no state carrier anywhere, no seed flag
# ------------------------------------------------------------------
start_devnet devnet-gina --fund "$work/gina.skey:1:200000000" \
  --fund-skey "$work/bob.skey" --fund-outputs 2 --fund-lovelace 2000000000
gina_dir="$work/gina-actor"
run gina-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$gina_dir" --blueprint "$blueprint" "${node[@]}" "${gina[@]}"
jq -e '.createRefusal == null' "$receipts/gina-preview.json" >/dev/null \
  || fail "gina's preview refuses a fundable one-output wallet: $(jq -r .createRefusal "$receipts/gina-preview.json")"
jq -e '.seedFrom == "publication-change"' "$receipts/gina-preview.json" >/dev/null \
  || fail "gina's preview does not name a chained seed: $(jq -r .seedFrom "$receipts/gina-preview.json")"
gina_token="$(field gina-preview .stateToken)"
gina_seed="$(field gina-preview .seed)"
gina_addr="$(field gina-preview .wallet)"
[ -n "$gina_token" ] && [ -n "$gina_seed" ] || fail "gina's preview names no token or seed"
say "gina's preview names token $gina_token from seed $gina_seed"
[ -z "$(managed_find "$gina_dir" journal.jsonl)" ] || fail "gina's preview wrote a journal"
[ -z "$(managed_find "$gina_dir" registry.pending.json)" ] || fail "gina's preview wrote a pending identity"

run gina-public-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$work/gina-public" --blueprint "$blueprint" "${node[@]}" --wallet-address "$gina_addr"
[ "$(field gina-public-preview .stateToken)" = "$gina_token" ] \
  || fail "gina's public preview names another token"
[ "$(field gina-public-preview .seed)" = "$gina_seed" ] \
  || fail "gina's public preview names another seed"
[ "$(jq -r .createRefusal "$receipts/gina-public-preview.json")" = null ] \
  || fail "gina's public preview refuses"
jq -e '.seedFrom == "publication-change"' "$receipts/gina-public-preview.json" >/dev/null \
  || fail "gina's public preview does not name a chained seed"
say "gina's key and public previews agree"

# The settings file holds the node and the contracts before the create; the
# create keeps the registry's name in it (#717).
gina_home="$work/gina-home"
mkdir -p "$gina_home"
gina_settings="$gina_home/singular.json"
jq -n --arg url "$provider_url" --arg time "$time_directory" --arg bp "$blueprint" --argjson magic "$network_magic" \
  '{"koios-url": $url, "network-time": $time, "network-magic": $magic, "blueprint": $bp}' >"$gina_settings"
run gina-create success -- create --process-time 120000 --retract-time 30000 \
  --state-dir "$gina_dir" --blueprint "$blueprint" "${node[@]}" "${gina[@]}" \
  --save-state-token --config "$gina_settings"
[ "$(field gina-create .stateToken)" = "$gina_token" ] \
  || fail "gina's create made another token: $(field gina-create .stateToken) vs $gina_token"
[ "$(jq -r '.["state-token"]' "$gina_settings")" = "$gina_token" ] \
  || fail "the settings file does not hold gina's token: $(jq -c . "$gina_settings")"
jq -e --arg url "$provider_url" --arg time "$time_directory" --arg bp "$blueprint" \
  '(keys == ["blueprint", "koios-url", "network-magic", "network-time", "state-token"])
   and .["koios-url"] == $url and .["network-time"] == $time and .blueprint == $bp
   and (.["network-magic"] | type) == "number"' "$gina_settings" >/dev/null \
  || fail "the create did not keep the other keys with their kinds: $(jq -c . "$gina_settings")"
grep -q "now holds the state token" "$receipts/gina-create.err" \
  || fail "gina's create did not say which file holds the name: $(head -n 3 "$receipts/gina-create.err")"
say "gina's create kept the token in $gina_settings and left the other keys as they were"
[ "$(field gina-create .seed)" = "$gina_seed" ] \
  || fail "gina's create booted from another seed: $(field gina-create .seed) vs $gina_seed"
say "gina's no-flag create made the previewed token"
gina_journal="$(managed_journal "$gina_dir" "$gina_token" "$(field gina-create .walletKeyHash)")"
[ -f "$gina_journal" ] || fail "gina's create left no journal"
first_tx="$(jq -r 'select(.journalEvent == "submitted" and .journalStep == "publish-state") | .journalTxId' "$gina_journal" | head -n 1)"
[ -n "$first_tx" ] || fail "gina's journal names no publish-state submission"
[ "$gina_seed" = "$first_tx#1" ] \
  || fail "gina's seed $gina_seed is not the first publication's change $first_tx#1"
say "gina's seed is the first publication's change $gina_seed"
jq -e '[.references[] | .role] | sort == ["application","request","state","witness-active"]' \
  "$receipts/gina-create.json" >/dev/null || fail "gina's create did not publish the six references"
for ref_out in $(jq -r '.references[] | .output' "$receipts/gina-create.json"); do
  probe_one="$work/gina-ref-probe.json"
  "$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$ref_out" >"$probe_one"
  jq -e --arg r "$ref_out" 'any(.live[]; . == $r)' "$probe_one" >/dev/null \
    || fail "gina's reference $ref_out is not live"
done
say "gina's one-output wallet completed; every reference is live"
bob_dir="$work/bob-gina"
mkdir -p "$bob_dir"
run bob-gina-inspect success -- inspect --key keyEmpty --state-token "$gina_token" \
  --state-dir "$bob_dir" --blueprint "$blueprint" "${node[@]}"
[ "$(field bob-gina-inspect .leaf)" = unknown ] \
  || fail "bob did not read gina's registry from the token alone"
say "bob read gina's registry from the state token alone"
# The next command names no registry, no node and no contracts on its line: it
# reads them from the settings file the create wrote into, and from nowhere
# else (no variable of this shell gives a setting).
run bob-gina-inspect-file success -- inspect --key keyEmpty --state-dir "$bob_dir" \
  --config "$gina_settings"
[ "$(field bob-gina-inspect-file .leaf)" = unknown ] \
  || fail "the settings file alone did not name gina's registry"
say "a command with the settings file alone read gina's registry"
# The control: the same file with the name taken out leaves the command with no
# registry, so the success above came from the key and from nothing else.
jq 'del(.["state-token"])' "$gina_settings" >"$gina_home/without-name.json"
without_status=0
"$open_datum" inspect --key keyEmpty --state-dir "$bob_dir" --config "$gina_home/without-name.json" \
  >"$receipts/bob-without-name.out" 2>"$receipts/bob-without-name.err" || without_status=$?
[ "$without_status" -eq 2 ] || fail "an inspect with no registry anywhere exited $without_status, wanted 2"
grep -q -- "--state-token" "$receipts/bob-without-name.err" \
  || fail "the refusal does not name the missing registry: $(head -n 3 "$receipts/bob-without-name.err")"
say "without the key the same command is refused: the registry came from the file"
# The control for the switch itself: a settings file that cannot be used is
# refused with status 2 before a wallet is opened or the chain is read, and
# nothing is written or spent.
refused_dir="$work/gina-save-refused"
printf '{' >"$gina_home/broken.json"
save_status=0
"$open_datum" create --process-time 120000 --retract-time 30000 \
  --state-dir "$refused_dir" --blueprint "$blueprint" "${node[@]}" "${gina[@]}" \
  --save-state-token --config "$gina_home/broken.json" \
  >"$receipts/save-broken.out" 2>"$receipts/save-broken.err" || save_status=$?
[ "$save_status" -eq 2 ] || fail "a create over a broken settings file exited $save_status, wanted 2"
[ ! -s "$receipts/save-broken.out" ] || fail "a create over a broken settings file printed a receipt"
grep -q "broken.json" "$receipts/save-broken.err" \
  || fail "the refusal does not name the settings file: $(head -n 3 "$receipts/save-broken.err")"
[ ! -e "$refused_dir" ] || fail "the refused create made its state directory"
if [ "$(id -u)" -eq 0 ]; then
  say "skipped the read-only settings control: root writes a read-only file"
else
  cp "$gina_settings" "$gina_home/read-only.json"
  chmod 444 "$gina_home/read-only.json"
  save_status=0
  "$open_datum" create --process-time 120000 --retract-time 30000 \
    --state-dir "$refused_dir" --blueprint "$blueprint" "${node[@]}" "${gina[@]}" \
    --save-state-token --config "$gina_home/read-only.json" \
    >"$receipts/save-read-only.out" 2>"$receipts/save-read-only.err" || save_status=$?
  [ "$save_status" -eq 2 ] || fail "a create over a read-only settings file exited $save_status, wanted 2"
  grep -q "read-only" "$receipts/save-read-only.err" \
    || fail "the refusal does not say the file is read-only: $(head -n 3 "$receipts/save-read-only.err")"
  [ ! -e "$refused_dir" ] || fail "the refused create made its state directory"
  [ "$(jq -r '.["state-token"]' "$gina_home/read-only.json")" = "$gina_token" ] \
    || fail "the refused create touched the read-only file"
fi
say "the switch over a settings file that cannot be used is refused before anything is touched"

# ------------------------------------------------------------------
# Pin pair on a second fresh wallet and devnet (no carrier anywhere)
# ------------------------------------------------------------------
start_devnet devnet-pin --fund "$work/ginapin.skey:1:200000000"
pin_dir="$work/ginapin-actor"
run ginapin-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$pin_dir" --blueprint "$blueprint" "${node[@]}" "${ginapin[@]}"
jq -e '.createRefusal == null' "$receipts/ginapin-preview.json" >/dev/null \
  || fail "ginapin's preview refuses: $(jq -r .createRefusal "$receipts/ginapin-preview.json")"
jq -e '.seedFrom == "publication-change"' "$receipts/ginapin-preview.json" >/dev/null \
  || fail "ginapin's preview does not name a chained seed"
ginapin_token="$(field ginapin-preview .stateToken)"
ginapin_seed="$(field ginapin-preview .seed)"
[ -n "$ginapin_token" ] && [ -n "$ginapin_seed" ] || fail "ginapin's preview names no token or seed"
say "ginapin's preview names token $ginapin_token from seed $ginapin_seed"
run ginapin-create success -- create --process-time 120000 --retract-time 30000 \
  --seed "$ginapin_seed" --state-dir "$pin_dir" --blueprint "$blueprint" "${node[@]}" "${ginapin[@]}"
[ "$(field ginapin-create .stateToken)" = "$ginapin_token" ] \
  || fail "ginapin's pinned create made another token"
[ "$(field ginapin-create .seed)" = "$ginapin_seed" ] \
  || fail "ginapin's pinned create booted from another seed"
say "ginapin's pinned create made the previewed token"
# The wallet moved (the pin create spent its sole output). The same pin on a
# FRESH directory is refused before anything is submitted: no journal, no
# pending identity, the moved output unspent, nothing else changed.
pin_last_tx="$(jq -er '.transactions[-1]' "$receipts/ginapin-create.json")"
pin_final_change="$pin_last_tx#1"
pin_probe_before="$work/ginapin-final-before.json"
"$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$pin_final_change" >"$pin_probe_before"
jq -e --arg r "$pin_final_change" 'any(.live[]; . == $r)' "$pin_probe_before" >/dev/null \
  || fail "ginapin's final change $pin_final_change is not live after her create"
pin_fresh="$work/ginapin-moved-actor"
run ginapin-recreate client-refusal -- create --process-time 120000 --retract-time 30000 \
  --seed "$ginapin_seed" --state-dir "$pin_fresh" --blueprint "$blueprint" "${node[@]}" "${ginapin[@]}"
[ -z "$(managed_find "$pin_fresh" journal.jsonl)" ] || fail "the refused pin recreate wrote a journal"
[ -z "$(managed_find "$pin_fresh" registry.pending.json)" ] || fail "the refused pin recreate wrote a pending identity"
pin_probe_after="$work/ginapin-final-after.json"
"$devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$pin_final_change" >"$pin_probe_after"
jq -e --arg r "$pin_final_change" 'any(.live[]; . == $r)' "$pin_probe_after" >/dev/null \
  || fail "ginapin's moved output $pin_final_change was spent by the refused recreate"
say "ginapin's spent pin was refused before anything was submitted; the moved output stays unspent"

# ------------------------------------------------------------------
# Hank: short one-output wallets, no carrier anywhere, no seed flag
# ------------------------------------------------------------------
start_devnet devnet-hank --fund "$work/hanka.skey:1:5000000" --fund "$work/hankb.skey:1:105000000"
# HankA: one 5 tADA output, below the first publication (no carrier).
# Preview succeeds with the whole-run refusal and null seed fields (no
# placeholder, no funding judgement); create fails with client-refusal and
# the same text before anything is written.
hanka_dir="$work/hanka-actor"
run hanka-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$hanka_dir" --blueprint "$blueprint" "${node[@]}" "${hanka[@]}"
hanka_refusal="$(jq -r .createRefusal "$receipts/hanka-preview.json")"
case "$hanka_refusal" in
  publication-unfunded*"nothing was submitted") ;;
  *) fail "hanka's preview does not refuse funding: $hanka_refusal" ;;
esac
jq -e '.seed == null and .stateToken == null and .seedFrom == null' "$receipts/hanka-preview.json" >/dev/null \
  || fail "hanka's preview names a seed for an unfundable first publication"
hanka_addr="$(field hanka-preview .wallet)"
run hanka-public-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$work/hanka-public2" --blueprint "$blueprint" "${node[@]}" --wallet-address "$hanka_addr"
[ "$(field hanka-public-preview .createRefusal)" = "$hanka_refusal" ] \
  || fail "hanka's public preview differs"
jq -e '.seed == null and .stateToken == null and .seedFrom == null' "$receipts/hanka-public-preview.json" >/dev/null \
  || fail "hanka's public preview names a seed for an unfundable first publication"
say "hanka's key and public previews agree"
run hanka-create client-refusal -- create --process-time 120000 --retract-time 30000 \
  --state-dir "$hanka_dir" --blueprint "$blueprint" "${node[@]}" "${hanka[@]}"
[ "$(field hanka-create .reason)" = "$hanka_refusal" ] \
  || fail "hanka's create refusal differs from her preview"
say "hanka refused with one verdict: $hanka_refusal"
[ -z "$(managed_find "$hanka_dir" journal.jsonl)" ] || fail "the refused hanka create wrote a journal"
[ -z "$(managed_find "$hanka_dir" registry.pending.json)" ] || fail "the refused hanka create wrote a pending identity"
run hanka-preview2 success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$work/hanka-public3" --blueprint "$blueprint" "${node[@]}" --wallet-address "$hanka_addr"
[ "$(jq -r .createRefusal "$receipts/hanka-preview2.json")" = "$hanka_refusal" ] \
  || fail "hanka's wallet changed under the refused create"
say "the refused create left hanka's wallet unchanged"
# HankB: one 105 tADA output, covering the first publication (which needs
# 53698530) but not the whole run (which needs at least 162649217; no
# carrier). Preview names the chained seed with the whole-run refusal;
# create fails with the same text.
hankb_dir="$work/hankb-actor"
run hankb-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$hankb_dir" --blueprint "$blueprint" "${node[@]}" "${hankb[@]}"
hankb_refusal="$(jq -r .createRefusal "$receipts/hankb-preview.json")"
case "$hankb_refusal" in
  publication-unfunded*"nothing was submitted") ;;
  *) fail "hankb's preview does not refuse funding: $hankb_refusal" ;;
esac
jq -e '.seedFrom == "publication-change"' "$receipts/hankb-preview.json" >/dev/null \
  || fail "hankb's preview does not name a chained seed"
hankb_addr="$(field hankb-preview .wallet)"
run hankb-public-preview success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$work/hankb-public" --blueprint "$blueprint" "${node[@]}" --wallet-address "$hankb_addr"
[ "$(field hankb-public-preview .createRefusal)" = "$hankb_refusal" ] \
  || fail "hankb's public preview differs"
jq -e '.seedFrom == "publication-change"' "$receipts/hankb-public-preview.json" >/dev/null \
  || fail "hankb's public preview does not name a chained seed"
say "hankb's key and public previews agree"
run hankb-create client-refusal -- create --process-time 120000 --retract-time 30000 \
  --state-dir "$hankb_dir" --blueprint "$blueprint" "${node[@]}" "${hankb[@]}"
[ "$(field hankb-create .reason)" = "$hankb_refusal" ] \
  || fail "hankb's create refusal differs from her preview"
say "hankb refused with one verdict: $hankb_refusal"
[ -z "$(managed_find "$hankb_dir" journal.jsonl)" ] || fail "the refused hankb create wrote a journal"
[ -z "$(managed_find "$hankb_dir" registry.pending.json)" ] || fail "the refused hankb create wrote a pending identity"
run hankb-preview2 success -- create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$hankb_dir" --blueprint "$blueprint" "${node[@]}" "${hankb[@]}"
[ "$(jq -r .createRefusal "$receipts/hankb-preview2.json")" = "$hankb_refusal" ] \
  || fail "hankb's wallet changed under the refused create"
say "the refused create left hankb's wallet unchanged"

say "one-output create: PASS"
