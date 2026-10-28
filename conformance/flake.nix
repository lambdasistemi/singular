{
  description = "Singular consumer comparison evidence reader";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
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
      url = "github:input-output-hk/iohk-nix/0ce7cc21b9a4cfde41871ef486d01a8fafbf9627";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages/8479db771a3186eb326e42d8480eddc20a208275";
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
        # singular-registry and the open-datum application without editing
        # offchain/ or applications/: the build root carries all packages,
        # and the merged cabal.project is
        # derived from offchain's own at build time so it cannot
        # drift from it (no hand-copied index-state or pins).
        offchainSrc = ../offchain;
        openDatumSrc = ../applications/open-datum/offchain;
        src = pkgs.runCommand "conformance-src" { } ''
          mkdir -p $out
          cp -r ${offchainSrc}/. $out/offchain
          cp -r ${./.}/. $out/conformance
          mkdir -p $out/applications/open-datum
          cp -r ${openDatumSrc}/. $out/applications/open-datum/offchain
          # derive the merged cabal.project from offchain's own, so it cannot drift
          sed 's|^  \.$|  offchain\n  conformance\n  applications/open-datum/offchain|' ${offchainSrc}/cabal.project > $out/cabal.project
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

        coverageGate =
          pkgs.runCommand "coverage-gate"
            {
              # git rides the closure: the release boundary binds the tree via
              # git and is fail-closed on unknown identity. A missing git must
              # never stand in for honest debt.
              buildInputs = [
                pkgs.makeWrapper
                pkgs.python3
                pkgs.git
              ];
              meta = {
                mainProgram = "coverage-gate";
              };
            }
            ''
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
        coverageGateTests =
          pkgs.runCommand "coverage-gate-tests"
            {
              buildInputs = [
                pkgs.python3
                pkgs.git
              ];
            }
            ''
              cd ${coverageSrc}/conformance/coverage
              PYTHONPATH=$PWD ${pkgs.python3}/bin/python3 -m unittest discover -s tests
              touch $out
            '';

        # The gate's own verdicts against the same frozen snapshot: inventory
        # reconciles, ratchet passes, completion honestly refuses.
        coverageGateSnapshot =
          pkgs.runCommand "coverage-gate-snapshot"
            {
              buildInputs = [ pkgs.python3 ];
            }
            ''
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

        inherit (project.project.hsPkgs.conformance) components;

        inherit (components.exes) conformance;
        appendixTests = components.tests.conformance-tests;

        # #278 terminal-attestation-permanent: the pinned house formatter, extracted from this tree's
        # locked dev-shell tool set — the same Fourmolu version the
        # off-chain lint resolves (the two locks are byte-identical), so
        # the two format checks cannot drift. Fail-closed on anything but
        # exactly one Fourmolu tool in the shell.
        shellTool =
          pattern:
          let
            matches = builtins.filter (
              p: builtins.match pattern (p.name or "") != null
            ) project.project.shell.nativeBuildInputs;
          in
          assert builtins.length matches == 1;
          builtins.head matches;
        fourmoluTool = shellTool "fourmolu-exe-fourmolu-.*";
        # #278 supply-matches-leaf-state: HLint from the same locked dev-shell tool set, so the
        # Conformance lint resolves the HLint the off-chain lint runs.
        hlintTool = shellTool "hlint-exe-hlint-.*";

        # #278 terminal-attestation-permanent: the Conformance Haskell format check. Discovery mirrors
        # the off-chain lint: every hs-source-dirs the Cabal manifests
        # declare (conformance.cabal and the #80 evaluation spike's
        # spike.cabal), visited recursively, so a new component or source
        # directory is covered with no list to edit; empty discovery or a
        # missing declared directory fails closed. The house configuration
        # is the committed fourmolu.yaml at the repository root, passed
        # explicitly so a missing configuration fails loudly instead of
        # silently falling back to Fourmolu defaults. Like the off-chain
        # lint, the check runs over the FLAKE SOURCE (a store copy), so
        # the bytes it checks are candidate-bound; the root `just
        # format-check` carries the whole-tree checkout-context carrier.
        # The Conformance Haskell extent, shared by the format and lint
        # checks so the two cannot visit different files.
        haskellDiscovery = ''
          cd "${src}/conformance"
          conf_dirs=$(
            awk '/^[ \t]*hs-source-dirs:/ {
              sub(/^[ \t]*hs-source-dirs:[ \t]*/, "")
              for (i = 1; i <= NF; i++) print $i
            }' conformance.cabal
          ) || { echo "format-check: source discovery failed: cannot read conformance.cabal (awk exit $?)" >&2; exit 1; }
          [ -n "$conf_dirs" ] || { echo "format-check: source discovery found no hs-source-dirs in conformance.cabal" >&2; exit 1; }
          spike_dirs=$(
            awk '/^[ \t]*hs-source-dirs:/ {
              sub(/^[ \t]*hs-source-dirs:[ \t]*/, "")
              for (i = 1; i <= NF; i++) print "coverage/evaluation/" $i
            }' coverage/evaluation/spike.cabal
          ) || { echo "format-check: source discovery failed: cannot read coverage/evaluation/spike.cabal (awk exit $?)" >&2; exit 1; }
          [ -n "$spike_dirs" ] || { echo "format-check: source discovery found no hs-source-dirs in coverage/evaluation/spike.cabal" >&2; exit 1; }
          dirs=$(printf '%s\n%s\n' "$conf_dirs" "$spike_dirs" | sort -u)
          [ -n "$dirs" ] || { echo "format-check: discovered no source directories" >&2; exit 1; }
          for d in $dirs; do
            [ -d "$d" ] || { echo "format-check: declared source directory missing: $d" >&2; exit 1; }
          done
          files=$(find $dirs -name '*.hs' | sort -u)
          [ -n "$files" ] || { echo "format-check: no Haskell sources in the discovered extent" >&2; exit 1; }
          echo "conformance haskell extent: $(printf '%s\n' $files | wc -l) Haskell sources over $(printf '%s\n' $dirs | wc -l) dirs, house fourmolu.yaml, no exclusions" >&2
        '';

        formatCheck = pkgs.writeShellApplication {
          name = "format-check";
          runtimeInputs = [
            fourmoluTool
            pkgs.coreutils
            pkgs.gawk
            pkgs.findutils
          ];
          excludeShellChecks = [
            "SC2046"
            "SC2086"
          ];
          text = ''
            ${haskellDiscovery}
            # The GHC option matches the off-chain lint invocation so the
            # two checks share one formatter dialect.
            fourmolu --config ${../fourmolu.yaml} --ghc-opt=-XImportQualifiedPost -m check $files
          '';
        };

        # #278 supply-matches-leaf-state: HLint over exactly the extent the format check visits
        # (the Conformance Cabal stanzas plus the #80 evaluation spike),
        # discovered at check time, with no exclusions and no ignore file.
        hlintCheck = pkgs.writeShellApplication {
          name = "hlint-check";
          runtimeInputs = [
            hlintTool
            pkgs.coreutils
            pkgs.gawk
            pkgs.findutils
          ];
          excludeShellChecks = [
            "SC2046"
            "SC2086"
          ];
          text = ''
            ${haskellDiscovery}
            hlint $files
          '';
        };

        hlintCheckRun = pkgs.runCommand "singular-conformance-hlint-check" { } ''
          ${pkgs.lib.getExe hlintCheck}
          touch "$out"
        '';

        # #278 terminal-attestation-permanent, audit F003: the flake check EXECUTES the same app over
        # the flake source it was built from — `nix build`/`nix flake
        # check` on this attribute runs Fourmolu over the store copy, it
        # does not merely build and shellcheck a wrapper. The app stays
        # the single carrier (same binary CI runs); no divergent inline
        # logic, strict runtime closure preserved.
        formatCheckRun = pkgs.runCommand "singular-conformance-format-check" { } ''
          ${pkgs.lib.getExe formatCheck}
          touch "$out"
        '';

        # #562 item 2: the pinned cabal the conformance shell carries, so
        # the evaluation cleanup wrapper runs under the pinned toolchain
        # without entering a dev shell. Fail-closed on anything but one
        # match (the same extraction the offchain build-graph wrappers
        # use).
        evaluationCabal =
          let
            matches = builtins.filter (
              p: builtins.match "cabal-install-exe-cabal-.*" (p.name or "") != null
            ) project.project.shell.nativeBuildInputs;
          in
          assert builtins.length matches == 1;
          builtins.head matches;

        # #562 item 4 (slice S1): the evaluation cleanup-control suite as a
        # conformance flake app. The suite (four cases over the factored
        # cleanup predicate) is a plain cabal test-suite pinned to its own
        # tasty-bdd source package, so it runs under the pinned cabal and
        # GHC this flake's shell already resolves — without entering a dev
        # shell. The wrapper owns its state: the evaluation tree is copied
        # to a scratch directory the wrapper creates and removes on every
        # exit (cabal's dist-newstyle build state lives inside that copy,
        # never in the checkout), and the cabal download cache (Hackage
        # index plus the pinned tasty-bdd fetch) lives under a named
        # directory the wrapper creates under XDG_CACHE_HOME (or HOME),
        # reusable across runs like the runner's Nix cache — a cache, not
        # build state. Every acquisition and population step (scratch
        # creation, tree copy, cache directory) maps its failure to exit 2
        # with its diagnostic, never a verdict; cabal's own exit stays the
        # verdict. No process is started or stopped.
        evaluationCleanupControls = pkgs.writeShellApplication {
          name = "evaluation-cleanup-controls";
          runtimeInputs = [
            evaluationCabal
            project.project.pkg-set.config.ghc.package
            pkgs.bash
            pkgs.coreutils
            pkgs.git
          ];
          text = ''
            if ! work="$(mktemp -d)"; then
              echo "evaluation-cleanup-controls: setup failed creating the scratch directory (TMPDIR=''${TMPDIR:-unset})" >&2
              exit 2
            fi
            trap 'rm -rf "$work"' EXIT
            src="$PWD/conformance/coverage/evaluation"
            [ -d "$src" ] || {
              echo "evaluation-cleanup-controls: no conformance/coverage/evaluation under $PWD (run from the repository root)" >&2
              exit 2
            }
            if ! cp -a "$src" "$work/evaluation"; then
              echo "evaluation-cleanup-controls: setup failed copying the evaluation tree to scratch" >&2
              exit 2
            fi
            cache_root="''${XDG_CACHE_HOME:-''${HOME:+$HOME/.cache}}"
            [ -n "''${cache_root:-}" ] || {
              echo "evaluation-cleanup-controls: no cache location: set XDG_CACHE_HOME or HOME" >&2
              exit 2
            }
            if ! mkdir -p "$cache_root/singular-evaluation-cleanup-cabal"; then
              echo "evaluation-cleanup-controls: setup failed creating the cabal download cache directory" >&2
              exit 2
            fi
            export CABAL_DIR="$cache_root/singular-evaluation-cleanup-cabal"
            # Acquisition: the Hackage package index (the pinned tasty-bdd
            # fetch rides the same cache). A missing or failed update is
            # setup failure, never a verdict; on a warm cache it is a fast
            # incremental check.
            if ! cabal update; then
              echo "evaluation-cleanup-controls: setup failed updating the Hackage package index" >&2
              exit 2
            fi
            cd "$work/evaluation"
            cabal test cleanup-control
          '';
        };

      in
      {
        packages = {
          inherit conformance;
          # Generated Haddock reference for the Conformance library, consumed
          # by the root documentation build. Same source tree, same lock: the
          # docs manifest can bind the reference to this candidate's content.
          # The flag pair follows the off-chain reference's proven recipe:
          # --internal hands the library's package-internal modules (the
          # asset-evidence owner) to Haddock, and --haddock-option=--show-all
          # cancels the hide attribute so every module of the library extent
          # gets both a module page and a hyperlinked source page. The flags
          # are scoped to this documentation output alone, through a project
          # that only appends them as an extra package module: every other
          # build output keeps the untouched closure.
          library-haddock =
            (project.project.appendModule {
              modules = [
                {
                  packages.conformance.setupHaddockFlags = [
                    "--internal"
                    "--haddock-option=--show-all"
                  ];
                }
              ];
            }).hsPkgs.conformance.components.library.haddock;
          # Theorem-coverage gate (issue #80): app + its two verification
          # derivations, buildable without touching the Haskell graph.
          inherit coverageGate coverageGateTests coverageGateSnapshot;
        };

        checks = {
          format-check = formatCheckRun;
          hlint-check = hlintCheckRun;
          conformance-exe = components.exes.conformance;
          conformance-tests =
            pkgs.runCommand "conformance-appendix-tests-check"
              {
                nativeBuildInputs = [ pkgs.glibcLocales ];
                LANG = "C.UTF-8";
                LC_ALL = "C.UTF-8";
              }
              ''
                # The unit suite reads both packaged fixtures and the bound
                # repository statements/specification beside conformance/.
                cd ${../.}/conformance
                ${pkgs.lib.getExe appendixTests} > "$out" 2>&1 || { cat "$out"; exit 1; }
              '';
          coverage-gate-tests = coverageGateTests;
          coverage-gate-snapshot = coverageGateSnapshot;
        };

        apps = {
          format-check = {
            type = "app";
            meta.description = "Check Conformance Haskell formatting";
            program = pkgs.lib.getExe formatCheck;
          };
          hlint-check = {
            type = "app";
            meta.description = "Lint Conformance Haskell sources";
            program = pkgs.lib.getExe hlintCheck;
          };
          conformance = {
            type = "app";
            meta.description = "Run the conformance suite";
            program = pkgs.lib.getExe conformance;
          };
          conformance-appendix-tests = {
            type = "app";
            meta.description = "Run conformance harness appendix tests";
            program = pkgs.lib.getExe appendixTests;
          };
          coverage-gate = {
            type = "app";
            meta.description = "Run the theorem coverage gate";
            program = "${coverageGate}/bin/coverage-gate";
          };
          # #562 item 4 (slice S1): the evaluation cleanup-control suite,
          # `cabal test cleanup-control` of conformance/coverage/evaluation
          # under the pinned toolchain, scratch owned.
          evaluation-cleanup-controls = {
            type = "app";
            meta.description = "Run evaluation cleanup controls";
            program = pkgs.lib.getExe evaluationCleanupControls;
          };
        };

        devShells = {
          inherit (project.devShells) default;
        };
      }
    );
}
