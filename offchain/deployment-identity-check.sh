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

# The naming scripts pin two hashes in their source: the registry's state
# script (naming.ak `mpfs_state_hash`, used by the application and the
# retirement custody) and the retirement custody's (application.ak
# `retirement_custody_hash`). The naming manifest check compares each script
# with its own build only, so a pin left behind by a registry change still
# builds and still matches. Read both hashes from the blueprints just built
# and require each, byte-aligned, in the compiled code that pins it, before
# any devnet starts.
naming_identity_problems() {
  jq -r -n --slurpfile reg "$1" --slurpfile nam "$2" '
    def hash($bp; $t): [$bp.validators[] | select(.title == $t) | .hash] | first;
    def code($bp; $t): [$bp.validators[] | select(.title == $t) | .compiledCode] | first;
    def carries($c; $h):
      $c != null and $h != null
      and ([$c | indices($h)[] | select(. % 2 == 0)] | length > 0);
    hash($reg[0]; "state.state.spend") as $state
    | hash($nam[0]; "retirement_custody.retirement_custody.spend") as $custody
    | code($nam[0]; "application.application.spend") as $app
    | code($nam[0]; "retirement_custody.retirement_custody.spend") as $held
    | (if $state == null then "the registry blueprint has no state.state.spend" else empty end),
      (if $custody == null then "the naming blueprint has no retirement_custody.retirement_custody.spend" else empty end),
      (if carries($app; $state) then empty else "application.application.spend does not carry the registry state hash \($state)" end),
      (if carries($held; $state) then empty else "retirement_custody.retirement_custody.spend does not carry the registry state hash \($state)" end),
      (if carries($app; $custody) then empty else "application.application.spend does not carry the retirement custody hash \($custody)" end)
  '
}
# Control: against a registry whose state hash is another, the comparison
# must refuse, or it guards nothing.
jq '.validators |= map(if .title == "state.state.spend" then .hash = ("00" * 28) else . end)' \
  "$registry" >"$work/other-registry.json"
if [ -z "$(naming_identity_problems "$work/other-registry.json" "$naming")" ]; then
  echo 'FAIL: naming identity: the comparison accepted a registry with another state hash' >&2
  exit 1
fi
if ! problems="$(naming_identity_problems "$registry" "$naming")"; then
  echo 'FAIL: naming identity: the blueprints could not be read' >&2
  exit 1
fi
if [ -n "$problems" ]; then
  while IFS= read -r p; do echo "FAIL: naming identity: $p" >&2; done <<<"$problems"
  exit 1
fi
echo "naming identity: OK — the application and the retirement custody carry state $(jq -r '.validators[] | select(.title == "state.state.spend") | .hash' "$registry"); the application carries retirement custody $(jq -r '.validators[] | select(.title == "retirement_custody.retirement_custody.spend") | .hash' "$naming")"

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
  "$deployment" "$@" >"$work/refusal.out" 2>&1
  local rc=$?
  set -e
  if [ "$rc" -eq 0 ] || ! grep -F -- "$want" "$work/refusal.out" >/dev/null; then
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
nix run --quiet "$offchain#devnet" >"$work/devnet.out" 2>"$work/devnet.err" &
devnet_pid=$!
provider_url=
network_magic=
time_directory=
for _ in $(seq 1 300); do
  settings="$(head -n1 "$work/devnet.out" 2>/dev/null || true)"
  provider_url="$(jq -er '.providerUrl' <<<"$settings" 2>/dev/null || true)"
  network_magic="$(jq -er '.networkMagic' <<<"$settings" 2>/dev/null || true)"
  time_directory="$(jq -er '.networkTimeDirectory' <<<"$settings" 2>/dev/null || true)"
  if [ -n "$provider_url" ] && [ "$network_magic" = 42 ] && [ -r "$time_directory/time-manifest.json" ]; then break; fi
  if ! kill -0 "$devnet_pid" 2>/dev/null; then break; fi
  sleep 1
done
if [ -z "$provider_url" ] || [ "$network_magic" != 42 ] || [ ! -r "$time_directory/time-manifest.json" ]; then
  echo 'SETUP-FAIL: devnet produced no provider and pinned time settings' >&2
  tail -40 "$work/devnet.err" >&2 || true
  exit 1
fi

joiner="$work/joiner.skey"
manifest="$work/deployment.json"
nix run --quiet "$offchain#deployment" -- genesis-skey --out "$joiner"
"$deployment" genesis-skey "--out=$work/joiner-equals.skey" >/dev/null
cmp -s "$joiner" "$work/joiner-equals.skey" || {
  echo 'FAIL: genesis-skey --out=FILE wrote a different key than --out FILE' >&2
  exit 1
}
external=(--koios-url "$provider_url" --network-magic "$network_magic" --network-time "$time_directory" --wallet-skey "$joiner")
nix run --quiet "$offchain#deployment" -- deploy "${external[@]}" --out "$manifest" --release identity-check >"$work/deploy.out"
nix run --quiet "$offchain#deployment" -- verify "${external[@]}" --deployment "$manifest" >"$work/verify.out"
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

jq '.depRepresentativePolicy = ("00" * 28)' "$manifest" >"$work/wrong-policy.json"
if cmp -s "$manifest" "$work/wrong-policy.json"; then
  echo 'SETUP-FAIL: policy mutation did not change the manifest' >&2
  exit 1
fi
set +e
nix run --quiet "$offchain#deployment" -- verify "${external[@]}" --deployment "$work/wrong-policy.json" >"$work/wrong-policy.out" 2>&1
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
