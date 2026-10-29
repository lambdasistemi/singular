#!/usr/bin/env bash
# Tool, not a product obligation: run the two creation workflows on separate
# development networks with the same frozen genesis and generated wallet funding.
# Both networks and their child processes belong to this command; diagnostics
# survive failure. Only generated development-network keys are used.
# usage: measure-creation-cost.sh BASELINE BLUEPRINT REVISION CANDIDATE BLUEPRINT REVISION DEVNET GENESIS NODE OUTPUT
set -euo pipefail
[ "$#" = 10 ] || {
  echo "see the usage in $0" >&2
  exit 2
}
baseline="$1" baseline_blueprint="$2" baseline_revision="$3"
candidate="$4" candidate_blueprint="$5" candidate_revision="$6"
devnet="$7" genesis="$8" node_program="$9" destination="${10}"
tool_directory="$(cd "$(dirname "$0")" && pwd)"
[ ! -e "$destination" ] || {
  echo "the output directory already exists" >&2
  exit 2
}
mkdir -p "$destination"
destination="$(cd "$destination" && pwd)"
scratch="$(mktemp -d /tmp/creation.XXXXXX)"
declare -A devnet_pids=()
stop_network() {
  local design="$1"
  if [ -n "${devnet_pids[$design]:-}" ]; then
    kill "${devnet_pids[$design]}" 2>/dev/null || true
    wait "${devnet_pids[$design]}" 2>/dev/null || true
    unset 'devnet_pids[$design]'
  fi
  local pid
  for pid in $(pgrep -f "cardano-node run --config $scratch/$design/cardano-e2e" || true); do
    kill "$pid" 2>/dev/null || true
  done
}
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
  local code=$?
  trap - EXIT
  stop_network previous
  stop_network candidate
  for design in previous candidate; do
    [ ! -f "$scratch/$design/cardano-e2e/node.log" ] || cp "$scratch/$design/cardano-e2e/node.log" "$destination/$design/node.log"
  done
  rm -f "$destination/wallet.skey"
  rm -rf "$scratch"
  exit "$code"
}
trap cleanup EXIT
cp -R "$genesis" "$destination/genesis"
chmod -R u+w "$destination/genesis"
start_epoch="$(($(date +%s) + 5))"
start_time="$(date -u -d "@$start_epoch" +%Y-%m-%dT%H:%M:%SZ)"
sed -i "s/PLACEHOLDER/$start_time/" "$destination/genesis/shelley-genesis.json"
sed -i "s/\"startTime\": 0/\"startTime\": $start_epoch/" "$destination/genesis/byron-genesis.json"
od -An -tx1 -N32 /dev/urandom | tr -d ' \n' >"$destination/wallet.skey"
export E2E_GENESIS_DIR="$destination/genesis"
# Both nodes must begin at the frozen genesis together: starting a new empty
# node after the other leg would miss this small devnet's initial ledger-view
# window. The harness owns, terminates and joins both concurrent nodes.
for design in previous candidate; do
  mkdir -p "$scratch/$design" "$destination/$design"
  TMPDIR="$scratch/$design" "$devnet" --fund-skey "$destination/wallet.skey" --fund-outputs 8 --fund-lovelace 2000000000 \
    --evidence-dir "$destination/$design/source" >"$destination/$design/devnet.out" 2>"$destination/$design/devnet.err" &
  devnet_pids[$design]=$!
done
for design in previous candidate; do
  program="$baseline" blueprint="$baseline_blueprint" revision="$baseline_revision"
  if [ "$design" = candidate ]; then
    program="$candidate" blueprint="$candidate_blueprint" revision="$candidate_revision"
  fi
  leg="$destination/$design"
  for _ in $(seq 1 900); do
    [ -s "$leg/devnet.out" ] && break
    kill -0 "${devnet_pids[$design]}" || exit 3
    sleep 1
  done
  provider="$(head -n1 "$leg/devnet.out" | jq -er .providerUrl)"
  network_time="$(head -n1 "$leg/devnet.out" | jq -er .networkTimeDirectory)"
  version_text="$("$program" --version)"
  [[ "$version_text" == *"$revision"* ]] || {
    echo "program revision differs" >&2
    exit 3
  }
  release="$(jq -n --arg version "$version_text" --arg blueprint "$(sha256sum "$blueprint" | cut -d' ' -f1)" \
    --arg program "$(sha256sum "$program" | cut -d' ' -f1)" \
    '{version: $version, blueprintSha256: $blueprint, programSha256: $program}')"
  for creation in first later; do
    mkdir -p "$leg/$creation/home"
    windows=(--process-time 60000 --retract-time 180000)
    [ "$design" = previous ] || windows=(--process-time 60000 --reclaim-time 180000 --booking-width 60000)
    env -i HOME="$leg/$creation/home" PATH=/nonexistent LC_ALL=C.UTF-8 \
      "$program" create --blueprint "$blueprint" "${windows[@]}" --state-dir "$leg/$creation/state" \
      --wallet-skey "$destination/wallet.skey" --koios-url "$provider" --network-time "$network_time" --network-magic 42 \
      >"$leg/$creation/receipt.json" 2>"$leg/$creation/stderr"
  done
  # Stop/join before reading the completed source record. The private node and
  # client must coexist during execution; nothing outlives this measuring tool.
  stop_network "$design"
  jq -n --arg design "$design" --arg revision "$revision" --argjson release "$release" \
    --arg nodeVersion "$("$node_program" --version)" --arg devnetHash "$(sha256sum "$devnet" | cut -d' ' -f1)" \
    --arg pythonVersion "$(python3 --version)" --arg jqVersion "$(jq --version)" \
    --arg first "$leg/first/receipt.json" --arg later "$leg/later/receipt.json" \
    '{design: $design, revision: $revision, application: "open datum",
      tools: {cardanoNode: $nodeVersion, devnetSha256: $devnetHash, python: $pythonVersion, jq: $jqVersion},
      workload: {creations: ["first", "later"], fundingOutputs: 8, fundingLovelacePerOutput: 2000000000,
        processingMilliseconds: 60000, reclaimingMilliseconds: 180000},
      first: {commandReceipt: $first, release: $release}, later: {commandReceipt: $later, release: $release}}' \
    >"$leg/manifest.json"
  python3 "$tool_directory/creation-cost.py" capture --manifest "$leg/manifest.json" \
    --source "$leg/source/independent-facade-sources.jsonl" --output "$destination/$design.json"
done
