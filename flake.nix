{
  description = "Singular executable model, statement debt and documentation";
  inputs = {
    dev-assets-mkdocs.url = "github:paolino/dev-assets/a9d7371c1118de4026ba6ee3a9c3b54614924b82?dir=mkdocs";
    dev-assets-playwright.url = "github:paolino/dev-assets/a8f2ff7603bc793794d3e4459b2d5510a57e72a2?dir=playwright";
    # This repository's own off-chain tree, as a relative in-tree input: the
    # generated API reference's Haddock build and its manifest source digests
    # come from exactly this source. Its dependencies keep their own locked
    # revisions (no follows rebinding), and offchain/flake.lock stays as is.
    offchain.url = "path:./offchain";
    # The Conformance tree the same way, as a relative path input that keeps
    # the whole repository as the flake's source (dir=conformance): the
    # Conformance build root synthesizes from sibling trees (offchain, lean,
    # tools), so a bare subdirectory input could not evaluate, and the flake's
    # outPath is the conformance directory itself. Its generated library
    # reference binds to this candidate's own source, with its dependencies
    # keeping their own locked revisions and conformance/flake.lock staying as
    # is. The Conformance flake's inputs are declared verbatim from the
    # off-chain flake's, so the lock node shares the already-locked revisions
    # those declarations resolve to — no new upstream input is fetched or
    # created.
    conformance.url = "path:./?dir=conformance";
    # The on-chain Aiken project the same way: its flake pins the Aiken
    # compiler, and the site publishes the reference that compiler's
    # `aiken docs` generates from this candidate's validators. Its
    # dependencies keep their own locked revisions.
    onchain.url = "path:./onchain";
    nixpkgs.follows = "dev-assets-mkdocs/nixpkgs";
  };
  outputs =
    {
      self,
      nixpkgs,
      dev-assets-mkdocs,
      dev-assets-playwright,
      offchain,
      conformance,
      onchain,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      each = nixpkgs.lib.genAttrs systems;
      project =
        system:
        import ./nix/docs.nix {
          pkgs = import nixpkgs { inherit system; };
          src = self;
          sharedShell = dev-assets-mkdocs.devShells.${system}.default;
          sharedSource = dev-assets-mkdocs;
          mermaidJs = dev-assets-mkdocs.packages.${system}.mermaid-js;
          inherit offchain conformance onchain;
        };
      model =
        system:
        import ./nix/model.nix {
          pkgs = import nixpkgs { inherit system; };
          src = self;
        };
      coverage =
        system:
        import ./nix/coverage.nix {
          pkgs = import nixpkgs { inherit system; };
          src = self;
        };
      inventory =
        system:
        import ./nix/inventory.nix {
          pkgs = import nixpkgs { inherit system; };
          src = self;
        };
      simulator =
        system:
        import ./nix/simulator.nix {
          pkgs = import nixpkgs { inherit system; };
          src = self;
        };
      browser =
        system:
        import ./nix/browser.nix {
          pkgs = import nixpkgs { inherit system; };
          browserPkgs = import dev-assets-playwright.inputs.nixpkgs { inherit system; };
          src = self;
        };
      packages = system: {
        default = (project system).docs;
        inherit (project system) docs;
        docs-release = (project system).releaseArchive;
        model = (model system).package;
      };
      buildGate =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          # Build artifacts only; checks and check-running apps stay separate.
        in
        pkgs.linkFarm "singular-build-gate" (
          pkgs.lib.mapAttrsToList (name: path: {
            name = "package-${name}";
            inherit path;
          }) (packages system)
        );
      # #299: the Demo 1 journey from the extracted release archive, run as
      # separate `singular` processes on one development node, plus the
      # retained insert-active and update-terminal archive controls. Run
      # from the repository root: `nix run --quiet .#demo1-cli-check`.
      demo1 =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          # #449: the recovery controls as one app per part, each on its own
          # development node, so CI runs the parts as parallel jobs. An empty
          # part list runs them all.
          # #300/#449: the demonstration's four refusals on one existing
          # registry; an empty part list runs every part.
          attachApp = name: parts: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name;
                runtimeInputs = with pkgs; [
                  bash
                  python3
                  curl
                  xxd
                  coreutils
                  diffutils
                  findutils
                  git
                  gnugrep
                  gnused
                  gnutar
                  gzip
                  jq
                  procps
                  nix
                ];
                text = ''CLI_ATTACH_PARTS="${parts}" bash ${./tools/demo1_cli_attach_check.sh} "$PWD"'';
              }
            );
          };
          recoveryApp = name: parts: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name;
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  diffutils
                  findutils
                  jq
                  nix
                  # the controls find and stop their own development node
                  procps
                  # read-root.py and the CBOR reader; without it the check
                  # script falls back to nix develop
                  python3
                ];
                text = ''CLI_RECOVERY_PARTS="${parts}" CLI_RECOVERY_CONTROLS=${./tools/cli_recovery_controls.sh} bash ${./tools/cli_recovery_controls_check.sh} "$PWD"'';
              }
            );
          };
          flagsTools = with pkgs; [
            bash
            coreutils
            diffutils
            findutils
            gawk
            gnugrep
            gnused
            nix
          ];
          # #326: verify a published release from its downloaded bytes —
          # sums, the stated model revision against the one the
          # conformance evidence is compiled against, archive members, and
          # the Demo 1 journey built from the archive's own flake:
          # `nix run .#verify-release -- vX.Y.Z`.
          verifyRelease = pkgs.writeShellApplication {
            name = "verify-release";
            runtimeInputs = with pkgs; [
              bash
              coreutils
              curl
              diffutils
              findutils
              gawk
              git
              gnugrep
              gnused
              gnutar
              gzip
              jq
              nix
              # the journey's concurrent-writer control holds the
              # registry's lock with flock, and it finds and stops
              # its own development node with pgrep and pkill
              procps
              util-linux
            ];
            text = ''
              export VERIFY_RELEASE_JOURNEY=${./tools/demo1_cli_journey.sh}
              export DEMO1_CREATE_RACE=${./tools/demo1_cli_create_race.sh}
              export VERIFY_RELEASE_MODEL_REVISION=${./conformance/model-revision}
              bash ${./tools/verify_release.sh} "$@"
            '';
          };
        in
        {
          verify-release = {
            type = "app";
            program = pkgs.lib.getExe verifyRelease;
          };
          # #326: every refusal of verify-release by name — the published
          # v0.7.0 and mutated copies of an assembled release:
          # `nix run .#verify-release-controls -- RELEASE-DIR`.
          verify-release-controls = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "verify-release-controls";
                runtimeInputs = with pkgs; [
                  coreutils
                  findutils
                  gnugrep
                  gnused
                  gnutar
                  gzip
                ];
                text = ''VERIFY_RELEASE=${pkgs.lib.getExe verifyRelease} bash ${./tools/verify_release_controls.sh} "$@"'';
              }
            );
          };
          demo1-cli-check = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-cli-check";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  gnugrep
                  gnused
                  jq
                  nix
                ];
                text = ''DEMO1_VERIFY_RELEASE=${pkgs.lib.getExe verifyRelease} bash ${./tools/demo1_cli_check.sh} "$PWD"'';
              }
            );
          };
          # #299: the ordinary CLI's refusal controls, judged from their
          # receipts: `nix run --quiet .#demo1-cli-controls`.
          demo1-cli-controls = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-cli-controls";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  findutils
                  gnugrep
                  jq
                  procps
                  nix
                ];
                text = ''DEMO1_CONTROLS=${./tools/demo1_cli_controls.sh} bash ${./tools/demo1_cli_controls_check.sh} "$PWD"'';
              }
            );
          };
          # #300: the demonstration's four refusals on one existing registry and
          # two fresh keys: `nix run --quiet .#demo1-cli-attach`.
          demo1-cli-attach = attachApp "demo1-cli-attach" "";
          # #449: one app per part, each with its own registry and node, so CI
          # runs the parts as parallel jobs.
          demo1-cli-attach-takes = attachApp "demo1-cli-attach-takes" "takes";
          demo1-cli-attach-indexer-reads = attachApp "demo1-cli-attach-indexer-reads" "indexer-reads";
          demo1-cli-attach-tampered-a = attachApp "demo1-cli-attach-tampered-a" "tampered-a";
          demo1-cli-attach-tampered-b = attachApp "demo1-cli-attach-tampered-b" "tampered-b";
          demo1-cli-attach-over-allowance = attachApp "demo1-cli-attach-over-allowance" "over-allowance";
          # #300: the public-indexer readback against a local indexer that answers
          # with the shapes the public services return:
          # `nix run --quiet .#demo1-readback-check`.
          demo1-readback-check = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-readback-check";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  curl
                  gnugrep
                  jq
                  python3
                  xxd
                ];
                text = ''bash ${./tools/demo1_readback_check.sh} ${./tools/demo1_readback.sh}'';
              }
            );
          };
          # #326: the flags documented for `singular` equal what its --help
          # prints, pair by pair: `nix run --quiet .#cli-flags-check`.
          cli-flags-check = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-flags-check";
                runtimeInputs = flagsTools;
                text = ''bash ${./tools/cli_flags_check.sh} "$PWD"'';
              }
            );
          };
          # Its controls: `nix run --quiet .#cli-flags-controls`.
          cli-flags-controls = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-flags-controls";
                runtimeInputs = flagsTools;
                text = ''bash ${./tools/cli_flags_controls.sh} "$PWD"'';
              }
            );
          };
          # #325: the ordinary CLI's recovery controls — a lost
          # acknowledgement, a local commit interrupted before and after the
          # mirror is saved, a transaction never sent, and an accepting
          # control — judged from receipts and journals:
          # `nix run --quiet .#cli-recovery-controls`.
          cli-recovery-controls = recoveryApp "cli-recovery-controls" "";
          # #449: the parts seen passing on main since #411, one CI job each.
          cli-recovery-accepting = recoveryApp "cli-recovery-accepting" "accepting";
          cli-recovery-lost-answer = recoveryApp "cli-recovery-lost-answer" "lost-answer";
          cli-recovery-killed = recoveryApp "cli-recovery-killed" "accepting killed";
        };
    in
    {
      packages = each (system: packages system // { build-gate = buildGate system; });
      checks = each (system: {
        docs = (project system).check;
        release = (project system).releaseCheck;
        model = (model system).check;
        simulator = (simulator system).check;
        browser = (browser system).check;
        coverage = (coverage system).check;
        inventory = (inventory system).check;
      });
      apps = each (
        system:
        (
          (project system).apps
          // (model system).apps
          // (simulator system).apps
          // (browser system).apps
          // (coverage system).apps
          // (inventory system).apps
          // (demo1 system)
          // (import ./nix/ci-apps.nix {
            pkgs = import nixpkgs { inherit system; };
            inherit offchain onchain system;
          })
        )
      );
      # #278 terminal-attestation-permanent: the root development shell carries the pinned house
      # formatter — the exact Fourmolu the off-chain lock resolves, exposed
      # by the offchain flake — so `just format`, `just format-check` and
      # `just format-controls` (all inside `just ci`) run the one pinned
      # binary the lint checks run. No second version source.
      # #278: it also carries the pinned lint and format tools `just lint`
      # runs over every other code family (tools/lint_code.py).
      devShells = each (system: {
        default = (project system).shell.overrideAttrs (
          old:
          (browser system).environment
          // {
            nativeBuildInputs =
              (old.nativeBuildInputs or [ ])
              ++ [ offchain.packages.${system}.fourmolu ]
              ++ (with import nixpkgs { inherit system; }; [
                lean4
                nodejs
                nixfmt
                statix
                deadnix
                ruff
                shellcheck
                shfmt
                biome
                actionlint
                yamlfmt
              ]);
          }
        );
      });
    };
}
