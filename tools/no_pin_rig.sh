#!/usr/bin/env bash
# The rig the no-pin journeys share (#742), sourced by a journey that has set
# open_datum, devnet, blueprint_source, chain_view, work and rig_name:
# one generated development network that funds four wallets, a way to run a
# command as a wallet in a working directory and a home of its own, the verdict
# table with its checks and the controls that hand each assertion altered input,
# and the reader of the chain's own record. A journey adds its scenario.
# shellcheck disable=SC2016 # single-quoted jq programs name jq variables, never shell ones
# shellcheck disable=SC2154 # the sourcing journey sets the variables named above
# shellcheck disable=SC2034 # the sourcing journey reads release_hash and failed
[ ! -e "$work" ] || {
  echo "$rig_name: $work exists; every run takes a fresh directory" >&2
  exit 2
}
mkdir -p "$work"
work="$(cd "$work" && pwd)"
receipts="$work/receipts"
chain_dir="$work/chain"
listings="$work/listings"
mkdir -p "$receipts" "$chain_dir" "$listings" "$work/actors" "$work/release"
verdicts="$work/verdicts.md"
printf '| leg | clause | verdict |\n|---|---|---|\n' >"$verdicts"
failed=0
leg=""

say() { echo "$rig_name: $*" >&2; }
setup_fail() {
  echo "$rig_name: SETUP: $*" >&2
  exit 3
}

# ------------------------------------------------------------------
# One development node, and four wallets
# ------------------------------------------------------------------
timeout_bin="$(command -v timeout)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/no-pin.XXXXXX")"
node_pids() { pgrep -f "cardano-node run --config $scratch/cardano-e2e" 2>/dev/null || true; }
# shellcheck disable=SC2329 # the EXIT trap below invokes this
release_scratch() {
  local code=$?
  local pid _wait
  trap - EXIT
  [ -n "${devnet_pid:-}" ] && kill "$devnet_pid" 2>/dev/null || true
  for pid in $(node_pids); do kill "$pid" 2>/dev/null || true; done
  for _wait in $(seq 1 100); do
    [ -z "$(node_pids)" ] && break
    sleep 0.1
  done
  # The node's database and the facade's record of the chain are large and
  # are read only while the node runs; the chain views keep what was read.
  chmod -R u+rwx "$scratch" 2>/dev/null || true
  rm -rf "$scratch" || true
  # The wallets' keys are throwaway keys of this network; the copies of the release are the one in release/.
  rm -f "$work"/actors/*/cwd/*.skey "$work"/actors/*/cwd/plutus.json
  if [ -e "$scratch" ]; then
    echo "$rig_name: scratch remains: $scratch" >&2
    code=1
  fi
  cat "$verdicts" || true
  exit "$code"
}
trap release_scratch EXIT
export TMPDIR="$scratch"
export E2E_GENESIS_DIR="${E2E_GENESIS_DIR:?E2E_GENESIS_DIR names the genesis directory of the development network}"

actors=(carol alice bob dave)
for actor in "${actors[@]}"; do
  mkdir -p "$work/actors/$actor/cwd" "$work/actors/$actor/home"
  od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$work/actors/$actor/cwd/$actor.skey"
done
fund=()
for actor in "${actors[@]}"; do fund+=(--fund-skey "$work/actors/$actor/cwd/$actor.skey"); done
"$devnet" "${fund[@]}" --fund-outputs 8 --fund-lovelace 2000000000 \
  >"$scratch/devnet.out" 2>"$scratch/devnet.err" &
devnet_pid=$!

provider_url=""
time_directory=""
network_magic=""
probe_socket=""
evidence_directory=""
for _ in $(seq 1 900); do
  settings="$(head -n1 "$scratch/devnet.out" 2>/dev/null || true)"
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
  tail -40 "$scratch/devnet.err" >&2 || true
  setup_fail "the development network never printed usable provider, time, probe and record settings"
fi
evidence="$evidence_directory/independent-facade-sources.jsonl"
say "one development network at $provider_url; the chain's own record is read from it"

# The release: the validators every wallet runs against, copied to each one's
# directory, and the hash of the request validator, which is the application's
# policy and the payment credential of the committed address.
cp "$blueprint_source" "$work/release/plutus.json"
release_hash="$(sha256sum "$work/release/plutus.json" | cut -d' ' -f1)"
application_hash="$(jq -er '.validators[] | select(.title == "open_datum_requests.open_datum_requests.spend") | .hash' "$work/release/plutus.json")"
[[ "$application_hash" =~ ^[0-9a-f]{56}$ ]] || setup_fail "the release carries no request validator hash"
for actor in "${actors[@]}"; do cp "$work/release/plutus.json" "$work/actors/$actor/cwd/plutus.json"; done

node=(--koios-url "$provider_url" --network-time "$time_directory" --network-magic "$network_magic")

# ------------------------------------------------------------------
# Running a command as a wallet
# ------------------------------------------------------------------
# run_as ACTOR NAME PROGRAM ARGS...: one process, in the wallet's own directory
# with a home of their own and nothing else in the environment. The wallet's key
# and the release are the files beside it. The receipt, the narration and the
# exit status are kept under the receipts; no verdict is given.
run_as() {
  local actor="$1" name="$2" program="$3" status=0
  shift 3
  (
    cd "$work/actors/$actor/cwd"
    env -i HOME="$work/actors/$actor/home" PATH=/nonexistent LC_ALL=C.UTF-8 \
      "$timeout_bin" 900 "$program" "$@" "${node[@]}" --wallet-skey "$actor.skey" \
      >"$receipts/$name.json" 2>"$receipts/$name.err" </dev/null
  ) || status=$?
  printf '%s\n' "$status" >"$receipts/$name.status"
}
# as ACTOR NAME PROGRAM ARGS...: run_as, and the command must succeed.
as() {
  local name="$2" status
  run_as "$@"
  status="$(cat "$receipts/$name.status")"
  if [ "$status" = 0 ] && jq -e '.outcome == "success"' "$receipts/$name.json" >/dev/null 2>&1; then
    say "$name: success"
  else
    say "$name: $(jq -r 'if .reason then .outcome + "/" + .reason else .outcome end' "$receipts/$name.json" 2>/dev/null || echo "no receipt") (exit $status)"
    tail -5 "$receipts/$name.err" >&2 || true
    record "$name" "the command succeeds" "**does not hold**"
    failed=1
    exit 1
  fi
}
field() { jq -r "$2" "$receipts/$1.json"; }

# ------------------------------------------------------------------
# Verdicts
# ------------------------------------------------------------------
record() {
  printf '| %s | %s | %s |\n' "$1" "$2" "$3" >>"$verdicts"
}
# check CLAUSE CMD...: the clause holds when CMD exits 0.
check() {
  local clause="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    record "$leg" "$clause" holds
    say "$leg: holds: $clause"
  else
    record "$leg" "$clause" "**does not hold**"
    say "$leg: DOES NOT HOLD: $clause"
    failed=1
  fi
}
# control CLAUSE CMD...: the assertion CMD, handed altered input, fails; an
# assertion that holds on altered input proves nothing.
control() {
  local clause="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    record "$leg" "control: $clause" "**holds on altered input**"
    say "$leg: CONTROL HOLDS ON ALTERED INPUT: $clause"
    failed=1
  else
    record "$leg" "control: $clause" "fails on altered input"
    say "$leg: control fails as it must: $clause"
  fi
}

# ------------------------------------------------------------------
# The chain, read from its own record
# ------------------------------------------------------------------
chain_blocks() { grep -c '"kind":"chain-sync-full-block"' "$evidence" || true; }
# Wait until the chain has moved on by a few blocks, so that what a command
# sent just before it exited is in the record before it is read.
settle() {
  local start
  start="$(chain_blocks)"
  for _ in $(seq 1 600); do
    [ "$(chain_blocks)" -ge $((start + 4)) ] && return 0
    sleep 0.5
  done
  setup_fail "the chain produced no further block"
}
chain() { python3 -I "$chain_view" "$@" <"$evidence"; }
# view_tx NAME TXID: the transaction as the chain holds it.
view_tx() {
  local tries=0
  until chain tx "$2" >"$chain_dir/$1.tx.json" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 240 ] || setup_fail "the chain's record never held transaction $2 ($1)"
    sleep 0.5
  done
}
# view_unspent NAME: every output no later block spends.
view_unspent() {
  settle
  chain unspent >"$chain_dir/$1.unspent.json"
}
tx_of() { field "$1" ".submissions[] | select(.step == \"$2\") | .tx"; }
now_ms() { date +%s%3N; }
# Wait until the chain's clock, which is the wall clock, is past a time named
# in milliseconds, with a margin for the node's slots.
wait_until_ms() {
  while [ "$(now_ms)" -lt "$(($1 + 4000))" ]; do sleep 1; done
}
equal() { [ -n "$1" ] && [ "$1" != null ] && [ "$1" = "$2" ]; }
