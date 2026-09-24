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
        # singular-registry without editing offchain/: the build root
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
        # The naming blueprint (#157 D-BOOT)
        # -------------------------------------------------------
        # The four pins the eight-field boot datum carries are DERIVED,
        # never typed: the application policy is the naming application
        # script's own hash, and the three token policies are
        # `witness(kind, registry)` applied at kinds 0, 1 and 2. Both
        # need the naming partition's compiled code, so the harness
        # builds that partition's blueprint here and hands the runner its
        # store path — the same way it already hands it the devnet
        # genesis. No new flake input, so the copied lock still resolves.
        namingSrc = ../naming-onchain;

        aikenStdlib = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "stdlib";
          rev = "v2.2.0";
          hash = "sha256-BDaM+JdswlPasHsI03rLl4OR7u5HsbAd3/VFaoiDTh4=";
        };

        aikenFuzz = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "fuzz";
          rev = "v2.1.1";
          hash = "sha256-oMHBJ/rIPov/1vB9u608ofXQighRq7DLar+hGrOYqTw=";
        };

        aikenPackagesToml = pkgs.writeText "packages.toml" ''
          [[packages]]
          name = "aiken-lang/stdlib"
          version = "v2.2.0"
          source = "github"

          [[packages]]
          name = "aiken-lang/fuzz"
          version = "v2.1.1"
          source = "github"
        '';

        naming-blueprint = pkgs.stdenv.mkDerivation {
          pname = "singular-naming-plutus-blueprint";
          version = "0.1.0";
          src = pkgs.lib.cleanSource namingSrc;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            mkdir -p build/packages
            cp ${aikenPackagesToml} build/packages/packages.toml
            cp -r ${aikenStdlib} build/packages/aiken-lang-stdlib
            cp -r ${aikenFuzz} build/packages/aiken-lang-fuzz
            chmod -R u+w build/packages
            aiken build --trace-filter user-defined --trace-level verbose
          '';
          installPhase = ''
            cp plutus.json $out
          '';
        };

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
          # git rides the closure: the release boundary binds the tree via
          # git and is fail-closed on unknown identity. A missing git must
          # never stand in for honest debt.
          buildInputs = [ pkgs.makeWrapper pkgs.python3 pkgs.git ];
          meta = {
            mainProgram = "coverage-gate";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.python3}/bin/python3 $out/bin/coverage-gate \
            --prefix PYTHONPATH : ${coverageSrc}/conformance/coverage \
            --prefix PATH : ${pkgs.git}/bin \
            --add-flags "-m singular_coverage.gate"
        '';

        # Gate unit suite over the frozen snapshot, including every armed
        # failure control and the real-tree discovery/inventory assertions.
        # git rides along so the real-git candidate-binding controls run,
        # not skip, in this derivation.
        coverageGateTests = pkgs.runCommand "coverage-gate-tests" {
          buildInputs = [ pkgs.python3 pkgs.git ];
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

        # Compile the observation and its proof against this checkout's model.
        # The executable transports abstract IDs; Cardano bytes stay in Haskell.
        modelLock = builtins.fromJSON (builtins.readFile ../flake.lock);
        modelPkgs = import (builtins.fetchTree modelLock.nodes.nixpkgs.locked) {
          inherit system;
        };
        # The generic evaluator: the DSL's abstract scenario and the context
        # the caller established, through the model's own driver. Edge-agnostic
        # on purpose, so #223's connected retirement is the same call with a
        # setup trace rather than a second adapter.
        driverTransport = modelPkgs.runCommand "singular-driver-transport" {
          nativeBuildInputs = [ modelPkgs.lean4 modelPkgs.stdenv.cc ];
          meta.mainProgram = "driver-transport";
        } ''
          mkdir work
          cp -r ${../lean} work/lean
          cp ${../lakefile.toml} work/lakefile.toml
          chmod -R u+w work
          cp ${./lean/DriverTransport.lean} work/lean/DriverTransport.lean
          cat >> work/lakefile.toml <<'EOF'

          [[lean_exe]]
          name = "driver-transport"
          root = "DriverTransport"
          EOF
          cd work
          lake build driver-transport
          mkdir -p $out/bin
          cp .lake/build/bin/driver-transport $out/bin/
        '';

        # The row runner, wrapped so it brings the locked cardano-node
        # on its own PATH like the offchain journey runners, with the
        # devnet genesis defaulting to this suite's own copy
        # (E2E_GENESIS_DIR still overrides). The blueprint comes from the
        # caller at run time (REGISTRY_BLUEPRINT); no store path is baked
        # in.
        #
        # The copy differs from offchain/e2e-test/genesis in one field:
        # shelley epochLength, 500 slots raised to 20000. At 0.1s a slot
        # the original gives a two-epoch conversion horizon of a hundred
        # seconds, and a ten-row registry-mode session — which books an
        # approval and folds an edge per row, each its own transaction —
        # runs past it and cannot convert a deadline to a slot. Every
        # other file and parameter is byte-identical.
        conformance = pkgs.runCommand "conformance" {
          buildInputs = [ pkgs.makeWrapper ];
          meta = (components.exes.conformance.meta or { }) // {
            mainProgram = "conformance";
          };
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.conformance} $out/bin/conformance \
            --prefix PATH : ${cardanoNode}/bin \
            --set CONFORMANCE_DRIVER_CORPUS ${../lean/driver-corpus.json} \
            --set CONFORMANCE_MODEL_EVALUATOR ${pkgs.lib.getExe driverTransport} \
            --set-default E2E_GENESIS_DIR ${src}/conformance/genesis \
            --set-default NAMING_BLUEPRINT ${naming-blueprint}
        '';

        # A separate test binary owns the deliberately insufficient budget.
        # The public conformance executable never links its fixture module.
        foldBudgetRegression = pkgs.runCommand "fold-budget-regression" {
          buildInputs = [ pkgs.makeWrapper ];
          meta.mainProgram = "fold-budget-regression";
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.exes.fold-budget-regression} $out/bin/fold-budget-regression \
            --prefix PATH : ${cardanoNode}/bin \
            --set CONFORMANCE_DRIVER_CORPUS ${../lean/driver-corpus.json} \
            --set CONFORMANCE_MODEL_EVALUATOR ${pkgs.lib.getExe driverTransport} \
            --set-default E2E_GENESIS_DIR ${src}/conformance/genesis \
            --set-default NAMING_BLUEPRINT ${naming-blueprint}
        '';

        # The appendix suite compares against the committed driver corpus, so
        # the corpus travels with the binary rather than being copied into the
        # test tree where it could drift from the model.
        appendixTests = pkgs.runCommand "conformance-appendix-tests" {
          nativeBuildInputs = [ pkgs.makeWrapper ];
          meta.mainProgram = "conformance-tests";
        } ''
          mkdir -p $out/bin
          makeWrapper ${pkgs.lib.getExe components.tests.conformance-tests} $out/bin/conformance-tests \
            --set CONFORMANCE_DRIVER_CORPUS ${../lean/driver-corpus.json}
        '';

        # The public test command executes the book, including fresh devnet
        # transactions. The cheap evidence-checker suite remains available by
        # its explicit appendix name; it cannot generate the product book.
        runningBook = pkgs.writeShellApplication {
          name = "conformance-tests";
          runtimeInputs = [ pkgs.nix pkgs.git pkgs.coreutils ];
          text = ''
            book_args=()
            if [ "$#" -eq 2 ] && [ "$1" = "--book" ]; then
              book_args=(--output "$2")
            elif [ "$#" -ne 0 ]; then
              echo 'usage: conformance-tests [--book BOOK.md]' >&2
              echo 'For report-unit-test filters, use conformance-appendix-tests.' >&2
              exit 2
            fi
            if [ -z "''${REGISTRY_BLUEPRINT:-}" ]; then
              REGISTRY_BLUEPRINT="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
              export REGISTRY_BLUEPRINT
            fi
            if [ ! -r "$REGISTRY_BLUEPRINT" ]; then
              echo "Live story needs a readable validator blueprint: $REGISTRY_BLUEPRINT" >&2
              exit 1
            fi
            ${pkgs.lib.getExe appendixTests}
            echo 'Harness appendix: honest fold budget regression'
            budget_receipts="$(mktemp -d -t singular-budget-regression.XXXXXX)"
            ${pkgs.lib.getExe foldBudgetRegression} --receipts-dir "$budget_receipts"
            receipts="$(mktemp -d -t singular-running-book.XXXXXX)"
            ${pkgs.lib.getExe conformance} book --receipts-dir "$receipts" "''${book_args[@]}"
          '';
        };

      in
      {
        packages = {
          inherit conformance driverTransport foldBudgetRegression;
          # #157 D-BOOT: the naming partition's blueprint, so the four
          # pins are derived rather than typed.
          inherit naming-blueprint;
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
          fold-budget-regression = {
            type = "app";
            program = pkgs.lib.getExe foldBudgetRegression;
          };
          conformance = {
            type = "app";
            program = pkgs.lib.getExe conformance;
          };
          conformance-tests = {
            type = "app";
            program = pkgs.lib.getExe runningBook;
          };
          conformance-appendix-tests = {
            type = "app";
            program = pkgs.lib.getExe appendixTests;
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
