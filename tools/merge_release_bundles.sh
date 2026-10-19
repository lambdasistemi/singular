#!/usr/bin/env bash
# merge-release-bundles (#695): add the platform bundles to the release
# directory the publisher is about to upload, and to its one SHA256SUMS.
#
# usage: merge_release_bundles.sh CONF RELEASE_DIR BUNDLES_DIR VERSION
#
# CONF is release_bundles.sh. RELEASE_DIR holds the documentation and
# on-chain archives and the SHA256SUMS over them. BUNDLES_DIR (may be empty
# or absent for a release that ships none) holds the tarballs the bundle
# builds uploaded. For a release that ships bundles every platform in CONF
# must be there, and nothing else named like a bundle: the bundles are copied
# beside the archives and listed after them in SHA256SUMS, one line each.
#
# Exit 0 and a `merge-release-bundles: PASS` line; exit 1 and one FAIL line
# when a platform's bundle is missing or an unexpected one is present.
set -euo pipefail

# a missing tool is a failed setup, never a pass
for tool in grep sed find basename sort sha256sum cp wc; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "merge-release-bundles: needs $tool on PATH" >&2
    exit 2
  }
done

[ "$#" -eq 4 ] || {
  echo "usage: merge_release_bundles.sh CONF RELEASE_DIR BUNDLES_DIR VERSION" >&2
  exit 2
}
conf="$1"
release="$2"
bundles="$3"
version="$4"
# shellcheck source=/dev/null
. "$conf"
[ -f "$release/SHA256SUMS" ] || {
  echo "merge-release-bundles: FAIL $release has no SHA256SUMS"
  exit 1
}

present=""
if [ -n "$bundles" ] && [ -d "$bundles" ]; then
  present="$(find "$bundles" -mindepth 1 -maxdepth 1 -exec basename {} \; | LC_ALL=C sort)"
fi

wanted=""
if bundles_required "$version"; then
  for system in $SYSTEMS; do
    wanted="$wanted singular-$version-$system.tar.gz"
    printf '%s\n' "$present" | grep -Fxq "singular-$version-$system.tar.gz" || {
      echo "merge-release-bundles: FAIL release $version ships a bundle for every platform in $conf, and singular-$version-$system.tar.gz is missing from ${bundles:-no bundle directory}"
      exit 1
    }
  done
fi
for file in $present; do
  case " $wanted " in
    *" $file "*) ;;
    *)
      echo "merge-release-bundles: FAIL $file is in the bundle directory and is not a bundle release $version ships"
      exit 1
      ;;
  esac
done

for file in $wanted; do
  cp "$bundles/$file" "$release/$file"
  (cd "$release" && sha256sum "$file") >>"$release/SHA256SUMS"
done
(cd "$release" && sha256sum --check --strict --quiet SHA256SUMS) \
  || {
    echo "merge-release-bundles: FAIL the merged SHA256SUMS does not match the release directory"
    exit 1
  }
echo "merge-release-bundles: PASS $(printf '%s\n' "$wanted" | wc -w | tr -d ' ') bundles merged into $(wc -l <"$release/SHA256SUMS" | tr -d ' ') checksum lines"
