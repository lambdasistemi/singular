{
  description = "Singular consumer conformance (issue #63) — generic registry rows on a real devnet";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  # The inputs block is kept verbatim from ../offchain/flake.nix, and this
  # tree's flake.lock is a byte-for-byte copy of ../offchain/flake.lock —
  # never regenerated. The offchain sources enter as a plain path
  # reference below (offchainSrc), not as a flake input, so the copied
  # lock resolves without an added entry: the toolchain and every pinned
  # hash stay comparable with the tree this harness imports.
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
    # Pinned cardano-node, used as a subprocess by the devnet run. The
    # wrapper below puts it on the runner's PATH, exactly like the
    # journey/li-refusals wrappers in ../offchain/flake.nix.
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
        # Synthesized build root (issue #63)
        # -------------------------------------------------------
        # conformance/ is self-contained but imports
        # cardano-mpfs-cage without editing offchain/: the build root
        # carries both packages, and the merged cabal.project is
        # derived from offchain's own at build time so it cannot
        # drift from it (no hand-copied index-state or pins).
        offchainSrc = ../offchain;
        src = pkgs.runCommand "conformance-src" { } ''
          mkdir -p $out
          cp -r ${offchainSrc}/. $out/offchain
          cp -r ${./.}/. $out/conformance
          # derive the merged cabal.project from offchain's own, so it cannot drift
          sed 's|^  \.$|  offchain\n  conformance|' ${offchainSrc}/cabal.project > $out/cabal.project
        '';

        # -------------------------------------------------------
        # Coverage gate root (issue #80)
        # -------------------------------------------------------
        # Separate from `src` above so the coverage gate's inputs — the
        # frozen lean/ contract, tools/ (check_model.py) and the gate itself
        # — are hash-bound for the snapshot tests WITHOUT touching the
        # Haskell build graph: `nix build .#conformance` stays byte-identical.
        coverageSrc = pkgs.runCommand "coverage-src" { } ''
          mkdir -p $out/conformance
          cp -r ${../lean} $out/lean
          cp -r ${../tools} $out/tools
          cp -r ${./.}/coverage $out/conformance/coverage
        '';

        coverageGate = pkgs.runCommand "coverage-gate" {
          buildInputs = [ pkgs.makeWrapper pkgs.python3 ];
          meta = {
            mainProgram = "coverage-gate";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.python3}/bin/python3 $out/bin/coverage-gate \
            --prefix PYTHONPATH : ${coverageSrc}/conformance/coverage \
            --add-flags "-m singular_coverage.gate"
        '';

        # Gate unit suite over the frozen snapshot, including every armed
        # failure control and the real-tree discovery/inventory assertions.
        coverageGateTests = pkgs.runCommand "coverage-gate-tests" {
          buildInputs = [ pkgs.python3 ];
        } ''
          cd ${coverageSrc}/conformance/coverage
          PYTHONPATH=$PWD ${pkgs.python3}/bin/python3 -m unittest discover -s tests
          touch $out
        '';

        # The gate's own verdicts against the same frozen snapshot: inventory
        # reconciles, ratchet passes, completion honestly refuses.
        coverageGateSnapshot = pkgs.runCommand "coverage-gate-snapshot" {
          buildInputs = [ pkgs.python3 ];
        } ''
          export PYTHONPATH=${coverageSrc}/conformance/coverage
          ${pkgs.python3}/bin/python3 -m singular_coverage.gate \
            --root ${coverageSrc} inventory > /dev/null
          ${pkgs.python3}/bin/python3 -m singular_coverage.gate \
            --root ${coverageSrc} ratchet > /dev/null
          if ${pkgs.python3}/bin/python3 -m singular_coverage.gate \
              --root ${coverageSrc} completion > /dev/null 2>&1; then
            echo "coverage gate: completion unexpectedly passed a nonzero-debt snapshot"
            exit 1
          fi
          mkdir -p $out
        '';

        project = import ./nix/project.nix {
          inherit CHaP pkgs src;
        };

        components =
          project.project.hsPkgs.conformance.components;

        cardanoNode =
          cardano-node.packages.${system}.cardano-node;

        # The row runner, wrapped so it brings the locked cardano-node
        # on its own PATH like the offchain journey runners, with the
        # devnet genesis defaulting to the offchain sources carried in
        # the synthesized root (E2E_GENESIS_DIR still overrides). The
        # blueprint comes from the caller at run time
        # (MPFS_BLUEPRINT); no store path is baked in.
        conformance = pkgs.runCommand "conformance" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.conformance.meta or { }) // {
            mainProgram = "conformance";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.conformance} $out/bin/conformance \
            --prefix PATH : ${cardanoNode}/bin \
            --set-default E2E_GENESIS_DIR ${src}/offchain/e2e-test/genesis
        '';

      in
      {
        packages = {
          inherit conformance;
          # Mechanical adapter (D-008): exposes the cardano-node already
          # locked as this flake's input, so the devnet run consumes the
          # locked identity instead of re-resolving a remote tag.
          cardano-node = cardanoNode;
          # Theorem-coverage gate (issue #80): app + its two verification
          # derivations, buildable without touching the Haskell graph.
          inherit coverageGate coverageGateTests coverageGateSnapshot;
        };

        checks = {
          conformance-exe = components.exes.conformance;
          conformance-tests = components.tests.conformance-tests;
          coverage-gate-tests = coverageGateTests;
          coverage-gate-snapshot = coverageGateSnapshot;
        };

        apps = {
          conformance = {
            type = "app";
            program = pkgs.lib.getExe conformance;
          };
          conformance-tests = {
            type = "app";
            program =
              pkgs.lib.getExe components.tests.conformance-tests;
          };
          coverage-gate = {
            type = "app";
            program = "${coverageGate}/bin/coverage-gate";
          };
        };

        devShells = {
          default = project.devShells.default;
        };
      }
    );
}
