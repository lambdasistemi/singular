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
built="$(nix build --quiet --no-link --print-out-paths "$offchain#devnet" "$offchain#deployment")"
# The same wrapped command `nix run .#deployment` launches, invoked directly
# for the checks below so they add no Nix start.
deployment="$(printf '%s\n' "$built" | grep -E -- '-deployment$')/bin/deployment"
if [ ! -x "$deployment" ]; then
  echo 'SETUP-FAIL: the build produced no deployment command' >&2
  exit 1
fi

# The verb router needs no node. The first argument that is not a flag
# selects one of the four verbs; anything else is the usage refusal, and
# each verb refuses its missing required flag by name.
expect_refusal() {
  local want="$1"
  shift
  set +e
  "$deployment" "$@" > "$work/refusal.out" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ] || ! grep -F -- "$want" "$work/refusal.out" > /dev/null; then
    echo "FAIL: deployment $* exited $rc without: $want" >&2
    cat "$work/refusal.out" >&2
    exit 1
  fi
}
usage='usage: deployment deploy --out MANIFEST'
expect_refusal "$usage"
expect_refusal "$usage" --out stray count
expect_refusal 'deploy needs --out MANIFEST' deploy
expect_refusal 'verify needs --deployment MANIFEST' verify
expect_refusal 'count needs --deployment MANIFEST' count
expect_refusal 'count needs --what state|reference' count --deployment "$work/unread.json"
expect_refusal 'genesis-skey needs --out FILE' genesis-skey

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
"$deployment" genesis-skey "--out=$work/joiner-equals.skey" > /dev/null
cmp -s "$joiner" "$work/joiner-equals.skey" || {
  echo 'FAIL: genesis-skey --out=FILE wrote a different key than --out FILE' >&2
  exit 1
}
external=(--node-socket "$sock" --network-magic 42 --wallet-skey "$joiner")
nix run --quiet "$offchain#deployment" -- deploy "${external[@]}" --out "$manifest" --release identity-check > "$work/deploy.out"
nix run --quiet "$offchain#deployment" -- verify "${external[@]}" --deployment "$manifest" > "$work/verify.out"
grep -F 'deployment complete:' "$work/verify.out" >/dev/null || {
  echo 'FAIL: intact manifest did not reach completed node verification' >&2
  cat "$work/verify.out" >&2
  exit 1
}

# count against the deployment just made: one registry output under the
# recorded state policy, and exactly the reference outputs the manifest
# records, asked with both flag spellings; an unknown --what is refused.
states="$("$deployment" count "${external[@]}" --deployment "$manifest" --what state)"
if [ "$states" != 1 ]; then
  echo "FAIL: count --what state reported '$states' registry outputs, not 1" >&2
  exit 1
fi
recorded="$(jq '.depReferenceScripts | length' "$manifest")"
references="$("$deployment" count "${external[@]}" "--deployment=$manifest" --what=reference)"
if [ "$references" != "$recorded" ]; then
  echo "FAIL: count --what=reference reported '$references', the manifest records $recorded" >&2
  exit 1
fi
expect_refusal 'count: --what must be state or reference, not registry' \
  count "${external[@]}" --deployment "$manifest" --what registry

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

echo "PASS: verb router refusals held; intact node verification reached completion; count found $states registry output and $references of $recorded recorded reference outputs; changed representative policy exited $rc with identity diagnostic"
