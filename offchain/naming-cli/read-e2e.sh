#!/usr/bin/env bash
# Exercise the packaged command's read boundary on one isolated node.
set -euo pipefail
root="$(realpath "${1:-.}")"
work="$(mktemp -d /tmp/naming-cli.XXXXXX)"
evidence="${SINGULAR_CLI_EVIDENCE:-$work/evidence}"
mkdir -p "$evidence"
cleanup() {
    if [ -n "${node_pid:-}" ]; then
        # The background devnet does not unwind its Haskell bracket on TERM.
        # Stop its direct node child before terminating the launcher.
        pkill -TERM -P "$node_pid" 2>/dev/null || true
        kill "$node_pid" 2>/dev/null || true
        wait "$node_pid" 2>/dev/null || true
    fi
    rm -f "$work/genesis.skey"
}
trap cleanup EXIT
registry="$(nix build --quiet --no-link --print-out-paths "$root/onchain#plutus-blueprint")"
naming="$(nix build --quiet --no-link --print-out-paths "$root/naming-onchain#plutus-blueprint")"
export REGISTRY_BLUEPRINT="$registry" NAMING_BLUEPRINT="$naming"
cli="$(nix build --quiet --no-link --print-out-paths "$root/offchain#singular-naming")/bin/singular-naming"
deployment="$(nix build --quiet --no-link --print-out-paths "$root/offchain#deployment")/bin/deployment"
devnet="$(nix build --quiet --no-link --print-out-paths "$root/offchain#devnet")/bin/devnet"
"$cli" --help > "$evidence/help.txt"
export TMPDIR="$work"
export E2E_GENESIS_DIR="$root/offchain/e2e-test/genesis"
"$devnet" > "$evidence/node.out" 2> "$evidence/node.err" &
node_pid=$!
for _ in $(seq 1 300); do
    socket="$(head -n1 "$evidence/node.out")"
    [ -n "$socket" ] && [ -S "$socket" ] && break
    kill -0 "$node_pid" 2>/dev/null || break
    sleep 1
done
[ -n "${socket:-}" ] && [ -S "$socket" ] || { echo 'devnet socket unavailable' >&2; exit 1; }
"$deployment" genesis-skey --out "$work/genesis.skey"
wallet=(--node-socket "$socket" --network-magic 42 --wallet-skey "$work/genesis.skey")
manifest="$work/registry.json"
"$deployment" deploy "${wallet[@]}" --out "$manifest" --release naming-cli-read-test > "$evidence/deploy.log"
selected=(--deployment "$manifest" --node-socket "$socket" --network-magic 42)
state_before="$("$deployment" count "${wallet[@]}" --deployment "$manifest" --what state)"
refs_before="$("$deployment" count "${wallet[@]}" --deployment "$manifest" --what reference)"
"$cli" "${selected[@]}" attach > "$evidence/attach.json"
jq -e '.observation.status == "attached"' "$evidence/attach.json" > /dev/null
"$cli" "${selected[@]}" inspect --name user-chosen-name > "$evidence/inspect.json"
jq -e '.observation.name == "user-chosen-name" and .observation.entry.status == "absent" and .observation.pendingRequests == []' "$evidence/inspect.json" > /dev/null
jq --arg policy '00000000000000000000000000000000000000000000000000000000' '.depStatePolicy = $policy' "$manifest" > "$work/wrong.json"
if "$cli" --deployment "$work/wrong.json" --node-socket "$socket" --network-magic 42 attach > "$evidence/refused.out" 2> "$evidence/refused.err"; then
    echo 'wrong deployment identity was accepted' >&2
    exit 1
fi
case "$(cat "$evidence/refused.err")" in
    *'manifest belongs to another release'*) ;;
    *) echo 'wrong deployment failed for an unrelated reason' >&2; exit 1 ;;
esac
state_after="$("$deployment" count "${wallet[@]}" --deployment "$manifest" --what state)"
refs_after="$("$deployment" count "${wallet[@]}" --deployment "$manifest" --what reference)"
[ "$state_before" = "$state_after" ]
[ "$refs_before" = "$refs_after" ]
printf '%s\n' 'PASS: packaged attach/inspect read the selected registry, refused wrong identity, and created no registry or reference scripts'
