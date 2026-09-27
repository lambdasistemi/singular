#!/usr/bin/env bash
# Supported deployment identity boundary. The old three-runner attachment
# script is deliberately outside this check.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
offchain="$repo/offchain"
cd "$offchain"
work="$(mktemp -d /tmp/s269-identity.XXXXXX)"
devnet_pid=
cleanup() {
  if [ -n "$devnet_pid" ]; then kill "$devnet_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

registry="$(nix build --quiet --no-link --print-out-paths "$repo/onchain#plutus-blueprint")"
naming="$(nix build --quiet --no-link --print-out-paths "$repo/naming-onchain#plutus-blueprint")"
export REGISTRY_BLUEPRINT="$registry" NAMING_BLUEPRINT="$naming"
nix build --quiet --no-link "$offchain#devnet" "$offchain#deployment"

export TMPDIR="$work"
nix run --quiet "$offchain#devnet" > "$work/devnet.out" 2> "$work/devnet.err" &
devnet_pid=$!
sock=
for _ in $(seq 1 300); do
  sock="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  if [ -n "$sock" ] && [ -S "$sock" ]; then break; fi
  if ! kill -0 "$devnet_pid" 2>/dev/null; then break; fi
  sleep 1
done
if [ -z "$sock" ] || [ ! -S "$sock" ]; then
  echo 'SETUP-FAIL: devnet produced no live socket' >&2
  tail -40 "$work/devnet.err" >&2 || true
  exit 1
fi

joiner="$work/joiner.skey"
manifest="$work/deployment.json"
nix run --quiet "$offchain#deployment" -- genesis-skey --out "$joiner"
external=(--node-socket "$sock" --network-magic 42 --wallet-skey "$joiner")
nix run --quiet "$offchain#deployment" -- deploy "${external[@]}" --out "$manifest" --release identity-check > "$work/deploy.out"
nix run --quiet "$offchain#deployment" -- verify "${external[@]}" --deployment "$manifest" > "$work/verify.out"
grep -F 'deployment complete:' "$work/verify.out" >/dev/null || {
  echo 'FAIL: intact manifest did not reach completed node verification' >&2
  cat "$work/verify.out" >&2
  exit 1
}

jq '.depRepresentativePolicy = ("00" * 28)' "$manifest" > "$work/wrong-policy.json"
if cmp -s "$manifest" "$work/wrong-policy.json"; then
  echo 'SETUP-FAIL: policy mutation did not change the manifest' >&2
  exit 1
fi
set +e
nix run --quiet "$offchain#deployment" -- verify "${external[@]}" --deployment "$work/wrong-policy.json" > "$work/wrong-policy.out" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo 'FAIL: mismatched representative policy was accepted' >&2
  exit 1
fi
grep -F "this release's registry-bound active policy differs from the deployment" "$work/wrong-policy.out" >/dev/null || {
  echo "FAIL: rejection exit=$rc lacked the intended identity diagnostic" >&2
  cat "$work/wrong-policy.out" >&2
  exit 1
}

echo "PASS: intact node verification reached completion; changed representative policy exited $rc with identity diagnostic"
