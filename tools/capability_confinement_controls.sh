#!/usr/bin/env bash
# Negative and positive controls for the capability confinement check.
#
# Each control runs on a scratch copy of the tree (the working tree is
# never touched): a planted raw-capability import where none belongs, or
# a damaged allowlist, must fail; the clean tree must pass; and the one
# compiler negative plants a raw import with a use in the main library,
# where the production closure (no local-services dep) must refuse it.
# The working tree is never touched.
#
# Usage: tools/capability_confinement_controls.sh [repo-root]
set -euo pipefail

root=${1:-.}
check="$root/tools/capability_confinement_check.sh"
allow="$root/tools/capability-confinement.allow"

[ -x "$check" ] || {
  echo "SETUP-FAIL: no check at $check" >&2
  exit 2
}
[ -f "$allow" ] || {
  echo "SETUP-FAIL: no allowlist at $allow" >&2
  exit 2
}

pass=0
fail=0
report() {
  if [ "$1" = "$2" ]; then
    pass=$((pass + 1))
    echo "CONTROL-PASS: $3"
  else
    fail=$((fail + 1))
    echo "CONTROL-FAIL: $3 (wanted exit $2, got $1)" >&2
  fi
}

# A scratch copy with the relative layout nix evaluates: offchain is the
# flake root; ../naming-onchain, ../../tools and ../../fourmolu.yaml are
# read off the filesystem beside it.
scratch_of() {
  local dest
  dest=$(mktemp -d)
  mkdir -p "$dest/tools"
  cp -R "$root/offchain" "$dest/offchain"
  cp -R "$root/naming-onchain" "$dest/naming-onchain"
  cp "$root/tools/signed_tx_control.sh" "$root/tools/signing-exports.allow" "$dest/tools/"
  cp "$root/fourmolu.yaml" "$dest/fourmolu.yaml"
  cp "$root/tools/capability_confinement_check.sh" "$root/tools/capability-confinement.allow" "$dest/tools/"
  printf '%s' "$dest"
}

# 1. The clean tree passes.
s=$(scratch_of)
bash "$s/tools/capability_confinement_check.sh" "$s" >/dev/null 2>&1 && ec=0 || ec=$?
report "$ec" 0 "clean tree passes the check"
rm -rf "$s"

# 2. A planted raw import in the main library fails the check.
s=$(scratch_of)
printf '\n%s\n' "import Singular.Registry.SessionIO (parameters)" >>"$s/offchain/lib/Singular/Registry/Lifecycle.hs"
bash "$s/tools/capability_confinement_check.sh" "$s" >/dev/null 2>&1 && ec=0 || ec=$?
report "$ec" 1 "planted raw import in main-lib module fails the check"
rm -rf "$s"

# 3. A planted raw import in a non-boundary command fails the check.
s=$(scratch_of)
printf '\n%s\n' "import Singular.Registry.SessionIO (parameters)" >>"$s/offchain/cli/src/Singular/CLI/Fold.hs"
bash "$s/tools/capability_confinement_check.sh" "$s" >/dev/null 2>&1 && ec=0 || ec=$?
report "$ec" 1 "planted raw import in non-boundary CLI module fails the check"
rm -rf "$s"

# 4. A planted raw import in a boundary module still passes (allowlist).
s=$(scratch_of)
printf '\n%s\n' "import Singular.Registry.SessionIO (parameters)" >>"$s/offchain/cli/src/Singular/CLI/Session.hs"
bash "$s/tools/capability_confinement_check.sh" "$s" >/dev/null 2>&1 && ec=0 || ec=$?
report "$ec" 0 "planted raw import in boundary module passes through the allowlist"
rm -rf "$s"

# 5. Allowlist damage fails with a diagnostic: reasonless, stale, unneeded.
s=$(scratch_of)
printf '%s\n' "offchain/lib/Singular/Registry/Lifecycle.hs" >>"$s/tools/capability-confinement.allow"
bash "$s/tools/capability_confinement_check.sh" "$s" >/dev/null 2>&1 && ec=0 || ec=$?
report "$ec" 1 "reasonless allowlist entry fails the check"
rm -rf "$s"

s=$(scratch_of)
printf '%s\n' "offchain/lib/Singular/Registry/Gone.hs: gone module" >>"$s/tools/capability-confinement.allow"
bash "$s/tools/capability_confinement_check.sh" "$s" >/dev/null 2>&1 && ec=0 || ec=$?
report "$ec" 1 "stale allowlist entry fails the check"
rm -rf "$s"

s=$(scratch_of)
printf '%s\n' "offchain/lib/Singular/Registry/Lifecycle.hs: no confined use here" >>"$s/tools/capability-confinement.allow"
bash "$s/tools/capability_confinement_check.sh" "$s" >/dev/null 2>&1 && ec=0 || ec=$?
report "$ec" 1 "unneeded allowlist entry fails the check"
rm -rf "$s"

# 6. Compiler negative: a raw import WITH a use in the main library fails
# the production component build because the main closure has no
# local-services dep. The diagnostic must name the hidden package.
s=$(scratch_of)
sed -i '/^import Singular.Registry.Config (CageConfig (..))$/a import Singular.Registry.SessionIO (withLatest)' \
  "$s/offchain/lib/Singular/Registry/Lifecycle.hs"
printf '\n%s\n' "plantedCapabilityUse = withLatest" >>"$s/offchain/lib/Singular/Registry/Lifecycle.hs"
build_out=$(cd "$s/offchain" && nix build .#component-build 2>&1) || true
if printf '%s' "$build_out" | grep -q "Could not load module .Singular.Registry.SessionIO."; then
  report 1 1 "planted raw import with use fails the production component build on the hidden package"
else
  printf '%s\n' "$build_out" | tail -5 >&2
  report 0 1 "planted raw import with use fails the production component build on the hidden package"
fi
rm -rf "$s"

# 7. Legal-use positive: the clean tree builds its production components
# through the surface only.
s=$(scratch_of)
if (cd "$s/offchain" && nix build --quiet .#component-build >/dev/null 2>&1); then
  built=0
else
  built=1
fi
report "$built" 0 "clean tree builds its production components"
rm -rf "$s"

echo "capability-confinement-controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
