# The relocatable release bundle of `singular`, `open-datum` and the
# development node for one platform: a tarball whose top directory holds
# launchers in bin/, the real executables in libexec/, every non-system
# library in lib/ (the registry's programs) and lib-node/ (cardano-node, built
# against other libraries), and in share/ the packaged data, the node's genesis
# files and the deployment blueprint with the release number beside it. The
# assembly scripts live beside this file; the workflows only build this output,
# run the smoke script on it and publish it.
{
  pkgs,
  version,
  commit,
  singular,
  openDatum,
  # the development node launcher, unwrapped, and the cardano-node it starts
  devnet,
  cardanoNode,
  # the directory of genesis files, keys and settings the node starts from
  devnetGenesis,
  # the deployment blueprint (plutus.json) the release ships, the same for every
  # platform: share/plutus.json, with the release number in share/version.txt
  blueprint,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;
  name = "singular-${version}-${system}";
  tools =
    with pkgs;
    [
      coreutils
      diffutils
      findutils
      gawk
      gnugrep
      gnused
      gnutar
      gzip
    ]
    ++ (
      if pkgs.stdenv.isDarwin then
        [
          pkgs.darwin.cctools
          pkgs.darwin.sigtool
        ]
      else
        [ pkgs.patchelf ]
    );
in
pkgs.runCommand "${name}-bundle"
  (
    {
      nativeBuildInputs = tools;
      BUNDLE_NAME = name;
      BUNDLE_VERSION = version;
      BUNDLE_COMMIT = commit;
      SINGULAR_PKG = singular;
      OPEN_DATUM_PKG = openDatum;
      DEVNET_PKG = devnet;
      CARDANO_NODE_PKG = cardanoNode;
      DEVNET_GENESIS = devnetGenesis;
      BLUEPRINT = blueprint;
      LAUNCHER = ./release-bundle/launcher.sh;
      DEVNET_PRELUDE = ./release-bundle/launcher-devnet.sh;
      COMMON = ./release-bundle/common.sh;
      passthru = {
        inherit name;
        tarball = "${name}.tar.gz";
      };
      meta.description = "Relocatable Singular executables and development node for ${system}";
      meta.platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
    }
    // pkgs.lib.optionalAttrs pkgs.stdenv.isDarwin {
      # nixpkgs' signing helper, and the allocator every Mach-O tool that touches
      # a signature spawns by name
      SIGNING_UTILS = pkgs.darwin.signingUtils;
      CODESIGN_ALLOCATE = "${pkgs.darwin.cctools}/bin/codesign_allocate";
    }
  )
  ''
    bash ${
      if pkgs.stdenv.isDarwin then
        ./release-bundle/assemble-darwin.sh
      else
        ./release-bundle/assemble-linux.sh
    }
  ''
