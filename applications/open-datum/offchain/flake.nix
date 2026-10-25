{
  description = "Open-datum application — Haskell package against the registry";

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

        registrySrc = ../../../offchain;
        appSrc = ./.;
        negativeSrc = ../negative;

        src = pkgs.runCommand "open-datum-src" { } ''
          mkdir -p $out
          cp -r ${registrySrc}/. $out/registry
          rm -rf $out/registry/dist-newstyle $out/registry/result $out/registry/.git
          mkdir -p $out/open-datum
          cp -r ${appSrc}/src $out/open-datum/src
          cp -r ${appSrc}/app $out/open-datum/app
          cp -r ${appSrc}/forged-registry $out/open-datum/forged-registry
          if [ -d ${appSrc}/test ]; then cp -r ${appSrc}/test $out/open-datum/test; fi
          # The Koios fixtures live once, in the registry tree; stage them
          # beside the application's own fixtures (its command-line corpus
          # and its help snapshots), where the application tests expect them.
          mkdir -p $out/open-datum/test/fixtures
          chmod -R u+w $out/open-datum/test
          cp -R ${registrySrc}/test/fixtures/. $out/open-datum/test/fixtures/
          chmod -R u+w $out/open-datum/test/fixtures
          if [ -d ${appSrc}/test-tags ]; then cp -r ${appSrc}/test-tags $out/open-datum/test-tags; fi
          cp ${appSrc}/open-datum.cabal $out/open-datum/open-datum.cabal
          cp ${appSrc}/LICENSE $out/open-datum/LICENSE
          mkdir -p $out/negative
          cp -r ${negativeSrc}/app $out/negative/app
          cp -r ${negativeSrc}/src $out/negative/src
          cp ${negativeSrc}/singular-negative.cabal $out/negative/singular-negative.cabal
          cp ${registrySrc}/LICENSE $out/negative/LICENSE 2>/dev/null || cp ${appSrc}/LICENSE $out/negative/LICENSE
          sed 's|^  \.$|  registry\n  open-datum\n  negative|' ${registrySrc}/cabal.project > $out/cabal.project
        '';

        project = import ./nix/project.nix {
          inherit CHaP pkgs src;
        };

        # Explicit test build: flag selection reaches the registry-cli
        # dependency linked by both application and registry executables.
        harnessProject = import ./nix/project.nix {
          inherit CHaP pkgs src;
          testHarness = true;
        };
        harnessOpenDatumComponents = harnessProject.project.hsPkgs.open-datum.components;
        harnessRegistryComponents = harnessProject.project.hsPkgs.singular-registry.components;

        openDatumComponents = project.project.hsPkgs.open-datum.components;

        # The commit this tree stands at, for `open-datum --version`: the one a
        # release archive states in RELEASE-COMMIT beside this flake (a file
        # here is outside the source the executable is built from, so the
        # cached build stays valid), else the revision of the git checkout
        # (marked dirty when it is), else unknown. The stamping helper is the
        # registry tree's, the one definition.
        commit =
          if builtins.pathExists ./RELEASE-COMMIT then
            pkgs.lib.removeSuffix "\n" (builtins.readFile ./RELEASE-COMMIT)
          else
            self.rev or (self.dirtyRev or "unknown");
        stamp = import ../../../offchain/nix/stamp-commit.nix { inherit pkgs; };
        open-datum = stamp {
          exe = openDatumComponents.exes.open-datum;
          program = "open-datum";
          inherit commit;
        };
        negativeComponents = project.project.hsPkgs.singular-negative.components;
        registryComponents = project.project.hsPkgs.singular-registry.components;

        inventory = import ./nix/component-inventory.nix {
          inherit pkgs;
          components = {
            inherit (openDatumComponents) library;
            exes = {
              inherit (openDatumComponents.exes) open-datum;
              # The same executable before the commit is stamped into a copy of
              # it: the cached Haskell build, for consumers that stamp their own.
              open-datum-unstamped = openDatumComponents.exes.open-datum;
              inherit (negativeComponents.exes) singular-negative;
              inherit (openDatumComponents.exes) forged-registry;
            };
            tests = {
              inherit (openDatumComponents.tests) open-datum-tests;
            };
            sublibs = { };
          };
        };

        componentBuild = pkgs.symlinkJoin {
          name = "open-datum-component-build";
          paths = inventory.memberPaths ++ [ inventory.inventoryGate ];
        };

        haskellChecksBase = import ./nix/checks.nix {
          inherit pkgs;
          components = {
            tests = {
              inherit (openDatumComponents.tests) open-datum-tests;
            };
          };
          inherit (project.project) shell;
        };

        # The request validator the builder rows judge their transactions with:
        # the blueprint built by the application's on-chain tree, and the pinned
        # identity manifest its hash is checked against.
        openDatumBlueprint =
          ((import ../onchain/flake.nix).outputs {
            inherit nixpkgs flake-utils;
          }).packages.${system}.plutus-blueprint;

        # The Koios fixtures live once, in the registry tree; the test
        # runner stages them where the tests expect them, beside the
        # application's own fixtures, since the repository holds no second
        # copy of the Koios ones under the application tree.
        openDatumTestsWithFixtures = pkgs.writeShellApplication {
          name = "open-datum-tests";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            fixture_dir=$(mktemp -d)
            trap 'rm -rf "$fixture_dir"' EXIT
            mkdir -p "$fixture_dir/test"
            cp -R ${registrySrc}/test/fixtures "$fixture_dir/test/fixtures"
            chmod -R u+w "$fixture_dir/test/fixtures"
            cp -R ${appSrc}/test/fixtures/. "$fixture_dir/test/fixtures/"
            chmod -R u+w "$fixture_dir/test/fixtures"
            export OPEN_DATUM_BLUEPRINT=${openDatumBlueprint}
            export OPEN_DATUM_SCRIPT_IDENTITY=${../onchain/script-identity.json}
            cd "$fixture_dir"
            ${pkgs.lib.getExe openDatumComponents.tests.open-datum-tests} "$@"
          '';
        };

        openDatumTestsCheck =
          pkgs.runCommand "open-datum-tests-check"
            {
              nativeBuildInputs = [ pkgs.glibcLocales ];
              LANG = "C.UTF-8";
              LC_ALL = "C.UTF-8";
            }
            ''
              ${pkgs.lib.getExe openDatumTestsWithFixtures} > "$out" 2>&1 || { cat "$out"; exit 1; }
            '';

        haskellChecks = haskellChecksBase // {
          apps = haskellChecksBase.apps // {
            open-datum-tests = openDatumTestsWithFixtures;
          };
          open-datum-tests = openDatumTestsCheck;
        };

        haskellApps = import ./nix/apps.nix {
          inherit pkgs;
          checks = haskellChecks;
        };

        fourmoluTool =
          let
            matches = builtins.filter (
              p: builtins.match "fourmolu-exe-fourmolu-.*" (p.name or "") != null
            ) project.project.shell.nativeBuildInputs;
          in
          assert builtins.length matches == 1;
          builtins.head matches;

      in
      {
        packages = {
          component-build = componentBuild;
          inherit open-datum;
          # The same executable before the commit is stamped into a copy of
          # it: the cached Haskell build, for consumers that stamp their own.
          open-datum-unstamped = openDatumComponents.exes.open-datum;
          open-datum-test-harness = harnessOpenDatumComponents.exes.open-datum;
          singular-test-harness = harnessRegistryComponents.exes.singular;
          inherit (negativeComponents.exes) singular-negative;
          # #730: the test-only harness of the forged-pins journey.
          inherit (openDatumComponents.exes) forged-registry;
          inherit (registryComponents.exes) singular;
          fourmolu = fourmoluTool;
        };

        checks = builtins.removeAttrs haskellChecks [ "apps" ];

        apps = haskellApps // {
          open-datum = {
            type = "app";
            program = pkgs.lib.getExe open-datum;
          };
          singular-negative = {
            type = "app";
            program = pkgs.lib.getExe negativeComponents.exes.singular-negative;
          };
          singular = {
            type = "app";
            program = pkgs.lib.getExe registryComponents.exes.singular;
          };
        };

        devShells = {
          inherit (project.devShells) default;
        };
      }
    );
}
