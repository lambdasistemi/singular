{
  description = "Registry off-chain — Haskell cage package";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
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
      url = "github:input-output-hk/iohk-nix/0ce7cc21b9a4cfde41871ef486d01a8fafbf9627";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url = "github:intersectmbo/cardano-haskell-packages/8479db771a3186eb326e42d8480eddc20a208275";
      flake = false;
    };
    # Pinned cardano-node, used as a subprocess by the devnet end-to-end
    # tests. Version tracks the upstream cardano-node-clients
    # devnet Dockerfile.
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
  };

  outputs =
    {
      self,
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

        # The commit this tree stands at, for `singular --version`: the one a
        # release archive states at its root (RELEASE-COMMIT, beside this
        # flake's directory: a file inside it would change the Haskell source
        # and miss the binary cache), else the revision of the git checkout
        # (marked dirty when it is), else unknown. Read only when a stamped
        # executable is built.
        commit =
          if builtins.pathExists ../RELEASE-COMMIT then
            pkgs.lib.removeSuffix "\n" (builtins.readFile ../RELEASE-COMMIT)
          else
            self.rev or (self.dirtyRev or "unknown");
        stamp = import ./nix/stamp-commit.nix { inherit pkgs; };
        singular = stamp {
          exe = components.exes.singular;
          program = "singular";
          inherit commit;
        };

        inherit (project.project.hsPkgs.singular-registry) components;

        # Recovery controllers run a separately configured whole package.
        # No ordinary package or released executable consumes this project.
        harnessProject = import ./nix/project.nix {
          inherit CHaP pkgs;
          testHarness = true;
        };
        harnessComponents = harnessProject.project.hsPkgs.singular-registry.components;

        # #264 T264-05 (epic answers A-005 and A-008/A-009/A-010): the
        # classified supported component carrier. EVERY declared Cabal
        # component is classified in ./nix/component-inventory.nix — built
        # here (the components the current required workflow commands and
        # the supported shipped registry commands consume, plus the library
        # and every test component), or explicitly unverified with its
        # owning issue. That file, and the manifest shipped in this build's
        # output, are the single authority for the complete row set; this
        # comment deliberately does not restate it. Every unverified
        # component stays declared and exported; nothing claims it works.
        # The classification's inventory gate runs inside this build and
        # fails it on an unclassified or unrecognized new stanza, a stale
        # row, a row without an issue/reason, or an empty set; a member
        # build failure fails the build the same way. Building a test
        # component compiles it and runs nothing. The green claim covers
        # exactly the classified members — never the whole package.
        componentBuild =
          let
            inventory = import ./nix/component-inventory.nix {
              inherit pkgs components;
            };
          in
          pkgs.symlinkJoin {
            name = "singular-registry-component-build";
            paths = inventory.memberPaths ++ [ inventory.inventoryGate ];
          };

        cardanoNode = cardano-node.packages.${system}.cardano-node;

        haskellChecks = import ./nix/checks.nix {
          inherit pkgs components;
          inherit (project.project) shell;
          inherit cardanoNode;
          ghc = project.project.pkg-set.config.ghc.package;
          namingBlueprint =
            ((import ../naming-onchain/flake.nix).outputs {
              inherit nixpkgs flake-utils;
            }).packages.${system}.plutus-blueprint;
          # The Singular state validator the builder rows judge their
          # transactions with: the blueprint built by the on-chain tree, and
          # the pinned identity manifest its hash is checked against.
          stateBlueprint =
            ((import ../onchain/flake.nix).outputs {
              inherit
                nixpkgs
                flake-utils
                haskellNix
                iohkNix
                ;
            }).packages.${system}.plutus-blueprint;
          stateScriptIdentity = ../onchain/script-identity.json;
        };

        # #278 terminal-attestation-permanent: the pinned house formatter. Fourmolu is resolved by the
        # locked dev-shell tool set; this extraction exposes exactly that
        # binary as a package, so the root format recipes, the root format
        # controls and this tree's lint check all run the one pinned
        # Fourmolu — no second version source, no drift. The match is
        # fail-closed: anything but exactly one Fourmolu tool in the shell
        # aborts evaluation.
        fourmoluTool =
          let
            matches = builtins.filter (
              p: builtins.match "fourmolu-exe-fourmolu-.*" (p.name or "") != null
            ) project.project.shell.nativeBuildInputs;
          in
          assert builtins.length matches == 1;
          builtins.head matches;

        haskellApps = import ./nix/apps.nix {
          inherit pkgs;
          checks = haskellChecks;
        };

        # #562 item 2: the pinned cabal the offchain shell carries, so the
        # build-graph wrappers run under the pinned toolchain without
        # entering a dev shell. Fail-closed on anything but one match.
        cabalTool =
          let
            matches = builtins.filter (
              p: builtins.match "cabal-install-exe-cabal-.*" (p.name or "") != null
            ) project.project.shell.nativeBuildInputs;
          in
          assert builtins.length matches == 1;
          builtins.head matches;

        # #562 item 2: the registry CLI build-graph check and its controls as
        # offchain flake apps. Each owns its scratch directory (mktemp with
        # trap cleanup, bounded to the run, no process stopped) and runs
        # from the checkout so the scripts' own layout still resolves. Setup
        # (downloading the package index, then fetching the pinned git
        # sources) exits 2, distinct from the verdict exit 1 the scripts use.
        # On a clean runner the setup owns its Cabal state: config and
        # package index under a named reusable cache in XDG_CACHE_HOME,
        # never $HOME/.config/cabal or $HOME/.cabal; the package lists are
        # downloaded before the solve (cabal solves against an empty index
        # otherwise); and the HTTPS download path is declared, its external
        # transport (curl) in the executables and the certificate bundle
        # exported.
        buildGraphRuntime = [
          cabalTool
          project.project.pkg-set.config.ghc.package
          pkgs.bash
          pkgs.bzip2
          pkgs.cacert
          pkgs.coreutils
          pkgs.curl
          pkgs.findutils
          pkgs.gawk
          pkgs.git
          pkgs.gnugrep
          pkgs.gnused
          pkgs.liburing
          pkgs.lmdb
          pkgs.lz4
          pkgs.ncurses
          pkgs.pkg-config
          pkgs.rocksdb
          pkgs.snappy
          pkgs.zlib
          pkgs.zstd
          pkgs.libblst
          pkgs.libsodium-vrf
          pkgs.secp256k1
        ];
        buildGraphSetup = ''
          if [ -f "offchain/singular-registry.cabal" ]; then src0="$PWD/offchain"; else src0="$PWD"; fi
          [ -f "$src0/singular-registry.cabal" ] || { echo "registry-cli-build-graph: no singular-registry.cabal under $src0" >&2; exit 2; }
          # The wrapper owns its scratch copy: the whole tree is copied
          # first, then the copied build outputs (dist-newstyle, dist,
          # result) are removed so the fetch below repopulates them inside
          # scratch; the live checkout is never read for build state nor
          # written. The trap removes scratch on success and on setup
          # failure alike. Every acquisition and population step maps its
          # failure to exit 2 (setup) with its diagnostic, never exit 1
          # (verdict, reserved for the scripts' own refusals).
          if ! work="$(mktemp -d)"; then
            echo "registry-cli-build-graph: setup failed creating the scratch directory (TMPDIR=''${TMPDIR:-unset})" >&2
            exit 2
          fi
          trap 'rm -rf "$work"' EXIT
          if ! mkdir -p "$work/copy"; then
            echo "registry-cli-build-graph: setup failed creating the scratch copy directory under $work" >&2
            exit 2
          fi
          if ! cp -a "$src0/." "$work/copy/"; then
            echo "registry-cli-build-graph: setup failed copying the tree to scratch" >&2
            exit 2
          fi
          if ! rm -rf "$work/copy/dist-newstyle" "$work/copy/dist" "$work/copy/result"; then
            echo "registry-cli-build-graph: setup failed removing copied build outputs in scratch" >&2
            exit 2
          fi
          src="$work/copy"
          export PKG_CONFIG_PATH="${pkgs.lib.getDev pkgs.ncurses}/lib/pkgconfig:${pkgs.lib.getDev pkgs.ncurses}/share/pkgconfig:${pkgs.lib.getDev pkgs.libblst}/lib/pkgconfig:${pkgs.lib.getDev pkgs.libblst}/share/pkgconfig:${pkgs.lib.getDev pkgs.libsodium-vrf}/lib/pkgconfig:${pkgs.lib.getDev pkgs.libsodium-vrf}/share/pkgconfig:${pkgs.lib.getDev pkgs.secp256k1}/lib/pkgconfig:${pkgs.lib.getDev pkgs.secp256k1}/share/pkgconfig:${pkgs.lib.getDev pkgs.zlib}/lib/pkgconfig:${pkgs.lib.getDev pkgs.zlib}/share/pkgconfig:${pkgs.lib.getDev pkgs.rocksdb}/lib/pkgconfig:${pkgs.lib.getDev pkgs.rocksdb}/share/pkgconfig:${pkgs.lib.getDev pkgs.bzip2}/lib/pkgconfig:${pkgs.lib.getDev pkgs.bzip2}/share/pkgconfig:${pkgs.lib.getDev pkgs.lz4}/lib/pkgconfig:${pkgs.lib.getDev pkgs.lz4}/share/pkgconfig:${pkgs.lib.getDev pkgs.snappy}/lib/pkgconfig:${pkgs.lib.getDev pkgs.snappy}/share/pkgconfig:${pkgs.lib.getDev pkgs.zstd}/lib/pkgconfig:${pkgs.lib.getDev pkgs.zstd}/share/pkgconfig:${pkgs.lib.getDev pkgs.lmdb}/lib/pkgconfig:${pkgs.lib.getDev pkgs.lmdb}/share/pkgconfig:${pkgs.lib.getDev pkgs.liburing}/lib/pkgconfig:${pkgs.lib.getDev pkgs.liburing}/share/pkgconfig''${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
          # The app owns its Cabal state: config and package index live in a
          # named reusable cache directory under XDG_CACHE_HOME (or
          # HOME/.cache when unset), never in $HOME/.config/cabal or
          # $HOME/.cabal; a warm copy makes the index bootstrap incremental,
          # a fresh one downloads it whole. The certificate bundle is
          # exported for the transport curl and the git fetches alike.
          cache_root="''${XDG_CACHE_HOME:-''${HOME:+$HOME/.cache}}"
          [ -n "''${cache_root:-}" ] || {
            echo "registry-cli-build-graph: no cache location: set XDG_CACHE_HOME or HOME" >&2
            exit 2
          }
          if ! mkdir -p "$cache_root/singular-registry-build-graph-cabal"; then
            echo "registry-cli-build-graph: setup failed creating the cabal download cache directory" >&2
            exit 2
          fi
          export CABAL_DIR="$cache_root/singular-registry-build-graph-cabal"
          export CURL_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          export GIT_SSL_CAINFO="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          # On a clean runner cabal solves against an empty index unless the
          # package lists are downloaded first (hackage and the project's
          # cardano-haskell-packages repository alike); a warm cache makes
          # this a fast incremental check.
          if ! (cd "$src" && cabal update); then
            echo "registry-cli-build-graph: setup failed updating the package index (cabal update)" >&2
            exit 2
          fi
          if ! out="$(cd "$src" && cabal build --dry-run all 2>&1)"; then
            echo "registry-cli-build-graph: setup failed fetching the pinned git sources and the package index (cabal build --dry-run all)" >&2
            printf '%s\n' "$out" >&2
            exit 2
          fi
        '';
        registryCliBuildGraphCheckApp = pkgs.writeShellApplication {
          name = "registry-cli-build-graph-check";
          runtimeInputs = buildGraphRuntime;
          text = buildGraphSetup + ''
            bash "$src/nix/registry-cli-build-graph-check.sh" "$src"
          '';
        };
        registryCliBuildGraphControlsApp = pkgs.writeShellApplication {
          name = "registry-cli-build-graph-controls";
          runtimeInputs = buildGraphRuntime;
          text = buildGraphSetup + ''
            bash "$src/nix/registry-cli-build-graph-controls.sh" "$src"
          '';
        };

        # A standalone development node for commands and their test harnesses.
        devnet =
          pkgs.runCommand "devnet"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.devnet.meta or { }) // {
                mainProgram = "devnet";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.devnet} $out/bin/devnet \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # #326: the backend contract suite over every adapter, wrapped so it
        # brings the locked cardano-node for the devnet nodes it generates.
        contract-tests =
          pkgs.runCommand "contract-tests"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.tests.contract-tests.meta or { }) // {
                mainProgram = "contract-tests";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.tests.contract-tests} $out/bin/contract-tests \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # #326 R5: the external leg. A devnet started as a process of its own
        # funds a fresh key; the contract suite then reaches that node only
        # by the private probe socket in the devnet settings, magic and key.
        # This is retained private legacy characterization, not the shipping
        # Koios constructor or row16 production-deletion evidence.
        contract-external = pkgs.writeShellApplication {
          name = "contract-external";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.jq
            devnet
            contract-tests
          ];
          text = builtins.readFile ./contract-test/external.sh;
        };

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
          # Recording modes are read-only. The explicit private confirmation
          # smoke submits generated-fixture key payments on the private node.
          local-services-record =
            pkgs.runCommand "local-services-record"
              {
                nativeBuildInputs = [ pkgs.makeWrapper ];
                meta.mainProgram = "local-services-record";
              }
              ''
                mkdir -p $out/bin
                makeWrapper ${pkgs.lib.getExe components.exes.local-services-record} $out/bin/local-services-record \
                  --prefix PATH : ${cardanoNode}/bin
              '';
          # #264 T264-05: the classified supported off-chain component build
          # carrier (epic answer A-005; classification and inventory gate in
          # ./nix/component-inventory.nix). CI builds it with
          # `nix build --quiet .#component-build` from offchain.
          component-build = componentBuild;
          # Generated Haddock reference for the library, consumed by the
          # root documentation build. Same source tree, same lock: the docs
          # manifest can bind the reference to this candidate's content.
          #
          # A-003: Haddock documents exposed modules only by default, but
          # the generated API reference requires a module page and a
          # source page for EVERY module the public library stanza
          # declares — including the fold owners #267 keeps in
          # `other-modules` behind the unchanged six-export facade.
          # Two flags make that happen without exposing a public import
          # path: Cabal's `--internal` hands the non-exposed modules to
          # Haddock (the g13 probe showed their source pages appear), and
          # `--haddock-option=--show-all` cancels Haddock's hide
          # attribute for the run — haddock-api 2.32 documents `show-all`
          # as "behave as if no modules have the hide attribute", which is
          # why `--internal` alone emitted source pages but no module
          # pages. The flags are scoped to this documentation package
          # alone, through a project that only appends them as an extra
          # package module on the args-level modules list: every build
          # output below keeps the untouched closure.
          library-haddock =
            (project.project.appendModule {
              modules = [
                {
                  packages.singular-registry.setupHaddockFlags = [
                    "--internal"
                    "--haddock-option=--show-all"
                  ];
                }
              ];
            }).hsPkgs.singular-registry.components.library.haddock;
          # The root reference takes only Ledger/Provider page pairs from
          # their public local-services owner; private Node pages stay out.
          local-services-haddock = components.sublibs.local-services.haddock;
          inherit test-vectors test-vectors-json;
          # The generic development node remains available to command journeys.
          inherit devnet;
          # #326: the contract suite and its external leg.
          inherit contract-tests contract-external;
          # #299: the packaged `singular registry` commands. It reaches a
          # node through the socket its caller names and spawns none, so it
          # needs no cardano-node on its PATH.
          inherit singular;
          # The same executable before the commit is stamped into a copy of
          # it: the cached Haskell build, for consumers that stamp their own.
          singular-unstamped = components.exes.singular;
          # The development node launcher before the wrapper that puts the
          # locked cardano-node on its PATH: the release bundle carries this
          # executable and the node beside it.
          devnet-unwrapped = components.exes.devnet;
          # #641: a test-harness tool the packaged bundle control seals its
          # devnet keys with; never evidence of anything.
          inherit (components.exes) vault-seal;
          singular-test-harness = harnessComponents.exes.singular;
          # #326 R4: a SignedTx is constructible only through signTx.
          inherit (haskellChecks) signed-tx-control;
          # #278 terminal-attestation-permanent: the pinned house formatter, for the root format
          # recipes and controls (same locked tool as the lint check).
          fourmolu = fourmoluTool;
          # Mechanical adapter (D-008): exposes the cardano-node already
          # locked as this flake's input, so the devnet recipe consumes the
          # locked identity instead of re-resolving a remote tag.
          inherit (cardano-node.packages.${system}) cardano-node;
        };

        # vectors-freshness was deleted from ./nix/checks.nix (break 5,
        # D-003): the golden lives in the onchain tree, outside this
        # flake root. The procedure lives in ./justfile (vectors-check).
        checks = builtins.removeAttrs haskellChecks [ "apps" ];

        apps = haskellApps // {
          # #326.
          contract-tests = {
            type = "app";
            meta.description = "Run the command contract tests";
            program = pkgs.lib.getExe contract-tests;
          };
          contract-external = {
            type = "app";
            meta.description = "Run external command contract checks";
            program = pkgs.lib.getExe contract-external;
          };
          # #299.
          singular = {
            type = "app";
            meta.description = "Run the Singular registry command line";
            program = pkgs.lib.getExe singular;
          };
          # #562 item 2: the registry CLI build-graph check and its controls.
          registry-cli-build-graph-check = {
            type = "app";
            meta.description = "Check the registry command build graph";
            program = pkgs.lib.getExe registryCliBuildGraphCheckApp;
          };
          registry-cli-build-graph-controls = {
            type = "app";
            meta.description = "Run registry command build graph controls";
            program = pkgs.lib.getExe registryCliBuildGraphControlsApp;
          };
        };

        devShells = {
          inherit (project.devShells) default;
        };
      }
    );
}
