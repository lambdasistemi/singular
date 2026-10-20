#!/usr/bin/env bash
# verify-release, the bundle part (#695): check the platform bundles of a
# published release from the downloaded bytes alone. It needs no Nix, so a
# macOS machine runs it on the macOS bundle.
#
# usage: verify_release_bundles.sh CONF SMOKE CONTROLS DIR VERSION TAG_COMMIT
#
# CONF is release_bundles.sh, SMOKE and CONTROLS the bundle smoke script
# and its controls, DIR the directory the release's assets were downloaded
# into (SHA256SUMS and the bundles), TAG_COMMIT the commit the release's tag
# names. For every platform in CONF, in order:
#
#   listed      the bundle is in DIR and SHA256SUMS lists it
#   sum         its recorded checksum is its actual one
#   layout      it extracts to singular-VERSION-SYSTEM/ and holds both
#               launchers and executables, VERSION and COMMIT
#   identity    its VERSION is the release's and its COMMIT is the tag's
#   run         on the platform this runs on: the smoke script and its
#               controls, so `--version` names the tag commit from the
#               executable itself; a bundle of another platform is checked
#               up to identity and is run by its own platform's job
#
# Exit 0 and `verify-release: bundles: PASS`; exit 1 and one
# `verify-release: REFUSED <name>: <detail>` line otherwise. The names:
# bundle-missing, bundle-sum-mismatch, bundle-layout, bundle-commit-mismatch,
# bundle-run-failed. Exit 2 on usage.
set -euo pipefail

# a missing tool is a failed setup, never a pass
for tool in tar gzip grep sed awk find basename tr wc cut head sort sha256sum mktemp dd; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "verify-release: needs $tool on PATH" >&2
    exit 2
  }
done

[ "$#" -eq 6 ] || {
  echo "usage: verify_release_bundles.sh CONF SMOKE CONTROLS DIR VERSION TAG_COMMIT" >&2
  exit 2
}
conf="$1"
smoke="$2"
controls="$3"
dir="$4"
version="$5"
tag_commit="$6"
# shellcheck source=/dev/null
. "$conf"
# the smoke script reads the same rule for the development node
export RELEASE_BUNDLES_CONF="$conf"

refuse() {
  echo "verify-release: REFUSED $1: $2"
  exit 1
}
work="$(mktemp -d "${TMPDIR:-/tmp}/verify-bundles.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
native="$(native_system)"
checked=""

for system in $SYSTEMS; do
  name="singular-$version-$system.tar.gz"
  [ -f "$dir/$name" ] || refuse bundle-missing "$name was not downloaded from the release"
  recorded="$(awk -v n="$name" '$2 == n { print $1 }' "$dir/SHA256SUMS")"
  [ -n "$recorded" ] || refuse bundle-missing "SHA256SUMS does not list $name"
  actual="$(cd "$dir" && sha256sum "$name" | cut -d' ' -f1)"
  [ "$recorded" = "$actual" ] \
    || refuse bundle-sum-mismatch "$name has checksum $actual, SHA256SUMS lists $recorded"

  tree="$work/$system"
  mkdir -p "$tree"
  tar -xzf "$dir/$name" -C "$tree" 2>"$work/tar.err" \
    || refuse bundle-layout "$name does not extract: $(tr '\n' ' ' <"$work/tar.err")"
  top="$(cd "$tree" && ls -A)"
  [ "$top" = "singular-$version-$system" ] \
    || refuse bundle-layout "$name holds [$top], not singular-$version-$system"
  for member in bin/singular bin/open-datum libexec/singular libexec/open-datum VERSION COMMIT; do
    [ -e "$tree/$top/$member" ] || refuse bundle-layout "$name carries no $member"
  done
  if devnet_required "$version"; then
    for member in bin/devnet bin/cardano-node libexec/devnet libexec/cardano-node share/devnet/genesis/node-config.json; do
      [ -e "$tree/$top/$member" ] || refuse bundle-layout "$name carries no $member"
    done
  fi
  [ "$(cat "$tree/$top/VERSION")" = "$version" ] \
    || refuse bundle-commit-mismatch "$name says version $(cat "$tree/$top/VERSION"), the release is $version"
  [ "$(cat "$tree/$top/COMMIT")" = "$tag_commit" ] \
    || refuse bundle-commit-mismatch "$name was built from $(cat "$tree/$top/COMMIT"), the tag names $tag_commit"

  if [ "$system" = "$native" ]; then
    bash "$smoke" "$dir/$name" "$version" "$tag_commit" >"$work/smoke.out" 2>&1 \
      || refuse bundle-run-failed "$name on $native: $(grep 'FAIL' "$work/smoke.out" | head -n 1)"
    bash "$controls" "$dir/$name" "$version" "$tag_commit" >"$work/controls.out" 2>&1 \
      || refuse bundle-run-failed "the controls on $name: $(grep 'FAIL' "$work/controls.out" | head -n 1)"
    checked="$checked $system(run)"
  else
    checked="$checked $system(identity)"
  fi
done
echo "verify-release: bundles: PASS —$checked name $version and $tag_commit"
