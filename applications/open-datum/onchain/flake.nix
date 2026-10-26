{
  description = "Singular open-datum application — Aiken validator + envelope types";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  # The inputs block is kept verbatim from ../../../onchain/flake.nix, and
  # this tree's flake.lock is a byte-for-byte copy of
  # ../../../onchain/flake.lock — never regenerated. This is the two-flake
  # split pattern (#31, D-018): the copied lock pins the same nixpkgs
  # revision as the registry partition, so the Aiken toolchain (which comes
  # from that nixpkgs) is the same compiler that built and pinned the
  # registry's scripts. Compiling the application's validators with a
  # different compiler would make their pinned hashes incomparable with the
  # registry's. Only nixpkgs (for aiken, jq) is actually evaluated; the
  # remaining inputs are declared solely so the copied lock resolves
  # without regeneration.
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
    # Pinned cardano-node, as in ../../../onchain/flake.nix. Unused here;
    # kept so the copied lock's node stays valid for this flake's inputs.
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # -------------------------------------------------------
        # Aiken build (hermetic, mirroring ../../../onchain/flake.nix)
        # -------------------------------------------------------

        stdlib = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "stdlib";
          rev = "v2.2.0";
          hash = "sha256-BDaM+JdswlPasHsI03rLl4OR7u5HsbAd3/VFaoiDTh4=";
        };

        fuzz = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "fuzz";
          rev = "v2.1.1";
          hash = "sha256-oMHBJ/rIPov/1vB9u608ofXQighRq7DLar+hGrOYqTw=";
        };

        merkle-patricia-forestry = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "merkle-patricia-forestry";
          rev = "v2.1.0";
          hash = "sha256-c+ZM1bvR0Zpuz5hCB+F6VWfDThagBHxgoNWHvEUQT/4=";
        };

        # This project's own sources, filtered by its .gitignore.
        appSrc = pkgs.lib.cleanSource ./.;

        # The registry Aiken project this application depends on
        # (#528 S5.1): the working tree's onchain/ project, filtered by
        # its own .gitignore (build output and the built blueprint are
        # ignored there, so lib/ is included and build/ and plutus.json
        # excluded with no second enumeration here). No copy of any
        # registry module lives in this tree (single source); the staging
        # below places this source at
        # build/packages/singular-registry, the directory name Aiken
        # derives from the dependency's name `singular/registry`.
        registrySrc = pkgs.lib.cleanSource ../../../onchain;

        packagesToml = pkgs.writeText "packages.toml" ''
          [[packages]]
          name = "aiken-lang/stdlib"
          version = "v2.2.0"
          source = "github"

          [[packages]]
          name = "aiken-lang/fuzz"
          version = "v2.1.1"
          source = "github"

          [[packages]]
          name = "aiken-lang/merkle-patricia-forestry"
          version = "v2.1.0"
          source = "github"

          [[packages]]
          name = "singular/registry"
          version = "0.0.0"
          source = "github"
        '';

        # The package list for the composed test assembly below: the
        # registry's own three prelude packages. The assembly's aiken.toml
        # is the registry's, which does not depend on itself, so the
        # singular/registry row must not appear here.
        assemblyPackagesToml = pkgs.writeText "packages.toml" ''
          [[packages]]
          name = "aiken-lang/stdlib"
          version = "v2.2.0"
          source = "github"

          [[packages]]
          name = "aiken-lang/fuzz"
          version = "v2.1.1"
          source = "github"

          [[packages]]
          name = "aiken-lang/merkle-patricia-forestry"
          version = "v2.1.0"
          source = "github"
        '';

        # Stage stdlib, fuzz, merkle-patricia-forestry and the registry
        # project into build/packages so `aiken <subcommand>` runs
        # hermetically in the sandbox. Reused across the build and the
        # shell so there is one source of truth for the Aiken prelude.
        aikenPrelude = ''
          mkdir -p build/packages
          rm -rf build/packages/aiken-lang-stdlib build/packages/aiken-lang-fuzz build/packages/aiken-lang-merkle-patricia-forestry build/packages/singular-registry
          cp ${packagesToml} build/packages/packages.toml
          cp -r ${stdlib} build/packages/aiken-lang-stdlib
          cp -r ${fuzz} build/packages/aiken-lang-fuzz
          cp -r ${merkle-patricia-forestry} build/packages/aiken-lang-merkle-patricia-forestry
          cp -r ${registrySrc} build/packages/singular-registry
          chmod -R u+w build/packages
        '';

        plutus-blueprint = pkgs.stdenv.mkDerivation {
          pname = "open-datum-plutus-blueprint";
          version = "0.0.0";
          # The blueprint build reads every module `aiken build`
          # type-checks, and `aiken build` type-checks the whole project
          # including its tests — but the composed
          # `validators/open_datum.tests.ak` and
          # `validators/open_datum_requests_termination_composed.tests.ak`
          # call the registry's state validators, which no dependent project
          # can import (a dependent sees only the dependency's lib/ modules).
          # The production build filters exactly these two non-validator
          # files out of its source; the committed tree keeps them,
          # `aiken fmt` still visits them, and their tests run only in the
          # composed assembly below. The
          # blueprint still holds the application's validators only.
          # (Consequence: a bare `aiken build` in a dev shell, over the
          # unfiltered tree, refuses these test files; build the blueprint
          # with `nix build .#plutus-blueprint` and run the suite with
          # `nix run .#open-datum-aiken-tests`.)
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            filter =
              path: type:
              pkgs.lib.cleanSourceFilter path type
              && !(
                type == "regular"
                && builtins.elem (baseNameOf (toString path)) [
                  "open_datum.tests.ak"
                  "open_datum_requests_termination_composed.tests.ak"
                ]
              );
          };
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            ${aikenPrelude}
            aiken build
          '';
          installPhase = ''
            cp plutus.json $out
          '';
        };

        # -------------------------------------------------------
        # Deployment blueprint (S5.2): the registry plus the application
        # -------------------------------------------------------

        # The registry blueprint rebuilt here from the same tree the
        # application depends on (`registrySrc`, the working tree's
        # onchain/ project filtered by its own .gitignore). Same prelude
        # and same `aiken build` as onchain/flake.nix, so the bytes equal
        # the registry flake's own `.#plutus-blueprint`; rebuilding here
        # keeps the merge inside one flake with no eval-time flake
        # crossing (the root comparison still builds both flakes as its
        # own runtime steps). The assembly package list (no self row) is
        # reused: the registry project does not depend on itself.
        registry-blueprint = pkgs.stdenv.mkDerivation {
          pname = "registry-plutus-blueprint";
          version = "0.0.0";
          src = registrySrc;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            mkdir -p build/packages
            rm -rf build/packages/aiken-lang-stdlib build/packages/aiken-lang-fuzz build/packages/aiken-lang-merkle-patricia-forestry
            cp ${assemblyPackagesToml} build/packages/packages.toml
            cp -r ${stdlib} build/packages/aiken-lang-stdlib
            cp -r ${fuzz} build/packages/aiken-lang-fuzz
            cp -r ${merkle-patricia-forestry} build/packages/aiken-lang-merkle-patricia-forestry
            chmod -R u+w build/packages
            aiken build
          '';
          installPhase = ''
            cp plutus.json $out
          '';
        };

        # The merged deployment blueprint: every executable's `--blueprint`
        # input, with the pairing guarantee that the application and the
        # witnesses come from one build. Chosen by test over composing both
        # validators directories into one project and running `aiken build`
        # once: the merge copies both blueprints' `compiledCode` bytes
        # verbatim, so every hash is byte-identical by construction
        # (manual jq merge tested 14/14 equal base-hashes.json, 26
        # definitions, preamble from the registry's); a single rebuild
        # would recompile, reintroduce the single-project layout the split
        # just removed, and risk drift from the two already-pinned builds
        # (aiken.toml compiler fields differ: 1.1.16 vs 1.1.21, same
        # toolchain today). Preamble from the registry's (title
        # singular/registry, as the base document); validators concatenated
        # and sorted by title for a deterministic document; definitions
        # merged with `*` after refusing any overlapping definition that
        # differs (today the 4 shared primitives are byte-identical) and
        # refusing duplicate validator titles — a merge that cannot fail
        # guards nothing.
        open-datum-blueprint =
          pkgs.runCommand "open-datum-deployment-blueprint"
            {
              nativeBuildInputs = [ pkgs.jq ];
              registryBlueprint = registry-blueprint;
              appBlueprint = plutus-blueprint;
            }
            ''
              set -euo pipefail
              overlap_diff="$(jq -r -n --slurpfile r "$registryBlueprint" --slurpfile a "$appBlueprint" '
                ($r[0].definitions | keys[]) as $k
                | select($a[0].definitions | has($k))
                | select($r[0].definitions[$k] != $a[0].definitions[$k])
                | "DIFFER: \($k)"
              ')" || {
                echo "open-datum-blueprint: jq could not compare definitions" >&2
                exit 1
              }
              if [ -n "$overlap_diff" ]; then
                echo "open-datum-blueprint: overlapping definitions differ:" >&2
                printf '%s\n' "$overlap_diff" >&2
                exit 1
              fi
              dup_titles="$(jq -r -s '
                (.[0].validators + .[1].validators) | map(.title) | group_by(.) | map(select(length > 1) | .[0]) | .[]
              ' "$registryBlueprint" "$appBlueprint")" || {
                echo "open-datum-blueprint: jq could not check validator titles" >&2
                exit 1
              }
              if [ -n "$dup_titles" ]; then
                echo "open-datum-blueprint: duplicate validator titles:" >&2
                printf '%s\n' "$dup_titles" >&2
                exit 1
              fi
              jq -s '
                .[0] as $reg | .[1] as $app
                | {
                  preamble: $reg.preamble,
                  validators: (( $reg.validators + $app.validators) | sort_by(.title)),
                  definitions: ($reg.definitions * $app.definitions)
                }
              ' "$registryBlueprint" "$appBlueprint" > "$out"
              count="$(jq '.validators | length' "$out")"
              expected="$(jq -s '(.[0].validators | length) + (.[1].validators | length)' "$registryBlueprint" "$appBlueprint")"
              [ "$count" = "$expected" ] || {
                echo "open-datum-blueprint: expected $expected validators (registry plus application), built $count" >&2
                exit 1
              }
              echo "open-datum-blueprint: OK — $count validators, preamble $(jq -r '.preamble.title' "$out"), $(jq '.definitions | keys | length' "$out") definitions" >&2
            '';

        # #278: every hand-written and generated Aiken source is in the
        # pinned formatter's canonical form; `aiken fmt --check` visits the
        # whole project (validators/) with no exclusions.
        aiken-fmt = pkgs.stdenv.mkDerivation {
          pname = "open-datum-aiken-fmt";
          version = "0.0.0";
          src = appSrc;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            aiken fmt --check
          '';
          installPhase = "touch $out";
        };

        # -------------------------------------------------------
        # Script identity (the onchain/script-identity.json pattern)
        # -------------------------------------------------------

        # The committed manifest records, for every validator in this
        # tree's blueprint, its title, compiled hash and parameter
        # count. Generated from a real build; never hand-typed.
        scriptIdentityManifest = ./script-identity.json;

        # Two-directional comparison, quantified over the blueprint's
        # validator set: a moved hash, a validator missing from the
        # manifest and a manifest entry with no counterpart all fail,
        # naming the validator and both hashes. A manifest or blueprint
        # with zero validators is a failure rather than a vacuous pass.
        # S5.3: the application's permanent record and module are derived
        # here from the application's blueprint alone (never the registry's
        # record); the registry side is derived separately in onchain/.
        script-identity =
          pkgs.runCommand "open-datum-script-identity-check"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.python3
              ];
              blueprint = plutus-blueprint;
              manifest = scriptIdentityManifest;
            }
            ''
              set -euo pipefail
              problems="$(jq -r -n \
                --slurpfile bp "$blueprint" \
                --slurpfile man "$manifest" \
                '
                  ($bp[0].validators | map({key: .title, value: .hash}) | from_entries) as $built
                  | ($man[0].validators | map({key: .title, value: .hash}) | from_entries) as $pinned
                  | (if ($built | length) == 0
                     then ["FAIL: the blueprint reports zero validators"] else [] end)
                    + (if ($pinned | length) == 0
                     then ["FAIL: the manifest records zero validators"] else [] end)
                    + (if $man[0].compiler != $bp[0].preamble.compiler.version then
                         ["FAIL: compiler moved: manifest records \($man[0].compiler), blueprint reports \($bp[0].preamble.compiler.version)"]
                       else [] end)
                    + [$built | to_entries[] | .key as $k |
                         if ($pinned | has($k) | not) then
                           "FAIL: validator \($k) is missing from the manifest (built hash \(.value))"
                         elif $pinned[$k] != .value then
                           "FAIL: validator \($k) moved: manifest expects \($pinned[$k]), build produced \(.value)"
                         else empty end]
                    + [$pinned | to_entries[] | .key as $k |
                         if ($built | has($k) | not) then
                           "FAIL: manifest entry \($k) (hash \(.value)) has no counterpart in the build"
                         else empty end]
                  | .[]
                ')" || {
                echo "FAIL: jq could not parse the blueprint or the manifest" >&2
                exit 1
              }
              if [ -n "$problems" ]; then
                echo "script-identity check FAILED:" >&2
                printf '%s\n' "$problems" >&2
                exit 1
              fi
              python3 ${../../../tools/m1_identity.py} --root ${../../../.} --application-blueprint "$blueprint" --check
              echo "script-identity: OK — $(jq '.validators | length' "$manifest") open-datum validators pinned, manifest matches the built blueprint (compiler $(jq -r '.compiler' "$manifest")); application Permanent module fresh"
              touch $out
            '';

        # -------------------------------------------------------
        # Open-datum Aiken tests, composed assembly (A-002)
        # -------------------------------------------------------

        # The application's tests call the registry's state validator
        # (`state.state.spend`), which a dependent Aiken project cannot
        # import (a dependent sees only the dependency's lib/ modules).
        # So the tests run neither as `aiken check` over this project
        # alone nor as a second copy in the repository: the runner below
        # assembles, in a scratch directory that is never committed, the
        # registry Aiken project (validators/ and lib/ as committed) plus
        # this application's whole validators/ directory as committed
        # (open_datum.ak, application/envelope.ak, open_datum.tests.ak, text
        # verbatim — the five `state.*` call sites stay as they are — and
        # the request validator with its modules, fixtures and tests, which
        # import only the registry's lib/ modules), and runs `aiken check`
        # there. The assembly is read from the two trees at build time; no
        # copy of either side lives in the repository.
        open-datum-aiken-tests-runner = pkgs.writeShellApplication {
          name = "open-datum-aiken-tests";
          runtimeInputs = [
            pkgs.aiken
            pkgs.coreutils
          ];
          text = ''
            set -euo pipefail
            work="$(mktemp -d)"
            trap 'rm -rf "$work"' EXIT
            mkdir -p "$work/assembly/validators/application" "$work/assembly/lib"
            cp -r ${registrySrc}/validators/. "$work/assembly/validators/"
            cp -r ${registrySrc}/lib/. "$work/assembly/lib/"
            cp ${registrySrc}/aiken.toml "$work/assembly/aiken.toml"
            cp ${registrySrc}/aiken.lock "$work/assembly/aiken.lock"
            cp -r ${appSrc}/validators/. "$work/assembly/validators/"
            chmod -R u+w "$work/assembly"
            mkdir -p "$work/assembly/build/packages"
            cp ${assemblyPackagesToml} "$work/assembly/build/packages/packages.toml"
            cp -r ${stdlib} "$work/assembly/build/packages/aiken-lang-stdlib"
            cp -r ${fuzz} "$work/assembly/build/packages/aiken-lang-fuzz"
            cp -r ${merkle-patricia-forestry} "$work/assembly/build/packages/aiken-lang-merkle-patricia-forestry"
            chmod -R u+w "$work/assembly/build/packages"
            cd "$work/assembly"
            exec aiken check "$@"
          '';
        };

        # The check runs the runner and requires its log to name the
        # application's suite (a run that never executed the moved tests
        # is a failure, not a pass) and to name a closed refusal row (a run
        # that never executed the closed rows is a failure, not a pass) and
        # to name each suite of the request validator (a run that never
        # executed one is a failure, not a pass);
        # then a control run over a scratch copy with one expected digest
        # mutated must fail, and a second control run with the closed Update
        # arm planted to accept must fail naming a closed refusal row — a
        # checker that cannot fail does not guard anything.
        open-datum-aiken-tests =
          pkgs.runCommand "open-datum-aiken-tests"
            {
              nativeBuildInputs = [
                pkgs.aiken
                pkgs.coreutils
                pkgs.gnugrep
                pkgs.gnused
              ];
            }
            ''
              set -euo pipefail
              ${pkgs.lib.getExe open-datum-aiken-tests-runner} >"$out" 2>&1 || { cat "$out"; exit 1; }
              grep -q 'envelope_a_hashes_to_the_shared_digest' "$out" || {
                echo "FAIL: the test assembly never executed the moved open-datum suite" >&2
                exit 1
              }
              grep -q 'closed_update_refuses_every_payload' "$out" || {
                echo "FAIL: the test assembly never executed the closed refusal rows" >&2
                exit 1
              }
              for suite in configuration registration mint phases fold reclaim cleanup payments; do
                grep -q "open_datum_requests_$suite.tests" "$out" || {
                  echo "FAIL: the test assembly never executed the request validator suite $suite" >&2
                  exit 1
                }
              done
              work="$(mktemp -d)"
              trap 'rm -rf "$work"' EXIT
              mkdir -p "$work/mutant/validators/application" "$work/mutant/lib"
              cp -r ${registrySrc}/validators/. "$work/mutant/validators/"
              cp -r ${registrySrc}/lib/. "$work/mutant/lib/"
              cp ${registrySrc}/aiken.toml "$work/mutant/aiken.toml"
              cp ${registrySrc}/aiken.lock "$work/mutant/aiken.lock"
              cp ${appSrc}/validators/open_datum.ak "$work/mutant/validators/open_datum.ak"
              cp ${appSrc}/validators/open_datum.tests.ak "$work/mutant/validators/open_datum.tests.ak"
              cp ${appSrc}/validators/application/envelope.ak "$work/mutant/validators/application/envelope.ak"
              chmod -R u+w "$work/mutant"
              sed -i 's|04594ee38435664066a45633a4b4c0963e9922cc70ce7ba221f8805187220f91|04594ee38435664066a45633a4b4c0963e9922cc70ce7ba221f8805187220f92|' "$work/mutant/validators/open_datum.tests.ak"
              grep -q '0f92' "$work/mutant/validators/open_datum.tests.ak" || {
                echo "FAIL: the mutant plant did not apply" >&2
                exit 2
              }
              mkdir -p "$work/mutant/build/packages"
              cp ${assemblyPackagesToml} "$work/mutant/build/packages/packages.toml"
              cp -r ${stdlib} "$work/mutant/build/packages/aiken-lang-stdlib"
              cp -r ${fuzz} "$work/mutant/build/packages/aiken-lang-fuzz"
              cp -r ${merkle-patricia-forestry} "$work/mutant/build/packages/aiken-lang-merkle-patricia-forestry"
              chmod -R u+w "$work/mutant/build/packages"
              if (cd "$work/mutant" && aiken check >mutant.log 2>&1); then
                echo "FAIL: the test assembly accepted a mutant with a wrong expected digest" >&2
                exit 1
              fi
              grep -q 'envelope_a_hashes_to_the_shared_digest' "$work/mutant/mutant.log" || {
                echo "FAIL: the mutant run failed without executing the mutated test" >&2
                cat "$work/mutant/mutant.log" >&2
                exit 1
              }
              echo "open-datum-aiken-tests: control refused the mutant" >&2
              mkdir -p "$work/closed-mutant/validators/application" "$work/closed-mutant/lib"
              cp -r ${registrySrc}/validators/. "$work/closed-mutant/validators/"
              cp -r ${registrySrc}/lib/. "$work/closed-mutant/lib/"
              cp ${registrySrc}/aiken.toml "$work/closed-mutant/aiken.toml"
              cp ${registrySrc}/aiken.lock "$work/closed-mutant/aiken.lock"
              cp ${appSrc}/validators/open_datum.ak "$work/closed-mutant/validators/open_datum.ak"
              cp ${appSrc}/validators/open_datum.tests.ak "$work/closed-mutant/validators/open_datum.tests.ak"
              cp ${appSrc}/validators/application/envelope.ak "$work/closed-mutant/validators/application/envelope.ak"
              chmod -R u+w "$work/closed-mutant"
              sed -i 's|traceFalse(@"closed-datum-update")|open_datum.spend(registry, datum, Update, own, tx)|' "$work/closed-mutant/validators/open_datum.ak"
              grep -q 'open_datum.spend(registry, datum, Update, own, tx)' "$work/closed-mutant/validators/open_datum.ak" || {
                echo "FAIL: the closed mutant plant did not apply" >&2
                exit 2
              }
              mkdir -p "$work/closed-mutant/build/packages"
              cp ${assemblyPackagesToml} "$work/closed-mutant/build/packages/packages.toml"
              cp -r ${stdlib} "$work/closed-mutant/build/packages/aiken-lang-stdlib"
              cp -r ${fuzz} "$work/closed-mutant/build/packages/aiken-lang-fuzz"
              cp -r ${merkle-patricia-forestry} "$work/closed-mutant/build/packages/aiken-lang-merkle-patricia-forestry"
              chmod -R u+w "$work/closed-mutant/build/packages"
              if (cd "$work/closed-mutant" && aiken check >closed-mutant.log 2>&1); then
                echo "FAIL: the test assembly accepted a mutant whose closed Update arm accepts" >&2
                exit 1
              fi
              grep -q 'closed_update_refuses_every_payload' "$work/closed-mutant/closed-mutant.log" || {
                echo "FAIL: the closed mutant run failed without naming a closed refusal test" >&2
                cat "$work/closed-mutant/closed-mutant.log" >&2
                exit 1
              }
              echo "open-datum-aiken-tests: control refused the closed mutant" >&2
            '';

        # -------------------------------------------------------
        # Full M1 boundary over the merged blueprint (A-005 S5.2)
        # -------------------------------------------------------

        # The temporary registry-only boundary in onchain/flake.nix returns
        # here to full coverage: registry contexts from the registry tree
        # plus application contexts from the composed assembly (same seed,
        # same suites as the split), evaluated together by the same
        # tools/m1_boundary.py in default full mode against the merged
        # deployment blueprint. Nothing weakened, nothing dropped; the
        # fault control (excluded-admission artifact) runs as before.
        permanent-boundary =
          pkgs.runCommand "permanent-m1-compiled-boundary-full"
            {
              nativeBuildInputs = [
                pkgs.aiken
                pkgs.python3
              ];
              blueprint = open-datum-blueprint;
            }
            ''
              set -euo pipefail
              work="$(mktemp -d)"
              trap 'rm -rf "$work"' EXIT
              mkdir -p "$work/registry"
              cp -r ${registrySrc}/validators "$work/registry/validators"
              cp -r ${registrySrc}/lib "$work/registry/lib"
              cp ${registrySrc}/aiken.toml "$work/registry/aiken.toml"
              cp ${registrySrc}/aiken.lock "$work/registry/aiken.lock"
              chmod -R u+w "$work/registry"
              mkdir -p "$work/registry/build/packages"
              cp ${assemblyPackagesToml} "$work/registry/build/packages/packages.toml"
              cp -r ${stdlib} "$work/registry/build/packages/aiken-lang-stdlib"
              cp -r ${fuzz} "$work/registry/build/packages/aiken-lang-fuzz"
              cp -r ${merkle-patricia-forestry} "$work/registry/build/packages/aiken-lang-merkle-patricia-forestry"
              chmod -R u+w "$work/registry/build/packages"
              (cd "$work/registry" && aiken check -m 'permanent_boundary.{..}' --seed 505 > "$work/contexts.json")
              mkdir -p "$work/assembly/validators/application" "$work/assembly/lib"
              cp -r ${registrySrc}/validators/. "$work/assembly/validators/"
              cp -r ${registrySrc}/lib/. "$work/assembly/lib/"
              cp ${registrySrc}/aiken.toml "$work/assembly/aiken.toml"
              cp ${registrySrc}/aiken.lock "$work/assembly/aiken.lock"
              cp ${appSrc}/validators/open_datum.ak "$work/assembly/validators/open_datum.ak"
              cp ${appSrc}/validators/open_datum.tests.ak "$work/assembly/validators/open_datum.tests.ak"
              cp ${appSrc}/validators/application/envelope.ak "$work/assembly/validators/application/envelope.ak"
              chmod -R u+w "$work/assembly"
              mkdir -p "$work/assembly/build/packages"
              cp ${assemblyPackagesToml} "$work/assembly/build/packages/packages.toml"
              cp -r ${stdlib} "$work/assembly/build/packages/aiken-lang-stdlib"
              cp -r ${fuzz} "$work/assembly/build/packages/aiken-lang-fuzz"
              cp -r ${merkle-patricia-forestry} "$work/assembly/build/packages/aiken-lang-merkle-patricia-forestry"
              chmod -R u+w "$work/assembly/build/packages"
              (cd "$work/assembly" && aiken check -m 'open_datum.{..}' --seed 505 > "$work/application-contexts.json")
              python3 ${../../../tools/m1_boundary.py} \
                --blueprint "$blueprint" --contexts "$work/contexts.json" \
                --application-contexts "$work/application-contexts.json" \
                --aiken ${pkgs.aiken}/bin/aiken --receipts-dir receipts
              mkdir -p "$out"
              cp -r receipts "$out/receipts"
              cp "$work/contexts.json" "$work/application-contexts.json" "$out/"
            '';

      in
      {
        packages = {
          default = plutus-blueprint;
          inherit plutus-blueprint registry-blueprint open-datum-blueprint;
          inherit script-identity permanent-boundary;
        };

        checks = {
          inherit
            aiken-fmt
            script-identity
            open-datum-aiken-tests
            permanent-boundary
            ;
        };

        apps = {
          open-datum-aiken-tests = {
            type = "app";
            program = pkgs.lib.getExe open-datum-aiken-tests-runner;
          };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.aiken
            pkgs.just
          ];
          shellHook = ''
            if [ -f aiken.toml ]; then
              mkdir -p build/packages
              rm -rf build/packages/aiken-lang-stdlib build/packages/aiken-lang-fuzz build/packages/aiken-lang-merkle-patricia-forestry build/packages/singular-registry
              cp ${packagesToml} build/packages/packages.toml
              cp -r ${stdlib} build/packages/aiken-lang-stdlib
              cp -r ${fuzz} build/packages/aiken-lang-fuzz
              cp -r ${merkle-patricia-forestry} build/packages/aiken-lang-merkle-patricia-forestry
              cp -r ${registrySrc} build/packages/singular-registry
              chmod -R u+w build/packages
            fi
          '';
        };
      }
    );
}
