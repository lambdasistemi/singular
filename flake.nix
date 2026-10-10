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
      # #451 re-cut R1/R2: the recovery evidence collector and the pure case
      # census, as shared derivations exposed both as buildable packages and
      # as apps — one writeShellApplication each, every executable named in
      # runtimeInputs, so nothing depends on a runner's ambient PATH.
      recoveryTools =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          evidence = pkgs.writeShellApplication {
            name = "cli-recovery-cross-wallet-evidence";
            runtimeInputs = with pkgs; [
              bash
              coreutils
              findutils
              gawk
            ];
            text = ''
              # usage: cli-recovery-cross-wallet-evidence SOURCE OUTPUT SHA RUN PART
              # SOURCE is the exact captured run root; SHA/RUN/PART identify
              # that captured producer, never this collector's own candidate.
              [ "$#" -eq 5 ] || { echo "usage: cli-recovery-cross-wallet-evidence SOURCE OUTPUT SHA RUN PART" >&2; exit 2; }
              source="$1" out="$2" sha="$3" run="$4" part="$5"
              mkdir -p "$out/receipts" "$out/registry"
              manifest="$out/manifest.txt"
              note() { printf '%s\n' "$*" >>"$manifest"; }
              printf 'producer_sha=%s\nproducer_run=%s\nproducer_part=%s\n' "$sha" "$run" "$part" >"$manifest"
              if [ -d "$source/receipts" ]; then
                # Original records only: every receipt a real command printed;
                # the derived tampered copies the mutation predicates judge
                # stay out and are named by measured extent below.
                find "$source/receipts" -maxdepth 1 -type f \
                  ! -name '*-tampered.json' ! -name '*-red.out' ! -name '*-red.err' ! -name '*-red.exit' \
                  -exec cp -a {} "$out/receipts/" \;
                if [ -e "$source/registry/journal.jsonl" ]; then
                  cp -a "$source/registry/journal.jsonl" "$out/registry/"
                else
                  note "absent: registry/journal.jsonl"
                fi
                if [ -d "$source/registry/submissions" ]; then
                  cp -a "$source/registry/submissions" "$out/registry/"
                else
                  note "absent: registry/submissions"
                fi
                for item in verdicts.md fold-holds.list node-execution-time.json \
                  direct-processes.trie.jsonl trie-command-invocations; do
                  if [ -e "$source/$item" ]; then
                    cp -a "$source/$item" "$out/"
                  else
                    note "absent: $item"
                  fi
                done
                # The hold-coverage record is written under receipts/, where
                # the originals copy already retains it: expected and checked
                # at the path the harness writes, so an absent line means the
                # captured run genuinely produced none.
                if [ -e "$source/receipts/fold-hold-coverage.json" ]; then
                  note "present: receipts/fold-hold-coverage.json"
                else
                  note "absent: receipts/fold-hold-coverage.json"
                fi
                derived=$(find "$source/receipts" -maxdepth 1 -type f \
                  \( -name '*-tampered.json' -o -name '*-red.out' -o -name '*-red.err' -o -name '*-red.exit' \) \
                  -printf '%s\n' | awk '{n++; s+=$1} END {printf "%d files %d bytes", n, s}')
                snaps=""
                if [ -d "$source/snapshots" ]; then snaps=$(du -sb "$source/snapshots" | cut -f1); fi
                note "records: receipts=$(find "$out/receipts" -type f | wc -l)"
                note "excluded-by-measured-extent: derived mutation copies ($derived); snapshot copies (''${snaps:-absent} bytes); funding keys; node database"
                (
                  cd "$out"
                  find . -type f ! -name manifest.txt -print0 | sort -z | xargs -0r sha256sum
                ) >>"$manifest"
              else
                note "no receipts directory at the supplied source; nothing was collected"
              fi
            '';
          };
          parts = pkgs.writeShellApplication {
            name = "cli-recovery-cross-wallet-parts";
            runtimeInputs = with pkgs; [
              bash
              coreutils
              gnugrep
              gnused
              jq
            ];
            text = ''
              holds=$(grep -hoE 'harnessHoldAt[[:space:]]+"SINGULAR_HARNESS_HOLD_[A-Z_]+"' \
                ${./offchain/cli/src/Singular/CLI/Session.hs} ${./offchain/cli/src/Singular/CLI/Fold.hs} \
                | sed -E 's/.*"(SINGULAR_HARNESS_HOLD_[A-Z_]+)".*/\1/' | sort -u)
              [ -n "$holds" ] || { echo "the fold path declares no hold points" >&2; exit 3; }
              printf '%s\n' "$holds" | jq -Rsc --arg lost "cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer" \
                '{part: ((split("\n") | map(select(. != "") | "cross-wallet:" + .)) + [$lost])}'
            '';
          };
        };
      packages = system: {
        default = (project system).docs;
        inherit (project system) docs;
        docs-release = (project system).releaseArchive;
        model = (model system).package;
        # #451 re-cut R1: the collector as a buildable package; the app below
        # refers to this same writeShellApplication derivation.
        cli-recovery-cross-wallet-evidence = (recoveryTools system).evidence;
        # #381: the replay-fault control build — the packaged singular rebuilt
        # with the committed replay-fault patch applied at package level over
        # the existing source. Package level because the fault lives in the
        # registry library, which the executable links: patching the
        # executable derivation alone rebuilds it unpatched (proven by the
        # first control run refusing nothing). Reuses the offchain lock's own
        # inputs and project shape; adds no input, edits no offchain file.
        # Never the packaged product: the journey apps keep the unpatched
        # binary; only the replay-fault control app runs this one.
        singular-replay-fault =
          let
            pkgs = import offchain.inputs.nixpkgs {
              overlays = [
                offchain.inputs.iohkNix.overlays.crypto
                offchain.inputs.haskellNix.overlay
                offchain.inputs.iohkNix.overlays.haskell-nix-crypto
                offchain.inputs.iohkNix.overlays.cardano-lib
              ];
              inherit system;
            };
            patchedSrc = pkgs.applyPatches {
              src = ./offchain;
              patches = [ ./tools/replay-fault.patch ];
            };
            fix-libs =
              { lib, pkgs, ... }:
              {
                packages.cardano-crypto-praos.components.library.pkgconfig = lib.mkForce [ [ pkgs.libsodium-vrf ] ];
                packages.cardano-crypto-class.components.library.pkgconfig = lib.mkForce [
                  [
                    pkgs.libsodium-vrf
                    pkgs.secp256k1
                    pkgs.libblst
                  ]
                ];
              };
            faultProject = pkgs.haskell-nix.cabalProject' (_: {
              name = "singular-registry-replay-fault";
              src = patchedSrc;
              compiler-nix-name = "ghc9123";
              cabalProjectLocal = "packages: negative";
              modules = [ fix-libs ];
              inputMap = {
                "https://chap.intersectmbo.org/" = offchain.inputs.CHaP;
              };
            });
          in
          faultProject.hsPkgs.singular-registry.components.exes.singular;
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
          # Scripts sourcing managed_state.sh travel with it: a bare
          # ${./tools/<script>} copies one file, leaving the sourced
          # sibling behind, so every such entry point resolves from here.
          managedScripts = pkgs.runCommand "managed-scripts" { } ''
            mkdir -p $out
            cp ${./tools/cli_recovery_controls.sh} $out/cli_recovery_controls.sh
            cp ${./tools/managed_state.sh} $out/managed_state.sh
            cp ${./tools/demo1_cli_journey.sh} $out/demo1_cli_journey.sh
            cp ${./tools/demo1_cli_create_race.sh} $out/demo1_cli_create_race.sh
            cp ${./tools/cli_recovery_receipt_cap.test.sh} $out/cli_recovery_receipt_cap.test.sh
          '';
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
                text = ''
                  bash ${managedScripts}/cli_recovery_receipt_cap.test.sh ${managedScripts}/cli_recovery_controls.sh
                  CLI_RECOVERY_PARTS="${parts}" CLI_RECOVERY_CONTROLS=${managedScripts}/cli_recovery_controls.sh bash ${./tools/cli_recovery_controls_check.sh} "$PWD"
                '';
              }
            );
          };
          # #451 re-cut: the shared collector and census derivations, exposed
          # as apps; their buildable package forms live in packages.
          cliRecoveryEvidence = (recoveryTools system).evidence;
          cliRecoveryParts = (recoveryTools system).parts;
          # #451 re-cut R2: one source-discovered case per invocation, through
          # the same controls and checkwrapper; the controls refuse an unknown
          # token against the shared census before any node starts.
          cliRecoveryCrossPartApp = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-recovery-cross-wallet-part";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  diffutils
                  findutils
                  jq
                  nix
                  procps
                  python3
                ];
                text = ''
                  [ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: cli-recovery-cross-wallet-part PART" >&2; exit 2; }
                  bash ${managedScripts}/cli_recovery_receipt_cap.test.sh ${managedScripts}/cli_recovery_controls.sh
                  CLI_RECOVERY_PARTS="$1" CLI_RECOVERY_CONTROLS=${managedScripts}/cli_recovery_controls.sh bash ${./tools/cli_recovery_controls_check.sh} "$PWD"
                '';
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
              # the two-actor run traces every file access of the folding
              # process, so one under the booker's directory fails it
              strace
            ];
            text = ''
              export VERIFY_RELEASE_JOURNEY=${managedScripts}/demo1_cli_journey.sh
              export DEMO1_CREATE_RACE=${managedScripts}/demo1_cli_create_race.sh
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
                  # the check stops a node that outlives the journey
                  procps
                ];
                text = ''
                  env -u DEMO1_KEEP_SCRATCH bash ${./tools/demo1_scratch_removal.test.sh} \
                    ${./tools/demo1_two_actor_control.sh} \
                    ${./tools/demo1_cli_controls_check.sh} \
                    ${./tools/demo1_cli_check.sh} \
                    ${./tools/demo1_cli_attach_check.sh}
                  DEMO1_VERIFY_RELEASE=${pkgs.lib.getExe verifyRelease} bash ${./tools/demo1_cli_check.sh} "$PWD"
                '';
              }
            );
          };
          # #419: the two-actor access check shown failing a complete Demo 1
          # run — Bob's fold process opens Alice's journal and the run
          # must fail exactly there: `nix run --quiet .#demo1-two-actor-control`.
          demo1-two-actor-control = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-two-actor-control";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  gnugrep
                  gnused
                  jq
                  nix
                  # the packaged check stops a node that outlives the journey
                  procps
                ];
                text = ''
                  bash ${./tools/demo1_scratch_removal.test.sh} \
                    ${./tools/demo1_two_actor_control.sh} \
                    ${./tools/demo1_cli_controls_check.sh} \
                    ${./tools/demo1_cli_check.sh} \
                    ${./tools/demo1_cli_attach_check.sh}
                  bash ${./tools/demo1_two_actor_control.test.sh} ${./tools/demo1_two_actor_control.sh}
                  DEMO1_CLI_CHECK=${./tools/demo1_cli_check.sh} \
                    DEMO1_VERIFY_RELEASE=${pkgs.lib.getExe verifyRelease} \
                    bash ${./tools/demo1_two_actor_control.sh} "$PWD"
                '';
              }
            );
          };
          registry-two-actors = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "registry-two-actors";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.strace
                  pkgs.python3
                  # the stop path verifies no surviving node with pkill/pgrep
                  pkgs.procps
                ];
                text = ''
                  base="''${REGISTRY_JOURNEY_ROOT:-''${XDG_CACHE_HOME:-$HOME/.cache}/singular-two-actors}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/run.XXXXXX")/journey"
                  echo "two actors: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  # #381: the altered journey leg inspects with the control
                  # build; without it the leg is skipped and its row pending.
                  SINGULAR_REPLAY_FAULT=${pkgs.lib.getExe self.packages.${system}.singular-replay-fault} \
                    python3 ${./tools/registry_two_actors.py} \
                    ${pkgs.lib.getExe offchain.packages.${system}.singular} \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                    ${onchain.packages.${system}.plutus-blueprint} "$work"
                '';
              }
            );
          };
          # #381: the foreign-open access check over the two-actor journey —
          # one real booking with --state-dir at the other actor's state root
          # must fail at the guard: `nix run --quiet .#registry-two-actors-control`.
          registry-two-actors-control = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "registry-two-actors-control";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  gnugrep
                  procps
                  python3
                  strace
                ];
                text = ''
                  base="''${REGISTRY_JOURNEY_ROOT:-''${XDG_CACHE_HOME:-$HOME/.cache}/singular-two-actors}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/control.XXXXXX")"
                  echo "two-actor control: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  # #381: the shipped harness's status taxonomy needs no
                  # development network, so it runs before anything starts one.
                  python3 ${./tools/registry_two_actors_status.test.py} ${./tools/registry_two_actors.py}
                  bash ${./tools/registry_two_actors_control.test.sh} ${./tools/registry_two_actors_control.sh}
                  bash ${./tools/registry_two_actors_control.sh} "$work" \
                    python3 ${./tools/registry_two_actors.py} \
                    ${pkgs.lib.getExe offchain.packages.${system}.singular} \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                    ${onchain.packages.${system}.plutus-blueprint}
                '';
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
                  diffutils
                  findutils
                  gawk
                  gnugrep
                  jq
                  procps
                  nix
                ];
                text = ''
                  bash ${./tools/demo1_scratch_removal.test.sh} \
                    ${./tools/demo1_two_actor_control.sh} \
                    ${./tools/demo1_cli_controls_check.sh} \
                    ${./tools/demo1_cli_check.sh} \
                    ${./tools/demo1_cli_attach_check.sh}
                  bash ${./tools/demo1_cli_controls_ran.test.sh} ${./tools/demo1_cli_controls_ran.sh}
                  bash ${./tools/demo1_cli_controls_composition.test.sh} ${./tools/demo1_cli_controls_composition.sh}
                  DEMO1_CONTROLS=${./tools/demo1_cli_controls.sh} \
                    DEMO1_CONTROLS_RAN=${./tools/demo1_cli_controls_ran.sh} \
                    DEMO1_CONTROLS_COMPOSITION=${./tools/demo1_cli_controls_composition.sh} \
                    bash ${./tools/demo1_cli_controls_check.sh} "$PWD"
                '';
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
                text = "bash ${./tools/demo1_readback_check.sh} ${./tools/demo1_readback.sh}";
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
          # #451: the cross-wallet part alone, on its own starting state.
          cli-recovery-cross-wallet = recoveryApp "cli-recovery-cross-wallet" "cross-wallet";
          # #451 re-cut: the pure case census, one case per invocation, and
          # the portable collector — the hosted gate runs the census app, the
          # per-case matrix and the collector app per matrix job.
          cli-recovery-cross-wallet-parts = {
            type = "app";
            program = pkgs.lib.getExe cliRecoveryParts;
          };
          cli-recovery-cross-wallet-part = cliRecoveryCrossPartApp;
          cli-recovery-cross-wallet-evidence = {
            type = "app";
            program = pkgs.lib.getExe cliRecoveryEvidence;
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
          // (import ./nix/ci-apps.nix {
            pkgs = import nixpkgs { inherit system; };
            inherit offchain onchain system;
          })
          // {
            # #381: the replay-fault control — one genuine insertion booked
            # and folded, then a real actor inspect with the control build
            # whose replay maps one edge to another. The job passes only on
            # exit 0, which the harness returns only for RootDoesNotChain
            # naming the registry and the fold, with no root:
            # `nix run --quiet .#registry-two-actors-replay-fault`.
            registry-two-actors-replay-fault = {
              type = "app";
              program =
                let
                  pkgs = import nixpkgs { inherit system; };
                in
                pkgs.lib.getExe (
                  pkgs.writeShellApplication {
                    name = "registry-two-actors-replay-fault";
                    runtimeInputs = with pkgs; [
                      bash
                      coreutils
                      gnugrep
                      procps
                      python3
                      strace
                    ];
                    text = ''
                      base="''${REGISTRY_JOURNEY_ROOT:-''${XDG_CACHE_HOME:-$HOME/.cache}/singular-two-actors}"
                      mkdir -p "$base"
                      work="$(mktemp -d "$base/replay-fault.XXXXXX")"
                      echo "replay-fault control: receipts in $work"
                      export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                      SINGULAR_UNFAULTED=${pkgs.lib.getExe offchain.packages.${system}.singular} \
                      SINGULAR_TWO_ACTOR_CONTROL=replay-fault \
                        python3 ${./tools/registry_two_actors.py} \
                        ${pkgs.lib.getExe self.packages.${system}.singular-replay-fault} \
                        ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                        ${onchain.packages.${system}.plutus-blueprint} "$work/journey"
                    '';
                  }
                );
            };
          }
          // (import ./nix/negative-host.nix { pkgs = import nixpkgs { inherit system; }; })
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
