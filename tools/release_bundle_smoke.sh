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
#   members     the launchers and executables, the packaged time files,
#               VERSION and COMMIT beside them, and, for a release that
#               carries the development node (#707), `devnet`, `cardano-node`
#               and the genesis files, and the deployment blueprint
#               share/plutus.json with share/version.txt naming VERSION
#               and, for a release that carries the table of releases (#728),
#               share/singular-registry/data/contracts/state-contracts.json
#   identity    `singular --version`, `open-datum --version` and
#               `devnet --version` print `<program> VERSION (commit COMMIT)`
#               and exit 0; `cardano-node --version` names its own release
#   help        `--help` of each exits 0 and prints something
#   offline     `singular wallet create` in a temporary directory, then
#               `wallet address`, name the same address
#   contracts   for a release that carries the table of releases: the bundled
#               `singular` refuses a registry made by other contracts and names
#               the releases that carry them and the page of the newest, so it
#               found its table; with the table file moved away it says the
#               table cannot be used and names no release, so the check can fail
#   standalone  nothing the executables load comes from the Nix store or the
#               host: on Linux the bundled loader resolves every library
#               inside the bundle, and a run in a sandbox that mounts the
#               bundle alone works when the runner allows one; on macOS every
#               load path is a system library or inside the bundle and every
#               file's ad-hoc signature verifies
#   node        `devnet` started from the unpacked bundle with an empty
#               environment prints its settings document, the node it
#               started answers on the socket the document names, and
#               stopping `devnet` stops the node and removes the socket
#
# Whether a bundle must carry the development node is decided by
# RELEASE_BUNDLE_DEVNET: `required` (a bundle built from source, which always
# does) or `by-version` (the default: the releases after LAST_WITHOUT_DEVNET in
# RELEASE_BUNDLES_CONF, release_bundles.sh beside this file unless set; an
# older release's bundle is checked as it was published).
#
# Exit 0 and a `release-bundle-smoke: PASS` line when every check passes;
# exit 1 and one `release-bundle-smoke: FAIL <check>: <detail>` line when one
# refuses; exit 2 on usage.
set -euo pipefail

# a missing tool is a failed setup, never a pass
for tool in tar gzip grep sed awk find basename tr wc cut head sort mktemp uname pgrep kill sleep ps; do
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
# alive PID: the process runs (a child that stopped and was not yet reaped does not)
alive() {
  state="$(ps -o stat= -p "$1" 2>/dev/null | tr -d " ")"
  [ -n "$state" ] && [ "${state#Z}" = "$state" ]
}

work="$(mktemp -d "${TMPDIR:-/tmp}/release-bundle-smoke.XXXXXX")"
devnet_pid=""
cleanup() {
  # a development node this run started never outlives it
  [ -z "$devnet_pid" ] || kill "$devnet_pid" 2>/dev/null || true
  chmod -R u+w "$work" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/tree"
tar -xzf "$tarball" -C "$work/tree" 2>"$work/extract.log" \
  || fail members "$tarball does not extract: $(tr '\n' ' ' <"$work/extract.log")"
entries="$(find "$work/tree" -mindepth 1 -maxdepth 1 -exec basename {} \;)"
[ "$(printf '%s\n' "$entries" | wc -l | tr -d ' ')" -eq 1 ] \
  || fail members "$tarball does not hold exactly one top directory: $entries"
bundle="$work/tree/$entries"
[ -d "$bundle" ] || fail members "$entries is not a directory"

# does this bundle have to carry the development node (#707)?
case "${RELEASE_BUNDLE_DEVNET:-by-version}" in
  required)
    with_devnet=true
    with_table=true
    ;;
  by-version)
    conf="${RELEASE_BUNDLES_CONF:-$(cd "$(dirname "$0")" && pwd)/release_bundles.sh}"
    [ -f "$conf" ] || {
      echo "release-bundle-smoke: no bundle rule at $conf" >&2
      exit 2
    }
    # shellcheck source=/dev/null
    . "$conf"
    # a bundle of an older release is checked as it was published; any
    # bundle that carries the node is checked as one that does
    if devnet_required "$version" || [ -e "$bundle/bin/devnet" ]; then
      with_devnet=true
    else
      with_devnet=false
    fi
    # likewise the table of releases: a bundle that carries it is checked as one that does
    if contract_table_required "$version" || [ -e "$bundle/share/singular-registry/data/contracts" ]; then
      with_table=true
    else
      with_table=false
    fi
    ;;
  *)
    echo "release-bundle-smoke: RELEASE_BUNDLE_DEVNET is required or by-version" >&2
    exit 2
    ;;
esac
cli_programs="singular open-datum"
bundled_programs="$cli_programs"
if $with_devnet; then
  cli_programs="$cli_programs devnet"
  bundled_programs="$cli_programs cardano-node"
fi

# members
for member in bin/singular bin/open-datum libexec/singular libexec/open-datum \
  share/singular-registry/data/network/preprod/time-manifest.json \
  share/singular-registry/data/network/devnet/shelley-genesis.json \
  VERSION COMMIT; do
  [ -e "$bundle/$member" ] || fail members "$tarball carries no $member"
done
if $with_table; then
  [ -e "$bundle/share/singular-registry/data/contracts/state-contracts.json" ] \
    || fail members "$tarball carries no share/singular-registry/data/contracts/state-contracts.json"
fi
if $with_devnet; then
  for member in bin/devnet bin/cardano-node libexec/devnet libexec/cardano-node \
    share/devnet/genesis/node-config.json share/devnet/genesis/topology.json \
    share/devnet/genesis/byron-genesis.json share/devnet/genesis/shelley-genesis.json \
    share/devnet/genesis/alonzo-genesis.json share/devnet/genesis/conway-genesis.json \
    share/devnet/genesis/dijkstra-genesis.json \
    share/devnet/genesis/delegate-keys/delegate1.kes.skey \
    share/devnet/genesis/delegate-keys/delegate1.opcert \
    share/devnet/genesis/delegate-keys/delegate1.vrf.skey \
    share/plutus.json share/version.txt; do
    [ -e "$bundle/$member" ] || fail members "$tarball carries no $member"
  done
  # the blueprint names the release it belongs to, and holds validators
  [ "$(cat "$bundle/share/version.txt")" = "$version" ] \
    || fail members "share/version.txt says $(cat "$bundle/share/version.txt"), not $version"
  grep -q '"validators"' "$bundle/share/plutus.json" \
    || fail members "share/plutus.json names no validators"
fi
for program in $bundled_programs; do
  [ -x "$bundle/bin/$program" ] || fail members "bin/$program is not executable"
  [ -x "$bundle/libexec/$program" ] || fail members "libexec/$program is not executable"
done
[ "$(cat "$bundle/VERSION")" = "$version" ] \
  || fail members "VERSION says $(cat "$bundle/VERSION"), not $version"
[ "$(cat "$bundle/COMMIT")" = "$commit" ] \
  || fail members "COMMIT says $(cat "$bundle/COMMIT"), not $commit"
pass members "$entries"

# identity
for program in $cli_programs; do
  expected="$program $version (commit $commit)"
  status=0
  printed="$("$bundle/bin/$program" --version 2>"$work/version.err")" || status=$?
  [ "$status" -eq 0 ] || fail identity "$program --version exited $status"
  [ "$printed" = "$expected" ] \
    || fail identity "$program --version printed [$printed], not [$expected]"
  [ ! -s "$work/version.err" ] \
    || fail identity "$program --version wrote to standard error: $(head -n 1 "$work/version.err")"
done
if $with_devnet; then
  # the node states its own release, not ours; it must run from the bundle
  status=0
  printed="$("$bundle/bin/cardano-node" --version 2>"$work/version.err" | head -n 1)" || status=$?
  case "$printed" in
    "cardano-node "*) ;;
    *) fail identity "cardano-node --version printed [$printed]" ;;
  esac
  node_release="${printed%% - *}"
  pass identity "$(printf '%s' "$cli_programs" | tr ' ' ',') name $version and $commit; $node_release"
else
  pass identity "singular and open-datum name $version and $commit"
fi

# help
for program in $cli_programs; do
  status=0
  "$bundle/bin/$program" --help >"$work/help.out" 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail help "$program --help exited $status"
  [ -s "$work/help.out" ] || fail help "$program --help printed nothing"
done
pass help "all print"

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

# contracts: a bundled program finds its table of releases. A registry whose
# policy is the hash of the contracts of an old release (the first of the table's
# rows that shares a release with others) is refused, before any chain read,
# with the releases that carry those contracts and the page of the newest. The
# table is then moved away: the same command says the table cannot be used and
# names no release, which is what shows the first answer came from the table.
if $with_table; then
  [ -f "$bundle/share/plutus.json" ] \
    || fail contracts "the bundle carries no share/plutus.json to run the program against"
  contracts_table="$bundle/share/singular-registry/data/contracts/state-contracts.json"
  contracts_policy=8ac9562f5fb6be9b9b913ae2ad2cc1d9e038f7f7039256f1ac9f7a62
  contracts_name="$(printf '%064d' 0)"
  contracts_probe() {
    "$bundle/bin/singular" registry describe --blueprint "$bundle/share/plutus.json" \
      --state-token "$contracts_policy.$contracts_name" --koios-url http://127.0.0.1:9 \
      --network-magic 42 2>&1 || true
  }
  contracts_first="$(contracts_probe)"
  for needle in state-token-foreign-release v0.4.1 v0.6.1 \
    https://github.com/lambdasistemi/singular/releases/tag/v0.6.1; do
    printf '%s' "$contracts_first" | grep -qF -- "$needle" \
      || fail contracts "the bundled singular did not say $needle of a registry of the contracts of v0.4.1: $(printf '%s' "$contracts_first" | tr '\n' ' ' | cut -c1-300)"
  done
  mv "$contracts_table" "$contracts_table.aside"
  contracts_second="$(contracts_probe)"
  mv "$contracts_table.aside" "$contracts_table"
  printf '%s' "$contracts_second" | grep -qF -- 'cannot be used' \
    || fail contracts "with the table moved away the bundled singular did not say the table cannot be used: $(printf '%s' "$contracts_second" | tr '\n' ' ' | cut -c1-300)"
  ! printf '%s' "$contracts_second" | grep -qF -- 'v0.6.1' \
    || fail contracts "with the table moved away the bundled singular still named a release"
  pass contracts "a registry of the contracts of v0.4.1 is refused naming v0.4.1 to v0.6.1 and their newest page; without the table it says so"
fi

# standalone
# linux_libraries DIRECTORY PROGRAM: the bundled loader of DIRECTORY resolves
# every library of PROGRAM inside DIRECTORY, and misses none.
linux_libraries() {
  directory="$1"
  program="$2"
  loader=""
  for candidate in "$bundle/$directory"/ld-linux-*; do
    [ -e "$candidate" ] && loader="$(basename "$candidate")"
    break
  done
  [ -n "$loader" ] || fail standalone "no loader in the bundle's $directory"
  "$bundle/$directory/$loader" --library-path "$bundle/$directory" --list "$bundle/libexec/$program" \
    >"$work/list.out" 2>&1 || fail standalone "the bundled loader cannot list $program"
  resolved="$(awk '$2 == "=>" && $3 ~ /^\// { print $3 }' "$work/list.out")"
  # nothing outside the bundle means something only when libraries resolved
  [ "$(printf '%s\n' "$resolved" | grep -c .)" -ge 5 ] \
    || fail standalone "the bundled loader resolved too few libraries for $program: $(tr '\n' ' ' <"$work/list.out")"
  printf '%s\n' "$resolved" | grep -q '/libc\.so' \
    || fail standalone "the bundled loader did not resolve the C library for $program"
  outside="$(printf '%s\n' "$resolved" | grep -v "^$bundle/$directory/" || true)"
  [ -z "$outside" ] \
    || fail standalone "$program loads outside the bundle: $(printf '%s' "$outside" | tr '\n' ' ')"
  missing="$(grep 'not found' "$work/list.out" || true)"
  [ -z "$missing" ] || fail standalone "$program misses a library: $missing"
}
case "$(uname -s)" in
  Linux)
    loader=""
    for candidate in "$bundle"/lib/ld-linux-*; do
      [ -e "$candidate" ] && loader="$(basename "$candidate")"
      break
    done
    [ -n "$loader" ] || fail standalone "no loader in the bundle's lib"
    for program in $cli_programs; do
      linux_libraries lib "$program"
    done
    if $with_devnet; then linux_libraries lib-node cardano-node; fi
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
    for file in "$bundle"/libexec/* "$bundle"/lib/* "$bundle"/lib-node/*; do
      [ -e "$file" ] || continue
      loads="$(otool -L "$file" | awk 'NR > 1 { print $1 }')"
      foreign="$(printf '%s\n' "$loads" | grep -v '^/usr/lib/\|^/System/\|^@executable_path/\.\./lib\(-node\)\{0,1\}/\|^@loader_path/' || true)"
      [ -z "$foreign" ] \
        || fail standalone "$(basename "$file") loads outside the bundle and the system: $(printf '%s' "$foreign" | tr '\n' ' ')"
      codesign --verify --strict "$file" 2>"$work/codesign.err" \
        || fail standalone "$(basename "$file") has no valid signature: $(head -n 1 "$work/codesign.err")"
    done
    for program in $cli_programs; do
      printed="$(env -i "$bundle/bin/$program" --version)" \
        || fail standalone "$program does not run with an empty environment"
      [ "$printed" = "$program $version (commit $commit)" ] \
        || fail standalone "$program with an empty environment printed [$printed]"
    done
    pass standalone "every load is a system library or inside the bundle; every signature verifies"
    ;;
  *) fail standalone "no standalone check for $(uname -s)" ;;
esac

# node: the development node, started from the unpacked bundle with an empty
# environment, so the node it runs is the bundled one and nothing is read from
# the host. Its settings document is the first line it prints.
checked="members, identity, help, offline and standalone"
if $with_table; then checked="members, identity, help, offline, contracts and standalone"; fi
if $with_devnet; then
  node_tmp="$work/node-tmp"
  mkdir -p "$node_tmp"
  (cd "$work" && exec env -i HOME="$work" TMPDIR="$node_tmp" "$bundle/bin/devnet") \
    >"$work/devnet.out" 2>"$work/devnet.err" &
  devnet_pid=$!
  settings_socket=""
  waited=0
  while [ "$waited" -lt 240 ]; do
    settings="$(head -n 1 "$work/devnet.out" 2>/dev/null || true)"
    settings_socket="$(printf '%s' "$settings" | sed -n 's/.*"privateProbeSocket":"\([^"]*\)".*/\1/p')"
    magic="$(printf '%s' "$settings" | sed -n 's/.*"networkMagic":\([0-9][0-9]*\).*/\1/p')"
    [ -n "$settings_socket" ] && [ "$magic" = 42 ] && [ -S "$settings_socket" ] && break
    alive "$devnet_pid" \
      || fail node "devnet exited before printing its settings: $(tail -n 3 "$work/devnet.err" | tr '\n' ' ')"
    sleep 1
    waited=$((waited + 1))
  done
  [ -S "$settings_socket" ] \
    || fail node "devnet printed no usable settings in ${waited}s: $(head -c 300 "$work/devnet.out") $(tail -n 3 "$work/devnet.err" | tr '\n' ' ')"
  # the node that answers is the bundle's own
  pgrep -f "$bundle/libexec/cardano-node" >/dev/null \
    || fail node "no cardano-node of this bundle is running although devnet printed its settings"
  stopped=0
  kill -TERM "$devnet_pid" 2>/dev/null || true
  while [ "$stopped" -lt 30 ]; do
    if ! alive "$devnet_pid" && ! pgrep -f "$bundle/libexec/cardano-node" >/dev/null; then break; fi
    sleep 1
    stopped=$((stopped + 1))
  done
  ! alive "$devnet_pid" \
    || fail node "devnet did not stop within ${stopped}s of SIGTERM"
  ! pgrep -f "$bundle/libexec/cardano-node" >/dev/null \
    || fail node "cardano-node outlived devnet by ${stopped}s"
  devnet_pid=""
  pass node "settings after ${waited}s from the bundle's own node; stopped with it in ${stopped}s"
  checked="$checked and node"
fi

echo "release-bundle-smoke: PASS $(basename "$tarball") — $checked"
