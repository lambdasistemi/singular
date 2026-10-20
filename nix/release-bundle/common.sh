# shellcheck shell=bash
# Steps shared by the Linux and the macOS assembly. Sourced, never run alone.
#
# shellcheck disable=SC2154
# (out and the variables below are set by the builder or the sourcing script)
#
# Expects in the environment: BUNDLE_NAME BUNDLE_VERSION BUNDLE_COMMIT
# SINGULAR_PKG OPEN_DATUM_PKG DEVNET_PKG CARDANO_NODE_PKG DEVNET_GENESIS
# BLUEPRINT LAUNCHER DEVNET_PRELUDE, and TMPDIR from the builder.

# The three programs built with the registry share one set of libraries; the
# node is built against other libraries (another C library, other copies of
# several shared ones) and keeps its own, so no name ever resolves to two.
programs="singular open-datum devnet"
node_program="cardano-node"
work="$TMPDIR/assemble"
bundle="$work/$BUNDLE_NAME"

fail() {
  echo "release-bundle: $*" >&2
  exit 1
}

package_of() {
  case "$1" in
    singular) printf '%s' "$SINGULAR_PKG" ;;
    open-datum) printf '%s' "$OPEN_DATUM_PKG" ;;
    devnet) printf '%s' "$DEVNET_PKG" ;;
    cardano-node) printf '%s' "$CARDANO_NODE_PKG" ;;
    *) fail "unknown program $1" ;;
  esac
}

# The executables as the real files the launchers start.
copy_executables() {
  mkdir -p "$bundle/bin" "$bundle/libexec" "$bundle/share/singular-registry"
  for program in $programs $node_program; do
    source_file="$(package_of "$program")/bin/$program"
    [ -x "$source_file" ] || fail "no executable at $source_file"
    cp -L "$source_file" "$bundle/libexec/$program"
    chmod u+w "$bundle/libexec/$program"
  done
}

# The packaged time recordings and genesis files. Each executable names the
# data outputs of its libraries, which must hold the same files.
copy_data() {
  for program in $programs; do
    # An executable names a data output for each of its own libraries and
    # itself; only the registry library's holds the packaged files. Find the
    # files under every data output it names, whatever the path inside is.
    grep -a -o -E '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]*-data' \
      "$bundle/libexec/$program" | sort -u >"$work/$program.dataroots" || true
    : >"$work/$program.manifests"
    while IFS= read -r root; do
      [ -n "$root" ] || continue
      find "$root" -type f -path '*/data/network/preprod/time-manifest.json' >>"$work/$program.manifests" 2>/dev/null || true
    done <"$work/$program.dataroots"
    sed 's|/data/network/preprod/time-manifest.json$||' "$work/$program.manifests" | sort -u >"$work/$program.datadir"
    if [ "$(wc -l <"$work/$program.datadir" | tr -d ' ')" -lt 1 ]; then
      named="$(grep -a -o -E '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]*' "$bundle/libexec/$program" | sort -u | head -n 30 | tr '\n' ' ')"
      fail "$program names no packaged data directory: data outputs [$(tr '\n' ' ' <"$work/$program.dataroots")] hold the files in [$(tr '\n' ' ' <"$work/$program.datadir")]; store paths it names: $named"
    fi
    # the Cabal data-directory variable is what lets the launcher move it
    [ "$(grep -a -c singular_registry_datadir "$bundle/libexec/$program")" -ge 1 ] \
      || fail "$program does not read singular_registry_datadir"
  done
  # Every data output either executable names must hold the same files, so
  # the one shipped is what whichever of them the program reads would give.
  cat "$work/singular.datadir" "$work/open-datum.datadir" | sort -u >"$work/all.datadirs"
  first="$(head -n 1 "$work/all.datadirs")"
  [ -f "$first/data/network/preprod/time-manifest.json" ] \
    || fail "no preprod time manifest under $first"
  [ -f "$first/data/network/devnet/shelley-genesis.json" ] \
    || fail "no devnet genesis under $first"
  while IFS= read -r other; do
    diff -r "$first/data" "$other/data" \
      || fail "the data outputs the executables name differ: $first and $other"
  done <"$work/all.datadirs"
  cp -rL "$first/data" "$bundle/share/singular-registry/data"
  chmod -R u+w "$bundle/share/singular-registry"
}

# The genesis files, keys and settings the development node starts a chain
# from: the directory the Nix journeys name with E2E_GENESIS_DIR, found
# relative to the bundle by the devnet launcher.
copy_genesis() {
  [ -d "$DEVNET_GENESIS" ] || fail "no genesis directory at $DEVNET_GENESIS"
  mkdir -p "$bundle/share/devnet"
  cp -rL "$DEVNET_GENESIS" "$bundle/share/devnet/genesis"
  chmod -R u+w "$bundle/share/devnet"
  for member in alonzo-genesis.json byron-genesis.json conway-genesis.json \
    dijkstra-genesis.json node-config.json shelley-genesis.json topology.json \
    delegate-keys/delegate1.kes.skey delegate-keys/delegate1.opcert \
    delegate-keys/delegate1.vrf.skey; do
    [ -f "$bundle/share/devnet/genesis/$member" ] \
      || fail "the genesis directory $DEVNET_GENESIS holds no $member"
  done
}

# The deployment blueprint the commands take as --blueprint, the same file the
# on-chain archive ships as onchain/plutus.json, with the release number beside
# it: `singular registry describe` reads its version label from version.txt
# next to the blueprint and refuses a blueprint without one.
copy_blueprint() {
  [ -f "$BLUEPRINT" ] || fail "no blueprint at $BLUEPRINT"
  grep -q '"validators"' "$BLUEPRINT" || fail "$BLUEPRINT names no validators"
  mkdir -p "$bundle/share"
  cp -L "$BLUEPRINT" "$bundle/share/plutus.json"
  chmod u+w "$bundle/share/plutus.json"
  printf '%s\n' "$BUNDLE_VERSION" >"$bundle/share/version.txt"
}

# bin/<program>: the launcher with this bundle's identity and loader filled in.
# $1 starts the registry's programs, $2 the node. The development node's
# launcher carries its own lines (DEVNET_PRELUDE); the others carry none.
write_launchers() {
  loader_command="$1"
  node_loader_command="$2"
  for program in $programs $node_program; do
    prelude=/dev/null
    loader="$loader_command"
    case "$program" in
      devnet) prelude="$DEVNET_PRELUDE" ;;
      "$node_program") loader="$node_loader_command" ;;
    esac
    sed -e '/# @PRELUDE@/{' -e "r $prelude" -e 'd' -e '}' "$LAUNCHER" \
      | sed \
        -e "s|@PROGRAM@|$program|g" \
        -e "s|@VERSION@|$BUNDLE_VERSION|g" \
        -e "s|@COMMIT@|$BUNDLE_COMMIT|g" \
        -e "s|@LOADER@|$loader|g" \
        >"$bundle/bin/$program"
    chmod +x "$bundle/bin/$program"
  done
  printf '%s\n' "$BUNDLE_VERSION" >"$bundle/VERSION"
  printf '%s\n' "$BUNDLE_COMMIT" >"$bundle/COMMIT"
}

# $out/<name>.tar.gz, identical bytes for identical contents.
write_tarball() {
  mkdir -p "$out"
  tar --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner \
    -cf - -C "$work" "$BUNDLE_NAME" | gzip -n >"$out/$BUNDLE_NAME.tar.gz"
  ls -l "$out"
}
