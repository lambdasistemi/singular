#!/usr/bin/env bash
# Controls for tools/ledger_client_dependencies_check.sh: it passes on this
# tree and fails, naming the offender, on each dependency it exists to
# refuse.
#
# Every control runs on a scratch copy of the Cabal file; the tree itself is
# never touched. Each planted dependency is added to the `library
# ledger-client` stanza only: the same package in another stanza must not
# trip the check, and a missing stanza must be a setup failure.
set -euo pipefail

repo=${1:-.}
check="$repo/tools/ledger_client_dependencies_check.sh"
scratch="$(mktemp -d)"
controls=0
trap 'rm -rf "$scratch"' EXIT

fresh() {
  rm -rf "$scratch/t"
  mkdir -p "$scratch/t/offchain"
  cp "$repo/offchain/singular-registry.cabal" "$scratch/t/offchain/"
}

# plant DEP: add DEP to the ledger-client stanza's build-depends.
plant() {
  sed -i "/^library ledger-client\$/,/^  build-depends:\$/s/^  build-depends:\$/  build-depends:\\n    , $1/" \
    "$scratch/t/offchain/singular-registry.cabal"
  awk '/^library ledger-client$/ { s = 1 } s && /^    , '"$1"'$/ { found = 1 } END { exit !found }' \
    "$scratch/t/offchain/singular-registry.cabal" || {
    echo "SETUP-FAIL: $1 was not planted in the ledger-client stanza" >&2
    exit 2
  }
}

# expect NAME STATUS PATTERN: the check on the scratch tree exits STATUS and
# its output matches PATTERN.
expect() {
  local name="$1" want="$2" pattern="$3" got=0
  bash "$check" "$scratch/t" >"$scratch/out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ] || ! grep -qE -- "$pattern" "$scratch/out"; then
    cat "$scratch/out" >&2
    echo "FAIL ledger-client-dependencies control '$name': exit $got (wanted $want), pattern '$pattern'" >&2
    exit 1
  fi
  controls=$((controls + 1))
  echo "control $name: exit $got, $(grep -cE -- "$pattern" "$scratch/out") matching line(s)"
}

fresh
expect clean-tree 0 '^PASS ledger-client-dependencies'

fresh
plant singular-registry:local-services
expect planted-component 1 'depends on singular-registry:local-services'

for package in directory filepath unix process network http-client \
  http-client-tls wai warp cardano-tx-tools; do
  fresh
  plant "$package"
  expect "planted-$package" 1 "depends on $package: $package is forbidden"
done

fresh
plant cardano-tx-tools:tx-build
expect planted-tx-build-component 1 "depends on cardano-tx-tools:tx-build: cardano-tx-tools is forbidden"

fresh
sed -i 's/^library ledger-client$/library ledger-client-gone/' \
  "$scratch/t/offchain/singular-registry.cabal"
expect no-stanza 2 "^SETUP-FAIL: no 'library ledger-client' stanza"

fresh
rm "$scratch/t/offchain/singular-registry.cabal"
expect no-cabal-file 2 '^SETUP-FAIL: no .*singular-registry.cabal'

echo "PASS ledger-client-dependencies-controls: $controls controls"
