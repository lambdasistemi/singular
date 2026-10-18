#!/usr/bin/env bash
# Start ONE private development node from the extracted release archive's own devnet, funding by address
# the two wallets scene 0 made: each address is read back out of its vault with `singular wallet
# address`, exactly as the Demo 1 run page does, and each gets six outputs of 2000 ada. The node never
# sees a key. It funds nothing outside this node.
# Every process this starts is recorded in $RUN/pids as "pid start-ticks role" BEFORE anything else can fail;
# devnet-down.sh stops only those.
# WORKAROUND: the negative host of scene 3 takes a key file, and a vault holds no key file to give it -> a harness-only forger key (derived from a label) is funded by file here, off camera, and scene 3 names it by the shorthand $FORGER; the viewer never sees a key file.
set -euo pipefail
: "${REHEARSAL_WORK:?devnet-up.sh needs the run scratch directory}"
: "${REHEARSAL_BIN:?devnet-up.sh needs the built binaries directory}"
: "${E2E_GENESIS_DIR:?devnet-up.sh needs the genesis directory}"
RUN="$REHEARSAL_WORK"
bin="$REHEARSAL_BIN"
ticks() {
  local s
  s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"
  read -r -a f <<<"$s"
  echo "${f[19]}"
}
vault_address() { "$bin/singular" wallet address --vault "$RUN/play/$1/$1.vault" --network-magic 42 --passphrase-fd 3 3<"$RUN/play/vault-pass/$1"; }
alice_addr="$(vault_address alice)"
bob_addr="$(vault_address bob)"
printf '%s' play-forger | sha256sum | cut -c1-64 >"$RUN/keys/forger.key"
"$bin/devnet" --fund-address "$alice_addr:6:2000000000" --fund-address "$bob_addr:6:2000000000" \
  --fund "$RUN/keys/forger.key:4:2000000000" \
  >"$RUN/devnet.out" 2>"$RUN/devnet.err" &
devnet_pid=$!
echo "$devnet_pid $(ticks "$devnet_pid") devnet" >>"$RUN/pids"
sock="" provider_url="" time_directory="" network_magic=""
for _ in $(seq 1 900); do
  settings="$(head -n1 "$RUN/devnet.out" 2>/dev/null || true)"
  sock="$(jq -er '.privateProbeSocket' <<<"$settings" 2>/dev/null || true)"
  provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
  time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
  network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
  [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -S "$sock" ] && [ -r "$time_directory/time-manifest.json" ] && break
  kill -0 "$devnet_pid" 2>/dev/null || break
  sleep 1
done
if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -S "$sock" ] || [ ! -r "$time_directory/time-manifest.json" ]; then
  tail -40 "$RUN/devnet.err" >&2 || true
  echo "devnet-up: SETUP: the devnet never printed usable settings" >&2
  exit 3
fi
# the devnet runner's own children (its node): recorded too
while read -r child; do
  echo "$child $(ticks "$child") node" >>"$RUN/pids"
done < <(ps -o pid= --ppid "$devnet_pid")
echo "$sock" >"$RUN/probe.sock"
# What the story's shell variables stand for; read by every scene (all paths relative to a player's directory).
# WORKAROUND: every command would repeat long node, blueprint and wallet flags and wrap -> $BLUEPRINT $NODE $TOKEN $VAULT $FORGER $bob_addr shell variables, set off camera in the run's session.env, shown once in scene 2.
cat >"$RUN/session.env" <<SESSION
export NODE="--koios-url $provider_url --network-time time --network-magic 42"
export BLUEPRINT="--blueprint onchain/plutus.json"
export VAULT="--vault alice.vault --passphrase-fd 3"
export FORGER="--wallet-skey $RUN/keys/forger.key"
export bob_addr="$bob_addr"
SESSION
echo "devnet-up: ready at $provider_url (pid $devnet_pid)"
