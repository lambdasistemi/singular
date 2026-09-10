{ CHaP, pkgs, ... }:

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
      # D-009: cabal's solver consults the pkg-config database inside this
      # shell. cardano-lmdb 0.4.0.3 needs pkg-config lmdb >=0.9 && <0.10;
      # without it the solver rejects 0.4.0.3, and GHC 9.12's base excludes
      # every older version, so solving fails before the node can start.
      pkgs.lmdb
      # D-009 (second addition, e2e-run-2.log): with lmdb visible the solver
      # advanced into ouroboros-consensus 1.0.0.0 → blockio → blockio-uring,
      # which needs pkg-config liburing >=2.0; absent, all three
      # blockio-uring versions were rejected and solving failed again.
      pkgs.liburing
      pkgs.pkg-config
    ];
  };

  project = pkgs.haskell-nix.cabalProject' ({ lib, pkgs, ... }: {
    name = "cardano-mpfs-cage";
    src = ./..;
    compiler-nix-name = "ghc9123";
    shell = shell { inherit pkgs; };
    modules = [ fix-libs ];
    inputMap = { "https://chap.intersectmbo.org/" = CHaP; };
  });

in {
  devShells.default = project.shell;
  inherit project;
}
