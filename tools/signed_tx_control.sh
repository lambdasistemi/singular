#!/usr/bin/env bash
# A SignedTx is obtained only by signing (#326 R4).
#
# GHC type-checks three fixtures against the real
# Singular.Registry.Node.Submit source: signing must compile; building a
# SignedTx by its constructor or by coercion must not, and must be refused
# because the constructor is hidden. Then the same two forgeries are
# type-checked against a scratch copy of the module that exports the
# constructor, and must compile: the refusal is the export list's doing,
# so this check fails the day the abstraction is broken.
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
for forgery in ByConstructor ByCoercion; do
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

if [ $status -ne 0 ]; then
  exit 1
fi
echo "PASS signed-tx-control: a SignedTx is constructible only through signTx"
