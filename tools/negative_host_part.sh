#!/usr/bin/env bash
# negative-host-part (second slice plus the registry pairs): the application
# pairs from the release archive, the stranger's taken key
# (stranger-registers-a-taken-key), the owner's taken key
# (owner-registers-a-taken-key-again), and the two revivals of a terminated
# key (owner-revives-a-terminated-key, stranger-revives-a-terminated-key).
# Parts: stranger-updates-the-key (first slice), the controller-signed
# tamper family (controller-tamper-controller|deposit|token|address|datum),
# the stranger's termination booking (stranger-terminates-the-key), the
# controller-signed release outside any fold
# (controller-withdraws-outside-a-fold), and the stranger's insertion of a
# taken key (stranger-registers-a-taken-key).
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
  stranger-updates-the-key | controller-tamper-controller | controller-tamper-deposit | controller-tamper-token | controller-tamper-address | controller-tamper-datum | stranger-terminates-the-key | controller-withdraws-outside-a-fold | stranger-registers-a-taken-key | owner-registers-a-taken-key-again | owner-revives-a-terminated-key | stranger-revives-a-terminated-key) ;;
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
run_ok preview "$open_datum" open-datum create --process-time 120000 --retract-time 30000 --preview \
  --state-dir "$work/preview" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$work/alice.skey" \
  || setup_fail "create preview failed"
seed="$(jq -er .seed "$receipts/preview.json")" || setup_fail "preview names no seed"
run_ok create "$open_datum" open-datum create --process-time 120000 --retract-time 30000 --seed "$seed" \
  --state-dir "$reg" --blueprint "$blueprint" "${node[@]}" --wallet-skey "$work/alice.skey" \
  || setup_fail "create failed"
state_token="$(jq -er .stateToken "$receipts/create.json")" || setup_fail "create names no state token"
pin_app="$(jq -er .pins.pinApplication "$receipts/create.json")" || setup_fail "create names no application pin"
pin_state="$(jq -er .pins.pinState "$receipts/create.json")" || setup_fail "create names no state pin"
common=(--state-dir "$reg" --blueprint "$blueprint" --state-token "$state_token")
run_ok insert "$open_datum" open-datum insert --key alice-1 --payload "$work/payload-insert.json" \
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
    forbidden_args=(registry update --key alice-1 --payload "$work/payload-update.json")
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
    "$host" registry update --key alice-1 --payload "$work/payload-update.json" \
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
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" \
      --state-dir "$work/host-bob" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" \
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
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" \
      --state-dir "$work/host-alice" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" \
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
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" \
      --state-dir "$work/host-alice" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/alice.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" \
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
    "$host" registry insert --key alice-1 --payload "$work/payload-insert.json" \
      --state-dir "$work/host-bob" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/forbidden.json" \
      >"$receipts/forbidden.out" 2>"$receipts/forbidden.stderr" || forbidden_status=$?
    "$host" registry insert --key "$fresh_key" --payload "$work/payload-insert.json" \
      --state-dir "$work/host-bob-control" --blueprint "$blueprint" --state-token "$state_token" \
      "${node[@]}" --wallet-skey "$work/bob.skey" --receipt "$receipts/control.json" \
      >"$receipts/control.out" 2>"$receipts/control.stderr" || control_status=$?
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
# (holding-ref today, and no-holding for a key with no holding, which
# later revival pairs need). Delivered parts pass exactly what they
# hardwire today.
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
if [ "$part" = controller-withdraws-outside-a-fold ]; then
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
say "judged: forbidden refused by the registry pin $expect_pin role $expect_role with reads equal; control accepted"

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
# (iv) control in forbidden form is refused (it would be refused, not accepted).
if judge "$receipts/forbidden.json" accepted; then
  fail "control: forbidden receipt passed the accepted clause"
fi
say "altered-receipt controls: each clause changes its verdict"

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
