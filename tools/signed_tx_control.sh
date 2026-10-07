#!/usr/bin/env bash
# A SignedTx is obtained only by signing (#326 R4).
#
# Check the defining generic Signing module.
# GHC must accept signing and refuse constructor, coercion and record forgeries
# because the constructor is hidden. The identical forgeries must compile when
# the defining module exports the constructor in a scratch copy.
# Its export list stays frozen; a planted forging export must be refused by
# name. An allowlisted export changed to forge remains a review obligation.
#
# Usage: tools/signed_tx_control.sh REPO-ROOT -- GHC-FLAGS...
# GHC-FLAGS name the package databases and dependencies of the real modules.
set -euo pipefail

root=$1
shift
[ "${1:-}" = "--" ] && shift
ghc_flags=("$@")
signing="$root/offchain/local-services/Singular/Registry/Signing.hs"
fixtures="$root/offchain/signed-tx-control"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

[ -f "$signing" ] || {
  echo "SETUP-FAIL: no $signing" >&2
  exit 2
}

declare -A module=(
  [signing]=Singular.Registry.Signing
)
declare -A allow=(
  [signing]="$root/tools/signing-exports.allow"
)
declare -A refusal=(
  [ByConstructor]='term-level use of the type constructor .SignedTx.'
  [ByCoercion]='data constructor .Singular\.Registry\.Signing\.SignedTx.'
  [ByRecord]='term-level use of the type constructor .SignedTx.'
)

prepare_tree() {
  local tree=$1
  mkdir -p "$scratch/$tree/Singular/Registry"
  cp "$signing" "$scratch/$tree/Singular/Registry/Signing.hs"
  chmod u+w "$scratch/$tree/Singular/Registry/Signing.hs"
}
prepare_tree real
prepare_tree broken
sed 's/^    ( SignedTx$/    ( SignedTx (..)/' "$signing" \
  >"$scratch/broken/Singular/Registry/Signing.hs"
if cmp -s "$signing" "$scratch/broken/Singular/Registry/Signing.hs"; then
  echo "SETUP-FAIL: the Signing constructor export did not apply" >&2
  exit 2
fi
mkdir -p "$scratch/fixtures-signing"
for fixture in BySigning ByConstructor ByCoercion ByRecord; do
  cp "$fixtures/$fixture.hs" "$scratch/fixtures-signing/$fixture.hs"
done

compile() {
  local scope=$1 tree=$2 fixture=$3
  ghc -fno-code -package-env - -outputdir "$scratch/out-$scope-$tree-$fixture" \
    -i"$scratch/$tree" "$scratch/fixtures-$scope/$fixture.hs" "${ghc_flags[@]}" \
    >"$scratch/$scope-$tree-$fixture.log" 2>&1
}

exports_of() {
  local scope=$1 tree=$2
  ghc -package-env - -fobject-code -i"$scratch/$tree" \
    -outputdir "$scratch/out-exports-$scope-$tree" \
    -e ":browse ${module[$scope]}" \
    "$scratch/fixtures-$scope/BySigning.hs" "${ghc_flags[@]}" \
    >"$scratch/browse-$scope-$tree.txt" 2>&1 || {
    cat "$scratch/browse-$scope-$tree.txt" >&2
    echo "SETUP-FAIL: GHCi could not browse $scope from tree $tree" >&2
    return 2
  }
  grep -vE '^[[:space:]]|^--|^(newtype|data) ' "$scratch/browse-$scope-$tree.txt" \
    | sed -E 's/^type //; s/[[:space:]].*$//; s/^.*\.//' | sort -u
}

status=0
scope=signing
if ! compile "$scope" real BySigning; then
  cat "$scratch/$scope-real-BySigning.log" >&2
  echo "SETUP-FAIL: $scope signing does not compile; refusals would say nothing" >&2
  exit 2
fi
echo "control $scope signing: compiles against the real module"
for forgery in ByConstructor ByCoercion ByRecord; do
  if compile "$scope" real "$forgery"; then
    echo "FAIL signed-tx-control: $scope $forgery compiles without signing" >&2
    status=1
  elif grep -qE "${refusal[$forgery]}" "$scratch/$scope-real-$forgery.log"; then
    echo "refused $scope $forgery: $(grep -m1 -oE "${refusal[$forgery]}" "$scratch/$scope-real-$forgery.log")"
  else
    cat "$scratch/$scope-real-$forgery.log" >&2
    echo "FAIL signed-tx-control: $scope $forgery refused for a different reason" >&2
    status=1
  fi
  if compile "$scope" broken "$forgery"; then
    echo "control $scope $forgery: compiles once the constructor is exported"
  else
    cat "$scratch/$scope-broken-$forgery.log" >&2
    echo "FAIL signed-tx-control: $scope $forgery does not compile even with the constructor exported; its refusal proves nothing" >&2
    status=1
  fi
done

[ -f "${allow[$scope]}" ] || {
  echo "SETUP-FAIL: no allowlist for $scope" >&2
  exit 2
}
real_exports="$(exports_of "$scope" real)" || exit 2
grep -qx signTx <<<"$real_exports" || {
  echo "SETUP-FAIL: signTx absent from $scope exports: $real_exports" >&2
  exit 2
}
expected="$(grep -vE '^(#|$)' "${allow[$scope]}" | sort -u)"
extra="$(comm -23 <(printf '%s\n' "$real_exports") <(printf '%s\n' "$expected"))"
stale="$(comm -13 <(printf '%s\n' "$real_exports") <(printf '%s\n' "$expected"))"
if [ -n "$extra" ] || [ -n "$stale" ]; then
  echo "FAIL signed-tx-control: $scope export mismatch: extra=[$extra] stale=[$stale]" >&2
  status=1
else
  echo "exports $scope: $(tr '\n' ' ' <<<"$real_exports")— exact allowlist"
fi

# The defining module owns its constructor. Each planted export must
# compile, then fail the frozen export comparison by its own name.
tree="planted-$scope"
prepare_tree "$tree"
target="$scratch/$tree/Singular/Registry/Signing.hs"
awk '{ print } /^    \( SignedTx$/ { print "    , forge" }' "$signing" >"$target"
printf '\nforge :: ConwayTx -> SignedTx\nforge = SignedTx\n' >>"$target"
grep -q '^    , forge$' "$target" || {
  echo "SETUP-FAIL: $scope planted export did not apply" >&2
  exit 2
}
planted_exports="$(exports_of "$scope" "$tree")" || exit 2
planted="$(comm -23 <(printf '%s\n' "$planted_exports") <(printf '%s\n' "$expected"))"
if [ "$planted" = forge ]; then
  echo "control $scope planted-export: refused by name: $planted"
else
  echo "FAIL signed-tx-control: $scope planted export not refused by name (got: '$planted')" >&2
  status=1
fi

[ "$status" -eq 0 ] || exit 1
echo "PASS signed-tx-control: a SignedTx is constructible only through signTx"
