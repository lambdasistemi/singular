#!/usr/bin/env bash
# negative-host-part (second slice plus the registry pairs and the short-fold
# sequence): the application pairs from the release archive, the stranger's
# taken key (stranger-registers-a-taken-key), the owner's taken key
# (owner-registers-a-taken-key-again), the two revivals of a terminated key
# (owner-revives-a-terminated-key, stranger-revives-a-terminated-key), and the
# connected short-fold sequence (short-fold-of-a-booked-termination).
# Parts: stranger-updates-the-key (first slice), the controller-signed
# tamper family (controller-tamper-controller|deposit|token|address|datum),
# the stranger's termination booking (stranger-terminates-the-key), the
# controller-signed release outside any fold
# (controller-withdraws-outside-a-fold), the stranger's insertion of a
# taken key (stranger-registers-a-taken-key), and the closed registry's
# refused update (closed-update).
# usage: negative_host_part.sh REPO-ROOT PART
#
# For one discovered part: assemble the release archive, extract it outside
# the checkout, build singular-negative and open-datum from the archive's
# application flake and singular and the development node from its offchain
# flake, run the forbidden command and its accepting control on one fresh
# node, judge every clause from the receipts, and scan
# every receipt and output for the key bytes generated. Refuses an unknown
# part before starting a node.
set -euo pipefail
[ "$#" -eq 2 ] || {
  echo "usage: $0 REPO-ROOT PART" >&2
  exit 2
}
root="$1"
part="$2"
case "$part" in
  stranger-updates-the-key | controller-tamper-controller | controller-tamper-deposit | controller-tamper-token | controller-tamper-address | controller-tamper-datum | stranger-terminates-the-key | controller-withdraws-outside-a-fold | stranger-registers-a-taken-key | owner-registers-a-taken-key-again | owner-revives-a-terminated-key | stranger-revives-a-terminated-key | short-fold-of-a-booked-termination | closed-update) ;;
  *)
    echo "negative-host-part: unknown part: $part" >&2
    exit 2
    ;;
esac

fail() {
  echo "negative-host-part [$part]: FAIL: $*" >&2
  exit 1
}
setup_fail() {
  echo "negative-host-part [$part]: SETUP: $*" >&2
  exit 3
}
say() { echo "negative-host-part [$part]: $*"; }

# Receipt cap (#513): past 50 MiB the run stops.
receipt_cap_bytes=52428800
receipt_bytes() {
  local s=0 n
  while IFS= read -r n; do s=$((s + n)); done < <(find "$1" -type f -printf '%s\n' 2>/dev/null || true)
  printf '%d' "$s"
}

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/negative-host.XXXXXX")"
release_scratch() {
  local code=$?
  trap - EXIT
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "cardano-node run --config ${scratch}/" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 50); do
    if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -f "cardano-node run --config ${scratch}/" >/dev/null 2>&1; then break; fi
    sleep 0.1
  done
  if [ "${NEGATIVE_KEEP_SCRATCH:-}" = 1 ]; then
    echo "kept scratch: $scratch" >&2
  else
    chmod -R u+rwx "$scratch" 2>/dev/null || true
    rm -rf "$scratch" || true
  fi
  exit "$code"
}
trap release_scratch EXIT

# 1. Assemble the release archive from this checkout.
release_dir="$scratch/release"
mkdir -p "$release_dir"
(cd "$root" && nix run --quiet .#release-artifacts -- "$release_dir") \
  || setup_fail "release-artifacts failed"
version="$(cat "$root/version.txt")"
onchain_archive="$release_dir/singular-onchain-$version.tar.gz"
[ -f "$onchain_archive" ] || setup_fail "archive missing: $onchain_archive"

# 2. Extract outside the checkout.
extracted="$scratch/extracted"
mkdir -p "$extracted"
tar -xzf "$onchain_archive" -C "$extracted" \
  || setup_fail "extraction failed"
[ ! -e "$extracted/.git" ] || fail "the archive carries a git checkout"
[ -f "$extracted/offchain/flake.nix" ] || setup_fail "extracted offchain flake missing"
[ -f "$extracted/applications/open-datum/offchain/flake.nix" ] || setup_fail "extracted application flake missing"
[ -f "$extracted/onchain/plutus.json" ] || setup_fail "extracted blueprint missing"
blueprint="$extracted/onchain/plutus.json"

# The application's flake reaches the registry via ../../../offchain, which
# pure evaluation allows only inside a git worktree. The archive carries no
# .git, so the extracted copy is made a temporary git worktree for the
# builds below; the archive itself is untouched.
git -C "$extracted" init -q || setup_fail "git init in the extracted archive failed"
git -C "$extracted" add -A || setup_fail "git add in the extracted archive failed"
git -C "$extracted" -c user.email=negative-host@local -c user.name=negative-host commit -qm extracted \
  || setup_fail "git commit in the extracted archive failed"

# 3. Build host and open-datum from the archive's application flake,
# ordinary singular and node from its offchain flake.
cd "$extracted/offchain"
singular="$(nix build --quiet --no-link --print-out-paths .#singular)/bin/singular"
devnet="$(nix build --quiet --no-link --print-out-paths .#devnet)/bin/devnet"
cd "$extracted/applications/open-datum/offchain"
host="$(nix build --quiet --no-link --print-out-paths .#singular-negative)/bin/singular-negative"
open_datum="$(nix build --quiet --no-link --print-out-paths .#open-datum)/bin/open-datum"
# The development node reads its genesis files relative to its working
# directory, so the run below starts from the archive's offchain tree.
cd "$extracted/offchain"
[ -x "$singular" ] || setup_fail "archive singular missing"
[ -x "$host" ] || fail "archive holds no singular-negative (focused RED)"
[ -x "$devnet" ] || setup_fail "archive devnet missing"
[ -x "$open_datum" ] || setup_fail "archive open-datum missing"
say "built host and open-datum from the application flake, singular and node from the offchain flake"

# The registry's own pins come from the registry the commands open, never
# from a literal: the create receipt names them, and each host receipt
# carries the application and state hashes its own command resolved.
# (The blueprint's open_datum hash is the UNAPPLIED validator and must NOT
# be used here: every registry deploys its own applied application script.)

# 4. One fresh node, wallets funded by the script.
work="$scratch/run"
mkdir -p "$work/receipts"
receipts="$work/receipts"
hexkey() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
hexkey >"$work/alice.skey"
hexkey >"$work/bob.skey"
# A node that never starts never served the pair: bounded restarts of the
# startup only (never after the pair begins) still leave exactly one fresh
# node for the run. Persistent startup failure stays a setup failure.
started=0
attempts=3
for attempt in $(seq 1 $attempts); do
  "$devnet" --fund-skey "$work/alice.skey" --fund-skey "$work/bob.skey" \
    --fund-outputs 6 --fund-lovelace 2000000000 \
    >"$work/devnet-$attempt.out" 2>"$work/devnet-$attempt.err" &
  devnet_pid=$!
  trap release_scratch EXIT
  provider_url=""
  time_dir=""
  network_magic=""
  sock=""
  for _ in $(seq 1 900); do
    settings="$(head -n1 "$work/devnet-$attempt.out" 2>/dev/null || true)"
    provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
    time_dir="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
    network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
    sock="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
    [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_dir/time-manifest.json" ] && break
    kill -0 "$devnet_pid" 2>/dev/null || break
    sleep 1
  done
  if [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ]; then
    started=1
    cp "$work/devnet-$attempt.out" "$work/devnet.out"
    cp "$work/devnet-$attempt.err" "$work/devnet.err"
    break
  fi
  kill "$devnet_pid" 2>/dev/null || true
  wait "$devnet_pid" 2>/dev/null || true
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "cardano-node run --config $work/" >/dev/null 2>&1 || true
  fi
  sleep 5
done
[ "$started" = 1 ] || setup_fail "devnet never printed usable settings in $attempts attempts"
say "one fresh node at $provider_url"
node=(--koios-url "$provider_url" --network-time "$time_dir" --network-magic "$network_magic")
reg="$work/registry"

# Payloads: insert carries the nested map; update carries a new datum.
jq -n '{map:[{k:{bytes:"6e616d65"},v:{list:[{int:-7},{bytes:"616c696365"},{constructor:2,fields:[]}]}}]}' >"$work/payload-insert.json"
jq -n '{constructor:3, fields:[{bytes:"626f62"},{int:123456789012345678901234567890}]}' >"$work/payload-update.json"

run_ok() {
  local receipt="$1"
  shift
  "$@" >"$receipts/$receipt.json" 2>"$receipts/$receipt.err" || {
    echo "command failed unexpectedly: $* (see $receipt.err)" >&2
    return 1
  }
}

# 5. Create, insert alice-1 as alice, fold to active.
# The reclaim part configures a longer retract window (120s process unchanged,
# 30s -> 600s retract): the part waits for the processing deadline (plus a
# small margin), checks the window around the wait, and runs the single reclaim
# immediately; the reclaim itself is still governed by the chain and the view's
# admission (tip inside the converted window), so a longer window only makes
# expiry unlikely, never impossible — expiry is a named setup failure, never a
# pass. All other parts keep 120000/30000.
process_time=120000
retract_time=30000
if [ "$part" = stranger-registers-a-taken-key ]; then
  retract_time=600000
fi
# Closed registries boot with the switch on the preview and on the create,
# for this part only: every other part boots open exactly as before.
closed_flag=()
if [ "$part" = closed-update ]; then
  closed_flag=(--closed)
fi
run_ok preview "$open_datum" open-datum create --process-time "$process_time" --retract-time "$retract_time" --preview "${closed_flag[@]}" \
  --state-dir "$work/preview" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$work/alice.skey" \
  || setup_fail "create preview failed"
seed="$(jq -er .seed "$receipts/preview.json")" || setup_fail "preview names no seed"
if [ "$part" = closed-update ]; then
  # The open pin of the same seed, previewed before anything is submitted:
  # once the create consumes the seed no preview can name it again, so the
  # comparison preview runs here, with the switch off.
  run_ok open-preview "$open_datum" open-datum create --process-time "$process_time" --retract-time "$retract_time" --preview --seed "$seed" \
    --state-dir "$work/preview-open" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$work/alice.skey" \
    || setup_fail "open preview of the same seed failed"
fi
run_ok create "$open_datum" open-datum create --process-time "$process_time" --retract-time "$retract_time" --seed "$seed" "${closed_flag[@]}" \
  --state-dir "$reg" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$work/alice.skey" \
  || setup_fail "create failed"
state_token="$(jq -er .stateToken "$receipts/create.json")" || setup_fail "create names no state token"
pin_app="$(jq -er .pins.pinApplication "$receipts/create.json")" || setup_fail "create names no application pin"
pin_state="$(jq -er .pins.pinState "$receipts/create.json")" || setup_fail "create names no state pin"
if [ "$part" = closed-update ]; then
  # The judged pin is closed-datum's: the create receipt names the closed
  # application, its pin equals the closed preview's pin and differs from
  # the open preview's pin of the same seed. Anything else is a setup
  # failure, never counted.
  [ "$(jq -er .application "$receipts/create.json")" = open_datum.closed_datum ] \
    || setup_fail "create receipt names no closed-datum application"
  [ "$pin_app" = "$(jq -er .pins.pinApplication "$receipts/preview.json")" ] \
    || setup_fail "recorded pin differs from the closed preview's pin"
  [ "$pin_app" != "$(jq -er .pins.pinApplication "$receipts/open-preview.json")" ] \
    || setup_fail "closed pin equals the open pin of the same seed"
fi
common=(--state-dir "$reg" --blueprint "$blueprint" --state-token "$state_token")
run_ok insert "$open_datum" open-datum insert --key alice-1 --payload "$work/payload-insert.json" --payload-schema detailed \
  "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
  || setup_fail "insert failed"
run_ok fold "$open_datum" open-datum fold "${common[@]}" "${node[@]}" --wallet-skey "$work/bob.skey" \
  || setup_fail "fold failed"
[ "$(jq -er .leaf "$receipts/fold.json" 2>/dev/null || echo)" != "" ] || true
run_ok inspect-active "$open_datum" open-datum inspect --key alice-1 "${common[@]}" "${node[@]}" \
  || setup_fail "inspect failed"
[ "$(jq -er .leaf "$receipts/inspect-active.json")" = active ] \
  || setup_fail "key is not active after fold"
say "registry ready: alice-1 active"

# 6. The pair: the forbidden command refused, its accepting control
# accepted. The controller signs both sides of the tamper family (her
# tampered update beside her honest update) and of the withdraw (her
# release outside any fold beside the same release inside the honest fold
# of the booked termination, ordinary commands); the termination booking
# pairs the stranger against the controller; the taken-key insertions pair
# the taken key against a fresh key from the same active registry state (the
# stranger's with Bob, the owner's with Alice); each revival first terminates
# alice-1 through the ordinary commands and folds it to terminal, then pairs
# the terminated key against a fresh key from that same terminated state (the
# owner's with Alice, the stranger's with Bob). Every refusal is judged below against the registry's own pin for
# its part (application or state); setup, encoding and client failures are
# classified and never counted.
mkdir -p "$work/host-bob" "$work/host-alice"
forbidden_status=0
control_status=0
case "$part" in
  stranger-updates-the-key | controller-tamper-controller | controller-tamper-deposit | controller-tamper-token | controller-tamper-address | controller-tamper-datum)
    forbidden_args=(registry update --key alice-1 --payload "$work/payload-update.json" --payload-schema detailed)
    case "$part" in
      controller-tamper-controller) forbidden_args+=(--tamper controller) ;;
      controller-tamper-deposit) forbidden_args+=(--tamper deposit) ;;
      controller-tamper-token) forbidden_args+=(--tamper token) ;;
      controller-tamper-address) forbidden_args+=(--tamper address) ;;
      controller-tamper-datum) forbidden_args+=(--tamper datum) ;;
    esac
    signer_skey="$work/bob.skey"
    [ "$part" = stranger-updates-the-key ] || signer_skey="$work/alice.skey"
    "$host" "${forbidden_args[@]}" \
      --state-dir "$work/host-bob" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$signer_skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry update --key alice-1 --payload "$work/payload-update.json" --payload-schema detailed \
      --state-dir "$work/host-alice" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
    ;;
  stranger-terminates-the-key)
    "$host" registry terminate --key alice-1 \
      --state-dir "$work/host-bob" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry terminate --key alice-1 \
      --state-dir "$work/host-alice" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
    ;;
  controller-withdraws-outside-a-fold)
    "$host" registry withdraw --key alice-1 \
      --state-dir "$work/host-bob" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    run_ok control-book "$open_datum" open-datum terminate --key alice-1 \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "control booking failed"
    run_ok control-fold "$open_datum" open-datum fold \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "control fold failed"
    run_ok control-inspect "$open_datum" open-datum inspect --key alice-1 \
      "${common[@]}" "${node[@]}" \
      || setup_fail "control inspect failed"
    [ "$(jq -er .leaf "$receipts/control-inspect.json")" = terminal ] \
      || setup_fail "key is not terminal after control fold"
    ;;
  closed-update)
    # The closed registry's honest update through the host, signed by the
    # controller with no tamper flag: the node refuses it. The control is
    # the termination of the same key, booked and folded with the
    # executable as the withdraw part's control is.
    "$host" registry update --key alice-1 --payload "$work/payload-update.json" --payload-schema detailed \
      --state-dir "$work/host-alice" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    run_ok control-book "$open_datum" open-datum terminate --key alice-1 \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "control booking failed"
    run_ok control-fold "$open_datum" open-datum fold \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "control fold failed"
    run_ok control-inspect "$open_datum" open-datum inspect --key alice-1 \
      "${common[@]}" "${node[@]}" \
      || setup_fail "control inspect failed"
    [ "$(jq -er .leaf "$receipts/control-inspect.json")" = terminal ] \
      || setup_fail "key is not terminal after control fold"
    ;;
  stranger-registers-a-taken-key)
    fresh_key="fresh-1"
    # Freshness is checked, not assumed: the control key was never used
    # earlier in the run, so the registry must not hold it.
    run_ok inspect-fresh "$open_datum" open-datum inspect --key "$fresh_key" \
      "${common[@]}" "${node[@]}" \
      || setup_fail "fresh key inspect failed"
    [ "$(jq -er .leaf "$receipts/inspect-fresh.json")" = unknown ] \
      || setup_fail "fresh key not fresh: expected unknown leaf"
    mkdir -p "$work/host-bob-control"
    # No `--fold` flag: the host always books then folds (issue 486 removes
    # the combined switch from the ordinary insert), so the command line
    # never carries it.
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-bob" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-bob-control" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
    ;;
  owner-revives-a-terminated-key)
    # Setup: terminate alice-1 through the ordinary commands and fold it to
    # terminal, as controller-withdraws-outside-a-fold does.
    run_ok setup-terminate "$open_datum" open-datum terminate --key alice-1 \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "setup termination booking failed"
    run_ok setup-fold "$open_datum" open-datum fold \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "setup fold failed"
    run_ok setup-inspect "$open_datum" open-datum inspect --key alice-1 \
      "${common[@]}" "${node[@]}" \
      || setup_fail "setup inspect failed"
    [ "$(jq -er .leaf "$receipts/setup-inspect.json")" = terminal ] \
      || setup_fail "key is not terminal after setup fold"
    fresh_key="fresh-3"
    # Freshness is checked from the terminated state, before either host
    # command, as stranger-registers-a-taken-key does.
    run_ok inspect-fresh "$open_datum" open-datum inspect --key "$fresh_key" \
      "${common[@]}" "${node[@]}" \
      || setup_fail "fresh key inspect failed"
    [ "$(jq -er .leaf "$receipts/inspect-fresh.json")" = unknown ] \
      || setup_fail "fresh key not fresh: expected unknown leaf"
    mkdir -p "$work/host-alice-control"
    # No `--fold` flag: the host always books then folds (issue 486 removes
    # the combined switch from the ordinary insert), so the command line
    # never carries it.
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-alice" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-alice-control" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
    ;;
  owner-registers-a-taken-key-again)
    fresh_key="fresh-2"
    # Freshness is checked, not assumed: the control key was never used
    # earlier in the run, so the registry must not hold it.
    run_ok inspect-fresh "$open_datum" open-datum inspect --key "$fresh_key" \
      "${common[@]}" "${node[@]}" \
      || setup_fail "fresh key inspect failed"
    [ "$(jq -er .leaf "$receipts/inspect-fresh.json")" = unknown ] \
      || setup_fail "fresh key not fresh: expected unknown leaf"
    mkdir -p "$work/host-alice-control"
    # No `--fold` flag: the host always books then folds (issue 486 removes
    # the combined switch from the ordinary insert), so the command line
    # never carries it.
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-alice" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-alice-control" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
    ;;
  stranger-revives-a-terminated-key)
    # Setup: the same termination to terminal through the ordinary commands.
    run_ok setup-terminate "$open_datum" open-datum terminate --key alice-1 \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "setup termination booking failed"
    run_ok setup-fold "$open_datum" open-datum fold \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "setup fold failed"
    run_ok setup-inspect "$open_datum" open-datum inspect --key alice-1 \
      "${common[@]}" "${node[@]}" \
      || setup_fail "setup inspect failed"
    [ "$(jq -er .leaf "$receipts/setup-inspect.json")" = terminal ] \
      || setup_fail "key is not terminal after setup fold"
    fresh_key="fresh-4"
    # Freshness is checked from the terminated state, before either host
    # command, as stranger-registers-a-taken-key does.
    run_ok inspect-fresh "$open_datum" open-datum inspect --key "$fresh_key" \
      "${common[@]}" "${node[@]}" \
      || setup_fail "fresh key inspect failed"
    [ "$(jq -er .leaf "$receipts/inspect-fresh.json")" = unknown ] \
      || setup_fail "fresh key not fresh: expected unknown leaf"
    mkdir -p "$work/host-bob-control"
    # No `--fold` flag: the host always books then folds (issue 486 removes
    # the combined switch from the ordinary insert), so the command line
    # never carries it.
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-bob" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" --payload-schema detailed \
      --state-dir "$work/host-bob-control" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
    ;;
  short-fold-of-a-booked-termination)
    # One connected sequence over one request: Alice inserts alice-2 and folds
    # it active (ordinary), books its termination (ordinary, no --fold, one
    # pending), Bob's short fold is refused with the request still pending,
    # then Bob's honest fold of the same request settles it terminal and pays
    # the controller in full. Same folder (Bob), same request, same state,
    # same path; the one difference is the payment (1 less vs exactly owed).
    # No `--fold` on any command line (issue 486).
    run_ok setup-insert "$open_datum" open-datum insert --key alice-2 --payload "$work/payload-insert.json" --payload-schema detailed \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "setup insert alice-2 failed"
    run_ok setup-fold "$open_datum" open-datum fold \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/bob.skey" \
      || setup_fail "setup fold alice-2 failed"
    run_ok setup-inspect-active "$open_datum" open-datum inspect --key alice-2 \
      "${common[@]}" "${node[@]}" \
      || setup_fail "setup inspect alice-2 failed"
    [ "$(jq -er .leaf "$receipts/setup-inspect-active.json")" = active ] \
      || setup_fail "alice-2 is not active after setup fold"
    run_ok setup-book "$open_datum" open-datum terminate --key alice-2 \
      "${common[@]}" "${node[@]}" --wallet-skey "$work/alice.skey" \
      || setup_fail "setup termination booking failed"
    run_ok setup-pending-inspect "$open_datum" open-datum inspect --key alice-2 \
      "${common[@]}" "${node[@]}" \
      || setup_fail "setup pending inspect failed"
    [ "$(jq -er '.pendingRequests | length' "$receipts/setup-pending-inspect.json")" = 1 ] \
      || setup_fail "exactly one request must be pending after setup booking"
    alice_addr="$(jq -er .wallet "$receipts/preview.json")" \
      || setup_fail "preview names no wallet address"
    run_ok outputs-before "$open_datum" open-datum inspect --key alice-2 --outputs-at "$alice_addr" \
      "${common[@]}" "${node[@]}" \
      || setup_fail "outputs-before inspect failed"
    mkdir -p "$work/host-bob-short" "$work/host-bob-short-control"
    "$host" registry fold --pay-short 1 \
      --state-dir "$work/host-bob-short" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry fold \
      --state-dir "$work/host-bob-short-control" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
    # Both stages name the same request; a run whose second stage names
    # another request reports a setup failure and is never credited.
    [ -f "$receipts/forbidden.json" ] \
      || setup_fail "forbidden produced no receipt: setup failure, never counted"
    [ -f "$receipts/control.json" ] \
      || setup_fail "control produced no receipt: setup failure, never counted"
    forb_reqs="$(jq -c .requests "$receipts/forbidden.json")" \
      || setup_fail "forbidden names no requests"
    ctrl_reqs="$(jq -c .requests "$receipts/control.json")" \
      || setup_fail "control names no requests"
    [ "$forb_reqs" = "$ctrl_reqs" ] \
      || setup_fail "second stage names another request ($ctrl_reqs vs $forb_reqs): setup failure, never a refusal"
    [ "$(jq -r '.requests | length' "$receipts/forbidden.json")" = 1 ] \
      || setup_fail "exactly one request must be folded"
    run_ok control-inspect "$open_datum" open-datum inspect --key alice-2 \
      "${common[@]}" "${node[@]}" \
      || setup_fail "control inspect failed"
    run_ok outputs-after "$open_datum" open-datum inspect --key alice-2 --outputs-at "$alice_addr" \
      "${common[@]}" "${node[@]}" \
      || setup_fail "outputs-after inspect failed"
    ;;
esac

# Enforce the receipt cap.
bytes="$(receipt_bytes "$receipts")"
[ "$bytes" -le "$receipt_cap_bytes" ] || fail "receipts exceed cap ($bytes bytes)"

# The judge is parameterised per part, and the shape lands here and only
# here: later briefs add parts and clauses, not parameters. The receipt
# field and registry pin the failing script must match (applicationHash
# against pinApplication, or stateHash against pinState from the create
# receipt); the failing role (application-spending, state-validator, and
# application-at-fold for the sequence); and the positive-read clause
# (holding-ref, no-holding for a key with no holding, and pending-deposit
# for the connected short-fold sequence: root and wallet readable,
# before.pending non-empty, before.deposit positive, holding present).
# Delivered parts pass exactly what they hardwire today.
expect_hash_field="applicationHash"
expect_pin="$pin_app"
expect_role="application-spending"
expect_read="holding-ref"
case "$part" in
  stranger-registers-a-taken-key | owner-registers-a-taken-key-again)
    expect_hash_field="stateHash"
    expect_pin="$pin_state"
    expect_role="state-validator"
    expect_read="holding-ref"
    ;;
  owner-revives-a-terminated-key | stranger-revives-a-terminated-key)
    expect_hash_field="stateHash"
    expect_pin="$pin_state"
    expect_role="state-validator"
    expect_read="no-holding"
    ;;
  short-fold-of-a-booked-termination)
    expect_hash_field="applicationHash"
    expect_pin="$pin_app"
    expect_role="application-at-fold"
    expect_read="pending-deposit"
    ;;
esac

# 7. Judge every clause from the receipts.
judge() {
  local receipt="$1" expectation="$2"
  case "$expectation" in
    refused-by-expected)
      jq -e '.outcome == "ledger-refusal"' "$receipt" >/dev/null \
        || return 1
      # The refusal names the registry's own pin: the failed hash equals
      # the hash field the command itself resolved, and that hash equals
      # the pin the ordinary create published.
      got_hash="$(jq -er --arg f "$expect_hash_field" '.[$f]' "$receipt")" || return 1
      [ "$got_hash" = "$expect_pin" ] || return 1
      jq -e --arg h "$got_hash" --arg r "$expect_role" '.failedScripts[] | select(.hash == $h and .role == $r)' "$receipt" >/dev/null \
        || return 1
      # Positive read: a degraded reader must not credit the
      # nothing-changed clause. The state root is a hex string other
      # than "unreadable". For holding-ref the holding names a real
      # output reference; for no-holding (a key with no holding, which
      # later revival pairs need) the wallet is readable and the holding
      # is null or names no output.
      root="$(jq -er .before.state.root "$receipt")" || return 1
      printf '%s' "$root" | grep -Eq '^[0-9a-f]+$' || return 1
      [ "$root" != "unreadable" ] || return 1
      case "$expect_read" in
        holding-ref)
          holding="$(jq -er .before.holding.output "$receipt")" || return 1
          printf '%s' "$holding" | grep -Eq '^[0-9a-f]{64}#[0-9]+$' || return 1
          ;;
        no-holding)
          jq -e '.before.wallet | type == "array"' "$receipt" >/dev/null || return 1
          jq -e '.before.holding == null or .before.holding.output == "none"' "$receipt" >/dev/null || return 1
          ;;
        pending-deposit)
          # The connected short-fold sequence: root already readable above;
          # wallet readable, holding present (a real output reference),
          # exactly one pending request (hence non-empty), deposit a positive
          # amount. `length == 1` enforces the setup's exactly-one-pending.
          jq -e '.before.wallet | type == "array"' "$receipt" >/dev/null || return 1
          holding="$(jq -er .before.holding.output "$receipt")" || return 1
          printf '%s' "$holding" | grep -Eq '^[0-9a-f]{64}#[0-9]+$' || return 1
          jq -e '.before.pending | type == "array" and length == 1' "$receipt" >/dev/null || return 1
          jq -e '.before.deposit | type == "number" and . > 0' "$receipt" >/dev/null || return 1
          ;;
        *) return 2 ;;
      esac
      jq -e '.before == .after' "$receipt" >/dev/null || return 1
      ;;
    accepted)
      jq -e '.outcome == "success"' "$receipt" >/dev/null || return 1
      ;;
    *) return 2 ;;
  esac
}
[ -f "$receipts/forbidden.json" ] || fail "forbidden $part produced no receipt (host exit $forbidden_status): classified client refusal, never counted as a node refusal"
judge "$receipts/forbidden.json" refused-by-expected \
  || fail "forbidden $part not credited: outcome=$(jq -r .outcome "$receipts/forbidden.json"), failedScripts=$(jq -c .failedScripts "$receipts/forbidden.json"), $expect_hash_field=$(jq -r --arg f "$expect_hash_field" '.[$f]' "$receipts/forbidden.json"), registry pin $expect_pin role $expect_role"
[ "$forbidden_status" -eq 11 ] \
  || fail "forbidden exit $forbidden_status, expected 11 (ledger-refusal)"
if [ "$part" = controller-withdraws-outside-a-fold ] || [ "$part" = closed-update ]; then
  judge "$receipts/control-book.json" accepted \
    || fail "control booking not accepted: outcome=$(jq -r .outcome "$receipts/control-book.json")"
  judge "$receipts/control-fold.json" accepted \
    || fail "control fold not accepted: outcome=$(jq -r .outcome "$receipts/control-fold.json")"
else
  [ -f "$receipts/control.json" ] || fail "control $part produced no receipt (host exit $control_status): setup failure, never counted"
  judge "$receipts/control.json" accepted \
    || fail "control $part not accepted: outcome=$(jq -r .outcome "$receipts/control.json")"
  [ "$control_status" -eq 0 ] \
    || fail "control exit $control_status, expected 0"
fi
# The settlement check as one function (terminal leaf, and paid against
# owed), called by the real control stage and every altered control; do not
# recompute inside a control. Owed is the request's deposit plus the holding's
# protected deposit, both from the forbidden before (same request the control
# folds): requestDeposit is `.before.pending[0].datum.fields[0].fields[4].int`
# (outer CageDatum `Constr 0 [request]`, inner wire order
# token,owner,key,edge,deposit,submittedAt,destination), envelopeDeposit is
# `.before.holding.envelope.fields[0].fields[5].int` (control fields
# version,[policy,name],active,key,controller,deposit). This is what the
# application sums: `validRelease` fails `release-additive` iff
# `paid < owed + releasedTo`, where `owed` is `held-tip = requestDeposit`
# (`rowDuties` floor, `registryOwed`/`payeeOwed`) and `releasedTo` is
# `control.deposit` (`releasedTo` over `Release` spends at this script); `paid`
# sums the fold outputs at the controller's key that settle (`settlesOf` off
# the cage credential, no delivered tokens for a pure termination, so every
# new output at Alice settles). Paid is the new Alice outputs after the
# control (outputs-at after minus outputs-at before at `preview.wallet`),
# lovelace summed, `>= owed` (floors, surplus unobservable). On success sets
# `settles_paid` and `settles_owed` for the message; verdict is the return
# code alone.
settles_and_pays() {
  local leaf_json="$1" before_json="$2" after_json="$3" forb_json="$4"
  [ "$(jq -er .leaf "$leaf_json")" = terminal ] || return 1
  local req_dep env_dep owed paid
  req_dep="$(jq -er '.before.pending[0].datum.fields[0].fields[4].int' "$forb_json")" || return 1
  env_dep="$(jq -er '.before.holding.envelope.fields[0].fields[5].int' "$forb_json")" || return 1
  owed=$((req_dep + env_dep))
  [ "$owed" -gt 0 ] || return 1
  paid="$(jq -n --slurpfile b "$before_json" --slurpfile a "$after_json" '
    ($b[0].outputsAt.outputs // []) as $bo
    | ($a[0].outputsAt.outputs // []) as $ao
    | ($bo | map(.output) | sort) as $bos
    | [$ao[] | select(.output as $o | $bos | index($o) | not) | .locked.lovelace] | add // 0
  ')" || return 1
  [ "$paid" -ge "$owed" ] || return 1
  settles_paid="$paid"
  settles_owed="$owed"
}
if [ "$part" = short-fold-of-a-booked-termination ]; then
  settles_paid=""
  settles_owed=""
  settles_and_pays "$receipts/control-inspect.json" "$receipts/outputs-before.json" "$receipts/outputs-after.json" "$receipts/forbidden.json" \
    || fail "control did not settle alice-2 terminal and paid in full (leaf=$(jq -r .leaf "$receipts/control-inspect.json"))"
  say "control settles: alice-2 terminal, paid $settles_paid >= owed $settles_owed"
fi
say "judged: forbidden refused by the registry pin $expect_pin role $expect_role with reads equal; control accepted"

# 7b. Reclaim clauses (stranger-registers-a-taken-key only): Bob reclaims the
# stranded booking with the ordinary command inside the retract window. Judged
# from the ordinary receipts and fresh ordinary reads, never from exit status
# alone. Each clause is one function; the live stage and every altered control
# call the same code (never recomputed inside a control).
# Classify an ordinary reclaim refusal by its exact reason code (never by a
# bare substring like "retract" or "window"): prints one word for the caller
# to map. $1 reason text, $2 now_ms, $3 retract_ends_ms. Dynamic numbers live
# inside the reasons, so each branch keys on the code's fixed wording. Every
# output branch is exactly one line (a case arm, or one of the two clock
# lines), so the deletion matrix can remove any branch alone and still have
# valid shell: a deleted fixed arm falls through to the clock lines, a
# deleted clock line falls to the line below it. The clock lines only apply
# when no fixed reason matched, so a matched reason is never overridden.
classify_reclaim_refusal() {
  local reason="$1" now_ms="$2" retract_ends="$3" word=""
  case "$reason" in
    *"is not pending in this registry"*) word=SETUP-NOT-PENDING ;;
    *"no nonempty validity interval inside the retract window"*) word=SETUP-NOT-PHASE2 ;;
    *"cannot convert"*) word=SETUP-UNCONVERTED ;;
    *"registry reject clears"*) word=SETUP-CLOSED ;;
    *"before the window"*) word=SETUP-BEFORE ;;
    *"is not the request's owner"* | *"does not require the owner's signature"*) word=FAIL-OWNER ;;
  esac
  # Past the deadline by the post-command host clock, and no fixed reason
  # matched, the window may have expired during submission itself: setup.
  [ -z "$word" ] && [ "$now_ms" -ge "$retract_ends" ] && word=SETUP-EXPIRED
  # Still nothing: an unmatched reason inside the window is simply
  # unclassified, a credited refusal that needs an owner decision.
  [ -z "$word" ] && word=FAIL-GENERIC
  printf '%s' "$word"
}
# Map a classifier word to its own named outcome: every setup word is the
# part's own window or booking setup and exits 3 through setup_fail (never a
# credited pass), owner and generic are credited refusals that need an owner
# decision, and no word at all is the classifier's silence, named as such so
# a deleted branch stays observable in the caller's message. $1 class, $2 the
# reclaim exit status, $3 reason, $4 now_ms, $5 retract_ends_ms.
reclaim_refusal_outcome() {
  local class="$1" status="$2" reason="$3" now_ms="$4" retract_ends="$5"
  case "$class" in
    SETUP-NOT-PENDING) setup_fail "ordinary reclaim says not pending ($reason): missing-request, never credited" ;;
    SETUP-NOT-PHASE2) setup_fail "ordinary reclaim outside phase two (not-phase2, exit $status, reason $reason): the built reclaim had no nonempty validity interval inside the retract window; setup failure, never credited" ;;
    SETUP-BEFORE) setup_fail "ordinary reclaim before its window ($reason): setup failure, never credited" ;;
    SETUP-CLOSED) setup_fail "ordinary reclaim window closed ($reason): setup failure, never credited" ;;
    SETUP-UNCONVERTED) setup_fail "ordinary reclaim window unconverted ($reason): setup failure, never credited" ;;
    SETUP-EXPIRED) setup_fail "ordinary reclaim window expired during submission ($reason; now $now_ms >= retractEnds $retract_ends): setup failure, never credited" ;;
    FAIL-OWNER) fail "ordinary reclaim refused (retract-owner, exit $status, reason $reason): A-014 requires an owner decision, never a host reclaim" ;;
    FAIL-GENERIC) fail "ordinary reclaim refused (exit $status, reason $reason): A-014 requires an owner decision, never a host reclaim" ;;
    *) fail "ordinary reclaim refusal unclassified (class '$class', exit $status, reason $reason): the classifier printed no known word; A-014 requires an owner decision, never a host reclaim" ;;
  esac
}
reclaim_names_command() {
  local reclaim_json="$1" expected_request="$2"
  [ "$(jq -er .outcome "$reclaim_json")" = success ] || return 1
  [ "$(jq -er .command "$reclaim_json")" = reclaim ] || return 1
  [ "$(jq -er .request "$reclaim_json")" = "$expected_request" ] || return 1
  [ "$(jq -er .edge "$reclaim_json")" = insertActive ] || return 1
}
booking_collected() {
  local reclaim_json="$1" before_json="$2" after_json="$3" expected_request="$4"
  local reclaim_owner before_owner
  reclaim_owner="$(jq -er .owner "$reclaim_json")" || return 1
  before_owner="$(jq -er --arg r "$expected_request" '.pendingRequests[] | select(.request == $r) | .owner' "$before_json")" || return 1
  [ "$reclaim_owner" = "$before_owner" ] || return 1
  jq -e --arg r "$expected_request" '.pendingRequests | map(.request) | index($r) != null' "$before_json" >/dev/null || return 1
  jq -e --arg r "$expected_request" '.pendingRequests | map(.request) | index($r) == null' "$after_json" >/dev/null || return 1
  [ "$(jq -er .root "$before_json")" = "$(jq -er .root "$after_json")" ] || return 1
  [ "$(jq -er .root "$reclaim_json")" = "$(jq -er .root "$after_json")" ] || return 1
  [ "$(jq -er .leaf "$before_json")" = active ] || return 1
  [ "$(jq -er .leaf "$after_json")" = active ] || return 1
}
deposit_returned() {
  local reclaim_json="$1" before_json="$2" after_json="$3" expected_addr="$4" expected_request="$5"
  local locked_lov returned_lov topup
  [ "$(jq -er .request "$reclaim_json")" = "$expected_request" ] || return 1
  [ "$(jq -er '.returned.request' "$reclaim_json")" = "$expected_request" ] || return 1
  [ "$(jq -er '.returned.index' "$reclaim_json")" = 0 ] || return 1
  [ "$(jq -er '.returned.output' "$reclaim_json")" = "$(jq -er .retract "$reclaim_json")#0" ] || return 1
  [ "$(jq -er '.returned.recipient' "$reclaim_json")" = "$expected_addr" ] || return 1
  [ "$(jq -c -S .locked "$reclaim_json")" = "$(jq -c -S --arg r "$expected_request" '.pendingRequests[] | select(.request == $r) | .locked' "$before_json")" ] || return 1
  locked_lov="$(jq -er .locked.lovelace "$reclaim_json")" || return 1
  returned_lov="$(jq -er .returned.lovelace "$reclaim_json")" || return 1
  topup="$(jq -er .topUp "$reclaim_json")" || return 1
  [ "$returned_lov" -ge "$locked_lov" ] || return 1
  [ "$topup" -eq "$((returned_lov - locked_lov))" ] || return 1
  [ "$locked_lov" -gt 0 ] || return 1
  # BEGIN-R3-amount-bind (F334-1): the summary number, the value object and
  # the fresh output's own lovelace are one amount, at least the booking.
  # Without this a full summary beside a matching short output passes.
  jq -e --arg o "$(jq -er '.returned.output' "$reclaim_json")" --argjson rlove "$returned_lov" --argjson llove "$locked_lov" --argjson want "$(jq -c '.returned.value' "$reclaim_json")" '
    ($want.lovelace == $rlove)
    and ([.outputsAt.outputs[] | select(.output == $o)] | length == 1)
    and ([.outputsAt.outputs[] | select(.output == $o)][0].locked == $want)
    and ([.outputsAt.outputs[] | select(.output == $o)][0].locked.lovelace == $rlove)
    and ($rlove >= $llove)
  ' "$after_json" >/dev/null || return 1
  # END-R3-amount-bind
  jq -e --arg o "$(jq -er '.returned.output' "$reclaim_json")" --argjson want "$(jq -c '.returned.value' "$reclaim_json")" '
    [.outputsAt.outputs[] | select(.output == $o)] | length == 1 and .[0].locked == $want
  ' "$after_json" >/dev/null || return 1
}
if [ "$part" = stranger-registers-a-taken-key ]; then
  reclaim_request="$(jq -er '.requests[0]' "$receipts/forbidden.json")" || setup_fail "stranded request missing in forbidden receipt"
  printf '%s' "$reclaim_request" | grep -Eq '^[0-9a-fA-F]{64}#[0-9]+$' || setup_fail "stranded request malformed: $reclaim_request"
  "$singular" --help >"$receipts/singular-help.out" 2>"$receipts/singular-help.err" || setup_fail "singular --help failed"
  grep -q "singular registry reclaim" "$receipts/singular-help.out" || setup_fail "singular --help does not name registry reclaim"
  "$singular" registry reclaim --help >"$receipts/singular-reclaim-help.out" 2>"$receipts/singular-reclaim-help.err" || setup_fail "singular registry reclaim --help failed"
  grep -q -- "--request" "$receipts/singular-reclaim-help.out" || setup_fail "reclaim --help names no --request"
  # The reclaim of this part takes a request and is singular's. The application also has a reclaim,
  # for a pending registration of the no-pin design; it takes --pending and never --request, so the
  # harness knows the command it invokes below is not that one.
  "$open_datum" registration reclaim --help >"$receipts/opendatum-reclaim-help.out" 2>"$receipts/opendatum-reclaim-help.err" || setup_fail "open-datum registration reclaim --help failed"
  grep -q -- "--pending" "$receipts/opendatum-reclaim-help.out" || setup_fail "open-datum registration reclaim --help names no --pending: not the reclaim of a pending registration"
  if grep -q -- "--request" "$receipts/opendatum-reclaim-help.out"; then
    setup_fail "open-datum registration reclaim --help names --request: it cannot be told from singular registry reclaim, which this part invokes"
  fi
  say "ordinary command: singular registry reclaim --request $reclaim_request (help agrees; open-datum's own reclaim takes --pending)"
  run_ok bob-preview "$open_datum" open-datum create --process-time "$process_time" --retract-time "$retract_time" --preview \
    --state-dir "$work/bob-preview" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$work/bob.skey" \
    || setup_fail "bob preview failed"
  bob_addr="$(jq -er .wallet "$receipts/bob-preview.json")" || setup_fail "bob preview names no wallet"
  [ -n "$bob_addr" ] || setup_fail "bob address empty"
  run_ok inspect-before-reclaim "$open_datum" open-datum inspect --key alice-1 "${common[@]}" "${node[@]}" \
    || setup_fail "before-reclaim inspect failed"
  [ "$(jq -er .leaf "$receipts/inspect-before-reclaim.json")" = active ] || setup_fail "key not active before reclaim"
  submitted="$(jq -er --arg r "$reclaim_request" '.pendingRequests[] | select(.request == $r) | .submittedAt' "$receipts/inspect-before-reclaim.json")" || setup_fail "stranded request not pending before reclaim (missing-request, never credited)"
  proc_time="$(jq -er .processTime "$receipts/inspect-before-reclaim.json")" || setup_fail "before inspect names no processTime"
  retr_time="$(jq -er .retractTime "$receipts/inspect-before-reclaim.json")" || setup_fail "before inspect names no retractTime"
  processing_ends=$((submitted + proc_time))
  retract_ends=$((submitted + proc_time + retr_time))
  now_ms=$(date +%s%3N)
  [ "$now_ms" -lt "$retract_ends" ] || setup_fail "reclaim window expired before the wait (now $now_ms >= retractEnds $retract_ends)"
  wait_ms=$((processing_ends + 5000 - now_ms))
  if [ "$wait_ms" -gt 0 ]; then
    say "waiting $wait_ms ms for the retract window to open (processingEnds $processing_ends)"
    sleep "$((wait_ms / 1000)).$(printf '%03d' "$((wait_ms % 1000))")"
  fi
  now_ms=$(date +%s%3N)
  [ "$now_ms" -lt "$retract_ends" ] || setup_fail "reclaim window expired after the wait (now $now_ms >= retractEnds $retract_ends)"
  mkdir -p "$work/reclaim-bob"
  reclaim_status=0
  "$singular" registry reclaim --request "$reclaim_request" \
    --state-dir "$work/reclaim-bob" --blueprint "$blueprint" --state-token "$state_token" \
    "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/reclaim.json" \
    >"$receipts/reclaim.out" 2>"$receipts/reclaim.stderr" || reclaim_status=$?
  [ -f "$receipts/reclaim.json" ] || setup_fail "ordinary reclaim produced no receipt (missing-request, never credited)"
  if [ "$reclaim_status" -ne 0 ]; then
    reason="$(jq -r .reason "$receipts/reclaim.json" 2>/dev/null || echo "no reason")"
    now_ms=$(date +%s%3N)
    class="$(classify_reclaim_refusal "$reason" "$now_ms" "$retract_ends")"
    reclaim_refusal_outcome "$class" "$reclaim_status" "$reason" "$now_ms" "$retract_ends"
  fi
  reclaim_names_command "$receipts/reclaim.json" "$reclaim_request" \
    || fail "reclaim not credited: command/request/edge mismatch (outcome=$(jq -r .outcome "$receipts/reclaim.json"))"
  run_ok inspect-after-reclaim "$open_datum" open-datum inspect --key alice-1 --outputs-at "$bob_addr" "${common[@]}" "${node[@]}" \
    || setup_fail "after-reclaim inspect failed"
  booking_collected "$receipts/reclaim.json" "$receipts/inspect-before-reclaim.json" "$receipts/inspect-after-reclaim.json" "$reclaim_request" \
    || fail "reclaim did not collect the booking (pending still live or root moved)"
  deposit_returned "$receipts/reclaim.json" "$receipts/inspect-before-reclaim.json" "$receipts/inspect-after-reclaim.json" "$bob_addr" "$reclaim_request" \
    || fail "reclaim did not return Bob's deposit (returned mismatch)"
  say "reclaimed: $reclaim_request collected, deposit returned to $bob_addr by singular registry reclaim"
fi

# 8. Altered-receipt controls: each clause changes its verdict.
altered="$work/altered"
mkdir -p "$altered"
# (i) refusal naming another script fails.
jq '.failedScripts[0].hash = "00000000000000000000000000000000000000000000000000000000"' \
  "$receipts/forbidden.json" >"$altered/forbidden-other-script.json"
if judge "$altered/forbidden-other-script.json" refused-by-expected; then
  fail "control: refusal naming another script passed"
fi
# (i-b) receipt hash differing from the registry pin fails.
jq --arg f "$expect_hash_field" '.[$f] = "00000000000000000000000000000000000000000000000000000000"' \
  "$receipts/forbidden.json" >"$altered/forbidden-other-pin.json"
if judge "$altered/forbidden-other-pin.json" refused-by-expected; then
  fail "control: receipt hash differing from the registry pin passed"
fi
# (ii) client failure never counts as refusal.
jq '.outcome = "client-refusal"' "$receipts/forbidden.json" >"$altered/forbidden-client.json"
if judge "$altered/forbidden-client.json" refused-by-expected; then
  fail "control: client refusal counted as node refusal"
fi
# (iii) changed post-read fails the equality clause.
jq '.after = (.before | .holding = {"tampered": true})' "$receipts/forbidden.json" >"$altered/forbidden-tampered-read.json"
if judge "$altered/forbidden-tampered-read.json" refused-by-expected; then
  fail "control: altered post-read passed the equality clause"
fi
# (v) degenerate before-read fails the positive-read clause.
jq '.before.state.root = "unreadable" | .before.holding.output = "none"' \
  "$receipts/forbidden.json" >"$altered/forbidden-degenerate-read.json"
if judge "$altered/forbidden-degenerate-read.json" refused-by-expected; then
  fail "control: degenerate before-read passed the positive-read clause"
fi
# (vi-vii) no-holding predicates, each the only reason to reject: built from
# the valid receipt with before equal to after. Only for the no-holding form;
# the holding-reference parts and their controls are untouched.
if [ "$expect_read" = no-holding ]; then
  # (vi) a real holding output must fail the no-holding clause.
  jq '.before.holding = {"output": "00000000000000000000000000000000000000000000000000000000#0"} | .after = .before' \
    "$receipts/forbidden.json" >"$altered/forbidden-real-holding.json"
  if judge "$altered/forbidden-real-holding.json" refused-by-expected; then
    fail "control: real holding passed the no-holding clause"
  fi
  # (vii) an unreadable wallet must fail the no-holding clause.
  jq '.before.wallet = "unreadable" | .after = .before' \
    "$receipts/forbidden.json" >"$altered/forbidden-unreadable-wallet.json"
  if judge "$altered/forbidden-unreadable-wallet.json" refused-by-expected; then
    fail "control: unreadable wallet passed the no-holding clause"
  fi
fi
# (viii) pending-deposit predicates, each the only reason to reject: built
# from the valid receipt with before equal to after. Only for the
# pending-deposit form; every other part and its controls are untouched.
if [ "$expect_read" = pending-deposit ]; then
  # Empty pending (hence not exactly one).
  jq '.before.pending = [] | .after = .before' \
    "$receipts/forbidden.json" >"$altered/forbidden-empty-pending.json"
  if judge "$altered/forbidden-empty-pending.json" refused-by-expected; then
    fail "control: empty pending passed the pending-deposit clause"
  fi
  # Non-positive deposit (zero): wallet array, holding present, one pending,
  # root readable and reads equal all hold; only the positive-deposit guard
  # fails.
  jq '.before.deposit = 0 | .after = .before' \
    "$receipts/forbidden.json" >"$altered/forbidden-zero-deposit.json"
  if judge "$altered/forbidden-zero-deposit.json" refused-by-expected; then
    fail "control: zero deposit passed the pending-deposit clause"
  fi
  # Unreadable wallet (non-array): holding present, one pending, positive
  # deposit, root readable and reads equal all hold; only the wallet guard
  # fails.
  jq '.before.wallet = "unreadable" | .after = .before' \
    "$receipts/forbidden.json" >"$altered/forbidden-unreadable-wallet.json"
  if judge "$altered/forbidden-unreadable-wallet.json" refused-by-expected; then
    fail "control: unreadable wallet passed the pending-deposit clause"
  fi
  # Holding that is not a real output reference: wallet array, one pending,
  # positive deposit, root readable and reads equal all hold; only the
  # holding guard fails.
  jq '.before.holding.output = "none" | .after = .before' \
    "$receipts/forbidden.json" >"$altered/forbidden-none-holding.json"
  if judge "$altered/forbidden-none-holding.json" refused-by-expected; then
    fail "control: none holding passed the pending-deposit clause"
  fi
fi
# (ix) settlement controls, each the only reason to be rejected, each calling
# the live `settles_and_pays` function itself (never recomputed): leaf not
# terminal, nothing paid, and one lovelace short. Only for the short-fold
# sequence.
if [ "$part" = short-fold-of-a-booked-termination ]; then
  # Leaf not terminal (active): owed and paid unchanged and valid; only the
  # leaf guard fails inside the function.
  jq '.leaf = "active"' \
    "$receipts/control-inspect.json" >"$altered/control-inspect-active.json"
  if settles_and_pays "$altered/control-inspect-active.json" "$receipts/outputs-before.json" "$receipts/outputs-after.json" "$receipts/forbidden.json"; then
    fail "control: active leaf passed the settlement function"
  fi
  # Nothing paid: leaf still terminal, owed unchanged; only paid fails.
  jq --slurpfile b "$receipts/outputs-before.json" '.outputsAt.outputs = $b[0].outputsAt.outputs' \
    "$receipts/outputs-after.json" >"$altered/outputs-after-no-payment.json"
  if settles_and_pays "$receipts/control-inspect.json" "$receipts/outputs-before.json" "$altered/outputs-after-no-payment.json" "$receipts/forbidden.json"; then
    fail "control: no new payment passed the settlement function"
  fi
  # One lovelace short: the new payment lowered by exactly 1; leaf terminal
  # and owed unchanged; only `paid >= owed` fails.
  jq --slurpfile b "$receipts/outputs-before.json" '
    ($b[0].outputsAt.outputs | map(.output) | sort) as $bos
    | .outputsAt.outputs |= map(if (.output as $o | $bos | index($o) | not) then .locked.lovelace -= 1 else . end)
  ' "$receipts/outputs-after.json" >"$altered/outputs-after-short.json"
  if settles_and_pays "$receipts/control-inspect.json" "$receipts/outputs-before.json" "$altered/outputs-after-short.json" "$receipts/forbidden.json"; then
    fail "control: short-by-one payment passed the settlement function"
  fi
fi
# (iv) control in forbidden form is refused (it would be refused, not accepted).
if judge "$receipts/forbidden.json" accepted; then
  fail "control: forbidden receipt passed the accepted clause"
fi
say "altered-receipt controls: each clause changes its verdict"
# (x-xii) reclaim controls, each the only reason to be rejected, each calling
# the live functions themselves (never recomputed). Only for
# stranger-registers-a-taken-key; every other part and its controls are untouched.
if [ "$part" = stranger-registers-a-taken-key ]; then
  jq '.command = "fold"' "$receipts/reclaim.json" >"$altered/reclaim-command-fold.json"
  if reclaim_names_command "$altered/reclaim-command-fold.json" "$reclaim_request"; then
    fail "control: folded command passed the reclaim-command clause"
  fi
  booking_collected "$altered/reclaim-command-fold.json" "$receipts/inspect-before-reclaim.json" "$receipts/inspect-after-reclaim.json" "$reclaim_request" \
    || fail "control: folded command failed the collected clause (isolation)"
  deposit_returned "$altered/reclaim-command-fold.json" "$receipts/inspect-before-reclaim.json" "$receipts/inspect-after-reclaim.json" "$bob_addr" "$reclaim_request" \
    || fail "control: folded command failed the returned clause (isolation)"
  jq --slurpfile b "$receipts/inspect-before-reclaim.json" '.pendingRequests = $b[0].pendingRequests' \
    "$receipts/inspect-after-reclaim.json" >"$altered/inspect-after-pending.json"
  if booking_collected "$receipts/reclaim.json" "$receipts/inspect-before-reclaim.json" "$altered/inspect-after-pending.json" "$reclaim_request"; then
    fail "control: re-added pending passed the collected clause"
  fi
  reclaim_names_command "$receipts/reclaim.json" "$reclaim_request" \
    || fail "control: re-added pending failed the command clause (isolation)"
  deposit_returned "$receipts/reclaim.json" "$receipts/inspect-before-reclaim.json" "$altered/inspect-after-pending.json" "$bob_addr" "$reclaim_request" \
    || fail "control: re-added pending failed the returned clause (isolation)"
  jq '.returned.lovelace += 1' "$receipts/reclaim.json" >"$altered/reclaim-returned-plus-one.json"
  if deposit_returned "$altered/reclaim-returned-plus-one.json" "$receipts/inspect-before-reclaim.json" "$receipts/inspect-after-reclaim.json" "$bob_addr" "$reclaim_request"; then
    fail "control: plus-one return passed the returned clause"
  fi
  reclaim_names_command "$altered/reclaim-returned-plus-one.json" "$reclaim_request" \
    || fail "control: plus-one return failed the command clause (isolation)"
  booking_collected "$altered/reclaim-returned-plus-one.json" "$receipts/inspect-before-reclaim.json" "$receipts/inspect-after-reclaim.json" "$reclaim_request" \
    || fail "control: plus-one return failed the collected clause (isolation)"
  # C-R4 short output with a full summary (F334-1): the value object and the
  # fresh output both say 1 while the summary still says the full booking.
  # Old R3 checks pass (summary>=locked, topUp, outputsAt==value at 1); only
  # the new amount-bind comparison rejects it.
  jq '.returned.value.lovelace = 1' "$receipts/reclaim.json" >"$altered/reclaim-value-short.json"
  jq --arg o "$(jq -er '.returned.output' "$receipts/reclaim.json")" '
    .outputsAt.outputs |= map(if .output == $o then .locked.lovelace = 1 else . end)
  ' "$receipts/inspect-after-reclaim.json" >"$altered/inspect-after-short.json"
  if deposit_returned "$altered/reclaim-value-short.json" "$receipts/inspect-before-reclaim.json" "$altered/inspect-after-short.json" "$bob_addr" "$reclaim_request"; then
    fail "control: short output with full summary passed the returned clause"
  fi
  reclaim_names_command "$altered/reclaim-value-short.json" "$reclaim_request" \
    || fail "control: short output failed the command clause (isolation)"
  booking_collected "$altered/reclaim-value-short.json" "$receipts/inspect-before-reclaim.json" "$altered/inspect-after-short.json" "$reclaim_request" \
    || fail "control: short output failed the collected clause (isolation)"
  say "reclaim controls: command, collected and returned each change their verdict alone"
fi

# 9. Scan the run directory for the signing-key bytes: receipts, stdio,
# host state directories with their journals, devnet logs. The key files
# themselves are excluded from the scan.
scan_keys() {
  local dir="$1"
  for sk in "$work/alice.skey" "$work/bob.skey"; do
    hex="$(cat "$sk")"
    for form in "$hex" "$(printf '%s' "$hex" | tr 'a-f' 'A-F')"; do
      if grep -rq --exclude='*.skey' "$form" "$dir" 2>/dev/null; then
        echo "key material found: $sk under $dir" >&2
        return 1
      fi
    done
  done
}
scan_keys "$work" || fail "key material printed in the run directory"
# Positive control: a planted copy fails the scan.
plantdir="$work/planted-control"
mkdir -p "$plantdir"
cp "$receipts/forbidden.json" "$plantdir/receipt.json"
cat "$work/alice.skey" >>"$plantdir/receipt.json"
if scan_keys "$plantdir" 2>/dev/null; then
  fail "control: planted key copy passed the scan"
fi
say "key scan: no key material printed; planted copy fails it"

echo "negative-host-part [$part]: PASS"
