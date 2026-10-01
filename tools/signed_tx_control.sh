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
# Then the whole export surface, as GHCi reports it to an importer, is
# judged by tools/signed_tx_surface.py: signTx must be the only exported
# binding that hands out a SignedTx, and SignedTx must have no instance.
# Planted producers and a planted instance must each be refused by name.
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

# The export surface, as an importer sees it: signTx must be the only
# exported way to a SignedTx, and SignedTx must have no instance. Judged on
# the real module, then on two planted defects the judge must name.
# GHCi from an importer of the module: :browse gives the exports with their
# types (the type as the importer sees it); :info gives the instances in
# scope. :info also shows an interpreted module's constructor whatever its
# export list says, so only its instance lines are judged; the module is
# loaded compiled (-fobject-code), so :browse shows its exports alone.
ghci_on() {
  local tree="$1" commands=()
  shift
  for c in "$@"; do commands+=(-e "$c"); done
  ghc -package-env - -fobject-code -i"$scratch/$tree" -outputdir "$scratch/out-surface-$tree" \
    "${commands[@]}" "$fixtures/BySigning.hs" "${ghc_flags[@]}" 2>&1 || {
    echo "SETUP-FAIL: GHCi could not run $* on tree $tree" >&2
    exit 2
  }
}
surface() {
  {
    ghci_on "$1" ":browse Singular.Registry.Node.Submit"
    ghci_on "$1" ":module + Singular.Registry.Node.Submit" ":info SignedTx" \
      | grep "^instance" || true
  } >"$scratch/surface-$1.txt"
  python3 "$root/tools/signed_tx_surface.py" <"$scratch/surface-$1.txt"
}

judged=0
surface real >"$scratch/judge-real.log" 2>&1 || judged=$?
case $judged in
  0) echo "surface real: $(cat "$scratch/judge-real.log")" ;;
  1)
    cat "$scratch/judge-real.log" >&2
    echo "FAIL signed-tx-control: the real module exports another way to a SignedTx" >&2
    status=1
    ;;
  *)
    cat "$scratch/judge-real.log" >&2
    echo "SETUP-FAIL: the surface judge did not run (exit $judged)" >&2
    exit 2
    ;;
esac

plant() {
  local tree="$1" exports="$2" defs="$3"
  mkdir -p "$scratch/$tree/Singular/Registry/Node"
  awk -v add="$exports" '{ print } /^      SignedTx$/ && add != "" { print add }' "$submit" \
    >"$scratch/$tree/Singular/Registry/Node/Submit.hs"
  printf '\n%s\n' "$defs" >>"$scratch/$tree/Singular/Registry/Node/Submit.hs"
  grep -qF "$defs" "$scratch/$tree/Singular/Registry/Node/Submit.hs" || {
    echo "SETUP-FAIL: the plant did not apply to $tree" >&2
    exit 2
  }
}

# expect_refused TREE PATTERN...: the judge exits 1 and names each pattern.
expect_refused() {
  local tree="$1" got=0
  shift
  surface "$tree" >"$scratch/judge-$tree.log" || got=$?
  if [ "$got" -ne 1 ]; then
    cat "$scratch/judge-$tree.log" >&2
    echo "FAIL signed-tx-control: the judge did not refuse the $tree plant (exit $got)" >&2
    status=1
    return
  fi
  for p in "$@"; do
    grep -qF -- "$p" "$scratch/judge-$tree.log" || {
      cat "$scratch/judge-$tree.log" >&2
      echo "FAIL signed-tx-control: the $tree plant was refused without naming $p" >&2
      status=1
    }
  done
  echo "control $tree: refused, naming $*"
}

plant producers "    , forgeSigned\n    , withForged" \
  "forgeSigned :: ConwayTx -> SignedTx
forgeSigned = SignedTx

withForged :: ConwayTx -> (SignedTx -> r) -> r
withForged tx k = k (SignedTx tx)"
expect_refused producers forgeSigned withForged

plant instance "" "instance Semigroup SignedTx where a <> _ = a"
expect_refused instance "instance of SignedTx"

if [ $status -ne 0 ]; then
  exit 1
fi
echo "PASS signed-tx-control: a SignedTx is constructible only through signTx"
