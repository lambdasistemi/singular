#!/usr/bin/env bash
# Controls for tools/ledger_client_dependencies_check.sh: it passes on this
# tree and fails, naming the offender, on each defect it exists to refuse.
#
# Every control runs on a scratch copy of the Cabal file and the allowlist;
# the tree itself is never touched. Each planted dependency reaches the
# `library ledger-client` stanza by one Cabal syntax: the literal field, an
# imported common stanza, a common stanza imported by a common stanza, a
# conditional, a second field. A package absent from the allowlist
# (`http-conduit`, an HTTP client the old fixed list did not name) must fail
# by each of them; the same package in a stanza the library does not import
# must not.
set -euo pipefail

repo=${1:-.}
check="$repo/tools/ledger_client_dependencies_check.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
controls=0

fresh() {
  rm -rf "$scratch/t"
  mkdir -p "$scratch/t/offchain" "$scratch/t/tools"
  cp "$repo/offchain/singular-registry.cabal" "$scratch/t/offchain/"
  cp "$repo/tools/ledger-client-dependencies.allow" "$scratch/t/tools/"
}

cabal() { echo "$scratch/t/offchain/singular-registry.cabal"; }

# after_header TEXT: put TEXT on the lines right after the ledger-client
# stanza header.
after_header() {
  awk -v text="$1" '{ print } /^library ledger-client$/ { print text }' "$(cabal)" >"$scratch/cabal.new"
  mv "$scratch/cabal.new" "$(cabal)"
}

# before_header TEXT: put TEXT on the lines right before the stanza header.
before_header() {
  awk -v text="$1" '/^library ledger-client$/ { print text } { print }' "$(cabal)" >"$scratch/cabal.new"
  mv "$scratch/cabal.new" "$(cabal)"
}

plant_literal() { after_header "  build-depends:
    , $1"; }
plant_same_line() { after_header "  build-depends: $1"; }
plant_conditional() { after_header "  if os(linux)
    build-depends:
      , $1"; }
plant_common() {
  before_header "common planted-deps
  build-depends:
    , $1
"
  after_header "  import: planted-deps"
}
plant_nested_common() {
  before_header "common planted-inner
  build-depends:
    , $1

common planted-outer
  import: planted-inner
"
  after_header "  import: planted-outer"
}
# A common stanza no ledger-client import reaches.
plant_unreached_common() {
  before_header "common planted-unreached
  build-depends:
    , $1
"
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
plant_literal singular-registry:local-services
expect planted-component 1 'depends on singular-registry:local-services .*may not be a dependency'

fresh
plant_literal singular-registry
expect planted-main-library 1 'depends on singular-registry .*may not be a dependency'

# The category the old fixed list could not enumerate.
fresh
plant_literal http-conduit
expect unlisted-literal 1 'depends on http-conduit .*not in tools/ledger-client-dependencies.allow'
fresh
plant_same_line http-conduit
expect unlisted-same-line 1 'depends on http-conduit .*not in tools/ledger-client-dependencies.allow'
fresh
plant_conditional http-conduit
expect unlisted-conditional 1 'depends on http-conduit .*not in tools/ledger-client-dependencies.allow'
fresh
plant_common http-conduit
expect unlisted-imported-common 1 "depends on http-conduit \\(declared in common planted-deps\\).*not in tools/ledger-client-dependencies.allow"
fresh
plant_nested_common http-conduit
expect unlisted-nested-common 1 "depends on http-conduit \\(declared in common planted-inner\\).*not in tools/ledger-client-dependencies.allow"

for package in directory filepath unix process network http-client \
  http-client-tls wai warp cardano-tx-tools cardano-tx-tools:tx-build; do
  fresh
  plant_literal "$package"
  expect "planted-$package" 1 "depends on $package .*${package%%:*} is forbidden"
  fresh
  plant_common "$package"
  expect "planted-$package-in-common" 1 "depends on $package \\(declared in common planted-deps\\).*${package%%:*} is forbidden"
done

# The allowlist cannot admit what is forbidden.
fresh
plant_literal directory
printf 'directory: control\n' >>"$scratch/t/tools/ledger-client-dependencies.allow"
expect allowlisted-forbidden 1 'depends on directory .*directory is forbidden'
fresh
plant_literal singular-registry:local-services
printf 'singular-registry:local-services: control\n' >>"$scratch/t/tools/ledger-client-dependencies.allow"
expect allowlisted-component 1 'depends on singular-registry:local-services .*may not be a dependency'

# A reviewed addition passes; the same addition in a stanza the library
# does not import is not a dependency of the library.
fresh
plant_literal http-conduit
printf 'http-conduit: control\n' >>"$scratch/t/tools/ledger-client-dependencies.allow"
expect reviewed-addition 0 '^PASS ledger-client-dependencies'
fresh
plant_unreached_common http-conduit
expect unreached-common 0 '^PASS ledger-client-dependencies'

fresh
printf 'transformers:\n' >>"$scratch/t/tools/ledger-client-dependencies.allow"
sed -i '0,/^transformers: .*/{//d}' "$scratch/t/tools/ledger-client-dependencies.allow"
expect reasonless-entry 1 "allowlist: 'transformers' carries no reason"

fresh
printf 'no-such-package: control\n' >>"$scratch/t/tools/ledger-client-dependencies.allow"
expect stale-entry 1 "allowlist: 'no-such-package' is no dependency of ledger-client"

fresh
sed -i 's/^library ledger-client$/library ledger-client-gone/' "$(cabal)"
expect no-stanza 2 "^SETUP-FAIL: no 'library ledger-client' stanza"

fresh
after_header "  import: no-such-common"
expect missing-common 2 '^SETUP-FAIL: no stanza common no-such-common'

fresh
rm "$scratch/t/tools/ledger-client-dependencies.allow"
expect no-allowlist 2 '^SETUP-FAIL: no .*ledger-client-dependencies.allow'

fresh
rm "$(cabal)"
expect no-cabal-file 2 '^SETUP-FAIL: no .*singular-registry.cabal'

echo "PASS ledger-client-dependencies-controls: $controls controls"
