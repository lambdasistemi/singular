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
  if [ -n "$devnet_pid" ]; then
    kill "$devnet_pid" 2>/dev/null || true
    wait "$devnet_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# With no argument the whole check runs: the blueprints, the naming identity,
# a devnet and a deployment made on it. With --router-only it builds the
# deployment command alone and runs the checks that need no node and no
# blueprint: the verb router and the flags deploy reads.
mode=full
case "${1:-}" in
  '') ;;
  --router-only) mode=router ;;
  *)
    echo 'usage: deployment-identity-check.sh [--router-only]' >&2
    exit 2
    ;;
esac

# Sets $deployment to the command of the build output named in $1: the same
# wrapped command `nix run .#deployment` launches, invoked directly for the
# checks below so they add no Nix start.
locate_deployment() {
  deployment="$(printf '%s\n' "$1" | grep -E -- '-deployment$')/bin/deployment"
  if [ ! -x "$deployment" ]; then
    echo 'SETUP-FAIL: the build produced no deployment command' >&2
    exit 1
  fi
}

# Runs the deployment command and requires a non-zero exit whose output says
# $1; the output stays in $work/refusal.out for refusal_omits.
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

# The last refusal must not mention $1.
refusal_omits() {
  if grep -F -- "$1" "$work/refusal.out" >/dev/null; then
    echo "FAIL: the refusal mentioned $1 although that field was valid" >&2
    cat "$work/refusal.out" >&2
    exit 1
  fi
}

# The first argument that is not a flag selects one of the four verbs;
# anything else is the usage refusal, and each verb refuses its missing
# required flag by name. Deploy needs both the registration cost and the
# booking width: each is refused by name when missing, a value that is not
# plain digits is refused (0x10 and a leading space were once taken as
# numbers), and a valid pair is refused for neither field, only for the
# blueprint this run does not have. It runs in a subshell with no blueprint in
# its environment, so a refusal naming the blueprint is the command reaching
# past its flags.
router_checks() (
  unset REGISTRY_BLUEPRINT NAMING_BLUEPRINT
  local usage='usage: deployment deploy --out MANIFEST'
  local out="$work/unwritten.json"
  local cost_refusal='--registration-cost needs a non-negative number of lovelace'
  local width_refusal='--booking-width needs a positive number of milliseconds'
  local bad
  expect_refusal "$usage"
  expect_refusal "$usage" --out stray count
  expect_refusal "$usage --registration-cost LOVELACE --booking-width MS"
  expect_refusal 'deploy needs --out MANIFEST' deploy
  expect_refusal 'verify needs --deployment MANIFEST' verify
  expect_refusal 'count needs --deployment MANIFEST' count
  expect_refusal 'count needs --what state|reference' count --deployment "$work/unread.json"
  expect_refusal 'genesis-skey needs --out FILE' genesis-skey

  expect_refusal 'deploy needs --registration-cost LOVELACE' \
    deploy --out "$out" --booking-width 20000
  expect_refusal 'deploy needs --registration-cost LOVELACE' deploy --out "$out"
  expect_refusal 'deploy needs --booking-width MS' \
    deploy --out "$out" --registration-cost 3000000
  for bad in 0x10 ' 5' '5 ' -1 +5 1.5 1e3 0o7 abc ''; do
    expect_refusal "$cost_refusal" \
      deploy --out "$out" --registration-cost "$bad" --booking-width 60000
  done
  expect_refusal "$cost_refusal" \
    deploy --out "$out" --registration-cost=0x10 --booking-width=60000
  for bad in 0x10 ' 60000' '60000 ' 0 -1 +5 1.5 1e3 0o7 abc ''; do
    expect_refusal "$width_refusal" \
      deploy --out "$out" --registration-cost 0 --booking-width "$bad"
  done
  expect_refusal "$width_refusal" \
    deploy --out "$out" --registration-cost=0 --booking-width=0x10

  # A valid pair is read: it gets past both flags and is refused only for the
  # missing blueprint, naming neither field. Both values the slice uses, both
  # spellings, either order.
  expect_refusal 'REGISTRY_BLUEPRINT is not set' \
    deploy --out "$out" --registration-cost 0 --booking-width 60000
  refusal_omits --registration-cost
  refusal_omits --booking-width
  expect_refusal 'REGISTRY_BLUEPRINT is not set' \
    deploy --booking-width=20000 --out "$out" --registration-cost=3000000
  refusal_omits --registration-cost
  refusal_omits --booking-width
)

if [ "$mode" = router ]; then
  locate_deployment "$(nix build --quiet --no-link --print-out-paths "$offchain#deployment")"
  router_checks
  echo 'PASS (router only): verb router refusals held; deploy refused each missing or malformed registration cost and booking width by name and read a valid pair'
  exit 0
fi

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
locate_deployment "$built"
router_checks

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
registration_cost=3000000
booking_width=20000
nix run --quiet "$offchain#deployment" -- deploy "${external[@]}" --out "$manifest" --release identity-check \
  --registration-cost "$registration_cost" --booking-width "$booking_width" >"$work/deploy.out"

# The two values deploy was given are the values its manifest records. The
# comparison is shown able to refuse: a manifest with either value changed
# must be reported before the real one is trusted.
manifest_economics_problems() {
  jq -r --argjson cost "$registration_cost" --argjson width "$booking_width" '
    (if .depRegistrationCost == $cost then empty else "depRegistrationCost is \(.depRegistrationCost), not \($cost)" end),
    (if .depBookingWidth == $width then empty else "depBookingWidth is \(.depBookingWidth), not \($width)" end)
  ' "$1"
}
jq '.depRegistrationCost += 1' "$manifest" >"$work/other-cost.json"
jq '.depBookingWidth += 1' "$manifest" >"$work/other-width.json"
for other in other-cost other-width; do
  if [ -z "$(manifest_economics_problems "$work/$other.json")" ]; then
    echo "FAIL: manifest economics: the comparison accepted a manifest with a changed value ($other)" >&2
    exit 1
  fi
done
if ! problems="$(manifest_economics_problems "$manifest")"; then
  echo 'FAIL: manifest economics: the manifest could not be read' >&2
  exit 1
fi
if [ -n "$problems" ]; then
  while IFS= read -r p; do echo "FAIL: manifest economics: $p" >&2; done <<<"$problems"
  exit 1
fi
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

echo "PASS: verb router refusals held; the manifest recorded registration cost $registration_cost and booking width $booking_width; intact node verification reached completion; count found $states registry output and $references of $recorded recorded reference outputs; changed representative policy exited $rc with identity diagnostic"
