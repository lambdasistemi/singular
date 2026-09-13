{
  description = "MPFS on-chain — Aiken validators + Haskell cage package";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
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
      url =
        "github:input-output-hk/iohk-nix/0ce7cc21b9a4cfde41871ef486d01a8fafbf9627";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url =
        "github:intersectmbo/cardano-haskell-packages/8479db771a3186eb326e42d8480eddc20a208275";
      flake = false;
    };
    # Pinned cardano-node, used as a subprocess by the devnet E2E
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
        # Aiken build
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
          rev = "v2.0.0";
          hash = "sha256-uHVQxA1dYDuPbH+pf6SkGNBF7nBlDXdULrPFkfUDjzU=";
        };

        # Vendored fix (ticket #81): v2.0.0's `do_excluding` lone-Fork arm
        # drops the walked common prefix, refusing real absence proofs whose
        # sole step is a root-level Fork with skip > 0. See
        # patches/README.md for provenance and the full patch digest. Every
        # reproduction path below stages THIS patched source, so the
        # blueprint, the checks, and the dev shell never disagree about the
        # vendored bytes.
        merkle-patricia-forestry-patched = pkgs.applyPatches {
          name = "merkle-patricia-forestry-v2.0.0-lone-fork-exclusion";
          src = merkle-patricia-forestry;
          patches = [ ./patches/mpf-v2.0.0-lone-fork-exclusion.patch ];
        };

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
          version = "v2.0.0"
          source = "github"
        '';

        # Stage stdlib, fuzz, and merkle-patricia-forestry into
        # build/packages so `aiken <subcommand>` runs hermetically
        # in the sandbox. Reused across the build and the check
        # derivations so there is one source of truth for the
        # Aiken prelude.
        aikenPrelude = ''
          mkdir -p build/packages
          rm -rf build/packages/aiken-lang-stdlib build/packages/aiken-lang-fuzz build/packages/aiken-lang-merkle-patricia-forestry
          cp ${packagesToml} build/packages/packages.toml
          cp -r ${stdlib} build/packages/aiken-lang-stdlib
          cp -r ${fuzz} build/packages/aiken-lang-fuzz
          cp -r ${merkle-patricia-forestry-patched} build/packages/aiken-lang-merkle-patricia-forestry
          chmod -R u+w build/packages
          # Mechanical staged-bytes guard (ticket #81): the vendored mpf
          # source must carry the lone-fork-exclusion fix. A staging that
          # resolves the unpatched upstream package from a user cache fails
          # the build here instead of producing a wrong blueprint or a
          # misdiagnosed test failure.
          grep -q "bytearray.concat" \
            build/packages/aiken-lang-merkle-patricia-forestry/lib/aiken/merkle-patricia-forestry.ak \
            || {
              echo "vendored mpf source staged UNPATCHED - refusing to build" >&2
              exit 1
            }
        '';

        plutus-blueprint = pkgs.stdenv.mkDerivation {
          pname = "mpf-plutus-blueprint";
          version = "0.0.0";
          src = pkgs.lib.cleanSource ./.;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            ${aikenPrelude}
            aiken build
          '';
          installPhase = ''
            cp plutus.json $out
          '';
        };

        aiken-check = pkgs.stdenv.mkDerivation {
          pname = "mpf-aiken-check";
          version = "0.0.0";
          src = pkgs.lib.cleanSource ./.;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            ${aikenPrelude}
            aiken check
          '';
          installPhase = "touch $out";
        };

        # Run the VENDORED PACKAGE's own test suite (including the
        # reg_lone_fork_* regression vectors the vendored patch adds) as a
        # standalone aiken project. This is the reproduction entrypoint for
        # the #81 lone-Fork exclusion fix: it fails on the unpatched v2.0.0
        # fetch and passes on the patched source.
        mpf-lone-fork-regression = pkgs.stdenv.mkDerivation {
          pname = "mpf-lone-fork-regression";
          version = "0.0.0";
          src = merkle-patricia-forestry-patched;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            export HOME=$PWD
            mkdir -p build/packages
            mv lib validators
            printf '%s\n' \
              'name = "vendored/mpf-regression"' \
              'version = "0.0.0"' \
              'compiler = "v1.1.21"' \
              'plutus = "v3"' \
              'license = "MPL-2.0"' \
              ''' \
              '[[dependencies]]' \
              'name = "aiken-lang/stdlib"' \
              'version = "v2.2.0"' \
              'source = "github"' \
              ''' \
              '[[dependencies]]' \
              'name = "aiken-lang/fuzz"' \
              'version = "v2.1.1"' \
              'source = "github"' > aiken.toml
            printf '%s\n' \
              '[[packages]]' \
              'name = "aiken-lang/stdlib"' \
              'version = "v2.2.0"' \
              'source = "github"' \
              ''' \
              '[[packages]]' \
              'name = "aiken-lang/fuzz"' \
              'version = "v2.1.1"' \
              'source = "github"' > build/packages/packages.toml
            cp -r ${stdlib} build/packages/aiken-lang-stdlib
            cp -r ${fuzz} build/packages/aiken-lang-fuzz
            chmod -R u+w .
            aiken check
          '';
          installPhase = "touch $out";
        };

        # (Haskell block deleted: project, components, haskellChecks,
        #  haskellApps, test-vectors, test-vectors-json all move to
        #  offchain/flake.nix. Breaks 2-4.)

        # Aiken-side checks. Exposed so CI can build them via
        # `.#checks.<sys>.<name>` like the Haskell checks, instead
        # of falling back to `nix develop .#aiken --command aiken …`.
        aikenChecks = {
          aiken-build = plutus-blueprint;
          inherit aiken-check;
          inherit mpf-lone-fork-regression;
        };

        # -------------------------------------------------------
        # Script identity (issue #34)
        # -------------------------------------------------------

        # The committed manifest records, for every validator in the
        # blueprint, its title and compiled hash, plus the upstream
        # source revision and the compiler string the blueprint
        # reports. Generated from a real build by
        # `just script-identity-regen` — never hand-typed.
        scriptIdentityManifest = ./script-identity.json;

        # Rebuild the blueprint and compare EVERY validator against the
        # manifest, in both directions: a moved hash, a validator
        # missing from the manifest and a manifest entry with no
        # counterpart in the build all fail, naming the validator and
        # both hashes. The comparison is quantified over the blueprint's
        # validator set, so a validator added or removed cannot pass
        # silently, and a manifest or blueprint with zero validators is
        # a failure rather than a vacuous pass.
        script-identity = pkgs.runCommand "mpf-script-identity-check" {
          nativeBuildInputs = [ pkgs.jq ];
          blueprint = plutus-blueprint;
          manifest = scriptIdentityManifest;
        } ''
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
          echo "script-identity: OK — $(jq '.validators | length' "$manifest") validators pinned, manifest matches the built blueprint (compiler $(jq -r '.compiler' "$manifest"))"
          touch $out
        '';

        scriptIdentityChecks = { inherit script-identity; };

        # The Aiken dev shell, bound once so `default` and the
        # back-compat `aiken` name expose the same shell.
        #
        # The shellHook stages the SAME patched vendored sources the
        # build/check derivations use into ./build/packages, so an
        # interactive `aiken build`/`aiken check` in the dev shell can
        # never silently resolve the UNPATCHED upstream v2.0.0 from the
        # user cache (ticket #81, A-001: every reproduction path must be
        # honest about the same patched bytes). build/ is gitignored.
        aikenShell = pkgs.mkShell {
          packages = [
            pkgs.aiken
            pkgs.just
            pkgs.lean4
          ];
          shellHook = ''
            if [ -f aiken.toml ]; then
              mkdir -p build/packages
              rm -rf build/packages/aiken-lang-stdlib build/packages/aiken-lang-fuzz build/packages/aiken-lang-merkle-patricia-forestry
              cp ${packagesToml} build/packages/packages.toml
              cp -r ${stdlib} build/packages/aiken-lang-stdlib
              cp -r ${fuzz} build/packages/aiken-lang-fuzz
              cp -r ${merkle-patricia-forestry-patched} build/packages/aiken-lang-merkle-patricia-forestry
              chmod -R u+w build/packages
              # Same staged-bytes guard as aikenPrelude: an interactive
              # aiken run in this shell cannot run against unpatched
              # vendored bytes without failing loudly on shell entry.
              grep -q "bytearray.concat" \
                build/packages/aiken-lang-merkle-patricia-forestry/lib/aiken/merkle-patricia-forestry.ak \
                || {
                  echo "vendored mpf source staged UNPATCHED - re-enter the shell" >&2
                  exit 1
                }
              echo "vendored aiken deps staged (mpf v2.0.0 + lone-fork-exclusion patch)"
            fi
          '';
        };

      in
      {
        packages = {
          default = plutus-blueprint;
          inherit plutus-blueprint;
          # Same derivation as checks.script-identity; exposed as a
          # package so recipes and CI can address it without naming the
          # system (`nix build .#script-identity`).
          inherit script-identity;
          # Mechanical digest of the vendored, patched mpf source. Compare
          # against the digest recorded in patches/README.md; a mismatch
          # means some path staged different bytes than the patch discloses.
          vendored-mpf-digest = pkgs.runCommand "vendored-mpf-digest" {
            src = merkle-patricia-forestry-patched;
            nativeBuildInputs = [ pkgs.coreutils ];
          } ''
            digest=$(find $src -type f -print0 | sort -z | xargs -0 sha256sum \
              | sha256sum | cut -d' ' -f1)
            echo "$digest" > $out
            echo "vendored mpf source digest: $digest"
          '';
        };

        checks = aikenChecks // scriptIdentityChecks;

        apps = { };

        devShells = {
          # NOTE: was `devShells.aiken`; after the split the Aiken
          # shell is the only (hence default) shell in this flake.
          # The `aiken` name is kept as an alias for justfile/CI
          # continuity (`nix develop .#aiken`).
          default = aikenShell;
          aiken = aikenShell;
        };
      }
    );
}
