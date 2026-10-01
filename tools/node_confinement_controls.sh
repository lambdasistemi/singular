#!/usr/bin/env bash
# Controls for tools/node_confinement_check.sh: it passes on this tree and
# fails, with its named diagnostic, on each defect it exists to refuse.
#
# Every control runs on a scratch copy of the scanned roots and the
# allowlist; the tree itself is never touched. The planted module is
# discovered — the first scanned source the allowlist does not exempt —
# so the control does not go stale when modules move.
set -euo pipefail

repo=${1:-.}
check="$repo/tools/node_confinement_check.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fresh() {
  rm -rf "$scratch/t"
  mkdir -p "$scratch/t/offchain" "$scratch/t/tools"
  cp -r "$repo/offchain/cli" "$repo/offchain/lib" "$scratch/t/offchain/"
  find "$scratch/t" -name dist-newstyle -prune -exec rm -rf {} +
  cp "$repo/tools/node-confinement.allow" "$scratch/t/tools/"
}

# expect NAME STATUS PATTERN: the check on the scratch tree exits STATUS
# and its output matches PATTERN.
expect() {
  local name="$1" want="$2" pattern="$3" got=0
  bash "$check" "$scratch/t" >"$scratch/out" 2>&1 || got=$?
  if [ "$got" -ne "$want" ] || ! grep -qE -- "$pattern" "$scratch/out"; then
    cat "$scratch/out" >&2
    echo "FAIL node-confinement control '$name': exit $got (wanted $want), pattern '$pattern'" >&2
    exit 1
  fi
  echo "control $name: exit $got, $(grep -cE -- "$pattern" "$scratch/out") matching line(s)"
}

fresh
expect clean-tree 0 '^PASS node-confinement'

# The planted module: the first scanned source no allowlist line names.
mapfile -t exempt < <(grep -vE '^(#|$)' "$scratch/t/tools/node-confinement.allow" | cut -d: -f1)
target=""
while IFS= read -r f; do
  rel=${f#"$scratch/t/"}
  skip=""
  for e in "${exempt[@]}"; do [ "$e" = "$rel" ] && skip=1; done
  [ -z "$skip" ] && {
    target="$rel"
    break
  }
done < <(find "$scratch/t/offchain/cli" -name '*.hs' | sort)
[ -n "$target" ] || {
  echo "SETUP-FAIL: no non-allowlisted module to plant into" >&2
  exit 2
}

fresh
sed -i '0,/^import /s//import Singular.Registry.Node (NodeMode (..))\nimport /' "$scratch/t/$target"
grep -q 'NodeMode (..)' "$scratch/t/$target" || {
  echo "SETUP-FAIL: the plant did not apply to $target" >&2
  exit 2
}
expect planted-mode 1 "^$target:[0-9]+:import Singular.Registry.Node \\(NodeMode"

fresh
printf '\nrawSend = submitTx\n' >>"$scratch/t/$target"
expect planted-raw-submit 1 "^$target:[0-9]+:rawSend = submitTx"

fresh
printf 'offchain/cli/Main.hs:\n' >>"$scratch/t/tools/node-confinement.allow"
expect reasonless-entry 1 "'offchain/cli/Main.hs' carries no reason"

fresh
printf 'offchain/cli/Gone.hs: a module that is not there\n' >>"$scratch/t/tools/node-confinement.allow"
expect stale-entry 1 "'offchain/cli/Gone.hs' does not exist"

fresh
printf 'offchain/cli/Main.hs: names nothing confined\n' >>"$scratch/t/tools/node-confinement.allow"
expect unneeded-entry 1 "'offchain/cli/Main.hs' names no confined identifier"

fresh
rm -rf "$scratch/t/offchain/lib"
mkdir -p "$scratch/t/offchain/lib"
expect empty-extent 2 '^EMPTY EXTENT'

echo "PASS node-confinement-controls: 7 controls, plant in $target"
