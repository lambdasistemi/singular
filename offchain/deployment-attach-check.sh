#!/usr/bin/env bash
# One devnet, one deployment, three runners attached to it.
#
# The claim: a run given --deployment boots no registry and publishes no
# reference script. Counting is the evidence — the number of registry
# state outputs and the number of reference-script outputs are read
# before and after the three runners, and any change fails this script.
#
# A control runs first: the same runner WITHOUT --deployment, which does
# boot and publish, so the counters are shown able to move. A check that
# has never been seen to fail is not evidence.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${devnet_pid:-}" ] && kill "$devnet_pid" 2>/dev/null || true' EXIT

mpfs="$(nix build --quiet --no-link --print-out-paths "$here/../onchain#plutus-blueprint")"
naming="$(nix build --quiet --no-link --print-out-paths "$here/../naming-onchain#plutus-blueprint")"
export MPFS_BLUEPRINT="$mpfs" NAMING_BLUEPRINT="$naming"

echo "attach-check: starting a devnet the deployment can outlive"
nix run --quiet "$here#devnet" > "$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
for _ in $(seq 1 120); do
    sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
    [ -n "$sock" ] && [ -S "$sock" ] && break
    sleep 1
done
[ -n "${sock:-}" ] || { echo "attach-check: the devnet never printed a socket" >&2; exit 1; }
echo "attach-check: devnet socket $sock"

# The devnet genesis key, in the file form a joiner supplies.
genesis_skey="$work/joiner.skey"
nix run --quiet "$here#deployment" -- genesis-skey --out "$genesis_skey"

external=(--node-socket "$sock" --network-magic 42 --wallet-skey "$genesis_skey")
manifest="$work/devnet-deployment.json"

count_state_outputs() { nix run --quiet "$here#deployment" -- count "${external[@]}" --deployment "$manifest" --what state; }
count_reference_outputs() { nix run --quiet "$here#deployment" -- count "${external[@]}" --deployment "$manifest" --what reference; }

echo "attach-check: deploying once"
nix run --quiet "$here#deployment" -- deploy "${external[@]}" --out "$manifest" --release devnet-check

before_state="$(count_state_outputs)"
before_refs="$(count_reference_outputs)"
echo "attach-check: before — $before_state registry state output(s), $before_refs reference output(s)"

for runner in register-rows recovery-rows retirement-rows; do
    echo "attach-check: $runner, attached"
    nix run --quiet "$here#$runner" -- "${external[@]}" --deployment "$manifest"
done

after_state="$(count_state_outputs)"
after_refs="$(count_reference_outputs)"
echo "attach-check: after  — $after_state registry state output(s), $after_refs reference output(s)"

fail=0
[ "$before_state" = "$after_state" ] || { echo "FAIL: a registry was booted ($before_state -> $after_state)"; fail=1; }
[ "$before_refs" = "$after_refs" ] || { echo "FAIL: reference scripts were published ($before_refs -> $after_refs)"; fail=1; }

echo "attach-check: control — the same runner without --deployment must move both counters"
nix run --quiet "$here#register-rows" -- "${external[@]}"
control_state="$(count_state_outputs)"
control_refs="$(count_reference_outputs)"
[ "$control_state" -gt "$after_state" ] || { echo "FAIL: the control booted no registry, so the state counter proves nothing"; fail=1; }
[ "$control_refs" -gt "$after_refs" ] || { echo "FAIL: the control published no reference scripts, so the reference counter proves nothing"; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo "attach-check: PASS — three runners attached, nothing booted, nothing published; the control moved both counters"
