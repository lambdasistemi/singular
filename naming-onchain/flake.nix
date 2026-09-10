{
  description = "Singular naming validators (issue #52) — Aiken representative policy + application validator";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  # The inputs block is kept verbatim from ../onchain/flake.nix, and this
  # tree's flake.lock is a byte-for-byte copy of ../onchain/flake.lock —
  # never regenerated. This is the two-flake split pattern (#31, D-018):
  # the copied lock pins the same nixpkgs revision as the imported
  # partition, so the Aiken toolchain (which comes from that nixpkgs) is
  # the same compiler that built and pinned onchain's scripts. Compiling
  # Singular's validators with a different compiler would make their
  # pinned hashes incomparable with the imported ones and would let a
  # compiler drift silently move a script identity. Only nixpkgs (for
  # aiken, jq) is actually evaluated; the remaining inputs are declared
  # solely so the copied lock resolves without regeneration.
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
    # Pinned cardano-node, as in ../onchain/flake.nix. Unused here; kept
    # so the copied lock's node stays valid for this flake's inputs.
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
        # Aiken build (hermetic, mirroring ../onchain/flake.nix)
        # -------------------------------------------------------

        stdlib = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "stdlib";
          rev = "v2.2.0";
          hash = "sha256-BDaM+JdswlPasHsI03rLl4OR7u5HsbAd3/VFaoiDTh4=";
        };

        packagesToml = pkgs.writeText "packages.toml" ''
          [[packages]]
          name = "aiken-lang/stdlib"
          version = "v2.2.0"
          source = "github"
        '';

        # Stage the stdlib into build/packages so `aiken <subcommand>`
        # runs hermetically in the sandbox — no network, no ambient
        # package state.
        aikenPrelude = ''
          mkdir -p build/packages
          cp ${packagesToml} build/packages/packages.toml
          cp -r ${stdlib} build/packages/aiken-lang-stdlib
          chmod -R u+w build/packages
        '';

        plutus-blueprint = pkgs.stdenv.mkDerivation {
          pname = "singular-naming-plutus-blueprint";
          version = "0.1.0";
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
          pname = "singular-naming-aiken-check";
          version = "0.1.0";
          src = pkgs.lib.cleanSource ./.;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            ${aikenPrelude}
            aiken check
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
        script-identity = pkgs.runCommand "naming-script-identity-check" {
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
          echo "script-identity: OK — $(jq '.validators | length' "$manifest") naming validators pinned, manifest matches the built blueprint (compiler $(jq -r '.compiler' "$manifest"))"
          touch $out
        '';

      in
      {
        packages = {
          default = plutus-blueprint;
          inherit plutus-blueprint;
          inherit script-identity;
        };

        checks = {
          inherit aiken-check script-identity;
        };

        apps = { };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.aiken
            pkgs.just
          ];
        };
      }
    );
}
