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
      dev-assets-playwright,
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
                for state_root in "$source/registry" "$source/registry-rolled-back"; do
                  if [ ! -d "$state_root" ]; then
                    note "absent state root: ''${state_root#"$source"/}"
                    continue
                  fi
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
                done
                note "managed: state_roots=$managed_roots journals=$managed_journals signed_bodies=$managed_bodies"
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
          # The cross-wallet case census now lives in the partition discovery app below.
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
            program = pkgs.lib.getExe (stampedSingular system);
          };
          open-datum = {
            type = "app";
            program = pkgs.lib.getExe (stampedOpenDatum system);
          };
          # #695: the bundles of a published release, downloaded without
          # credentials and checked on this platform against the commit the tag
          # names: `nix run .#verify-release-bundles -- vX.Y.Z COMMIT`. The
          # variable names a directory of already downloaded assets instead.
          verify-release-bundles = {
            type = "app";
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
            cp ${./tools/demo1_closed_journey.sh} $out/demo1_closed_journey.sh
            cp ${./tools/demo1_cli_create_race.sh} $out/demo1_cli_create_race.sh
            cp ${./tools/demo1_cli_one_output_create.sh} $out/demo1_cli_one_output_create.sh
            cp ${./tools/registry_bundle_control.sh} $out/registry_bundle_control.sh
            cp ${./tools/demo1_cli_prepare_funding.sh} $out/demo1_cli_prepare_funding.sh
            cp ${./tools/cli_recovery_receipt_cap.test.sh} $out/cli_recovery_receipt_cap.test.sh
          '';
          # #707: the ordinary tools the bundle journey runs on, and nothing
          # else: the PATH of a user who has no Nix
          bundleJourneyTools = pkgs.buildEnv {
            name = "demo1-bundle-journey-tools";
            paths =
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
                jq
                procps
              ]
              # the journey watches which files a command opens and locks its state
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                pkgs.strace
                pkgs.util-linux
              ];
          };
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
            two-requests = "two-requests trie-capability";
          };
          cliRecoveryPartitionNames = {
            history = "accepting, lost-answer, killed, never-sent and whole-journal with trie observations";
            rollback = "restored node rollback (rollback trie-capability)";
            two-requests = "interrupted two-request fold with trie observations";
          };
          # #451 re-cut: the shared collector derivation, exposed as an
          # app; its buildable package form lives in packages.
          cliRecoveryEvidence = (recoveryTools system).evidence;
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
                  jq -c -n --argjson parts "$staticParts" --argjson names "$staticNames" --arg holds "$holds" '
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
          verifyRelease =
            journey:
            pkgs.writeShellApplication {
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
                export VERIFY_RELEASE_JOURNEY=${managedScripts}/${journey}
                export VERIFY_RELEASE_BINARY_CHECK=${./tools/check_release_binary.py}
                export DEMO1_CREATE_RACE=${managedScripts}/demo1_cli_create_race.sh
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
          verify-release = {
            type = "app";
            program = pkgs.lib.getExe (verifyRelease "demo1_cli_journey.sh");
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
                text = ''VERIFY_RELEASE=${pkgs.lib.getExe (verifyRelease "demo1_cli_journey.sh")} bash ${./tools/verify_release_controls.sh} "$@"'';
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
                  DEMO1_VERIFY_RELEASE=${pkgs.lib.getExe (verifyRelease "demo1_cli_journey.sh")} bash ${./tools/demo1_cli_check.sh} "$PWD"
                '';
              }
            );
          };
          # #707: the Demo 1 journey from the unpacked Linux release bundle
          # alone: `singular`, `open-datum` and the development node come out
          # of the tarball, on a PATH that holds ordinary tools and no Nix.
          # Nix only builds the bundle beforehand; the blueprint is the bundle's.
          # Run from the repository root: `nix run --quiet .#demo1-bundle-journey`.
          demo1-bundle-journey = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-bundle-journey";
                runtimeInputs = [
                  pkgs.coreutils
                  pkgs.nix
                ];
                text = ''
                  bundle="$(nix build --quiet --no-link --print-out-paths .#release-bundle)"
                  tarball="$(ls "$bundle"/singular-*-${system}.tar.gz)"
                  DEMO1_JOURNEY=${managedScripts}/demo1_cli_journey.sh \
                    DEMO1_BUNDLE_TOOLS=${bundleJourneyTools}/bin \
                    bash ${./tools/demo1_bundle_journey.sh} "$tarball"
                '';
              }
            );
          };
          # #660: the closed-datum journey from the extracted release archive,
          # run as separate `singular` and `open-datum` processes on one
          # development node. Run from the repository root:
          # `nix run --quiet .#demo1-closed-check`.
          demo1-closed-check = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-closed-check";
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
                  DEMO1_VERIFY_RELEASE=${pkgs.lib.getExe (verifyRelease "demo1_closed_journey.sh")} bash ${./tools/demo1_closed_check.sh} "$PWD"
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
                    DEMO1_VERIFY_RELEASE=${pkgs.lib.getExe (verifyRelease "demo1_cli_journey.sh")} \
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
                    ${pkgs.lib.getExe (stampedSingular system)} \
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
                    ${pkgs.lib.getExe (stampedSingular system)} \
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
          # #406 slice 2: Carol funds a fresh wallet with one ada-only output
          # and runs create on its own fresh devnet with no state carrier
          # anywhere: `nix run --quiet .#demo1-cli-one-output-create`.
          demo1-cli-one-output-create = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-cli-one-output-create";
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
                  util-linux
                ];
                text = ''
                  base="''${REGISTRY_JOURNEY_ROOT:-''${TMPDIR:-/tmp}/singular-one-output}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/run.XXXXXX")/one-output"
                  echo "one-output create: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  root="$PWD"
                  [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
                    echo "demo1-cli-one-output-create: run from the repository root" >&2
                    exit 3
                  }
                  open_datum_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")" || exit 3
                  open_datum="$open_datum_out/bin/open-datum"
                  singular_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#singular")" || exit 3
                  singular="$singular_out/bin/singular"
                  devnet_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#devnet")" || exit 3
                  devnet="$devnet_out/bin/devnet"
                  deployment_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")" || exit 3
                  [ -f "$deployment_bp" ] || {
                    echo "demo1-cli-one-output-create: no deployment blueprint" >&2
                    exit 3
                  }
                  bash ${managedScripts}/demo1_cli_one_output_create.sh "$singular" "$open_datum" "$devnet" "$deployment_bp" "$work"
                '';
              }
            );
          };
          # #641: the registry writes' staged signers on a fresh devnet, by
          # the packaged commands: a create signed elsewhere, a fold from
          # the vault, a pending bundle stopping a second create, and an
          # unsent fold bundle reported dead past its deadline:
          # `nix run --quiet .#registry-bundle-control`.
          registry-bundle-control = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "registry-bundle-control";
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
                  util-linux
                ];
                text = ''
                  base="''${REGISTRY_JOURNEY_ROOT:-''${TMPDIR:-/tmp}/singular-bundles}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/run.XXXXXX")/bundles"
                  echo "bundle control: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  root="$PWD"
                  [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
                    echo "registry-bundle-control: run from the repository root" >&2
                    exit 3
                  }
                  open_datum_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")" || exit 3
                  open_datum="$open_datum_out/bin/open-datum"
                  singular_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#singular")" || exit 3
                  singular="$singular_out/bin/singular"
                  devnet_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#devnet")" || exit 3
                  devnet="$devnet_out/bin/devnet"
                  # a test-harness tool: it seals the devnet keys into vaults
                  vault_seal_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#vault-seal")" || exit 3
                  vault_seal="$vault_seal_out/bin/vault-seal"
                  deployment_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")" || exit 3
                  [ -f "$deployment_bp" ] || {
                    echo "registry-bundle-control: no deployment blueprint" >&2
                    exit 3
                  }
                  bash ${managedScripts}/registry_bundle_control.sh "$singular" "$open_datum" "$devnet" "$vault_seal" "$deployment_bp" "$root/version.txt" "$work"
                '';
              }
            );
          };
          # #491 remainder pull request 1: Carol prepares a funding output when
          # none suits, on its own fresh devnet from a one-output wallet:
          # `nix run --quiet .#demo1-cli-prepare-funding`.
          demo1-cli-prepare-funding = {
            type = "app";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "demo1-cli-prepare-funding";
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
                  jq
                  nix
                  procps
                  util-linux
                ];
                text = ''
                  base="''${REGISTRY_JOURNEY_ROOT:-''${TMPDIR:-/tmp}/singular-prepare-funding}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/run.XXXXXX")/prepare-funding"
                  echo "prepare funding: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  root="$PWD"
                  [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
                    echo "demo1-cli-prepare-funding: run from the repository root" >&2
                    exit 3
                  }
                  open_datum_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")" || exit 3
                  open_datum="$open_datum_out/bin/open-datum"
                  singular_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#singular")" || exit 3
                  singular="$singular_out/bin/singular"
                  devnet_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#devnet")" || exit 3
                  devnet="$devnet_out/bin/devnet"
                  deployment_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")" || exit 3
                  [ -f "$deployment_bp" ] || {
                    echo "demo1-cli-prepare-funding: no deployment blueprint" >&2
                    exit 3
                  }
                  bash ${managedScripts}/demo1_cli_prepare_funding.sh "$singular" "$open_datum" "$devnet" "$deployment_bp" "$work"
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
          # The portable collector — the hosted gate runs the census app, the
          # per-partition matrix and the collector app per matrix job.
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
      packages = nixpkgs.lib.recursiveUpdate (each (
        system: packages system // { build-gate = buildGate system; }
      )) bundles;
      checks = each (system: {
        docs = (project system).check;
        release = (project system).releaseCheck;
        model = (model system).check;
        simulator = (simulator system).check;
        browser = (browser system).check;
        coverage = (coverage system).check;
        inventory = (inventory system).check;
      });
      apps = nixpkgs.lib.recursiveUpdate (each (
        system:
        (
          (project system).apps
          // (model system).apps
          // (simulator system).apps
          // (browser system).apps
          // (coverage system).apps
          // (inventory system).apps
          // (demo1 system)
          // (import ./nix/demo1-rehearsal.nix {
            pkgs = import nixpkgs { inherit system; };
            rehearsal = ./demo1/rehearsal;
          })
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
                      SINGULAR_UNFAULTED=${pkgs.lib.getExe (stampedSingular system)} \
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
              # #730: the forged-pins journey. One raw development node funds
              # one wallet; the test harness (the open-datum package's forged-registry,
              # never a product command) boots a registry whose datum pins an
              # always-true active policy and mints a token named after a key
              # under it; the packaged `singular` and `open-datum` are run as
              # separate processes against it and must refuse it with the
              # refusal that names the active policy, show nothing of the
              # registry and add no transaction to a chain read from the
              # facade's own record; the same commands proceed on a registry
              # made the same way with the honest pin; two folds are the
              # evidence for the on-chain hardening; a fold that swaps a pin is
              # refused by the node; each assertion is shown failing on altered
              # input. The raw devnet reads its genesis from E2E_GENESIS_DIR
              # explicitly, never from the working directory.
              forgedPinsCheck = pkgs.writeShellApplication {
                name = "forged-pins-check";
                runtimeInputs = [
                  pkgs.bash
                  pkgs.coreutils
                  pkgs.gawk
                  pkgs.gnugrep
                  pkgs.jq
                  pkgs.nix
                  # the journey stops its own node by the pids it recorded
                  pkgs.procps
                  # the journey reads the chain's record through the reader
                  # view program, which is Python
                  pkgs.python3Minimal
                ];
                text = ''
                  set -euo pipefail
                  root="''${FORGED_PINS_CHECK_ROOT:-$PWD}"
                  [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
                    echo "forged-pins-check: run from the repository root (or set FORGED_PINS_CHECK_ROOT)" >&2
                    exit 3
                  }
                  base="''${TMPDIR:-''${XDG_CACHE_HOME:-$HOME/.cache}/singular-forged-pins}"
                  mkdir -p "$base"
                  work="$(mktemp -d "$base/run.XXXXXX")/journey"
                  echo "forged-pins-check: receipts in $work"
                  export E2E_GENESIS_DIR=${./offchain/e2e-test/genesis}
                  open_datum_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#open-datum")" || exit 3
                  open_datum="$open_datum_out/bin/open-datum"
                  [ -x "$open_datum" ] || {
                    echo "forged-pins-check: no open-datum binary in $open_datum_out" >&2
                    exit 3
                  }
                  harness_out="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/offchain#forged-registry")" || exit 3
                  harness="$harness_out/bin/forged-registry"
                  [ -x "$harness" ] || {
                    echo "forged-pins-check: no harness binary in $harness_out" >&2
                    exit 3
                  }
                  vault_seal_out="$(nix build --quiet --no-link --print-out-paths "$root/offchain#vault-seal")" || exit 3
                  vault_seal="$vault_seal_out/bin/vault-seal"
                  [ -x "$vault_seal" ] || {
                    echo "forged-pins-check: no vault-seal binary in $vault_seal_out" >&2
                    exit 3
                  }
                  # The deployment blueprint unions the application and the
                  # witnesses in one build: the document both programs get as
                  # --blueprint.
                  deployment_bp="$(nix build --quiet --no-link --print-out-paths "$root/applications/open-datum/onchain#open-datum-blueprint")" || exit 3
                  [ -f "$deployment_bp" ] || {
                    echo "forged-pins-check: the deployment blueprint build produced no file" >&2
                    exit 3
                  }
                  bash ${./tools/forged_pins_journey.sh} \
                    ${pkgs.lib.getExe (stampedSingular system)} \
                    "$open_datum" \
                    "$harness" \
                    ${pkgs.lib.getExe offchain.packages.${system}.devnet} \
                    "$vault_seal" \
                    "$deployment_bp" \
                    "$root/version.txt" \
                    ${./tools/forged_pins_reader_view.py} \
                    "$work"
                '';
              };
            in
            {
              forged-pins-check = {
                type = "app";
                program = pkgs.lib.getExe forgedPinsCheck;
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
              # base set recorded in base-hashes.json plus exactly the
              # declared closed titles — every base hash byte-identical,
              # each declared hash read from the application identity
              # manifest (one place, tied to the build by the identity job).
              # Titles are compared modulo the module path
              # (the first segment), so a move that renames only the module
              # path is tolerated while a changed hash, a missing validator
              # and an extra validator all fail. A declared title equal to a
              # base title must not hide it. The plants below run on
              # every invocation: a changed base hash, a missing base
              # validator (both selected by title), a collision, an
              # undeclared extra validator, and a moved declared hash must
              # each be refused, naming the validator — a comparison
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
                  declared="$root/specs/650-closed-datum/evidence/declared-additions.json"
                  manifest="$root/applications/open-datum/onchain/script-identity.json"
                  [ -f "$declared" ] || {
                    echo "script-hash-comparison: no declared-additions.json under $root" >&2
                    exit 2
                  }
                  [ -f "$manifest" ] || {
                    echo "script-hash-comparison: no application script-identity.json under $root" >&2
                    exit 2
                  }
                  jq -e '.titles | length == 3' "$declared" >/dev/null || {
                    echo "script-hash-comparison: declared additions must name exactly three titles" >&2
                    exit 1
                  }
                  jq -e '[.titles[] | select(startswith("open_datum."))] | length == 3' "$declared" >/dev/null || {
                    echo "script-hash-comparison: declared titles must start with open_datum." >&2
                    exit 1
                  }
                  if jq -r -n --slurpfile b "$base" --slurpfile d "$declared" '($b[0].validators | map(.title)) as $bt | ($d[0].titles[]) as $t | select($bt | index($t)) | $t' | grep -q .; then
                    echo "script-hash-comparison: a declared title equals a base title and must not hide it" >&2
                    exit 1
                  fi
                  jq -n --slurpfile b "$base" --slurpfile d "$declared" --slurpfile m "$manifest" '($b[0]) as $bb | ($d[0].titles) as $dt | ($m[0].validators | map({key: .title, value: .hash}) | from_entries) as $mh | {validators: ($bb.validators + [$dt[] | {title: ., hash: $mh[.] | select(. != null)}])} | select(.validators | length == ($bb.validators | length) + 3) | .' >"$work/expected.json" || {
                    echo "script-hash-comparison: could not build the expected set (a declared title has no hash in the identity manifest)" >&2
                    exit 1
                  }
                  [ -f "$work/expected.json" ] || {
                    echo "script-hash-comparison: expected set missing (a declared hash is absent from the manifest)" >&2
                    exit 1
                  }
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
                  if ! compare "$work/expected.json" "$work/union.json" >"$work/live.log" 2>&1; then
                    echo "script-hash-comparison: union differs from the expected set:" >&2
                    cat "$work/live.log" >&2
                    exit 1
                  fi
                  echo "script-hash-comparison: OK — $(jq '.validators | length' "$work/union.json") union validators equal the expected set (base $(jq '.validators | length' "$base") + 3 declared = $(jq '.validators | length' "$work/expected.json"), compiler $base_compiler)"
                  jq -r '.validators | sort_by(.title) | .[] | "\(.title) \(.hash)"' "$work/union.json"
                  jq '(.validators |= map(if .title == "state.state.spend" then .hash = "00000000000000000000000000000000000000000000000000000000" else . end))' "$work/union.json" >"$work/plant-changed.json"
                  jq -e '[.validators[] | select(.title == "state.state.spend" and .hash == "00000000000000000000000000000000000000000000000000000000")] | length == 1' "$work/plant-changed.json" >/dev/null || {
                    echo "script-hash-comparison: changed-hash plant did not apply to state.state.spend" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-changed.json" >"$work/plant-changed.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the changed-hash plant" >&2
                    exit 1
                  fi
                  grep -q 'moved' "$work/plant-changed.log" || {
                    echo "script-hash-comparison: changed-hash plant refused without naming the moved validator:" >&2
                    cat "$work/plant-changed.log" >&2
                    exit 1
                  }
                  grep -q 'state\.state\.spend\|state\.spend' "$work/plant-changed.log" || {
                    echo "script-hash-comparison: changed-hash plant refused without naming state.state.spend:" >&2
                    cat "$work/plant-changed.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: changed-hash plant refused" >&2
                  jq '.validators |= map(select(.title != "state.state.spend"))' "$work/union.json" >"$work/plant-missing.json"
                  jq -e '[.validators[] | select(.title == "state.state.spend")] | length == 0' "$work/plant-missing.json" >/dev/null || {
                    echo "script-hash-comparison: missing-validator plant did not apply to state.state.spend" >&2
                    exit 2
                  }
                  [ "$(jq '.validators | length' "$work/plant-missing.json")" = "$(($(jq '.validators | length' "$work/union.json") - 1))" ] || {
                    echo "script-hash-comparison: missing-validator plant did not apply" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-missing.json" >"$work/plant-missing.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the missing-validator plant" >&2
                    exit 1
                  fi
                  # S5-1d-r2: the missing row fails pre-map on raw-count
                  # equality (16 vs 17) before any map exists; that count
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
                  # exercise on the current 17-row subject.
                  jq '.validators += [{"title": "alternate.open_datum.mint", "hash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff", "compiledCode": "00"}]' "$work/union.json" >"$work/plant-collision.json"
                  [ "$(jq '.validators | length' "$work/plant-collision.json")" = "$(($(jq '.validators | length' "$work/union.json") + 1))" ] || {
                    echo "script-hash-comparison: collision plant did not apply" >&2
                    exit 2
                  }
                  grep -q 'alternate.open_datum.mint' "$work/plant-collision.json" || {
                    echo "script-hash-comparison: collision plant title missing" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-collision.json" >"$work/plant-collision.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the collision plant" >&2
                    exit 1
                  fi
                  grep -Eq 'ambiguous|count mismatch|not in the base' "$work/plant-collision.log" || {
                    echo "script-hash-comparison: collision plant refused without naming the collision:" >&2
                    cat "$work/plant-collision.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: collision plant refused" >&2
                  jq '(.validators |= map(select(.title != "state.state.spend")) + [{"title": "open_datum.undeclared.mint", "hash": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "compiledCode": "00"}])' "$work/union.json" >"$work/plant-undeclared.json"
                  [ "$(jq '.validators | length' "$work/plant-undeclared.json")" = "$(jq '.validators | length' "$work/union.json")" ] || {
                    echo "script-hash-comparison: undeclared-extra plant did not apply" >&2
                    exit 2
                  }
                  grep -q 'open_datum.undeclared.mint' "$work/plant-undeclared.json" || {
                    echo "script-hash-comparison: undeclared-extra plant title missing" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-undeclared.json" >"$work/plant-undeclared.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the undeclared-extra plant" >&2
                    exit 1
                  fi
                  grep -q 'open_datum.undeclared.mint\|undeclared.mint' "$work/plant-undeclared.log" || {
                    echo "script-hash-comparison: undeclared-extra plant refused without naming it:" >&2
                    cat "$work/plant-undeclared.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: undeclared-extra plant refused" >&2
                  jq '(.validators |= map(if .title == "open_datum.closed_datum.mint" then .hash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff" else . end))' "$work/union.json" >"$work/plant-declared-moved.json"
                  jq -e '[.validators[] | select(.title == "open_datum.closed_datum.mint" and .hash == "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff")] | length == 1' "$work/plant-declared-moved.json" >/dev/null || {
                    echo "script-hash-comparison: declared-moved plant did not apply to open_datum.closed_datum.mint" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-declared-moved.json" >"$work/plant-declared-moved.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the declared-moved plant" >&2
                    exit 1
                  fi
                  grep -q 'moved' "$work/plant-declared-moved.log" || {
                    echo "script-hash-comparison: declared-moved plant refused without naming the moved validator:" >&2
                    cat "$work/plant-declared-moved.log" >&2
                    exit 1
                  }
                  grep -q 'closed_datum.mint' "$work/plant-declared-moved.log" || {
                    echo "script-hash-comparison: declared-moved plant refused without naming open_datum.closed_datum.mint:" >&2
                    cat "$work/plant-declared-moved.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: declared-moved plant refused" >&2
                  # S5.2: the deployment blueprint itself. Built in the
                  # application's onchain flake from the same two trees
                  # (jq merge, preamble from the registry's), it must equal
                  # the expected set exactly and carry byte-identical
                  # compiledCode for all 17 validators — the pairing
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
                  if ! compare "$work/expected.json" "$merged_bp" >"$work/merged.log" 2>&1; then
                    echo "script-hash-comparison: merged blueprint differs from the expected set:" >&2
                    cat "$work/merged.log" >&2
                    exit 1
                  fi
                  echo "script-hash-comparison: OK — merged deployment blueprint equals the expected set ($(jq '.validators | length' "$merged_bp") validators, compiler $base_compiler)"
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
                  jq '(.validators |= map(if .title == "state.state.spend" then .hash = "00000000000000000000000000000000000000000000000000000000" else . end))' "$merged_bp" >"$work/plant-merged-changed.json"
                  jq -e '[.validators[] | select(.title == "state.state.spend" and .hash == "00000000000000000000000000000000000000000000000000000000")] | length == 1' "$work/plant-merged-changed.json" >/dev/null || {
                    echo "script-hash-comparison: merged changed-hash plant did not apply to state.state.spend" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-merged-changed.json" >"$work/plant-merged-changed.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the merged changed-hash plant" >&2
                    exit 1
                  fi
                  grep -q 'moved' "$work/plant-merged-changed.log" || {
                    echo "script-hash-comparison: merged changed-hash plant refused without naming the moved validator:" >&2
                    cat "$work/plant-merged-changed.log" >&2
                    exit 1
                  }
                  grep -q 'state\.state\.spend\|state\.spend' "$work/plant-merged-changed.log" || {
                    echo "script-hash-comparison: merged changed-hash plant refused without naming state.state.spend:" >&2
                    cat "$work/plant-merged-changed.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: merged changed-hash plant refused" >&2
                  jq '(.validators |= map(select(.title != "state.state.spend")) + [{"title": "open_datum.undeclared.mint", "hash": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "compiledCode": "00"}])' "$merged_bp" >"$work/plant-merged-undeclared.json"
                  [ "$(jq '.validators | length' "$work/plant-merged-undeclared.json")" = "$(jq '.validators | length' "$merged_bp")" ] || {
                    echo "script-hash-comparison: merged undeclared-extra plant did not apply" >&2
                    exit 2
                  }
                  grep -q 'open_datum.undeclared.mint' "$work/plant-merged-undeclared.json" || {
                    echo "script-hash-comparison: merged undeclared-extra plant did not apply" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-merged-undeclared.json" >"$work/plant-merged-undeclared.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the merged undeclared-extra plant" >&2
                    exit 1
                  fi
                  grep -q 'open_datum.undeclared.mint\|undeclared.mint' "$work/plant-merged-undeclared.log" || {
                    echo "script-hash-comparison: merged undeclared-extra plant refused without naming it:" >&2
                    cat "$work/plant-merged-undeclared.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: merged undeclared-extra plant refused" >&2
                  jq '(.validators |= map(if .title == "open_datum.closed_datum.mint" then .hash = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff" else . end))' "$merged_bp" >"$work/plant-merged-declared-moved.json"
                  jq -e '[.validators[] | select(.title == "open_datum.closed_datum.mint" and .hash == "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff")] | length == 1' "$work/plant-merged-declared-moved.json" >/dev/null || {
                    echo "script-hash-comparison: merged declared-moved plant did not apply" >&2
                    exit 2
                  }
                  if compare "$work/expected.json" "$work/plant-merged-declared-moved.json" >"$work/plant-merged-declared-moved.log" 2>&1; then
                    echo "script-hash-comparison: MISSED the merged declared-moved plant" >&2
                    exit 1
                  fi
                  grep -q 'moved' "$work/plant-merged-declared-moved.log" || {
                    echo "script-hash-comparison: merged declared-moved plant refused without naming the moved validator:" >&2
                    cat "$work/plant-merged-declared-moved.log" >&2
                    exit 1
                  }
                  grep -q 'closed_datum.mint' "$work/plant-merged-declared-moved.log" || {
                    echo "script-hash-comparison: merged declared-moved plant refused without naming open_datum.closed_datum.mint:" >&2
                    cat "$work/plant-merged-declared-moved.log" >&2
                    exit 1
                  }
                  echo "script-hash-comparison: merged declared-moved plant refused" >&2
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
      )) bundleApps;
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
