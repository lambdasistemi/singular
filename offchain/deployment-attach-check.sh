#!/usr/bin/env bash
# One devnet, one deployment, three runners attached to it.
#
# The claim: a run given --deployment boots no registry and publishes no
# reference script. Counting is the evidence — the number of registry
# state outputs and the number of reference-script outputs are read
# before and after the three runners, and any change fails this script.
#
# A control runs last: the same runner WITHOUT --deployment, which does
# boot and publish, so the counters are shown able to move. A check that
# has never been seen to fail is not evidence.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here"
work="$(mktemp -d)"
trap 'rm -rf "$work"; [ -n "${devnet_pid:-}" ] && kill "$devnet_pid" 2>/dev/null || true' EXIT

registry="$(nix build --quiet --no-link --print-out-paths "$here/../onchain#plutus-blueprint")"
naming="$(nix build --quiet --no-link --print-out-paths "$here/../naming-onchain#plutus-blueprint")"
export REGISTRY_BLUEPRINT="$registry" NAMING_BLUEPRINT="$naming"

# Build everything first. A `nix run` that has to build spends minutes
# before its program prints anything, and the socket wait below would
# time out on the build rather than on the devnet.
echo "attach-check: building the runners and tools"
nix build --quiet --no-link "$here#devnet" "$here#deployment" \
    "$here#register-rows" "$here#recovery-rows" "$here#retirement-rows"

# The devnet builds its chain under TMPDIR/cardano-e2e. Sharing that
# with the last run means starting on its database and timing out on a
# socket that never appears, so each run gets its own — kept short,
# because a unix socket path has a hard length limit.
export TMPDIR="$work"

echo "attach-check: starting a devnet the deployment can outlive"
nix run --quiet "$here#devnet" > "$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
for _ in $(seq 1 300); do
    sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
    [ -n "$sock" ] && [ -S "$sock" ] && break
    kill -0 "$devnet_pid" 2>/dev/null || break
    sleep 1
done
if [ -z "${sock:-}" ] || [ ! -S "${sock:-}" ]; then
    echo "attach-check: the devnet never printed a usable socket" >&2
    echo "--- devnet stdout ---" >&2; cat "$work/devnet.out" >&2 || true
    echo "--- devnet stderr ---" >&2; tail -40 "$work/devnet.err" >&2 || true
    exit 1
fi
echo "attach-check: devnet socket $sock"

# The devnet genesis key, in the file form a joiner supplies.
genesis_skey="$work/joiner.skey"
nix run --quiet "$here#deployment" -- genesis-skey --out "$genesis_skey"

external=(--node-socket "$sock" --network-magic 42 --wallet-skey "$genesis_skey")
manifest="$work/devnet-deployment.json"

count_state_outputs() { nix run --quiet "$here#deployment" -- count "${external[@]}" --deployment "$manifest" --what state; }
# Register publishes at its ordinary-party fixture address; deployment and
# the other runners publish at the funder. Observe both in every snapshot.
# This is the public address derived from register's partySeed.
register_publisher=60adb59bbc097e8051233f8aa3c5a5113406e10c8510bc99378e78f242
count_reference_outputs() { nix run --quiet "$here#deployment" -- count "${external[@]}" --deployment "$manifest" --what reference --reference-address-bytes "$register_publisher"; }

echo "attach-check: deploying once"
nix run --quiet "$here#deployment" -- deploy "${external[@]}" --out "$manifest" --release devnet-check

before_state="$(count_state_outputs)"
before_refs="$(count_reference_outputs)"
echo "attach-check: before — $before_state registry state output(s), $before_refs reference output(s)"

for runner in register-rows recovery-rows retirement-rows; do
    echo "attach-check: $runner, attached"
    spelling=()
    [ "$runner" != register-rows ] || spelling=(--spelling audience-name)
    nix run --quiet "$here#$runner" -- "${external[@]}" --deployment "$manifest" "${spelling[@]}"
done

echo "attach-check: the exact spelling is already held; rerun must submit and observe duplicate refusal"
nix run --quiet "$here#register-rows" -- "${external[@]}" --deployment "$manifest" --spelling=audience-name | tee "$work/rerun.out"
grep -F 'spelling "audience-name" is already held: duplicate insert refused' "$work/rerun.out"

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
echo "attach-check: control — $control_state registry state output(s), $control_refs reference output(s)"
[ "$control_state" -gt "$after_state" ] || { echo "FAIL: the control booted no registry, so the state counter proves nothing"; fail=1; }
[ "$control_refs" -gt "$after_refs" ] || { echo "FAIL: the control published no reference scripts, so the reference counter proves nothing"; fail=1; }

[ "$fail" -eq 0 ] || exit 1
echo "attach-check: PASS — three runners attached, nothing booted, nothing published; the control moved both counters"
