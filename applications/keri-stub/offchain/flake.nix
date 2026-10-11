{
  description = "Keri-stub application — Haskell package against the registry";

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

        src = pkgs.runCommand "keri-stub-src" { } ''
          mkdir -p $out
          cp -r ${registrySrc}/. $out/registry
          rm -rf $out/registry/dist-newstyle $out/registry/result $out/registry/.git
          mkdir -p $out/keri-stub
          cp -r ${appSrc}/src $out/keri-stub/src
          cp -r ${appSrc}/app $out/keri-stub/app
          if [ -d ${appSrc}/test ]; then cp -r ${appSrc}/test $out/keri-stub/test; fi
          if [ -d ${appSrc}/test-tags ]; then cp -r ${appSrc}/test-tags $out/keri-stub/test-tags; fi
          cp ${appSrc}/keri-stub.cabal $out/keri-stub/keri-stub.cabal
          cp ${appSrc}/LICENSE $out/keri-stub/LICENSE
          sed 's|^  \.$|  registry\n  keri-stub|' ${registrySrc}/cabal.project > $out/cabal.project
        '';

        project = import ./nix/project.nix {
          inherit CHaP pkgs src;
        };

        keriStubComponents = project.project.hsPkgs.keri-stub.components;
        registryComponents = project.project.hsPkgs.singular-registry.components;

        inventory = import ./nix/component-inventory.nix {
          inherit pkgs;
          components = {
            inherit (keriStubComponents) library;
            exes = {
              inherit (keriStubComponents.exes) keri-stub;
            };
            tests = {
              inherit (keriStubComponents.tests) keri-stub-tests;
            };
            sublibs = { };
          };
        };

        componentBuild = pkgs.symlinkJoin {
          name = "keri-stub-component-build";
          paths = inventory.memberPaths ++ [ inventory.inventoryGate ];
        };

        haskellChecksBase = import ./nix/checks.nix {
          inherit pkgs;
          components = {
            tests = {
              inherit (keriStubComponents.tests) keri-stub-tests;
            };
          };
          inherit (project.project) shell;
        };

        keriStubTestsWithRun = pkgs.writeShellApplication {
          name = "keri-stub-tests";
          runtimeInputs = [ pkgs.coreutils ];
          text = ''
            ${pkgs.lib.getExe keriStubComponents.tests.keri-stub-tests} "$@"
          '';
        };

        keriStubTestsCheck =
          pkgs.runCommand "keri-stub-tests-check"
            {
              nativeBuildInputs = [ pkgs.glibcLocales ];
              LANG = "C.UTF-8";
              LC_ALL = "C.UTF-8";
            }
            ''
              ${pkgs.lib.getExe keriStubTestsWithRun} > "$out" 2>&1 || { cat "$out"; exit 1; }
            '';

        haskellChecks = haskellChecksBase // {
          apps = haskellChecksBase.apps // {
            keri-stub-tests = keriStubTestsWithRun;
          };
          keri-stub-tests = keriStubTestsCheck;
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
          inherit (keriStubComponents.exes) keri-stub;
          inherit (registryComponents.exes) singular;
          fourmolu = fourmoluTool;
        };

        checks = builtins.removeAttrs haskellChecks [ "apps" ];

        apps = haskellApps // {
          keri-stub = {
            type = "app";
            program = pkgs.lib.getExe keriStubComponents.exes.keri-stub;
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
