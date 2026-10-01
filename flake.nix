{
  description = "Singular executable model, statement debt and documentation";
  inputs = {
    dev-assets-mkdocs.url = "github:paolino/dev-assets/34c7df6959c9fa36c6927808de6712b939e7a7fb?dir=mkdocs";
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
        in
        {
          demo1-cli-check = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-cli-check";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  gawk
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
                text = ''DEMO1_JOURNEY=${./tools/demo1_cli_journey.sh} DEMO1_CREATE_RACE=${./tools/demo1_cli_create_race.sh} bash ${./tools/demo1_cli_check.sh} "$PWD"'';
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
          # #325: the ordinary CLI's recovery controls — a lost
          # acknowledgement, a local commit interrupted before and after the
          # mirror is saved, a transaction never sent, and an accepting
          # control — judged from receipts and journals:
          # `nix run --quiet .#cli-recovery-controls`.
          cli-recovery-controls = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-recovery-controls";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  diffutils
                  findutils
                  jq
                  nix
                  # the controls find and stop their own development node
                  procps
                ];
                text = ''CLI_RECOVERY_CONTROLS=${./tools/cli_recovery_controls.sh} bash ${./tools/cli_recovery_controls_check.sh} "$PWD"'';
              }
            );
          };
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
        )
      );
      # #278 S2: the root development shell carries the pinned house
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
