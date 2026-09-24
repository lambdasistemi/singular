{
  description = "Registry on-chain — Aiken validators + Haskell cage package";

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
          rev = "v2.1.0";
          hash = "sha256-c+ZM1bvR0Zpuz5hCB+F6VWfDThagBHxgoNWHvEUQT/4=";
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
          version = "v2.1.0"
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
          cp -r ${merkle-patricia-forestry} build/packages/aiken-lang-merkle-patricia-forestry
          chmod -R u+w build/packages
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

        # (Haskell block deleted: project, components, haskellChecks,
        #  haskellApps, test-vectors, test-vectors-json all move to
        #  offchain/flake.nix. Breaks 2-4.)

        # Aiken-side checks. Exposed so CI can build them via
        # `.#checks.<sys>.<name>` like the Haskell checks, instead
        # of falling back to `nix develop .#aiken --command aiken …`.
        aikenChecks = {
          aiken-build = plutus-blueprint;
          inherit aiken-check;
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
          witnessSource = ./validators/witness.ak;
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
          # #177 I177-COPIES: the witness's registry pin, enforced here
          # rather than left to whichever devnet row next moves a token.
          #
          # `witness.ak` names the state script's hash as a CONSTANT —
          # Aiken cannot name a validator's own hash, and deriving it
          # from the `registry` parameter would admit a witness
          # parametrised against a fabricated script. A stale constant
          # is silent at compile time and costs a whole devnet run to
          # discover (muse finding F1).
          #
          # So the source pin is read out of the file and required to
          # EQUAL the `state.state.spend` hash of the blueprint this
          # derivation just built. Both sides fail closed: a pin that
          # cannot be read at all, and a blueprint with no
          # `state.state.spend`, are failures rather than a vacuous
          # match.
          pin="$(sed -n 's/^  #"\([0-9a-f]\{56\}\)"$/\1/p' "$witnessSource" | head -n1)"
          if [ -z "$pin" ]; then
            echo "FAIL: no registryStateHash pin found in witness.ak" >&2
            exit 1
          fi
          built="$(jq -r '.validators[] | select(.title == "state.state.spend") | .hash' "$blueprint")"
          if [ -z "$built" ] || [ "$built" = "null" ]; then
            echo "FAIL: the built blueprint carries no state.state.spend validator" >&2
            exit 1
          fi
          if [ "$pin" != "$built" ]; then
            echo "script-identity check FAILED:" >&2
            echo "FAIL: witness.ak pins the registry state hash at $pin, the built state.state.spend is $built" >&2
            exit 1
          fi
          echo "script-identity: witness.ak pin $pin equals the built state.state.spend"
          echo "script-identity: OK — $(jq '.validators | length' "$manifest") validators pinned, manifest matches the built blueprint (compiler $(jq -r '.compiler' "$manifest"))"
          touch $out
        '';

        # -------------------------------------------------------
        # Reference-publication size (issue #253)
        # -------------------------------------------------------

        # Every compiled validator is published once as a reference
        # script, and that publishing transaction must fit the ledger's
        # maxTxSize — the devnet genesis pins mainnet's 16384. A script
        # past it cannot be deployed at all, and nothing below the devnet
        # rows would say so. This is the only size a validator has to
        # fit: no transaction the product builds carries a validator
        # inline — a registry boots by reference to the published state
        # validator, and the boot builder refuses a wallet without that
        # publication (`StateValidatorNotPublished`).
        #
        # The bound is the script's compiled bytes plus the publishing
        # transaction's overhead (250 bytes: measured on the devnet
        # publication that refused a 16160-byte state script at 16410
        # bytes — one key input, the reference output, change, one key
        # witness) plus a 256-byte margin for a heavier publisher (a base
        # address, a few more inputs, a second witness). It is quantified
        # over the blueprint's validators, so an added validator is
        # checked without editing this, and a blueprint with none fails.
        #
        # The same checker is run on a copy of the blueprint whose state
        # validator is padded one byte past the bound, and must refuse
        # it: a checker that cannot fail does not guard anything.
        publishOverhead = 250;
        publishMargin = 256;

        referencePublicationSizeCheck = pkgs.writeShellApplication {
          name = "reference-publication-size-check";
          runtimeInputs = [ pkgs.jq pkgs.gnugrep ];
          text = ''
            blueprint="$1"
            maxTxSize="$2"
            limit=$(( maxTxSize - ${toString publishOverhead} - ${toString publishMargin} ))
            report="$(jq -e -r --argjson limit "$limit" '
              (.validators | length) as $n
              | if $n == 0 then error("the blueprint reports zero validators") else . end
              | .validators[]
              | (.compiledCode | length / 2) as $bytes
              | "\(if $bytes <= $limit then "OK  " else "FAIL" end) \(.title) \($bytes) bytes (limit \($limit))"
            ' "$blueprint")"
            printf '%s\n' "$report"
            if grep -q '^FAIL' <<<"$report"; then
              exit 1
            fi
          '';
        };

        reference-publication-size = pkgs.runCommand "mpf-reference-publication-size-check" {
          blueprint = plutus-blueprint;
          genesis = ../offchain/e2e-test/genesis/shelley-genesis.json;
          nativeBuildInputs = [ pkgs.jq ];
        } ''
          set -euo pipefail
          maxTxSize="$(jq -e '.protocolParams.maxTxSize' "$genesis")"
          ${pkgs.lib.getExe referencePublicationSizeCheck} "$blueprint" "$maxTxSize"
          limit=$(( maxTxSize - ${toString publishOverhead} - ${toString publishMargin} ))
          padded="$(mktemp)"
          jq --argjson limit "$limit" '
            .validators |= map(
              if .title == "state.state.spend" then
                .compiledCode += ("00" * ([$limit + 1 - (.compiledCode | length / 2), 1] | max))
              else . end)
          ' "$blueprint" > "$padded"
          if ${pkgs.lib.getExe referencePublicationSizeCheck} "$padded" "$maxTxSize" 2>/dev/null; then
            echo "FAIL: the size check accepted a state validator padded past the limit" >&2
            exit 1
          fi
          echo "reference-publication-size: control refused the padded state validator"
          touch $out
        '';

        scriptIdentityChecks = { inherit script-identity reference-publication-size; };

        # The Aiken dev shell, bound once so `default` and the
        # back-compat `aiken` name expose the same shell.
        #
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
              cp -r ${merkle-patricia-forestry} build/packages/aiken-lang-merkle-patricia-forestry
              chmod -R u+w build/packages
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
