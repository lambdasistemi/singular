{
  description = "MPFS off-chain — Haskell cage package";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  inputs = {
    hackageNix = {
      url = "github:input-output-hk/hackage.nix";
      flake = false;
    };
    haskellNix = {
      url = "github:input-output-hk/haskell.nix/04f3b8ad4063be341cb773e79c3ff3d88f2cb6d7";
      inputs.hackage.follows = "hackageNix";
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    iohkNix = {
      url =
        "github:input-output-hk/iohk-nix/0ce7cc21b9a4cfde41871ef486d01a8fafbf9627";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url =
        "github:intersectmbo/cardano-haskell-packages/8479db771a3186eb326e42d8480eddc20a208275";
      flake = false;
    };
    # Pinned cardano-node, used as a subprocess by the devnet E2E
    # tests. Version tracks the upstream cardano-node-clients
    # devnet Dockerfile.
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      haskellNix,
      iohkNix,
      CHaP,
      cardano-node,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          overlays = [
            iohkNix.overlays.crypto
            haskellNix.overlay
            iohkNix.overlays.haskell-nix-crypto
            iohkNix.overlays.cardano-lib
          ];
          inherit system;
        };

        # -------------------------------------------------------
        # Haskell build (cage package)
        # -------------------------------------------------------

        project = import ./nix/project.nix {
          inherit CHaP pkgs;
        };

        components =
          project.project.hsPkgs.cardano-mpfs-cage.components;

        cardanoNode =
          cardano-node.packages.${system}.cardano-node;

        haskellChecks = import ./nix/checks.nix {
          inherit pkgs components;
          shell = project.project.shell;
          inherit cardanoNode;
        };

        haskellApps = import ./nix/apps.nix {
          inherit pkgs;
          checks = haskellChecks;
        };

        # The bounded journey runner (D-012). A Nix-built binary —
        # haskell.nix resolves every dependency, so a clean runner
        # needs no cabal, no package index and no warm state (D-011)
        # — wrapped so it brings the locked cardano-node on its own
        # PATH, exactly like cage-tests-e2e in ./nix/checks.nix.
        # The blueprint and the identity manifest come from the
        # caller at run time (MPFS_BLUEPRINT, MPFS_SCRIPT_IDENTITY);
        # no store path is baked in.
        journey = pkgs.runCommand "journey" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.journey.meta or { }) // {
            mainProgram = "journey";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.journey} $out/bin/journey \
            --prefix PATH : ${cardanoNode}/bin
        '';

        # The LI01 canonical-initialization runner (issue #47),
        # wrapped the same way as journey: the locked cardano-node
        # on its own PATH, no store path baked in.
        li01 = pkgs.runCommand "li01" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.li01.meta or { }) // {
            mainProgram = "li01";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.li01} $out/bin/li01 \
            --prefix PATH : ${cardanoNode}/bin
        '';

        # The LM/LC maintenance and cancellation row runner (issue
        # #56), wrapped the same way as journey and li01: the locked
        # cardano-node on its own PATH, no store path baked in. The
        # naming-onchain blueprint comes from the caller at run time
        # (NAMING_BLUEPRINT).
        naming-rows = pkgs.runCommand "naming-rows" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.naming-rows.meta or { }) // {
            mainProgram = "naming-rows";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.naming-rows} $out/bin/naming-rows \
            --prefix PATH : ${cardanoNode}/bin
        '';

        # The LR recovery rows (issue #62), wrapped the same way as
        # journey, li01 and naming-rows: the locked cardano-node on its
        # own PATH, no store path baked in. The naming-onchain blueprint
        # comes from the caller at run time (NAMING_BLUEPRINT).
        recovery-rows = pkgs.runCommand "recovery-rows" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.recovery-rows.meta or { }) // {
            mainProgram = "recovery-rows";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.recovery-rows} $out/bin/recovery-rows \
            --prefix PATH : ${cardanoNode}/bin
        '';

        # The LT retirement rows (issue #66), wrapped the same way as
        # recovery-rows: the locked cardano-node on its own PATH, no store
        # path baked in. The naming-onchain blueprint comes from the caller
        # at run time (NAMING_BLUEPRINT).
        retirement-rows = pkgs.runCommand "retirement-rows" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.retirement-rows.meta or { }) // {
            mainProgram = "retirement-rows";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.retirement-rows} $out/bin/retirement-rows \
            --prefix PATH : ${cardanoNode}/bin
        '';

        # The seven wrong canonical initialization refusals (issue
        # #50), wrapped the same way as journey, li01 and naming-rows:
        # the locked cardano-node on its own PATH, no store path baked
        # in. Both blueprints (the MPFS bootstrap and the naming
        # policies) come from the caller at run time (MPFS_BLUEPRINT,
        # NAMING_BLUEPRINT).
        li-refusals = pkgs.runCommand "li-refusals" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.li-refusals.meta or { }) // {
            mainProgram = "li-refusals";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.li-refusals} $out/bin/li-refusals \
            --prefix PATH : ${cardanoNode}/bin
        '';

        # -------------------------------------------------------
        # Test vectors (from local Haskell package)
        # -------------------------------------------------------

        test-vectors = pkgs.runCommand "cage-vectors.ak" { } ''
          ${pkgs.lib.getExe components.exes.cage-test-vectors} --aiken > $out
        '';

        test-vectors-json = pkgs.runCommand "cage-vectors.json" { } ''
          ${pkgs.lib.getExe components.exes.cage-test-vectors} > $out
        '';

      in
      {
        packages = {
          inherit test-vectors test-vectors-json;
          # Issue #56: the wrapped LM/LC row runner exposed as a package
          # too, so `nix build .#naming-rows` and `nix run .#naming-rows`
          # hit the same derivation. Issue #50: same for li-refusals.
          # Issue #62: same for recovery-rows.
          # Issue #66: same for retirement-rows.
          inherit naming-rows li-refusals recovery-rows retirement-rows;
          # Mechanical adapter (D-008): exposes the cardano-node already
          # locked as this flake's input, so the devnet recipe consumes the
          # locked identity instead of re-resolving a remote tag.
          cardano-node = cardano-node.packages.${system}.cardano-node;
        };

        # vectors-freshness was deleted from ./nix/checks.nix (break 5,
        # D-003): the golden lives in the onchain tree, outside this
        # flake root. The procedure lives in ./justfile (vectors-check).
        checks = haskellChecks;

        apps = haskellApps // {
          journey = {
            type = "app";
            program = pkgs.lib.getExe journey;
          };
          li01 = {
            type = "app";
            program = pkgs.lib.getExe li01;
          };
          naming-rows = {
            type = "app";
            program = pkgs.lib.getExe naming-rows;
          };
          recovery-rows = {
            type = "app";
            program = pkgs.lib.getExe recovery-rows;
          };
          retirement-rows = {
            type = "app";
            program = pkgs.lib.getExe retirement-rows;
          };
          li-refusals = {
            type = "app";
            program = pkgs.lib.getExe li-refusals;
          };
        };

        devShells = {
          default = project.devShells.default;
        };
      }
    );
}
