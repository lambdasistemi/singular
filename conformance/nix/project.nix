{ CHaP, pkgs, src, ... }:

let
  fix-libs = { lib, pkgs, ... }: {
    packages.cardano-crypto-praos.components.library.pkgconfig =
      lib.mkForce [ [ pkgs.libsodium-vrf ] ];
    packages.cardano-crypto-class.components.library.pkgconfig =
      lib.mkForce [[ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ]];
  };
  shell = { pkgs, ... }: {
    tools = {
      cabal = {};
      fourmolu = {};
      hlint = {};
    };
    buildInputs = [
      pkgs.aiken
      pkgs.just
      pkgs.lean4
      # Same D-009 pkg-config database as offchain/nix/project.nix:
      # cardano-lmdb needs lmdb, blockio-uring needs liburing.
      pkgs.lmdb
      pkgs.liburing
      pkgs.pkg-config
    ];
  };

  project = pkgs.haskell-nix.cabalProject' ({ lib, pkgs, ... }: {
    name = "singular-conformance";
    inherit src;
    compiler-nix-name = "ghc9123";
    shell = shell { inherit pkgs; };
    modules = [ fix-libs ];
    inputMap = { "https://chap.intersectmbo.org/" = CHaP; };
  });

in {
  devShells.default = project.shell;
  inherit project;
}
