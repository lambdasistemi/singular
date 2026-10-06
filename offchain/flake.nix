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

        inherit (project.project.hsPkgs.singular-registry) components;

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

        # The bounded journey runner (D-012). A Nix-built binary —
        # haskell.nix resolves every dependency, so a clean runner
        # needs no cabal, no package index and no warm state (D-011)
        # — wrapped so it brings the locked cardano-node on its own
        # PATH, exactly like cage-tests-e2e in ./nix/checks.nix.
        # The blueprint and the identity manifest come from the
        # caller at run time (REGISTRY_BLUEPRINT, REGISTRY_SCRIPT_IDENTITY);
        # no store path is baked in.
        journey =
          pkgs.runCommand "journey"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.journey.meta or { }) // {
                mainProgram = "journey";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.devnet} $out/bin/journey \
                --add-flags "run ${pkgs.lib.getExe components.exes.journey}" \
                --set E2E_GENESIS_DIR ${./e2e-test/genesis} \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # #173 A173-COMMAND: the retained runner receives an explicit
        # provider and wallet. Its default private CI fixture belongs to
        # the devnet launcher, which forwards HTTP/time settings only.
        # The blueprint comes from the caller at run time
        # (REGISTRY_BLUEPRINT); no store path is baked in, which is what
        # lets it run from an EXTRACTED ARCHIVE with no checkout.
        insert-active =
          pkgs.runCommand "insert-active"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.insert-active.meta or { }) // {
                mainProgram = "insert-active";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.devnet} $out/bin/insert-active \
                --add-flags "run ${pkgs.lib.getExe components.exes.insert-active}" \
                --set E2E_GENESIS_DIR ${./e2e-test/genesis} \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # #177 I177-COMMAND: the retained runner receives HTTP/time and
        # wallet settings from its private CI launcher. The blueprint
        # comes from the caller at run time
        # (REGISTRY_BLUEPRINT); no store path is baked in, which is what
        # lets it run from an EXTRACTED ARCHIVE with no checkout.
        update-terminal =
          pkgs.runCommand "update-terminal"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.update-terminal.meta or { }) // {
                mainProgram = "update-terminal";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.devnet} $out/bin/update-terminal \
                --add-flags "run ${pkgs.lib.getExe components.exes.update-terminal}" \
                --set E2E_GENESIS_DIR ${./e2e-test/genesis} \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The LI01 canonical-initialization runner (issue #47),
        # wrapped the same way as journey: the locked cardano-node
        # on its own PATH, no store path baked in.
        li01 =
          pkgs.runCommand "li01"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.li01.meta or { }) // {
                mainProgram = "li01";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.li01} $out/bin/li01 \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The LM/LC maintenance and cancellation row runner (issue
        # #56), wrapped the same way as journey and li01: the locked
        # cardano-node on its own PATH, no store path baked in. The
        # naming-onchain blueprint comes from the caller at run time
        # (NAMING_BLUEPRINT).
        naming-rows =
          pkgs.runCommand "naming-rows"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.naming-rows.meta or { }) // {
                mainProgram = "naming-rows";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.naming-rows} $out/bin/naming-rows \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The LR recovery rows (issue #62), wrapped the same way as
        # journey, li01 and naming-rows: the locked cardano-node on its
        # own PATH, no store path baked in. The naming-onchain blueprint
        # comes from the caller at run time (NAMING_BLUEPRINT).
        recovery-rows =
          pkgs.runCommand "recovery-rows"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.recovery-rows.meta or { }) // {
                mainProgram = "recovery-rows";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.recovery-rows} $out/bin/recovery-rows \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The LT retirement rows (issue #66), wrapped the same way as
        # recovery-rows: the locked cardano-node on its own PATH, no store
        # path baked in. The naming-onchain blueprint comes from the caller
        # at run time (NAMING_BLUEPRINT).
        retirement-rows =
          pkgs.runCommand "retirement-rows"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.retirement-rows.meta or { }) // {
                mainProgram = "retirement-rows";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.retirement-rows} $out/bin/retirement-rows \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The seven wrong canonical initialization refusals (issue
        # #50), wrapped the same way as journey, li01 and naming-rows:
        # the locked cardano-node on its own PATH, no store path baked
        # in. Both blueprints (the registry bootstrap and the naming
        # policies) come from the caller at run time (REGISTRY_BLUEPRINT,
        # NAMING_BLUEPRINT).
        li-refusals =
          pkgs.runCommand "li-refusals"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.li-refusals.meta or { }) // {
                mainProgram = "li-refusals";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.li-refusals} $out/bin/li-refusals \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The genuine insert rows (issue #77), wrapped the same way as the
        # other row runners: the locked cardano-node on its own PATH, no
        # store path baked in. The naming-onchain blueprint comes from the
        # caller at run time (NAMING_BLUEPRINT).
        register-rows =
          pkgs.runCommand "register-rows"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.register-rows.meta or { }) // {
                mainProgram = "register-rows";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.register-rows} $out/bin/register-rows \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The deployment tool (issue #102): boots one registry, publishes
        # one set of reference scripts, records the manifest, and checks a
        # recorded manifest against a node. Wrapped like the runners so the
        # locked cardano-node is on its own PATH when the devnet path is
        # taken.
        deployment =
          pkgs.runCommand "deployment"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.deployment.meta or { }) // {
                mainProgram = "deployment";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.deployment} $out/bin/deployment \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # A devnet that outlives the process that needed it (issue #102):
        # a deployment is attached to by later runs, so proving attachment
        # works needs one chain several processes can reach.
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

        # The connected verifier (issue #77, supply-matches-leaf-state): recomputes verdicts from
        # raw run evidence. Pure offline tool: no node on PATH needed, but
        # wrapped like the runners for uniformity. Blueprints come from the
        # caller at run time (--blueprint/--blueprint-blueprint).
        connected-verifier =
          pkgs.runCommand "connected-verifier"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.connected-verifier.meta or { }) // {
                mainProgram = "connected-verifier";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.connected-verifier} $out/bin/connected-verifier \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The issue #79 repair rows (permissionless fold + insert-only
        # retract), wrapped the same way as the other row runners: the
        # locked cardano-node on its own PATH, no store path baked in.
        # The registry blueprint comes from the caller at run time
        # (REGISTRY_BLUEPRINT).
        repair-rows =
          pkgs.runCommand "repair-rows"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.repair-rows.meta or { }) // {
                mainProgram = "repair-rows";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.repair-rows} $out/bin/repair-rows \
                --prefix PATH : ${cardanoNode}/bin
            '';

        # The public retirement reader (independent verification from
        # retained evidence only): needs neither the locked cardano-node
        # (it never touches a node) nor any baked-in blueprint — the
        # evidence directory, run log and naming manifest all come from
        # the caller at run time, so plain wrapping suffices.
        retirement-verify =
          pkgs.runCommand "retirement-verify"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.retirement-verify.meta or { }) // {
                mainProgram = "retirement-verify";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.retirement-verify} $out/bin/retirement-verify
            '';

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
          node-internal-haddock = components.sublibs.node-internal.haddock;
          inherit test-vectors test-vectors-json;
          # Issue #56: the wrapped LM/LC row runner exposed as a package
          # too, so `nix build .#naming-rows` and `nix run .#naming-rows`
          # hit the same derivation. Issue #50: same for li-refusals.
          # Issue #62: same for recovery-rows.
          # Issue #66: same for retirement-rows.
          # Issue #79: same for repair-rows.
          # Issue #77: same for register-rows.
          inherit
            naming-rows
            li-refusals
            recovery-rows
            retirement-rows
            repair-rows
            register-rows
            connected-verifier
            ;
          # Issue #102: the deployment tool and the devnet a deployment can
          # outlive, both exposed so the attach check can reach them.
          inherit deployment devnet;
          # #326: the contract suite and its external leg.
          inherit contract-tests contract-external;
          # #173 A173-COMMAND: the packaged verb, exposed so the release
          # archive's documented invocation resolves without a checkout.
          inherit insert-active update-terminal;
          # #299: the packaged `singular registry` commands. It reaches a
          # node through the socket its caller names and spawns none, so it
          # needs no cardano-node on its PATH.
          inherit (components.exes) singular;
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
        checks = haskellChecks;

        apps = haskellApps // {
          # #326.
          contract-tests = {
            type = "app";
            program = pkgs.lib.getExe contract-tests;
          };
          contract-external = {
            type = "app";
            program = pkgs.lib.getExe contract-external;
          };
          # #299.
          singular = {
            type = "app";
            program = pkgs.lib.getExe components.exes.singular;
          };
          # #173 A173-COMMAND.
          update-terminal = {
            type = "app";
            program = pkgs.lib.getExe update-terminal;
          };
          insert-active = {
            type = "app";
            program = pkgs.lib.getExe insert-active;
          };
          journey = {
            type = "app";
            program = pkgs.lib.getExe journey;
          };
          li01 = {
            type = "app";
            program = pkgs.lib.getExe li01;
          };
          naming-rows = {
            type = "app";
            program = pkgs.lib.getExe naming-rows;
          };
          recovery-rows = {
            type = "app";
            program = pkgs.lib.getExe recovery-rows;
          };
          retirement-rows = {
            type = "app";
            program = pkgs.lib.getExe retirement-rows;
          };
          li-refusals = {
            type = "app";
            program = pkgs.lib.getExe li-refusals;
          };
          repair-rows = {
            type = "app";
            program = pkgs.lib.getExe repair-rows;
          };
          retirement-verify = {
            type = "app";
            program = pkgs.lib.getExe retirement-verify;
          };
          register-rows = {
            type = "app";
            program = pkgs.lib.getExe register-rows;
          };
          connected-verifier = {
            type = "app";
            program = pkgs.lib.getExe connected-verifier;
          };
        };

        devShells = {
          inherit (project.devShells) default;
        };
      }
    );
}
