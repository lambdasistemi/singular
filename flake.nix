{
  description = "Singular retained models, coverage and documentation";
  inputs = {
    dev-assets-mkdocs.url = "github:paolino/dev-assets/a9d7371c1118de4026ba6ee3a9c3b54614924b82?dir=mkdocs";
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
    # The open-datum application the same way, as the whole repository with its
    # flake directory: its source copies the registry tree from a sibling path,
    # which a bare subdirectory input could not reach. The release bundle takes
    # the `open-datum` executable from it; its dependencies keep their own
    # locked revisions.
    open-datum.url = "path:./?dir=applications/open-datum/offchain";
    # #707: the application's on-chain flake the same way, for the merged
    # deployment blueprint the release archive ships as onchain/plutus.json;
    # every release bundle and package carries the same file.
    open-datum-onchain.url = "path:./?dir=applications/open-datum/onchain";
    nixpkgs.follows = "dev-assets-mkdocs/nixpkgs";
    # #707: the organisation's binary distribution helpers (AppImage, DEB, RPM,
    # Homebrew; the distribute-binaries standard) and the NixOS bundlers they drive.
    dev-assets = {
      url = "github:paolino/dev-assets/ecc41cee5d4c18ac4a8a2527c07cf33cba300a11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
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
      dev-assets,
      offchain,
      conformance,
      onchain,
      open-datum,
      open-datum-onchain,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      each = nixpkgs.lib.genAttrs systems;
      # The platforms that ship a release bundle (the darwin one only has this output).
      bundleSystems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
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
              mkdir -p "$out/receipts"
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
                # Managed originals (#543): journals and signed bodies live
                # in managed identity partitions
                # (ROOT/net-MAGIC/POLICY/wallets/KEYHASH, the mirror of
                # Singular.CLI.ManagedState.managedDir), never at the legacy
                # source/registry/journal.jsonl or source/registry/submissions
                # paths. Collect every journal and every saved signed body
                # under each managed state root the run used, preserving
                # SOURCE-relative paths so the manifest below pins each
                # record's relative identity and bytes. Only journal.jsonl
                # and submissions/ contents are copied: funding keys
                # (*.skey), the node database, lock files, snapshots and
                # unrelated homes stay out by construction, and projections
                # are never renamed as originals — these bytes are the run's
                # own records, retained here before the runner cleans up.
                managed_roots=0
                managed_journals=0
                managed_bodies=0
                state_root="$source/state-line"
                if [ ! -d "$state_root" ]; then
                  note "absent state root: ''${state_root#"$source"/}"
                else
                  managed_roots=$((managed_roots + 1))
                  while IFS= read -r -d ''' record; do
                    rel="''${record#"$source"/}"
                    case "$rel" in
                      */journal.jsonl) managed_journals=$((managed_journals + 1)) ;;
                      */submissions/*) managed_bodies=$((managed_bodies + 1)) ;;
                      *) continue ;;
                    esac
                    mkdir -p "$out/$(dirname "$rel")"
                    cp -a "$record" "$out/$rel"
                  done < <(find "$state_root" -type f -print0 | sort -z)
                fi
                note "managed: state_roots=$managed_roots journals=$managed_journals signed_bodies=$managed_bodies"
                for item in verdicts.md node-execution-time.json; do
                  if [ -e "$source/$item" ]; then
                    cp -a "$source/$item" "$out/"
                  else
                    note "absent: $item"
                  fi
                done
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
          # Retained recovery cases are declared by the partition table below.
        };
      packages = system: {
        default = (project system).docs;
        inherit (project system) docs;
        docs-release = (project system).releaseArchive;
        # #451 re-cut R1: the collector as a buildable package; the app below
        # refers to this same writeShellApplication derivation.
        cli-recovery-cross-wallet-evidence = (recoveryTools system).evidence;

      };
      # #695: the relocatable `singular` and `open-datum` bundle of one
      # platform (nix/release-bundle.nix). The release version is the one
      # version.txt names; the commit is this flake's own revision, which a
      # tag run reads from the tag's checkout.
      # The sub-flakes enter this flake as path inputs, which carry no git
      # revision, so their executables are stamped here, with this flake's
      # own, from the unstamped cached build.
      rootCommit = self.rev or (self.dirtyRev or "unknown-dirty");
      stampedExe =
        system: exe: program:
        (import ./offchain/nix/stamp-commit.nix { pkgs = import nixpkgs { inherit system; }; }) {
          inherit exe program;
          commit = rootCommit;
        };
      stampedSingular =
        system: stampedExe system offchain.packages.${system}.singular-unstamped "singular";
      stampedOpenDatum =
        system: stampedExe system open-datum.packages.${system}.open-datum-unstamped "open-datum";
      releaseBundle =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        import ./nix/release-bundle.nix {
          inherit pkgs;
          version = pkgs.lib.removeSuffix "\n" (builtins.readFile ./version.txt);
          commit = rootCommit;
          singular = stampedSingular system;
          openDatum = stampedOpenDatum system;
          # #707: the development node, from the same locked flake the Nix
          # route uses, and the genesis directory the Nix journeys name.
          devnet = offchain.packages.${system}.devnet-unwrapped;
          cardanoNode = offchain.packages.${system}.cardano-node;
          devnetGenesis = ./offchain/e2e-test/genesis;
          # the deployment blueprint the on-chain archive ships, with the
          # release number beside it as the commands require
          blueprint = open-datum-onchain.packages.${system}.open-datum-blueprint;
        };
      # #707: the releases at the organisation's binary distribution standard,
      # through the dev-assets helpers: AppImage, DEB and RPM for Linux, a
      # Homebrew formula for macOS. Release outputs carry the release number;
      # the dev channels add this flake's short revision.
      releaseVersion = nixpkgs.lib.removeSuffix "\n" (builtins.readFile ./version.txt);
      devArtifactVersion = "${releaseVersion}-${self.shortRev or (self.dirtyShortRev or "dirty")}";
      productCommands = [
        "singular"
        "open-datum"
        "devnet"
      ];
      # devnet for the Linux packages: the launcher with the locked cardano-node
      # on its path and the genesis files the Nix journeys name, answering
      # --version and --help itself as the release bundle's launcher does
      # (any other argument starts a node).
      devnetCommand =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.writeShellScriptBin "devnet" ''
          case "''${1-}" in
            --version)
              printf '%s\n' 'devnet ${releaseVersion} (commit ${rootCommit})'
              exit 0
              ;;
            --help | -h)
              printf '%s\n' 'devnet ${releaseVersion} (commit ${rootCommit})' \
                'Starts a private Cardano development node and prints its settings as one JSON line.' \
                'Funding: --fund-address ADDRESS:N:LOVELACE (see the Demo 1 development node page).'
              exit 0
              ;;
          esac
          export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
          export PATH="${offchain.packages.${system}.cardano-node}/bin''${PATH:+:$PATH}"
          exec ${offchain.packages.${system}.devnet-unwrapped}/bin/devnet "$@"
        '';
      # the deployment blueprint the release ships, with the release number
      # beside it, as the Linux packages put it: share/singular/
      blueprintData =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.runCommand "singular-blueprint-${releaseVersion}" { } ''
          mkdir -p "$out/share/singular"
          cp ${open-datum-onchain.packages.${system}.open-datum-blueprint} "$out/share/singular/plutus.json"
          printf '%s\n' '${releaseVersion}' > "$out/share/singular/version.txt"
        '';
      # the one product the Linux packages carry: its three commands and the blueprint
      linuxProduct =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.symlinkJoin {
          name = "singular-${releaseVersion}";
          paths = [
            (stampedSingular system)
            (stampedOpenDatum system)
            (devnetCommand system)
            (blueprintData system)
          ];
          meta.mainProgram = "singular";
        };
      # an AppImage per command, one DEB and one RPM with every command on the path
      linuxArtifacts =
        system: artifactVersion:
        dev-assets.lib.mkLinuxArtifacts {
          pkgs = import nixpkgs { inherit system; };
          inherit system artifactVersion;
          inherit (dev-assets.inputs) bundlers;
          executableName = "singular";
          commands = productCommands;
          # each AppImage carries its own command only; the DEB and RPM all three
          commandPackages = {
            singular = stampedSingular system;
            open-datum = stampedOpenDatum system;
            devnet = devnetCommand system;
          };
          # the blueprint and its version.txt at a path users can name
          packageLinks = {
            "usr/share/singular" = "${blueprintData system}/share/singular";
          };
          version = releaseVersion;
          glibcPackage = linuxProduct system;
        };
      # the Homebrew formula of the macOS release bundle, which it ships as it is
      darwinArtifacts =
        system: extra:
        dev-assets.lib.mkDarwinHomebrewBundle { pkgs = import nixpkgs { inherit system; }; } (
          {
            pname = "singular";
            version = releaseVersion;
            owner = "lambdasistemi";
            repo = "singular";
            desc = "Registry of unique keys on Cardano: singular, open-datum and a private development node";
            homepage = "https://lambdasistemi.github.io/singular/";
            formulaClass = "Singular";
            executableNames = productCommands;
            bundleTarball = "${releaseBundle system}/singular-${releaseVersion}-${system}.tar.gz";
            smokeCommands = map (command: "${command} --version") productCommands;
            formulaTest = nixpkgs.lib.concatMapStringsSep "\n" (line: "    ${line}") [
              "%w[singular open-datum devnet].each do |program|"
              "  assert_match \"#{program} ${releaseVersion} (commit \", shell_output(\"#{bin}/#{program} --version\")"
              "end"
              "assert_match \"cardano-node\", shell_output(\"#{libexec}/bin/cardano-node --version\")"
              "assert_predicate libexec/\"share/plutus.json\", :exist?"
              "assert_equal \"${releaseVersion}\", (libexec/\"share/version.txt\").read.strip"
            ];
          }
          // extra
        );
      # What this flake offers on each platform that ships a bundle: the two
      # programs, stamped with this flake's revision (`nix run .#singular --
      # --version`), and the release bundle that carries both.
      bundles = nixpkgs.lib.genAttrs bundleSystems (
        system:
        {
          singular = stampedSingular system;
          open-datum = stampedOpenDatum system;
          release-bundle = releaseBundle system;
        }
        // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
          linux-release-artifacts = linuxArtifacts system releaseVersion;
          linux-dev-release-artifacts = linuxArtifacts system devArtifactVersion;
        }
        // nixpkgs.lib.optionalAttrs (system == "aarch64-darwin") {
          darwin-release-artifacts = darwinArtifacts system { };
          darwin-dev-homebrew-artifacts = darwinArtifacts system {
            artifactVersion = devArtifactVersion;
            releaseTag = "dev-homebrew";
            formulaName = "singular-dev";
            formulaClass = "SingularDev";
            formulaVersion = devArtifactVersion;
            formulaExtraLines = "\n  conflicts_with \"singular\", because: \"both install the same commands\"";
          };
        }
      );
      bundleApps = nixpkgs.lib.genAttrs bundleSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          singular = {
            type = "app";
            meta.description = "Run the Singular registry command line";
            program = pkgs.lib.getExe (stampedSingular system);
          };
          open-datum = {
            type = "app";
            meta.description = "Run the open-datum application command line";
            program = pkgs.lib.getExe (stampedOpenDatum system);
          };
          # #695: the bundles of a published release, downloaded without
          # credentials and checked on this platform against the commit the tag
          # names: `nix run .#verify-release-bundles -- vX.Y.Z COMMIT`. The
          # variable names a directory of already downloaded assets instead.
          verify-release-bundles = {
            type = "app";
            meta.description = "Download and verify published release bundles";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "verify-release-bundles";
                runtimeInputs =
                  with pkgs;
                  [
                    bash
                    coreutils
                    curl
                    diffutils
                    findutils
                    gawk
                    gnugrep
                    gnused
                    gnutar
                    gzip
                    perl
                  ]
                  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                    bubblewrap
                    procps
                  ];
                text = ''
                  [ "$#" -eq 2 ] || {
                    echo "usage: verify-release-bundles TAG COMMIT" >&2
                    exit 2
                  }
                  tag="$1"
                  commit="$2"
                  version="''${tag#v}"
                  # shellcheck source=/dev/null
                  . ${./tools/release_bundles.sh}
                  download="$(mktemp -d)"
                  trap 'rm -rf "$download"' EXIT
                  # the on-chain archive too: the bundles' blueprint is checked against it
                  names="SHA256SUMS singular-onchain-$version.tar.gz"
                  for system in $SYSTEMS; do names="$names singular-$version-$system.tar.gz"; done
                  for name in $names; do
                    if [ -n "''${VERIFY_RELEASE_BUNDLES_ASSETS:-}" ]; then
                      cp "$VERIFY_RELEASE_BUNDLES_ASSETS/$name" "$download/$name"
                    else
                      curl -fsSL --retry 3 -o "$download/$name" \
                        "https://github.com/lambdasistemi/singular/releases/download/$tag/$name"
                    fi
                  done
                  export RELEASE_BUNDLE_SMOKE=${./tools/release_bundle_smoke.sh}
                  export RELEASE_BUNDLES_CONF=${./tools/release_bundles.sh}
                  bash ${./tools/verify_release_bundles.sh} ${./tools/release_bundles.sh} \
                    ${./tools/release_bundle_smoke.sh} ${./tools/release_bundle_smoke_controls.sh} \
                    "$download" "$version" "$commit"
                '';
              }
            );
          };
          # #695: every check a built bundle passes on its own platform,
          # with the tools they need carried here instead of read from the
          # runner: `nix run .#release-bundle-checks -- TARBALL VERSION COMMIT`.
          release-bundle-checks = {
            type = "app";
            meta.description = "Check release bundle contents and identities";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "release-bundle-checks";
                runtimeInputs =
                  with pkgs;
                  [
                    bash
                    coreutils
                    diffutils
                    findutils
                    gawk
                    gnugrep
                    gnused
                    gnutar
                    gzip
                    perl
                  ]
                  ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                    bubblewrap
                    procps
                  ];
                text = ''
                  [ "$#" -eq 3 ] || {
                    echo "usage: release-bundle-checks TARBALL VERSION COMMIT" >&2
                    exit 2
                  }
                  export RELEASE_BUNDLE_SMOKE=${./tools/release_bundle_smoke.sh}
                  # a bundle built from this tree always carries the development
                  # node, whatever version the tree says
                  export RELEASE_BUNDLES_CONF=${./tools/release_bundles.sh}
                  export RELEASE_BUNDLE_DEVNET=required
                  bash ${./tools/release_bundle_smoke.sh} "$@"
                  bash ${./tools/release_bundle_smoke_controls.sh} "$@"
                  bash ${./tools/verify_release_bundles.test.sh} \
                    ${./tools/verify_release_bundles.sh} ${./tools/release_bundles.sh} \
                    ${./tools/release_bundle_smoke.sh} ${./tools/release_bundle_smoke_controls.sh} "$@"
                '';
              }
            );
          };
        }
        // pkgs.lib.optionalAttrs (system == "x86_64-linux") {
          # #707: the distribution standard's smoke of the Linux packages: each
          # extracted, each command run with --version. The dev-assets
          # linux-release action runs it as `nix run .#linux-artifact-smoke`.
          linux-artifact-smoke = {
            type = "app";
            meta.description = "Check Linux distribution packages";
            program = pkgs.lib.getExe (
              dev-assets.lib.mkLinuxArtifactSmoke {
                inherit pkgs system;
                artifacts = [
                  "appimage"
                  "deb"
                  "rpm"
                ];
              }
            );
          };
        }
      );
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
      # Scripts sourcing managed_state.sh are packaged with their sibling helpers.
      commandScripts =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.runCommand "managed-scripts" { } ''
          mkdir -p $out
          cp ${./tools/cli_recovery_controls.sh} $out/cli_recovery_controls.sh
          cp ${./tools/fixture_process.py} $out/fixture_process.py
          cp ${./tools/facade_lifecycle_controls.py} $out/facade_lifecycle_controls.py
          cp ${./tools/managed_state.sh} $out/managed_state.sh
          cp ${./tools/shared_publication_checks.sh} $out/shared_publication_checks.sh
          cp ${./tools/no_pin_chain_view.py} $out/no_pin_chain_view.py
          cp ${./tools/cli_recovery_receipt_cap.test.sh} $out/cli_recovery_receipt_cap.test.sh
        '';
      commandControls =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          managedScripts = commandScripts system;
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
          # The hosted recovery partitions, in one place. Each partition
          # lists its parts in running order; the discovery app, the
          # partition check, the per-partition runner and the documented
          # commands all derive from this list. Every retained partition
          # exercises its commands and checks identity and reconciliation.
          cliRecoveryPartitions = {
            shared-publications = "shared-publications";
            state-line = "state-line";
            holding-update = "holding-update";
            holding-terminate = "holding-terminate";
            termination-fold = "termination-fold";
          };
          cliRecoveryPartitionNames = {
            shared-publications = "shared script publications before and after interruption, and uncertain creation recovery";
            state-line = "registry creation, registration booking, reclaim, cleanup and folding interrupted three ways";
            holding-update = "controller holding updates interrupted three ways";
            holding-terminate = "permanent termination bookings interrupted three ways";
            termination-fold = "public termination folds by a second wallet interrupted three ways";
          };
          # #451 re-cut: the shared collector derivation, exposed as an
          # app; its buildable package form lives in packages.
          cliRecoveryEvidence = (recoveryTools system).evidence;
          # One retained partition per invocation, through the same receipt
          # cap and check wrapper. Unknown keys fail before any node starts.
          cliRecoveryPartitionApp = {
            type = "app";
            meta.description = "Run one command recovery partition";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-recovery-partition";
                runtimeInputs = recoveryRuntimeInputs;
                text = ''
                  [ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: cli-recovery-partition KEY" >&2; exit 2; }
                  key="$1"
                  staticParts='${builtins.toJSON cliRecoveryPartitions}'
                  parts="$(jq -r --arg k "$key" '.[$k] // empty' <<<"$staticParts")"
                  [ -n "$parts" ] || { echo "cli-recovery-partition: unknown partition: $key" >&2; exit 2; }
                  bash ${managedScripts}/cli_recovery_receipt_cap.test.sh ${managedScripts}/cli_recovery_controls.sh
                  CLI_RECOVERY_PARTS="$parts" CLI_RECOVERY_CONTROLS=${managedScripts}/cli_recovery_controls.sh bash ${./tools/cli_recovery_controls_check.sh} "$PWD"
                '';
              }
            );
          };
          # The partition census supplies every retained partition and its
          # hosted name. No node; both the workflow matrix and check read it.
          cliRecoveryPartitionsApp = {
            type = "app";
            meta.description = "List command recovery partitions";
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
                  jq -c -n --argjson parts "$staticParts" --argjson names "$staticNames" '
                    {partition: [$parts | to_entries[] | {key: .key, name: $names[.key], parts: .value}]}'
                '';
              }
            );
          };
          # The hosted check on the partitions: every retained scenario in
          # exactly one partition. Reads the discovery list; the script it
          # judges defaults to this checkout, CLI_RECOVERY_CONTROLS
          # overrides it for the dummy-part plant.
          cliRecoveryPartitionCheckApp = {
            type = "app";
            meta.description = "Check command recovery partition evidence";
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
                  bash ${./tools/cli_recovery_partition_check.test.sh} ${./tools/cli_recovery_partition_check.sh} "$1" "$2"
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
        in
        {
          # #326: the flags documented for `singular` and `open-datum` equal
          # what each binary's --help prints, triple by triple, with the
          # removed `singular registry insert | update | terminate` verbs
          # refused: `nix run --quiet .#cli-flags-check`.
          cli-flags-check = {
            type = "app";
            meta.description = "Check command line flag coverage";
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
            meta.description = "Run command line flag coverage controls";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "cli-flags-controls";
                runtimeInputs = flagsTools;
                text = ''bash ${./tools/cli_flags_controls.sh} "$PWD"'';
              }
            );
          };
          # #638 + #639: the packaged wallet vault controls — the real
          # `singular` through a passphrase descriptor with no
          # `cardano-cli` on the path, each control planted-defect
          # falsified; the sign family rewrites the committed bundle
          # fixture's signers with jq, and proves the offline verb under
          # a bwrap network namespace where the runner allows one, else
          # through provider refusals plus a python counting canary:
          # `nix run --quiet .#wallet-vault-controls`.
          wallet-vault-controls = {
            type = "app";
            meta.description = "Run wallet vault controls";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "wallet-vault-controls";
                runtimeInputs = flagsTools ++ [
                  pkgs.jq
                  pkgs.python3
                  pkgs.bubblewrap
                  pkgs.systemd
                ];
                text = ''bash ${./tools/wallet_vault_controls.sh} "$PWD"'';
              }
            );
          };
          # The private facade's joined lifecycle and fatal failure controls,
          # run as `open-datum` and `singular` processes — judged from
          # receipts and journals:
          # `nix run --quiet .#facade-lifecycle-controls`.
          facade-lifecycle-controls = {
            type = "app";
            meta.description = "Run command facade lifecycle controls";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "facade-lifecycle-controls";
                runtimeInputs = recoveryRuntimeInputs;
                text = ''
                  work="$(mktemp -d)/controls"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  exec python3 ${managedScripts}/facade_lifecycle_controls.py \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} "$work"
                '';
              }
            );
          };
          # The portable collector — the hosted gate runs the census app, the
          # per-partition matrix and the collector app per matrix job.
          cli-recovery-cross-wallet-evidence = {
            type = "app";
            meta.description = "Check recovery evidence across wallets";
            program = pkgs.lib.getExe cliRecoveryEvidence;
          };
          # The hosted partitions, derived from the single list above:
          # one runner, one discovery list and one census check.
          cli-recovery-partition = cliRecoveryPartitionApp;
          cli-recovery-partitions = cliRecoveryPartitionsApp;
          cli-recovery-partition-check = cliRecoveryPartitionCheckApp;
        };
      # The registration journey and release verifier share the same helper closure.
      noPinScripts =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.runCommand "no-pin-scripts" { } ''
          mkdir -p $out
          cp ${./tools/no_pin_rig.sh} $out/no_pin_rig.sh
          cp ${./tools/no_pin_registration_journey.sh} $out/no_pin_registration_journey.sh
          cp ${./tools/no_pin_batch_journey.sh} $out/no_pin_batch_journey.sh
          cp ${./tools/no_pin_batch_observations.py} $out/no_pin_batch_observations.py
          cp ${./tools/no_pin_registration_refusals.sh} $out/no_pin_registration_refusals.sh
          cp ${./tools/no_pin_batch_refusals.sh} $out/no_pin_batch_refusals.sh
          cp ${./tools/no_pin_termination_refusals.sh} $out/no_pin_termination_refusals.sh
          cp ${./tools/no_pin_chain_view.py} $out/no_pin_chain_view.py
          cp ${./tools/shared_publication_checks.sh} $out/shared_publication_checks.sh
          cp ${./tools/no_pin_termination_observations.py} $out/no_pin_termination_observations.py
          cp ${./tools/shared_registration_observations.py} $out/shared_registration_observations.py
          cp ${./tools/no_pin_reading_checks.py} $out/no_pin_reading_checks.py
          cp ${./tools/creation-cost.py} $out/creation-cost.py
          cp ${./specs/745-shared-publications/evidence/candidate.json} $out/creation-candidate.json
        '';
      # Release checks remain available independently of the command journeys.
      releaseVerification =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          # #326: verify a published release from its downloaded bytes —
          # sums, the stated model revision against the one the
          # conformance evidence is compiled against, archive members, and
          # the registration journey built from the archive's own flakes:
          # `nix run .#verify-release -- vX.Y.Z`.
          verifyRelease = pkgs.writeShellApplication {
            name = "verify-release";
            runtimeInputs = with pkgs; [
              bash
              python3
              # the bundle checks stamp a wrong commit with perl and, where
              # the runner allows it, run the bundle alone in a sandbox
              perl
              bubblewrap
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
              # the journey finds and stops its own development node
              procps
            ];
            text = ''
              export VERIFY_RELEASE_JOURNEY=${noPinScripts system}/no_pin_registration_journey.sh
              export VERIFY_RELEASE_CHAIN_VIEW=${noPinScripts system}/no_pin_chain_view.py
              export VERIFY_RELEASE_BINARY_CHECK=${./tools/check_release_binary.py}
              export VERIFY_RELEASE_MODEL_REVISION=${./conformance/model-revision}
              # #695: the platform bundles of a release that ships them
              export VERIFY_RELEASE_BUNDLE_CONF=${./tools/release_bundles.sh}
              export VERIFY_RELEASE_BUNDLE_VERIFIER=${./tools/verify_release_bundles.sh}
              export VERIFY_RELEASE_BUNDLE_SMOKE=${./tools/release_bundle_smoke.sh}
              export VERIFY_RELEASE_BUNDLE_CONTROLS=${./tools/release_bundle_smoke_controls.sh}
              export RELEASE_BUNDLE_SMOKE=${./tools/release_bundle_smoke.sh}
              bash ${./tools/verify_release.sh} "$@"
            '';
          };
        in
        {
          apps = {
            verify-release = {
              type = "app";
              meta.description = "Verify the release archive";
              program = pkgs.lib.getExe verifyRelease;
            };
            # #326: every refusal of verify-release by name — the published
            # v0.7.0 and mutated copies of an assembled release:
            # `nix run .#verify-release-controls -- RELEASE-DIR`.
            verify-release-controls = {
              type = "app";
              meta.description = "Run release archive verification controls";
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
                    jq
                  ];
                  text = ''VERIFY_RELEASE=${pkgs.lib.getExe verifyRelease} bash ${./tools/verify_release_controls.sh} "$@"'';
                }
              );
            };
            # The control needs the Nix daemon and real output derivations.
            release-build-control = {
              type = "app";
              meta.description = "Check release builds exclude development controls";
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
          };
        };

    in
    {
      packages = nixpkgs.lib.recursiveUpdate (each (
        system: packages system // { build-gate = buildGate system; }
      )) bundles;
      checks = each (system: {
        docs = (project system).check;
        release = (project system).releaseCheck;
        coverage = (coverage system).check;
        inventory = (inventory system).check;
      });
      apps = nixpkgs.lib.recursiveUpdate (each (
        system:
        (
          (project system).apps
          // (coverage system).apps
          // (inventory system).apps
          // (commandControls system)
          // (releaseVerification system).apps
          // (import ./nix/ci-apps.nix {
            pkgs = import nixpkgs { inherit system; };
            inherit offchain onchain system;
          })
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
                meta.description = "Check registry and application separation";
                program = pkgs.lib.getExe separationCheck;
              };
              application-separation-controls = {
                type = "app";
                meta.description = "Run registry and application separation controls";
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
              # #742: the registration journey and the refusals of the proved
              # design. One development network funds four wallets; the
              # release's packaged `singular` and `open-datum` create
              # registries, book, fold, reclaim and clean up registrations as
              # separate processes, each wallet in a directory and a home of its
              # own; the chain is read afterwards from the network's own record
              # by a program that takes nothing from any command, and each
              # assertion is shown failing on altered input. The refusals job
              # submits folds made wrong in one way through the test harness
              # no-pin-refusals and reads the node's answer. The release is the
              # deployment blueprint and the programs this flake packages, not a
              # build made for the job. The raw development network reads its
              # genesis from E2E_GENESIS_DIR explicitly, never from the working
              # directory. The scripts sit in one directory because the journeys
              # source the rig they share from beside themselves.
              noPinRuntime = [
                pkgs.bash
                pkgs.coreutils
                pkgs.diffutils
                pkgs.findutils
                pkgs.gawk
                pkgs.gnugrep
                pkgs.gnused
                pkgs.jq
                # the journeys stop their own node by the pids they recorded
                pkgs.procps
                # the chain view program is Python
                pkgs.python3Minimal
              ];
              noPinJourney =
                {
                  name,
                  results,
                  script,
                  programs,
                  extra ? [ ],
                }:
                pkgs.writeShellApplication {
                  inherit name;
                  runtimeInputs = noPinRuntime;
                  text = ''
                    set -euo pipefail
                    base="''${TMPDIR:-/tmp}"
                    mkdir -p "$base"
                    work="''${${results}:-$(mktemp -d "$base/${name}.XXXXXX")/results}"
                    echo "${name}: receipts in $work"
                    export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                    bash ${noPinScripts system}/${script} \
                      ${pkgs.lib.concatStringsSep " " programs} \
                      ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                      ${open-datum-onchain.packages.${system}.open-datum-blueprint} \
                      ${noPinScripts system}/no_pin_chain_view.py \
                      ${pkgs.lib.concatStringsSep " " extra} \
                      "$work"
                  '';
                };
              noPinRegistrationJourney = noPinJourney {
                name = "no-pin-registration-journey";
                results = "NO_PIN_JOURNEY_RESULTS";
                script = "no_pin_registration_journey.sh";
                programs = [
                  (pkgs.lib.getExe (stampedSingular system))
                  (pkgs.lib.getExe (stampedOpenDatum system))
                ];
              };
              noPinRegistrationRefusals = noPinJourney {
                name = "no-pin-registration-refusals";
                results = "NO_PIN_REFUSALS_RESULTS";
                script = "no_pin_registration_refusals.sh";
                programs = [ (pkgs.lib.getExe (stampedOpenDatum system)) ];
                extra = [ "${open-datum.packages.${system}.no-pin-refusals}/bin/no-pin-refusals" ];
              };
              noPinTerminationRefusals = noPinJourney {
                name = "no-pin-termination-refusals";
                results = "NO_PIN_TERMINATION_REFUSALS_RESULTS";
                script = "no_pin_termination_refusals.sh";
                programs = [ (pkgs.lib.getExe (stampedOpenDatum system)) ];
                extra = [ "${open-datum.packages.${system}.no-pin-refusals}/bin/no-pin-refusals" ];
              };
            in
            {
              no-pin-registration-journey = {
                type = "app";
                meta.description = "Run the registration journey on a development network";
                program = pkgs.lib.getExe noPinRegistrationJourney;
              };
              no-pin-registration-refusals = {
                type = "app";
                meta.description = "Check registration refusals on a development network";
                program = pkgs.lib.getExe noPinRegistrationRefusals;
              };
              no-pin-termination-refusals = {
                type = "app";
                meta.description = "Check termination refusals on a development network";
                program = pkgs.lib.getExe noPinTerminationRefusals;
              };
            }
          )
          // (
            let
              pkgs = import nixpkgs { inherit system; };
              # Both independent builds and the merged deployment must match
              # the producer-derived baseline after the declared removals.
              scriptHashComparison = pkgs.writeShellApplication {
                name = "script-hash-comparison";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.nix
                  pkgs.python3
                ];
                text = ''
                  set -euo pipefail
                  root="''${1:-$PWD}"
                  root=$(realpath -m "$root")
                  work=$(mktemp -d)
                  trap 'rm -rf "$work"' EXIT
                  nix build --quiet "$root/onchain#plutus-blueprint" -o "$work/registry"
                  nix build --quiet "$root/applications/open-datum/onchain#plutus-blueprint" -o "$work/application"
                  nix build --quiet "$root/applications/open-datum/onchain#open-datum-blueprint" -o "$work/merged"
                  python3 ${./tools/script_hash_comparison.py} \
                    --base "$root/specs/743-update-terminate-no-pin/evidence/onchain-removal-base.json" \
                    --record "$root/specs/743-update-terminate-no-pin/evidence/onchain-removals.json" \
                    --registry "$work/registry" --application "$work/application" \
                    --merged "$work/merged" \
                    --registry-manifest "$root/onchain/script-identity.json" \
                    --application-manifest "$root/applications/open-datum/onchain/script-identity.json"
                '';
              };
            in
            {
              script-hash-comparison = {
                type = "app";
                meta.description = "Compare registry and application script identities";
                program = pkgs.lib.getExe scriptHashComparison;
              };
            }
          )
        )
      )) bundleApps;
      # #278 terminal-attestation-permanent: the root development shell carries the pinned house
      # formatter — the exact Fourmolu the off-chain lock resolves, exposed
      # by the offchain flake — so `just format`, `just format-check` and
      # `just format-controls` (all inside `just ci`) run the one pinned
      # binary the lint checks run. No second version source.
      # #278: it also carries the pinned lint and format tools `just lint`
      # runs over every other code family (tools/lint_code.py).
      devShells = each (system: {
        default = (project system).shell.overrideAttrs (old: {
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
        });
      });
    };
}
