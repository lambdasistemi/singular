#!/usr/bin/env bash
# The controls of verify_release_bundles.sh (#695), against a real bundle
# built for this platform: every way a published bundle can be wrong is
# refused, for its own reason.
#
# usage: verify_release_bundles.test.sh VERIFY CONF SMOKE CONTROLS TARBALL VERSION COMMIT
set -Eeuo pipefail
# a failing command names itself: a silent exit hides which control broke
trap 'echo "verify-release-bundles-controls: FAIL at line $LINENO: $BASH_COMMAND" >&2' ERR
[ "$#" -eq 7 ] || {
  echo "usage: verify_release_bundles.test.sh VERIFY CONF SMOKE CONTROLS TARBALL VERSION COMMIT" >&2
  exit 2
}
verify="$1"
conf="$2"
smoke="$3"
controls="$4"
tarball="$5"
version="$6"
commit="$7"
# shellcheck source=/dev/null
. "$conf"
work="$(mktemp -d "${TMPDIR:-/tmp}/verify-bundles-test.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
native="$(native_system)"

# a downloaded release: the real bundle for this platform, a structural
# stand-in for every other platform (the other platform's own job runs it)
download() {
  local system name top program
  rm -rf "$work/download"
  mkdir -p "$work/download"
  for system in $SYSTEMS; do
    name="singular-$version-$system.tar.gz"
    if [ "$system" = "$native" ]; then
      cp "$tarball" "$work/download/$name"
      # a bundle copied from the read-only store is writable for the plants
      chmod u+w "$work/download/$name"
    else
      top="singular-$version-$system"
      rm -rf "$work/stand-in"
      mkdir -p "$work/stand-in/$top/bin" "$work/stand-in/$top/libexec"
      for program in singular open-datum; do
        printf '#!/bin/sh\n' >"$work/stand-in/$top/bin/$program"
        printf 'stand-in' >"$work/stand-in/$top/libexec/$program"
      done
      printf '%s\n' "$version" >"$work/stand-in/$top/VERSION"
      printf '%s\n' "$commit" >"$work/stand-in/$top/COMMIT"
      tar -czf "$work/download/$name" -C "$work/stand-in" "$top"
    fi
  done
  (cd "$work/download" && sha256sum ./*.tar.gz | sed 's|  \./|  |' >SHA256SUMS)
}
# change one byte of FILE to a different value (writing a fixed byte could
# write the byte already there)
flip_byte() {
  local original replacement
  original="$(dd if="$1" bs=1 skip=100 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')"
  replacement=$(((original + 1) % 256))
  # shellcheck disable=SC2059
  printf "\\$(printf '%03o' "$replacement")" | dd of="$1" bs=1 seek=100 conv=notrunc 2>/dev/null
}
run_verify() { bash "$verify" "$conf" "$smoke" "$controls" "$work/download" "$version" "$1"; }
must_refuse() {
  local label name
  label="$1"
  name="$2"
  shift 2
  if "$@" >"$work/out" 2>&1; then
    echo "verify-release-bundles-controls: FAIL $label was accepted"
    exit 1
  fi
  grep -q "REFUSED $name:" "$work/out" || {
    echo "verify-release-bundles-controls: FAIL $label was refused for another reason: $(tail -n 1 "$work/out")"
    exit 1
  }
  echo "verify-release-bundles-controls: $label refused as $name"
}

download
run_verify "$commit" >"$work/out" 2>&1 \
  || {
    echo "verify-release-bundles-controls: FAIL the good release is refused: $(tail -n 1 "$work/out")"
    exit 1
  }
echo "verify-release-bundles-controls: the good release passes: $(tail -n 1 "$work/out" | cut -c1-100)"

for system in $SYSTEMS; do
  name="singular-$version-$system.tar.gz"
  # the checksum file not updated after a byte of the bundle changed
  download
  flip_byte "$work/download/$name"
  must_refuse "a changed byte in the $system bundle" bundle-sum-mismatch run_verify "$commit"
  # the bundle not listed
  download
  grep -v " $name\$" "$work/download/SHA256SUMS" >"$work/sums" || true
  mv "$work/sums" "$work/download/SHA256SUMS"
  must_refuse "the $system bundle missing from the sums" bundle-missing run_verify "$commit"
  # the bundle not downloaded
  download
  rm "$work/download/$name"
  must_refuse "the $system bundle not downloaded" bundle-missing run_verify "$commit"
done

# a release whose tag names another commit than the bundles were built from
download
other="$(printf '%s' "$commit" | tr '0-9a-f' '1-9a-f0')"
must_refuse "a tag naming another commit" bundle-commit-mismatch run_verify "$other"
# a stand-in bundle for another platform without its executable
for system in $SYSTEMS; do
  [ "$system" != "$native" ] || continue
  download
  name="singular-$version-$system.tar.gz"
  rm -rf "$work/open"
  mkdir -p "$work/open"
  tar -xzf "$work/download/$name" -C "$work/open"
  rm "$work/open/singular-$version-$system/libexec/singular"
  tar -czf "$work/download/$name" -C "$work/open" "singular-$version-$system"
  (cd "$work/download" && sha256sum ./*.tar.gz | sed 's|  \./|  |' >SHA256SUMS)
  must_refuse "the $system bundle without its executable" bundle-layout run_verify "$commit"
done
echo "verify-release-bundles-controls: PASS"
