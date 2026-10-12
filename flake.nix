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
    # The Lean compiler the model builds with. It is the version root
    # `lean-toolchain` names (Lean 4.27.0), pinned to the nixpkgs commit that
    # packages it ("lean4: 4.26 -> 4.27"), so the compiler moves with this line
    # and not with the shared documentation tooling above.
    nixpkgs-lean.url = "github:NixOS/nixpkgs/7f4e8517083e42a1b38907598dadc02c7235b30e";
  };
  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-lean,
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
          leanPkgs = import nixpkgs-lean { inherit system; };
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
              holds=$(grep -rhoE 'harnessHoldAt[[:space:]]+"SINGULAR_HARNESS_HOLD_[A-Z_]+"' \
                ${./offchain/cli} \
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
              # No extra packages: the negative host moved to the
              # application's own tree, and the fault build needs only
              # the registry executable (main's offchain project lists
              # no cabalProjectLocal either).
              # The replay alteration is its own package build, with no
              # hold/drop/trace harness code linked into this variant.
              cabalProjectLocal = ''
                package singular-registry
                  flags: -test-harness
              '';
              modules = [
                fix-libs
                { packages.singular-registry.flags.test-harness = false; }
              ];
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
      # separate `singular` and `open-datum` processes on one development
      # node, plus the retained insert-active and update-terminal archive
      # controls. Run from the repository root: `nix run --quiet .#demo1-cli-check`.
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
            cp ${./tools/check_recovery_trie.py} $out/check_recovery_trie.py
            cp ${./tools/fixture_process.py} $out/fixture_process.py
            cp ${./tools/facade_lifecycle_controls.py} $out/facade_lifecycle_controls.py
            cp ${./tools/managed_state.sh} $out/managed_state.sh
            cp ${./tools/demo1_cli_journey.sh} $out/demo1_cli_journey.sh
            cp ${./tools/demo1_cli_create_race.sh} $out/demo1_cli_create_race.sh
            cp ${./tools/cli_recovery_receipt_cap.test.sh} $out/cli_recovery_receipt_cap.test.sh
          '';
          # #449: the recovery controls as one app per part, each on its own
          # development node, so CI runs the parts as parallel jobs. An empty
          # part list runs them all.
          # #300/#449: the demonstration's four refusals on one existing
          # registry, run as `open-datum` and `singular` processes (open verbs
          # through `open-datum`, takes through `cli-controls` with
          # `--singular`); an empty part list runs every part.
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
          # Every direct/wrapped recovery controller carries the same tools.
          # The lifecycle composition must not inherit them from an ambient
          # developer PATH after eliminating the old launcher wrapper chain.
          recoveryRuntimeInputs = with pkgs; [
            bash
            coreutils
            diffutils
            findutils
            gawk
            gnugrep
            gnused
            jq
            nix
            procps
            python3
          ];
          recoveryApp = name: parts: {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                inherit name;
                runtimeInputs = recoveryRuntimeInputs;
                text = ''
                  bash ${managedScripts}/cli_recovery_receipt_cap.test.sh ${managedScripts}/cli_recovery_controls.sh
                  CLI_RECOVERY_PARTS="${parts}" CLI_RECOVERY_CONTROLS=${managedScripts}/cli_recovery_controls.sh bash ${./tools/cli_recovery_controls_check.sh} "$PWD"
                '';
              }
            );
          };
          # The hosted recovery partitions, in one place. Each partition
          # lists its parts in running order; the discovery app, the
          # partition check, the per-partition runner and the documented
          # commands all derive from this list. Cross-wallet cases are
          # discovered from the fold path at discovery time, one partition
          # per case closed by the observation, so a new hold point joins
          # the matrix with nothing to edit here.
          cliRecoveryPartitions = {
            history = "accepting lost-answer killed never-sent whole-journal trie-capability";
            rollback = "rollback trie-capability";
          };
          cliRecoveryPartitionNames = {
            history = "accepting, lost-answer, killed, never-sent and whole-journal with trie observations";
            rollback = "restored node rollback (rollback trie-capability)";
          };
          # #451 re-cut: the shared collector derivation, exposed as an
          # app; its buildable package form lives in packages.
          cliRecoveryEvidence = (recoveryTools system).evidence;
          cliRecoveryParts = (recoveryTools system).parts;
          # #451 re-cut R2: one source-discovered case per invocation, through
          # the same controls and check wrapper; the controls refuse an unknown
          # token against the shared census before any node starts.
          cliRecoveryCrossPartApp = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-recovery-cross-wallet-part";
                runtimeInputs = recoveryRuntimeInputs;
                text = ''
                  [ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: cli-recovery-cross-wallet-part PART" >&2; exit 2; }
                  bash ${managedScripts}/cli_recovery_receipt_cap.test.sh ${managedScripts}/cli_recovery_controls.sh
                  CLI_RECOVERY_PARTS="$1" CLI_RECOVERY_CONTROLS=${managedScripts}/cli_recovery_controls.sh bash ${./tools/cli_recovery_controls_check.sh} "$PWD"
                '';
              }
            );
          };
          # One partition per invocation, by key (`history`, `rollback`) or
          # by discovered cross-wallet case (`cross-wallet:<hold>`), through
          # the same receipt cap and check wrapper; the controls refuse an
          # unknown token against the shared census before any node starts.
          cliRecoveryPartitionApp = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-recovery-partition";
                runtimeInputs = recoveryRuntimeInputs;
                text = ''
                  [ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: cli-recovery-partition KEY" >&2; exit 2; }
                  key="$1"
                  staticParts='${builtins.toJSON cliRecoveryPartitions}'
                  case "$key" in
                    cross-wallet:*) parts="$key trie-capability" ;;
                    *)
                      parts="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$staticParts")"
                      [ -n "$parts" ] || { echo "cli-recovery-partition: unknown partition: $key" >&2; exit 2; } ;;
                  esac
                  bash ${managedScripts}/cli_recovery_receipt_cap.test.sh ${managedScripts}/cli_recovery_controls.sh
                  CLI_RECOVERY_PARTS="$parts" CLI_RECOVERY_CONTROLS=${managedScripts}/cli_recovery_controls.sh bash ${./tools/cli_recovery_controls_check.sh} "$PWD"
                '';
              }
            );
          };
          # The partition census: every static partition with its hosted
          # name, then one partition per cross-wallet case discovered from
          # the fold path's own sources. No node; the workflow matrix and
          # the partition check both read this list.
          cliRecoveryPartitionsApp = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-recovery-partitions";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  gnugrep
                  gnused
                  jq
                ];
                text = ''
                  staticParts='${builtins.toJSON cliRecoveryPartitions}'
                  staticNames='${builtins.toJSON cliRecoveryPartitionNames}'
                  holds=$(grep -rhoE 'harnessHoldAt[[:space:]]+"SINGULAR_HARNESS_HOLD_[A-Z_]+"' \
                    ${./offchain/cli} | sed -E 's/.*"(SINGULAR_HARNESS_HOLD_[A-Z_]+)".*/\1/' | sort -u)
                  [ -n "$holds" ] || { echo "cli-recovery-partitions: the fold path declares no hold points" >&2; exit 2; }
                  jq -n --argjson parts "$staticParts" --argjson names "$staticNames" --arg holds "$holds" '
                    {partition: ([$parts | to_entries[] | {key: .key, name: $names[.key], parts: .value}] + ($holds | split("\n") | map(select(. != "") | {key: ("cross-wallet:" + .), name: ("another wallet fold: cross-wallet:" + . + " with trie observations"), parts: (. | "cross-wallet:" + . + " trie-capability")}) + [{key: "cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer", name: "another wallet fold: cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer with trie observations", parts: "cross-wallet:SINGULAR_HARNESS_HOLD_AFTER_SEND:lost-answer trie-capability"}]))}'
                '';
              }
            );
          };
          # The hosted check on the partitions: every scenario part in
          # exactly one partition, every partition closed by the
          # observation. Reads the discovery list; the controls script it
          # judges defaults to this checkout, CLI_RECOVERY_CONTROLS
          # overrides it for the dummy-part plant.
          cliRecoveryPartitionCheckApp = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-recovery-partition-check";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  gnugrep
                  gnused
                  jq
                ];
                text = ''
                  [ "$#" -eq 2 ] || { echo "usage: cli-recovery-partition-check REPO-ROOT PARTITIONS_JSON" >&2; exit 2; }
                  bash ${./tools/cli_recovery_partition_check.sh} "$1" "$2"
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
          # the Demo 1 journey built from the archive's own flakes:
          # `nix run .#verify-release -- vX.Y.Z`.
          verifyRelease = pkgs.writeShellApplication {
            name = "verify-release";
            runtimeInputs = with pkgs; [
              bash
              python3
              binutils
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
              export VERIFY_RELEASE_BINARY_CHECK=${./tools/check_release_binary.py}
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
          # The control needs the Nix daemon and real output derivations.
          release-build-control = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "release-build-control";
                runtimeInputs = with pkgs; [
                  bash
                  binutils
                  coreutils
                  gnugrep
                  nix
                  python3
                ];
                text = ''
                  export RELEASE_BINARY_CHECK=${./tools/check_release_binary.py}
                  bash ${./tools/release_build_control.sh} "$PWD"
                '';
              }
            );
          };
          # This mandatory carrier retains every original injected journey
          # assertion and independent trie observation on explicit test builds.
          demo1-cli-test-harness = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-cli-test-harness";
                runtimeInputs = with pkgs; [
                  bash
                  coreutils
                  diffutils
                  findutils
                  gawk
                  git
                  gnugrep
                  gnused
                  jq
                  nix
                  procps
                  strace
                  util-linux
                ];
                text = ''
                  export DEMO1_TEST_JOURNEY=${managedScripts}/demo1_cli_journey.sh
                  export DEMO1_CREATE_RACE=${managedScripts}/demo1_cli_create_race.sh
                  bash ${./tools/demo1_cli_test_harness_check.sh} "$PWD"
                '';
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
                  gnutar
                  gzip
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
                  # the journey builds open-datum from its own flake at start
                  pkgs.nix
                  # the stop path verifies no surviving node with pkill/pgrep
                  pkgs.procps
                ];
                text = ''
                  base="''${REGISTRY_JOURNEY_ROOT:-''${XDG_CACHE_HOME:-$HOME/.cache}/singular-two-actors}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/run.XXXXXX")/journey"
                  echo "two actors: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  # #528: insert, update, terminate and the termination fold
                  # run on the open-datum executable, built here from its own
                  # flake; without it the journey cannot start (setup).
                  root="$PWD"
                  [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
                    echo "registry-two-actors: run from the repository root" >&2
                    exit 3
                  }
                  open_datum_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")" || exit 3
                  open_datum="$open_datum_out/bin/open-datum"
                  [ -x "$open_datum" ] || {
                    echo "registry-two-actors: no open-datum binary in $open_datum_out" >&2
                    exit 3
                  }
                  # The deployment blueprint unions the application and the
                  # witnesses in one build (the document both CLIs get as
                  # --blueprint); the registry-only blueprint carries no
                  # open_datum validator.
                  deployment_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")" || exit 3
                  [ -f "$deployment_bp" ] || {
                    echo "registry-two-actors: no deployment blueprint" >&2
                    exit 3
                  }
                  # #381: the altered journey leg inspects with the control
                  # build; without it the leg is skipped and its row pending.
                  SINGULAR_REPLAY_FAULT=${pkgs.lib.getExe self.packages.${system}.singular-replay-fault} \
                    python3 ${./tools/registry_two_actors.py} \
                    ${pkgs.lib.getExe offchain.packages.${system}.singular} \
                    "$open_datum" \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                    "$deployment_bp" "$work"
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
                  nix
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
                  # #528: the journey's open verbs run on the open-datum
                  # executable, built here from its own flake (setup).
                  root="$PWD"
                  [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
                    echo "registry-two-actors-control: run from the repository root" >&2
                    exit 3
                  }
                  open_datum_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")" || exit 3
                  open_datum="$open_datum_out/bin/open-datum"
                  [ -x "$open_datum" ] || {
                    echo "registry-two-actors-control: no open-datum binary in $open_datum_out" >&2
                    exit 3
                  }
                  # The deployment blueprint unions the application and the
                  # witnesses in one build (the document both CLIs get as
                  # --blueprint).
                  deployment_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")" || exit 3
                  [ -f "$deployment_bp" ] || {
                    echo "registry-two-actors-control: no deployment blueprint" >&2
                    exit 3
                  }
                  # #381: the shipped harness's status taxonomy needs no
                  # development network, so it runs before anything starts one.
                  python3 ${./tools/registry_two_actors_status.test.py} ${./tools/registry_two_actors.py}
                  bash ${./tools/registry_two_actors_control.test.sh} ${./tools/registry_two_actors_control.sh}
                  bash ${./tools/registry_two_actors_control.sh} "$work" \
                    python3 ${./tools/registry_two_actors.py} \
                    ${pkgs.lib.getExe offchain.packages.${system}.singular} \
                    "$open_datum" \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                    "$deployment_bp"
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
          # two fresh keys, run as `open-datum` and `singular` processes:
          # `nix run --quiet .#demo1-cli-attach`.
          demo1-cli-attach = attachApp "demo1-cli-attach" "";
          # #449: one app per part, each with its own registry and node, so CI
          # runs the parts as parallel jobs.
          demo1-cli-attach-takes = attachApp "demo1-cli-attach-takes" "takes";
          demo1-cli-attach-indexer-reads = attachApp "demo1-cli-attach-indexer-reads" "indexer-reads";
          demo1-cli-attach-tampered-a = attachApp "demo1-cli-attach-tampered-a" "tampered-a";
          demo1-cli-attach-tampered-b = attachApp "demo1-cli-attach-tampered-b" "tampered-b";
          demo1-cli-attach-over-allowance = attachApp "demo1-cli-attach-over-allowance" "over-allowance";
          # #300: the public-indexer readback (`open-datum inspect` receipts)
          # against a local indexer that answers
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
          # #326: the flags documented for `singular` and `open-datum` equal
          # what each binary's --help prints, triple by triple, with the
          # removed `singular registry insert | update | terminate` verbs
          # refused: `nix run --quiet .#cli-flags-check`.
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
          # #325: the ordinary CLI's recovery controls, run as `open-datum`
          # and `singular` processes (open verbs through `open-datum`,
          # `reject`/`reclaim` through `singular registry`) — a lost
          # acknowledgement, a local commit interrupted before and after the
          # mirror is saved, a transaction never sent, and an accepting
          # control — judged from receipts and journals:
          # `nix run --quiet .#cli-recovery-controls`.
          facade-lifecycle-controls = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "facade-lifecycle-controls";
                runtimeInputs = recoveryRuntimeInputs;
                text = ''
                  work="$(mktemp -d)/controls"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  exec python3 ${managedScripts}/facade_lifecycle_controls.py \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} "$work" \
                  --startup-controller ${managedScripts}/cli_recovery_controls.sh \
                  --singular ${pkgs.lib.getExe offchain.packages.${system}.singular-test-harness} --root "$PWD"
                '';
              }
            );
          };
          cli-recovery-history = recoveryApp "cli-recovery-history" "accepting lost-answer killed never-sent whole-journal trie-capability";
          cli-recovery-rollback = recoveryApp "cli-recovery-rollback" "rollback trie-capability";
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
          # The hosted partitions, derived from the single list above:
          # one runner, one discovery list and one census check.
          cli-recovery-partition = cliRecoveryPartitionApp;
          cli-recovery-partitions = cliRecoveryPartitionsApp;
          cli-recovery-partition-check = cliRecoveryPartitionCheckApp;
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
                      nix
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
                      # #528: the journey's open verbs run on the open-datum
                      # executable, built here from its own flake (setup).
                      root="$PWD"
                      [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
                        echo "registry-two-actors-replay-fault: run from the repository root" >&2
                        exit 3
                      }
                      open_datum_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")" || exit 3
                      open_datum="$open_datum_out/bin/open-datum"
                      [ -x "$open_datum" ] || {
                        echo "registry-two-actors-replay-fault: no open-datum binary in $open_datum_out" >&2
                        exit 3
                      }
                      # The deployment blueprint unions the application and the
                      # witnesses in one build (the document both CLIs get as
                      # --blueprint).
                      deployment_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")" || exit 3
                      [ -f "$deployment_bp" ] || {
                        echo "registry-two-actors-replay-fault: no deployment blueprint" >&2
                        exit 3
                      }
                      SINGULAR_UNFAULTED=${pkgs.lib.getExe offchain.packages.${system}.singular} \
                      SINGULAR_TWO_ACTOR_CONTROL=replay-fault \
                        python3 ${./tools/registry_two_actors.py} \
                        ${pkgs.lib.getExe self.packages.${system}.singular-replay-fault} \
                        "$open_datum" \
                        ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                        "$deployment_bp" "$work/journey"
                    '';
                  }
                );
            };
          }
          // (import ./nix/negative-host.nix { pkgs = import nixpkgs { inherit system; }; })
          // (
            let
              pkgs = import nixpkgs { inherit system; };
              # #528 slice 4: the registry/application separation pair.
              # The check takes the repository root and scans the registry
              # trees named in its own data list; the controls plant a
              # naming, a reach, a dependency and the script hash in
              # scratch copies and require the clean tree to pass.
              separationCheck = pkgs.writeShellApplication {
                name = "application-separation-check";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.jq
                ];
                text = builtins.readFile ./tools/application_separation_check.sh;
              };
            in
            {
              application-separation-check = {
                type = "app";
                program = pkgs.lib.getExe separationCheck;
              };
              application-separation-controls = {
                type = "app";
                program = pkgs.lib.getExe (
                  pkgs.writeShellApplication {
                    name = "application-separation-controls";
                    runtimeInputs = [
                      pkgs.coreutils
                      pkgs.gnugrep
                      pkgs.gnused
                      pkgs.jq
                    ];
                    text =
                      "check=${pkgs.lib.getExe separationCheck}\n"
                      + builtins.readFile ./tools/application_separation_controls.sh;
                  }
                );
              };
            }
          )
          // (
            let
              pkgs = import nixpkgs { inherit system; };
              # #528 slice 7, brief 3: the keri-stub devnet journey. One
              # raw development node funds one wallet; the keri-stub
              # executable, built here from its own flake, boots a registry
              # for the stub's own always-succeeding policy, registers one
              # key, folds the stub's own request (standalone and --fold),
              # reads the key back active with its holding, and refuses a
              # second register of the same key at booking with nothing
              # submitted. The raw devnet reads its genesis from
              # E2E_GENESIS_DIR explicitly, never from the working
              # directory; the journey also proves no open-datum executable
              # was used.
              keriStubCheck = pkgs.writeShellApplication {
                name = "keri-stub-check";
                runtimeInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.findutils
                  pkgs.gnugrep
                  pkgs.jq
                  pkgs.nix
                  # the journey checks the live process record for an
                  # open-datum executable and stops its own node
                  pkgs.procps
                  # the journey derives testnet enterprise addresses for
                  # the repayment observation through the embedded bech32
                  # encoder (the controller's address, plus a decoy)
                  pkgs.python3Minimal
                ];
                text = ''
                  set -euo pipefail
                  root="''${KERI_STUB_CHECK_ROOT:-$PWD}"
                  [ -f "$root/applications/keri-stub/offchain/flake.nix" ] || {
                    echo "keri-stub-check: run from the repository root (or set KERI_STUB_CHECK_ROOT)" >&2
                    exit 3
                  }
                  base="''${TMPDIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/singular-keri-stub}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/run.XXXXXX")/journey"
                  echo "keri-stub-check: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  keri_stub_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/keri-stub/offchain#keri-stub")" || exit 3
                  keri_stub="$keri_stub_out/bin/keri-stub"
                  [ -x "$keri_stub" ] || {
                    echo "keri-stub-check: no keri-stub binary in $keri_stub_out" >&2
                    exit 3
                  }
                  blueprint="$(nix build --quiet --no-link --print-out-paths "$root/onchain#plutus-blueprint")" || exit 3
                  [ -f "$blueprint" ] || {
                    echo "keri-stub-check: the registry blueprint build produced no file" >&2
                    exit 3
                  }
                  bash ${./tools/keri_stub_journey.sh} "$keri_stub" \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                    "$blueprint" "$work"
                '';
              };
            in
            {
              keri-stub-check = {
                type = "app";
                program = pkgs.lib.getExe keriStubCheck;
              };
            }
          )
          // (
            let
              pkgs = import nixpkgs { inherit system; };
              # #528 S5.1: the split-blueprint hash comparison. The open-datum
              # validators build in their own Aiken project now, so no single
              # blueprint holds the whole contract: this app rebuilds the
              # registry blueprint and the application blueprint, unions
              # their validator sets, and requires the union to equal the
              # base set recorded in base-hashes.json exactly — every hash
              # byte-identical. Titles are compared modulo the module path
              # (the first segment), so a move that renames only the module
              # path is tolerated while a changed hash, a missing validator
              # and an extra validator all fail. The two plants below run on
              # every invocation: a changed hash and a missing validator
              # must each be refused, naming the validator — a comparison
              # that cannot fail guards nothing. Takes the repository root
              # (default: the working tree) and builds both blueprints
              # itself, so CI runs it with no other setup.
              scriptHashComparison = pkgs.writeShellApplication {
                name = "script-hash-comparison";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.jq
                  pkgs.nix
                ];
                text = ''
                  set -euo pipefail
                  root="''${1:-$PWD}"
                  root=$(realpath -m "$root")
                  base="$root/specs/528-registry-cli-split/evidence/base-hashes.json"
                  [ -f "$base" ] || {
                    echo "script-hash-comparison: no base-hashes.json under $root" >&2
                    exit 2
                  }
                  registry_bp="$(nix build --quiet --no-link --print-out-paths "$root/onchain#plutus-blueprint")"
                  app_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#plutus-blueprint")"
                  for bp in "$registry_bp" "$app_bp"; do
                    [ -f "$bp" ] || {
                      echo "script-hash-comparison: blueprint build produced no file: $bp" >&2
                      exit 2
                    }
                  done
                  base_compiler="$(jq -r '.compiler' "$base")"
                  for bp in "$registry_bp" "$app_bp"; do
                    built_compiler="$(jq -r '.preamble.compiler.version' "$bp")"
                    [ "$built_compiler" = "$base_compiler" ] || {
                      echo "script-hash-comparison: compiler moved: base records $base_compiler, build reports $built_compiler ($bp)" >&2
                      exit 1
                    }
                  done
                  work=$(mktemp -d)
                  trap 'rm -rf "$work"' EXIT
                  jq -s '{validators: (.[0].validators + .[1].validators)}' "$registry_bp" "$app_bp" >"$work/union.json"
                  # S5-1d-r2: one-to-one title correspondence with pre-map
                  # rejection. Raw checks (duplicate full titles, ambiguous
                  # normalised keys, empty sets, raw-count equality) run in
                  # their own jq invocation with no from_entries anywhere —
                  # a collision fails before any map exists. Only when raw
                  # passes do we build the normalised maps and compare
                  # hashes; then from_entries is one-to-one and lossless, so
                  # every validator and hash stays in the comparison.
                  compare() {
                    local raw problems
                    raw="$(jq -r -n --slurpfile b "$1" --slurpfile u "$2" '
                      ($b[0].validators) as $baseVals
                      | ($u[0].validators) as $unionVals
                      | ($baseVals | length) as $baseCount
                      | ($unionVals | length) as $unionCount
                      | ($baseVals | map(.title)) as $baseTitles
                      | ($unionVals | map(.title)) as $unionTitles
                      | ($baseTitles | unique | length) as $baseUnique
                      | ($unionTitles | unique | length) as $unionUnique
                      | ($baseVals | map(.title | split(".") | .[length - 2:] | join("."))) as $baseNorm
                      | ($unionVals | map(.title | split(".") | .[length - 2:] | join("."))) as $unionNorm
                      | ($baseNorm | unique | length) as $baseNormUnique
                      | ($unionNorm | unique | length) as $unionNormUnique
                      | (if $baseCount == 0
                         then ["FAIL: the base set records zero validators"] else [] end)
                        + (if $unionCount == 0
                           then ["FAIL: the union builds zero validators"] else [] end)
                        + (if $baseUnique != $baseCount
                           then ["FAIL: base has duplicate validator titles"] else [] end)
                        + (if $unionUnique != $unionCount
                           then ["FAIL: union has duplicate validator titles"] else [] end)
                        + (if $baseNormUnique != $baseCount
                           then ["FAIL: base has ambiguous normalised titles (collision)"] else [] end)
                        + (if $unionNormUnique != $unionCount
                           then ["FAIL: union has ambiguous normalised titles (collision)"] else [] end)
                        + (if $baseCount != $unionCount
                           then ["FAIL: count mismatch: base has \($baseCount), union has \($unionCount)"] else [] end)
                      | .[]
                    ')" || return 2
                    if [ -n "$raw" ]; then
                      printf '%s\n' "$raw"
                      return 1
                    fi
                    problems="$(jq -r -n --slurpfile b "$1" --slurpfile u "$2" '
                      ($b[0].validators | map({key: (.title | split(".") | .[length - 2:] | join(".")), value: .hash}) | from_entries) as $want
                      | ($u[0].validators | map({key: (.title | split(".") | .[length - 2:] | join(".")), value: .hash}) | from_entries) as $got
                      | (if ($want | length) == 0
                         then ["FAIL: the base set records zero validators"] else [] end)
                        + (if ($got | length) == 0
                           then ["FAIL: the union builds zero validators"] else [] end)
                        + [$want | to_entries[] | .key as $k |
                             if ($got | has($k) | not) then
                               "FAIL: base validator \($k) (hash \(.value)) has no counterpart in the union"
                             elif $got[$k] != .value then
                               "FAIL: validator \($k) moved: base expects \(.value), union builds \($got[$k])"
                             else empty end]
                        + [$got | to_entries[] | .key as $k |
                             if ($want | has($k) | not) then
                               "FAIL: union validator \($k) (hash \(.value)) is not in the base set"
                             else empty end]
                      | .[]
                    ')" || return 2
                    if [ -n "$problems" ]; then
                      printf '%s\n' "$problems"
                      return 1
                    fi
                    return 0
                  }
                  if ! compare "$base" "$work/union.json" >"$work/live.log" 2>&1; then
                    echo "script-hash-comparison: union differs from the base set:" >&2
                    cat "$work/live.log" >&2
                    exit 1
                  fi
                  echo "script-hash-comparison: OK — $(jq '.validators | length' "$work/union.json") union validators equal the base set ($(jq '.validators | length' "$base") recorded, compiler $base_compiler)"
                  jq -r '.validators | sort_by(.title) | .[] | "\(.title) \(.hash)"' "$work/union.json"
                  jq '.validators[0].hash = "00000000000000000000000000000000000000000000000000000000"' "$work/union.json" >"$work/plant-changed.json"
                  grep -q '00000000000000000000000000000000000000000000000000000000' "$work/plant-changed.json" || {
                    echo "script-hash-comparison: changed-hash plant did not apply" >&2
                    exit 2
                  }
                  if compare "$base" "$work/plant-changed.json" >"$work/plant-changed.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the changed-hash plant" >&2
                    exit 1
                  fi
                  grep -q 'moved' "$work/plant-changed.log" || {
                    echo "script-hash-comparison: changed-hash plant refused without naming the moved validator:" >&2
                    cat "$work/plant-changed.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: changed-hash plant refused" >&2
                  jq 'del(.validators[0])' "$work/union.json" >"$work/plant-missing.json"
                  [ "$(jq '.validators | length' "$work/plant-missing.json")" = "$(($(jq '.validators | length' "$work/union.json") - 1))" ] || {
                    echo "script-hash-comparison: missing-validator plant did not apply" >&2
                    exit 2
                  }
                  if compare "$base" "$work/plant-missing.json" >"$work/plant-missing.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the missing-validator plant" >&2
                    exit 1
                  fi
                  # S5-1d-r2: the missing row fails pre-map on raw-count
                  # equality (13 vs 14) before any map exists; that count
                  # mismatch is its reason.
                  grep -q 'count mismatch' "$work/plant-missing.log" || {
                    echo "script-hash-comparison: missing-validator plant refused without its count reason:" >&2
                    cat "$work/plant-missing.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: missing-validator plant refused" >&2
                  # S5-1d-r1 collision control: an extra validator under a path
                  # that normalises onto an existing title but carries another
                  # hash must fail (ambiguous normalised key and count
                  # mismatch) — the class the changed/missing plants do not
                  # exercise on the current 14-row subject.
                  jq '.validators += [{"title": "alternate.open_datum.mint", "hash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "compiledCode": "00"}]' "$work/union.json" >"$work/plant-collision.json"
                  [ "$(jq '.validators | length' "$work/plant-collision.json")" = "$(($(jq '.validators | length' "$work/union.json") + 1))" ] || {
                    echo "script-hash-comparison: collision plant did not apply" >&2
                    exit 2
                  }
                  grep -q 'alternate.open_datum.mint' "$work/plant-collision.json" || {
                    echo "script-hash-comparison: collision plant title missing" >&2
                    exit 2
                  }
                  if compare "$base" "$work/plant-collision.json" >"$work/plant-collision.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the collision plant" >&2
                    exit 1
                  fi
                  grep -Eq 'ambiguous|count mismatch|not in the base' "$work/plant-collision.log" || {
                    echo "script-hash-comparison: collision plant refused without naming the collision:" >&2
                    cat "$work/plant-collision.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: collision plant refused" >&2
                  # S5.2: the deployment blueprint itself. Built in the
                  # application's onchain flake from the same two trees
                  # (jq merge, preamble from the registry's), it must equal
                  # the base set exactly and carry byte-identical
                  # compiledCode for all 14 validators — the pairing
                  # guarantee every executable's --blueprint relies on.
                  merged_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")"
                  [ -f "$merged_bp" ] || {
                    echo "script-hash-comparison: merged blueprint build produced no file" >&2
                    exit 2
                  }
                  merged_compiler="$(jq -r '.preamble.compiler.version' "$merged_bp")"
                  [ "$merged_compiler" = "$base_compiler" ] || {
                    echo "script-hash-comparison: compiler moved: base records $base_compiler, merged reports $merged_compiler" >&2
                    exit 1
                  }
                  if ! compare "$base" "$merged_bp" >"$work/merged.log" 2>&1; then
                    echo "script-hash-comparison: merged blueprint differs from the base set:" >&2
                    cat "$work/merged.log" >&2
                    exit 1
                  fi
                  echo "script-hash-comparison: OK — merged deployment blueprint equals the base set ($(jq '.validators | length' "$merged_bp") validators, compiler $base_compiler)"
                  jq -r '.validators | sort_by(.title) | .[] | "\(.title) \(.hash)"' "$merged_bp"
                  # Byte-identical compiledCode: every merged validator must
                  # match the union's title, hash and compiledCode exactly.
                  # Empty output means identical; any DIFFER line fails.
                  diff_out="$(jq -s -r '
                    (.[0].validators | sort_by(.title)) as $m
                    | (.[1].validators | sort_by(.title)) as $u
                    | if ($m | length) != ($u | length) then "DIFFER: length \(($m | length)) vs \(($u | length))"
                      else range(0; ($m | length)) | select($m[.].title != $u[.].title or $m[.].hash != $u[.].hash or $m[.].compiledCode != $u[.].compiledCode) | "DIFFER: \($m[.].title)"
                      end
                  ' "$merged_bp" "$work/union.json")" || {
                    echo "script-hash-comparison: jq could not compare merged compiledCode" >&2
                    exit 2
                  }
                  [ -z "$diff_out" ] || {
                    echo "script-hash-comparison: merged compiledCode differs from the union:" >&2
                    printf '%s\n' "$diff_out" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: merged compiledCode byte-identical to the union" >&2
                  jq '.validators[0].hash = "00000000000000000000000000000000000000000000000000000000"' "$merged_bp" >"$work/plant-merged-changed.json"
                  if compare "$base" "$work/plant-merged-changed.json" >"$work/plant-merged-changed.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the merged changed-hash plant" >&2
                    exit 1
                  fi
                  grep -q 'moved' "$work/plant-merged-changed.log" || {
                    echo "script-hash-comparison: merged changed-hash plant refused without naming the moved validator:" >&2
                    cat "$work/plant-merged-changed.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: merged changed-hash plant refused" >&2
                '';
              };
            in
            {
              script-hash-comparison = {
                type = "app";
                program = pkgs.lib.getExe scriptHashComparison;
              };
            }
          )
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
              ++ [
                offchain.packages.${system}.fourmolu
                (import nixpkgs-lean { inherit system; }).lean4
              ]
              ++ (with import nixpkgs { inherit system; }; [
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
