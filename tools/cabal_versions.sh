#!/usr/bin/env bash
# cabal-versions (#695): the Cabal version of each shipped program follows the
# release manifest. Release 0.12.0 is Cabal version 0.12.0.0 (the Haskell
# package version policy takes four components, the fourth always 0), and
# `singular --version` and `open-datum --version` print what their package
# says.
#
# usage: cabal_versions.sh check|sync ROOT
#
#   check  exit 0 when every listed Cabal file states the manifest's version
#          followed by .0, else exit 1 with one FAIL line per file that does
#          not; "Cabal version matches manifest" in CI
#   sync   rewrite the version of each listed file to the manifest's, used on
#          the release pull request's branch after release-please bumped the
#          manifest
#
# Exit 2 on usage or when the manifest or a listed file is missing.
set -euo pipefail

files="offchain/singular-registry.cabal applications/open-datum/offchain/open-datum.cabal"

[ "$#" -eq 2 ] || {
  echo "usage: cabal_versions.sh check|sync ROOT" >&2
  exit 2
}
mode="$1"
root="$2"
manifest="$root/.release-please-manifest.json"
[ -f "$manifest" ] || {
  echo "cabal-versions: no $manifest" >&2
  exit 2
}
release="$(jq -er '."."' "$manifest")"
[[ "$release" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "cabal-versions: the manifest's version [$release] is not X.Y.Z" >&2
  exit 2
}
expected="$release.0"

status=0
for file in $files; do
  path="$root/$file"
  [ -f "$path" ] || {
    echo "cabal-versions: no $path" >&2
    exit 2
  }
  stated="$(sed -n -E 's/^version:[[:space:]]+([^[:space:]]+)[[:space:]]*$/\1/p' "$path")"
  [ "$(printf '%s\n' "$stated" | wc -l | tr -d ' ')" -eq 1 ] && [ -n "$stated" ] || {
    echo "cabal-versions: $file has no single version field" >&2
    exit 2
  }
  case "$mode" in
    check)
      if [ "$stated" = "$expected" ]; then
        echo "cabal-versions: $file $stated: PASS"
      else
        echo "cabal-versions: FAIL $file says $stated, the release manifest says $release (expected $expected)"
        status=1
      fi
      ;;
    sync)
      sed -i.bak -E "s/^(version:[[:space:]]+)[^[:space:]]+[[:space:]]*\$/\\1$expected/" "$path"
      rm -f "$path.bak"
      echo "cabal-versions: $file set to $expected"
      ;;
    *)
      echo "usage: cabal_versions.sh check|sync ROOT" >&2
      exit 2
      ;;
  esac
done
exit "$status"
