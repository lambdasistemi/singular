#!/usr/bin/env bash
# release-bundle-smoke (#695): run a release bundle as a user would, from the
# downloaded tarball alone. It needs no Nix, so it runs on every platform
# that ships a bundle and again on the published asset.
#
# usage: release_bundle_smoke.sh TARBALL VERSION COMMIT
#
# TARBALL is singular-VERSION-SYSTEM.tar.gz; VERSION is the release number
# (0.12.0) and COMMIT the commit the bundle must name. In order, each check
# stopping the run on refusal:
#
#   members     both launchers, both executables, the packaged time files,
#               VERSION and COMMIT beside them
#   identity    `singular --version` and `open-datum --version` print
#               `<program> VERSION (commit COMMIT)` and exit 0
#   help        `--help` of each exits 0 and prints something
#   offline     `singular wallet create` in a temporary directory, then
#               `wallet address`, name the same address
#   standalone  nothing the executables load comes from the Nix store or the
#               host: on Linux the bundled loader resolves every library
#               inside the bundle, and a run in a sandbox that mounts the
#               bundle alone works when the runner allows one; on macOS every
#               load path is a system library or inside the bundle and every
#               file's ad-hoc signature verifies
#
# Exit 0 and a `release-bundle-smoke: PASS` line when every check passes;
# exit 1 and one `release-bundle-smoke: FAIL <check>: <detail>` line when one
# refuses; exit 2 on usage.
set -euo pipefail

# a missing tool is a failed setup, never a pass
for tool in tar gzip grep sed awk find basename tr wc cut head sort mktemp uname; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "release-bundle-smoke: needs $tool on PATH" >&2
    exit 2
  }
done

[ "$#" -eq 3 ] || {
  echo "usage: release_bundle_smoke.sh TARBALL VERSION COMMIT" >&2
  exit 2
}
tarball="$1"
version="$2"
commit="$3"
[ -f "$tarball" ] || {
  echo "release-bundle-smoke: no such tarball: $tarball" >&2
  exit 2
}

fail() {
  echo "release-bundle-smoke: FAIL $1: $2"
  exit 1
}
pass() { echo "release-bundle-smoke: $1: PASS${2:+ — $2}"; }

work="$(mktemp -d "${TMPDIR:-/tmp}/release-bundle-smoke.XXXXXX")"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

mkdir -p "$work/tree"
tar -xzf "$tarball" -C "$work/tree" 2>"$work/extract.log" \
  || fail members "$tarball does not extract: $(tr '\n' ' ' <"$work/extract.log")"
entries="$(find "$work/tree" -mindepth 1 -maxdepth 1 -exec basename {} \;)"
[ "$(printf '%s\n' "$entries" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail members "$tarball does not hold exactly one top directory: $entries"
bundle="$work/tree/$entries"
[ -d "$bundle" ] || fail members "$entries is not a directory"

# members
for member in bin/singular bin/open-datum libexec/singular libexec/open-datum \
  share/singular-registry/data/network/preprod/time-manifest.json \
  share/singular-registry/data/network/devnet/shelley-genesis.json \
  VERSION COMMIT; do
  [ -e "$bundle/$member" ] || fail members "$tarball carries no $member"
done
for program in singular open-datum; do
  [ -x "$bundle/bin/$program" ] || fail members "bin/$program is not executable"
  [ -x "$bundle/libexec/$program" ] || fail members "libexec/$program is not executable"
done
[ "$(cat "$bundle/VERSION")" = "$version" ] \
  || fail members "VERSION says $(cat "$bundle/VERSION"), not $version"
[ "$(cat "$bundle/COMMIT")" = "$commit" ] \
  || fail members "COMMIT says $(cat "$bundle/COMMIT"), not $commit"
pass members "$entries"

# identity
for program in singular open-datum; do
  expected="$program $version (commit $commit)"
  status=0
  printed="$("$bundle/bin/$program" --version 2>"$work/version.err")" || status=$?
  [ "$status" -eq 0 ] || fail identity "$program --version exited $status"
  [ "$printed" = "$expected" ] \
    || fail identity "$program --version printed [$printed], not [$expected]"
  [ ! -s "$work/version.err" ] \
    || fail identity "$program --version wrote to standard error: $(head -n 1 "$work/version.err")"
done
pass identity "singular and open-datum name $version and $commit"

# help
for program in singular open-datum; do
  status=0
  "$bundle/bin/$program" --help >"$work/help.out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail help "$program --help exited $status"
  [ -s "$work/help.out" ] || fail help "$program --help printed nothing"
done
pass help "both print"

# offline
mkdir -p "$work/offline"
passphrase="release-bundle-smoke-passphrase"
created="$(cd "$work/offline" && printf '%s\n' "$passphrase" \
  | "$bundle/bin/singular" wallet create --vault vault --network-magic 1 --passphrase-fd 0)" \
  || fail offline "singular wallet create failed"
shown="$(cd "$work/offline" && printf '%s\n' "$passphrase" \
  | "$bundle/bin/singular" wallet address --vault vault --network-magic 1 --passphrase-fd 0)" \
  || fail offline "singular wallet address failed"
case "$created" in
  addr_test1*) ;;
  *) fail offline "wallet create printed [$created], not a preprod address" ;;
esac
[ "$created" = "$shown" ] \
  || fail offline "wallet address named [$shown], wallet create [$created]"
pass offline "wallet create and wallet address name $created"

# standalone
case "$(uname -s)" in
  Linux)
    loader=""
    for candidate in "$bundle"/lib/ld-linux-*; do
      [ -e "$candidate" ] && loader="$(basename "$candidate")"
      break
    done
    [ -n "$loader" ] || fail standalone "no loader in the bundle's lib"
    for program in singular open-datum; do
      "$bundle/lib/$loader" --library-path "$bundle/lib" --list "$bundle/libexec/$program" \
        >"$work/list.out" 2>&1 || fail standalone "the bundled loader cannot list $program"
      resolved="$(awk '$2 == "=>" && $3 ~ /^\// { print $3 }' "$work/list.out")"
      # nothing outside the bundle means something only when libraries resolved
      [ "$(printf '%s\n' "$resolved" | grep -c .)" -ge 5 ] \
        || fail standalone "the bundled loader resolved too few libraries for $program: $(tr '\n' ' ' <"$work/list.out")"
      printf '%s\n' "$resolved" | grep -q '/libc\.so' \
        || fail standalone "the bundled loader did not resolve the C library for $program"
      outside="$(printf '%s\n' "$resolved" | grep -v "^$bundle/lib/" || true)"
      [ -z "$outside" ] \
        || fail standalone "$program loads outside the bundle: $(printf '%s' "$outside" | tr '\n' ' ')"
      missing="$(grep 'not found' "$work/list.out" || true)"
      [ -z "$missing" ] || fail standalone "$program misses a library: $missing"
    done
    sandbox="not run (no usable bubblewrap)"
    if command -v bwrap >/dev/null 2>&1 \
      && bwrap --unshare-all --die-with-parent --ro-bind "$bundle" /bundle --proc /proc --dev /dev \
        --tmpfs /tmp --clearenv /bundle/lib/"$loader" --version >/dev/null 2>&1; then
      for program in singular open-datum; do
        printed="$(bwrap --unshare-all --die-with-parent --ro-bind "$bundle" /bundle --proc /proc \
          --dev /dev --tmpfs /tmp --chdir /tmp --clearenv \
          --setenv singular_registry_datadir /bundle/share/singular-registry \
          "/bundle/lib/$loader" --library-path /bundle/lib "/bundle/libexec/$program" --version)" \
          || fail standalone "$program does not run with only the bundle mounted"
        [ "$printed" = "$program $version (commit $commit)" ] \
          || fail standalone "$program in the sandbox printed [$printed]"
      done
      sandbox="run with only the bundle mounted (no /nix, no host libraries)"
    fi
    pass standalone "every library resolves inside the bundle; sandbox $sandbox"
    ;;
  Darwin)
    for file in "$bundle"/libexec/* "$bundle"/lib/*; do
      loads="$(otool -L "$file" | awk 'NR > 1 { print $1 }')"
      foreign="$(printf '%s\n' "$loads" | grep -v '^/usr/lib/\|^/System/\|^@executable_path/\.\./lib/\|^@loader_path/' || true)"
      [ -z "$foreign" ] \
        || fail standalone "$(basename "$file") loads outside the bundle and the system: $(printf '%s' "$foreign" | tr '\n' ' ')"
      codesign --verify --strict "$file" 2>"$work/codesign.err" \
        || fail standalone "$(basename "$file") has no valid signature: $(head -n 1 "$work/codesign.err")"
    done
    for program in singular open-datum; do
      printed="$(env -i "$bundle/bin/$program" --version)" \
        || fail standalone "$program does not run with an empty environment"
      [ "$printed" = "$program $version (commit $commit)" ] \
        || fail standalone "$program with an empty environment printed [$printed]"
    done
    pass standalone "every load is a system library or inside the bundle; every signature verifies"
    ;;
  *) fail standalone "no standalone check for $(uname -s)" ;;
esac

echo "release-bundle-smoke: PASS $(basename "$tarball") — members, identity, help, offline and standalone"
