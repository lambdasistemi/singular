#!/usr/bin/env bash
# The controls of cabal_versions.sh (#695): the check passes on the committed
# tree and refuses each way the versions can drift, and sync repairs drift.
#
# usage: cabal_versions.test.sh CABAL_VERSIONS ROOT
set -euo pipefail
[ "$#" -eq 2 ] || {
  echo "usage: cabal_versions.test.sh CABAL_VERSIONS ROOT" >&2
  exit 2
}
script="$1"
root="$2"
work="$(mktemp -d "${TMPDIR:-/tmp}/cabal-versions-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fresh() {
  rm -rf "$work/tree"
  mkdir -p "$work/tree/offchain" "$work/tree/applications/open-datum/offchain"
  cp "$root/.release-please-manifest.json" "$work/tree/"
  cp "$root/offchain/singular-registry.cabal" "$work/tree/offchain/"
  cp "$root/applications/open-datum/offchain/open-datum.cabal" "$work/tree/applications/open-datum/offchain/"
  # a tree copied from the read-only store is writable again for the plants
  chmod -R u+w "$work/tree"
}
must_fail() {
  label="$1"
  shift
  if "$@" >"$work/out" 2>&1; then
    echo "cabal-versions-controls: FAIL $label was accepted"
    exit 1
  fi
  echo "cabal-versions-controls: $label refused: $(grep -m1 -e FAIL -e "no " "$work/out" || head -n 1 "$work/out")"
}

# the committed tree passes, and the check looks at both files
fresh
bash "$script" check "$work/tree" >"$work/out"
[ "$(grep -c ': PASS' "$work/out")" -eq 2 ] \
  || {
    echo "cabal-versions-controls: FAIL the check did not read both files"
    exit 1
  }
echo "cabal-versions-controls: the committed tree passes, both files read"

# a Cabal file left behind (no release is older than this)
fresh
sed -i -E 's/^version:.*/version:       0.0.1.0/' "$work/tree/offchain/singular-registry.cabal"
must_fail "singular-registry behind the manifest" bash "$script" check "$work/tree"
fresh
sed -i -E 's/^version:.*/version:       0.0.1.0/' "$work/tree/applications/open-datum/offchain/open-datum.cabal"
must_fail "open-datum behind the manifest" bash "$script" check "$work/tree"
# the manifest ahead of both (no release is as new as this)
fresh
printf '{".":"999.0.0"}\n' >"$work/tree/.release-please-manifest.json"
must_fail "a manifest ahead of the Cabal files" bash "$script" check "$work/tree"
# a version without the fourth component
fresh
sed -i -E 's/^version:.*/version:       0.12.0/' "$work/tree/offchain/singular-registry.cabal"
must_fail "a three-component Cabal version" bash "$script" check "$work/tree"
# a missing file is no pass
fresh
rm "$work/tree/offchain/singular-registry.cabal"
must_fail "a missing Cabal file" bash "$script" check "$work/tree"

# sync repairs the drift the release manifest introduces
fresh
printf '{".":"999.0.0"}\n' >"$work/tree/.release-please-manifest.json"
bash "$script" sync "$work/tree" >/dev/null
bash "$script" check "$work/tree" >/dev/null
grep -q '^version:       999.0.0.0$' "$work/tree/offchain/singular-registry.cabal" \
  || {
    echo "cabal-versions-controls: FAIL sync wrote the wrong version"
    exit 1
  }
echo "cabal-versions-controls: sync moved both files to 999.0.0.0 and the check then passes"
echo "cabal-versions-controls: PASS"
