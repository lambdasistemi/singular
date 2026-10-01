#!/usr/bin/env bash
# A SignedTx is obtained only by signing (#326 R4).
#
# Outside Singular.Registry.Node.Submit, no route constructs a SignedTx.
# GHC type-checks fixtures against the real module's source: signing must
# compile; building a SignedTx by its constructor, by coercion or by record
# syntax must not, and must be refused because the constructor is hidden.
# The same forgeries are then type-checked against a scratch copy of the
# module that exports the constructor, and must compile: the refusal is the
# export list's doing, so this check fails the day the abstraction breaks.
#
# The module's export list is frozen: the names GHCi reports it exports must
# all be on tools/signed-tx-exports.allow, and a planted forging export
# must be refused by name. An export already on the allowlist that is
# changed to forge is left to review.
#
# Usage: tools/signed_tx_control.sh REPO-ROOT -- GHC-FLAGS...
# GHC-FLAGS name the package databases and units Submit.hs compiles with.
set -euo pipefail

root=$1
shift
[ "${1:-}" = "--" ] && shift
ghc_flags=("$@")
submit="$root/offchain/node-internal/Singular/Registry/Node/Submit.hs"
fixtures="$root/offchain/signed-tx-control"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

[ -f "$submit" ] || {
  echo "SETUP-FAIL: no $submit" >&2
  exit 2
}

# The diagnostic each forgery must be refused with: the hidden constructor.
declare -A refusal=(
  [ByConstructor]='term-level use of the type constructor .SignedTx.'
  [ByCoercion]='data constructor .Singular\.Registry\.Node\.Submit\.SignedTx.'
  [ByRecord]='term-level use of the type constructor .SignedTx.'
)

# compile TREE FIXTURE: type-check FIXTURE with Submit from TREE; the log
# lands at $scratch/TREE-FIXTURE.log.
compile() {
  local tree="$1" fixture="$2"
  ghc -fno-code -package-env - -outputdir "$scratch/out-$tree-$fixture" \
    -i"$scratch/$tree" "$fixtures/$fixture.hs" "${ghc_flags[@]}" \
    >"$scratch/$tree-$fixture.log" 2>&1
}

mkdir -p "$scratch/real/Singular/Registry/Node" "$scratch/broken/Singular/Registry/Node"
cp "$submit" "$scratch/real/Singular/Registry/Node/Submit.hs"
sed 's/^      SignedTx$/      SignedTx (..)/' "$submit" >"$scratch/broken/Singular/Registry/Node/Submit.hs"
if cmp -s "$submit" "$scratch/broken/Singular/Registry/Node/Submit.hs"; then
  echo "SETUP-FAIL: the constructor export did not apply to the scratch module" >&2
  exit 2
fi

if ! compile real BySigning; then
  cat "$scratch/real-BySigning.log" >&2
  echo "SETUP-FAIL: signing does not compile; the refusals below would say nothing" >&2
  exit 2
fi
echo "control signing: compiles against the real module"

status=0
for forgery in ByConstructor ByCoercion ByRecord; do
  if compile real "$forgery"; then
    echo "FAIL signed-tx-control: $forgery compiles against the real module: a SignedTx exists without signing" >&2
    status=1
  elif grep -qE "${refusal[$forgery]}" "$scratch/real-$forgery.log"; then
    echo "refused $forgery: $(grep -m1 -oE "${refusal[$forgery]}" "$scratch/real-$forgery.log")"
  else
    cat "$scratch/real-$forgery.log" >&2
    echo "FAIL signed-tx-control: $forgery was refused for another reason than the hidden constructor" >&2
    status=1
  fi
  if compile broken "$forgery"; then
    echo "control $forgery: compiles once the constructor is exported"
  else
    cat "$scratch/broken-$forgery.log" >&2
    echo "FAIL signed-tx-control: $forgery does not compile even with the constructor exported; its refusal proves nothing" >&2
    status=1
  fi
done

# The module's export list, frozen. GHCi browses the module from an
# importer, compiled (-fobject-code), and the names it exports are compared
# with tools/signed-tx-exports.allow: a new or renamed export fails by name,
# so a forging export added inside the module is a reviewed allowlist line.
exports_of() {
  local tree="$1"
  ghc -package-env - -fobject-code -i"$scratch/$tree" \
    -outputdir "$scratch/out-exports-$tree" \
    -e ":browse Singular.Registry.Node.Submit" \
    "$fixtures/BySigning.hs" "${ghc_flags[@]}" >"$scratch/browse-$tree.txt" 2>&1 || {
    cat "$scratch/browse-$tree.txt" >&2
    echo "SETUP-FAIL: GHCi could not browse Submit from tree $tree" >&2
    exit 2
  }
  # Unindented lines name one export each: a binding (name ::), or a type
  # (type Name :: kind); newtype and data lines repeat the type's name.
  grep -vE '^[[:space:]]|^--|^(newtype|data) ' "$scratch/browse-$tree.txt" \
    | sed -E 's/^type //; s/[[:space:]].*$//; s/^.*\.//' | sort -u
}

# frozen TREE: exports of TREE outside the allowlist, one per line.
frozen() {
  comm -23 <(exports_of "$1") <(grep -vE '^(#|$)' "$allow" | sort -u)
}

allow="$root/tools/signed-tx-exports.allow"
[ -f "$allow" ] || {
  echo "SETUP-FAIL: no allowlist at $allow" >&2
  exit 2
}
real_exports="$(exports_of real)"
grep -qx signTx <<<"$real_exports" || {
  echo "SETUP-FAIL: signTx is not among the exports GHCi reported: $real_exports" >&2
  exit 2
}
extra="$(frozen real)"
if [ -n "$extra" ]; then
  echo "FAIL signed-tx-control: Submit exports names the allowlist does not hold: $extra" >&2
  status=1
else
  echo "exports: $(tr '\n' ' ' <<<"$real_exports")— all on the allowlist"
fi

stale="$(comm -13 <(exports_of real) <(grep -vE '^(#|$)' "$allow" | sort -u))"
if [ -n "$stale" ]; then
  echo "FAIL signed-tx-control: the allowlist holds names Submit does not export: $stale" >&2
  status=1
fi

# The planted export: a forging function added to the export list.
mkdir -p "$scratch/planted/Singular/Registry/Node"
awk '{ print } /^      SignedTx$/ { print "    , forge" }' "$submit" \
  >"$scratch/planted/Singular/Registry/Node/Submit.hs"
printf '\nforge :: ConwayTx -> SignedTx\nforge = SignedTx\n' \
  >>"$scratch/planted/Singular/Registry/Node/Submit.hs"
grep -q '^    , forge$' "$scratch/planted/Singular/Registry/Node/Submit.hs" || {
  echo "SETUP-FAIL: the planted export did not apply" >&2
  exit 2
}
planted="$(frozen planted)"
if [ "$planted" = "forge" ]; then
  echo "control planted-export: refused by name: $planted"
else
  echo "FAIL signed-tx-control: the planted export was not refused by name (got: '$planted')" >&2
  status=1
fi

if [ $status -ne 0 ]; then
  exit 1
fi
echo "PASS signed-tx-control: a SignedTx is constructible only through signTx"
