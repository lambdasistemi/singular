{
  description = "Singular consumer conformance (issue #63) — generic registry rows on a real devnet";

  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys = [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };

  # The inputs block is kept verbatim from ../offchain/flake.nix, and this
  # tree's flake.lock is a byte-for-byte copy of ../offchain/flake.lock —
  # never regenerated. The offchain sources enter as a plain path
  # reference below (offchainSrc), not as a flake input, so the copied
  # lock resolves without an added entry: the toolchain and every pinned
  # hash stay comparable with the tree this harness imports.
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
    # Pinned cardano-node, used as a subprocess by the devnet run. The
    # wrapper below puts it on the runner's PATH, exactly like the
    # journey/li-refusals wrappers in ../offchain/flake.nix.
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
        # Synthesized build root (issue #63)
        # -------------------------------------------------------
        # conformance/ is self-contained but imports
        # singular-registry without editing offchain/: the build root
        # carries both packages, and the merged cabal.project is
        # derived from offchain's own at build time so it cannot
        # drift from it (no hand-copied index-state or pins).
        offchainSrc = ../offchain;
        src = pkgs.runCommand "conformance-src" { } ''
          mkdir -p $out
          cp -r ${offchainSrc}/. $out/offchain
          cp -r ${./.}/. $out/conformance
          # derive the merged cabal.project from offchain's own, so it cannot drift
          sed 's|^  \.$|  offchain\n  conformance|' ${offchainSrc}/cabal.project > $out/cabal.project
        '';

        # -------------------------------------------------------
        # The naming blueprint (#157 D-BOOT)
        # -------------------------------------------------------
        # The four pins the eight-field boot datum carries are DERIVED,
        # never typed: the application policy is the naming application
        # script's own hash, and the three token policies are
        # `witness(kind, registry)` applied at kinds 0, 1 and 2. Both
        # need the naming partition's compiled code, so the harness
        # builds that partition's blueprint here and hands the runner its
        # store path — the same way it already hands it the devnet
        # genesis. No new flake input, so the copied lock still resolves.
        namingSrc = ../naming-onchain;

        aikenStdlib = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "stdlib";
          rev = "v2.2.0";
          hash = "sha256-BDaM+JdswlPasHsI03rLl4OR7u5HsbAd3/VFaoiDTh4=";
        };

        aikenFuzz = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "fuzz";
          rev = "v2.1.1";
          hash = "sha256-oMHBJ/rIPov/1vB9u608ofXQighRq7DLar+hGrOYqTw=";
        };

        aikenPackagesToml = pkgs.writeText "packages.toml" ''
          [[packages]]
          name = "aiken-lang/stdlib"
          version = "v2.2.0"
          source = "github"

          [[packages]]
          name = "aiken-lang/fuzz"
          version = "v2.1.1"
          source = "github"
        '';

        naming-blueprint = pkgs.stdenv.mkDerivation {
          pname = "singular-naming-plutus-blueprint";
          version = "0.1.0";
          src = pkgs.lib.cleanSource namingSrc;
          nativeBuildInputs = [ pkgs.aiken ];
          buildPhase = ''
            mkdir -p build/packages
            cp ${aikenPackagesToml} build/packages/packages.toml
            cp -r ${aikenStdlib} build/packages/aiken-lang-stdlib
            cp -r ${aikenFuzz} build/packages/aiken-lang-fuzz
            chmod -R u+w build/packages
            aiken build --trace-filter user-defined --trace-level verbose
          '';
          installPhase = ''
            cp plutus.json $out
          '';
        };

        # -------------------------------------------------------
        # The registry validators, rebuilt by the harness (#287)
        # -------------------------------------------------------
        # A live refusal carries no reason: the deployed blueprint is
        # `aiken build` with no trace flags (../onchain/flake.nix). The
        # harness rebuilds the same ../onchain source with the same staged
        # packages and this flake's own compiler — the two flake locks are
        # byte-identical, so it is the same pinned `aiken` — and every build
        # it trusts must first reproduce ../onchain/script-identity.json.
        registrySrc = pkgs.lib.cleanSource ../onchain;
        registryManifest = ../onchain/script-identity.json;

        aikenMerklePatriciaForestry = pkgs.fetchFromGitHub {
          owner = "aiken-lang";
          repo = "merkle-patricia-forestry";
          rev = "v2.1.0";
          hash = "sha256-c+ZM1bvR0Zpuz5hCB+F6VWfDThagBHxgoNWHvEUQT/4=";
        };

        registryPackagesToml = pkgs.writeText "packages.toml" ''
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

        # The deployed recipe's staging and build line, with `flags` after
        # `aiken build` and `prepare` run on the unpacked source first.
        registryBlueprint =
          {
            pname,
            flags,
            prepare ? "",
          }:
          pkgs.stdenv.mkDerivation {
            inherit pname;
            version = "0.0.0";
            src = registrySrc;
            nativeBuildInputs = [ pkgs.aiken ];
            buildPhase = ''
              ${prepare}
              mkdir -p build/packages
              rm -rf build/packages/aiken-lang-stdlib build/packages/aiken-lang-fuzz build/packages/aiken-lang-merkle-patricia-forestry
              cp ${registryPackagesToml} build/packages/packages.toml
              cp -r ${aikenStdlib} build/packages/aiken-lang-stdlib
              cp -r ${aikenFuzz} build/packages/aiken-lang-fuzz
              cp -r ${aikenMerklePatriciaForestry} build/packages/aiken-lang-merkle-patricia-forestry
              chmod -R u+w build/packages
              aiken build ${flags}
            '';
            installPhase = ''
              cp plutus.json $out
            '';
          };

        # A build that differs from the deployed recipe by one compiler
        # input other than the trace flags: the source literal pinning the
        # state script's hash in witness.ak. The edit checks that it applied,
        # so a pattern that stopped matching fails here, not silently.
        registryMismatchedBlueprint = registryBlueprint {
          pname = "singular-registry-mismatched-blueprint";
          flags = "";
          prepare = ''
            grep -qE '^  #"[0-9a-f]{56}"$' validators/witness.ak
            sed -i -E 's/^  #"[0-9a-f]{56}"$/  #"00000000000000000000000000000000000000000000000000000000"/' validators/witness.ak
            grep -qE '^  #"0{56}"$' validators/witness.ak
          '';
        };

        # Every validator the manifest pins must be built at its pinned hash
        # by the same compiler, and nothing else built: a moved hash, a
        # validator on one side only, a compiler string that differs and an
        # empty side each fail, naming what differs. Quantified over both
        # validator sets, read at run time.
        registryIdentityCheck = pkgs.writeShellApplication {
          name = "registry-identity-check";
          runtimeInputs = [ pkgs.jq ];
          text = ''
            manifest="$1"
            blueprint="$2"
            problems="$(jq -r -n \
              --slurpfile bp "$blueprint" \
              --slurpfile man "$manifest" \
              '
                ($bp[0].validators | map({key: .title, value: .hash}) | from_entries) as $built
                | ($man[0].validators | map({key: .title, value: .hash}) | from_entries) as $pinned
                | (if ($built | length) == 0
                   then ["FAIL: the build reports zero validators"] else [] end)
                  + (if ($pinned | length) == 0
                   then ["FAIL: the manifest records zero validators"] else [] end)
                  + (if $man[0].compiler != $bp[0].preamble.compiler.version then
                       ["FAIL: compiler differs: manifest records \($man[0].compiler), build reports \($bp[0].preamble.compiler.version)"]
                     else [] end)
                  + [$built | to_entries[] | .key as $k |
                       if ($pinned | has($k) | not) then
                         "FAIL: validator \($k) is not in the manifest (built hash \(.value))"
                       elif $pinned[$k] != .value then
                         "FAIL: validator \($k) moved: manifest pins \($pinned[$k]), build produced \(.value)"
                       else empty end]
                  + [$pinned | to_entries[] | .key as $k |
                       if ($built | has($k) | not) then
                         "FAIL: manifest validator \($k) (hash \(.value)) was not built"
                       else empty end]
                | .[]
              ')" || {
              echo "FAIL: jq could not read the manifest or the blueprint" >&2
              exit 1
            }
            if [ -n "$problems" ]; then
              printf '%s\n' "$problems"
              exit 1
            fi
            echo "registry-identity: $(jq '.validators | length' "$blueprint") validators at the manifest's hashes (compiler $(jq -r '.compiler' "$manifest"))"
          '';
        };

        # The deployed recipe as the harness runs it, and the same build
        # with the traces a replay needs. Nothing else differs.
        registryTraceFlags = "--trace-filter user-defined --trace-level verbose";
        registryUntracedBlueprint = registryBlueprint {
          pname = "singular-registry-untraced-blueprint";
          flags = "";
        };
        registryTracedPlutus = registryBlueprint {
          pname = "singular-registry-traced-plutus";
          flags = registryTraceFlags;
        };

        # The traced build must name the same validators as the untraced
        # one, each with the same parameter, datum and redeemer schemas over
        # the same definitions, under the same compiler; and the flags must
        # have changed at least one validator, or the build carries no trace.
        # Quantified over both validator sets, read at run time.
        registryTraceCorrespondenceCheck = pkgs.writeShellApplication {
          name = "registry-trace-correspondence-check";
          runtimeInputs = [ pkgs.jq ];
          text = ''
            untraced="$1"
            traced="$2"
            problems="$(jq -r -n \
              --slurpfile u "$untraced" \
              --slurpfile t "$traced" \
              '
                def shape: .validators
                  | map({key: .title, value: {parameters, datum, redeemer}})
                  | from_entries;
                def hashes: .validators | map({key: .title, value: .hash}) | from_entries;
                ($u[0] | shape) as $us
                | ($t[0] | shape) as $ts
                | ($u[0] | hashes) as $uh
                | ($t[0] | hashes) as $th
                | (if ($us | length) == 0
                   then ["FAIL: the untraced build reports zero validators"] else [] end)
                  + (if ($ts | length) == 0
                   then ["FAIL: the traced build reports zero validators"] else [] end)
                  + (if $u[0].preamble.compiler.version != $t[0].preamble.compiler.version then
                       ["FAIL: compiler differs: untraced \($u[0].preamble.compiler.version), traced \($t[0].preamble.compiler.version)"]
                     else [] end)
                  + [$us | to_entries[] | .key as $k |
                       if ($ts | has($k) | not) then
                         "FAIL: validator \($k) is only in the untraced build"
                       elif $ts[$k].parameters != .value.parameters then
                         "FAIL: validator \($k) parameters differ between the untraced and traced builds"
                       elif $ts[$k] != .value then
                         "FAIL: validator \($k) datum or redeemer schema differs between the untraced and traced builds"
                       else empty end]
                  + [$ts | keys[] | select(. as $k | $us | has($k) | not) |
                       "FAIL: validator \(.) is only in the traced build"]
                  + (if $u[0].definitions != $t[0].definitions then
                       ["FAIL: the schema definitions differ between the untraced and traced builds"]
                     else [] end)
                  + (if ([$th | to_entries[] | select($uh[.key] != null and $uh[.key] != .value)] | length) == 0
                     then ["FAIL: no traced validator hash differs from its untraced hash; the trace flags had no effect"]
                     else [] end)
                | .[]
              ')" || {
              echo "FAIL: jq could not read the untraced or the traced blueprint" >&2
              exit 1
            }
            if [ -n "$problems" ]; then
              printf '%s\n' "$problems"
              exit 1
            fi
            changed="$(jq -n --slurpfile u "$untraced" --slurpfile t "$traced" \
              '($u[0].validators | map({key: .title, value: .hash}) | from_entries) as $uh
               | [$t[0].validators[] | select($uh[.title] != .hash)] | length')"
            echo "registry-trace-correspondence: $(jq '.validators | length' "$traced") validators with the same schemas; the traces change $changed of them"
          '';
        };

        # The check the traced blueprint is built behind (FR-03): the
        # harness's untraced build reproduces the deployed manifest, and the
        # traced build corresponds to it. Each comparison is then shown able
        # to refuse — a build that moves a deployed hash, an untraced build
        # passed off as traced, a traced build missing a validator and one
        # whose parameter schema differs — and each refusal must come from
        # the comparison's own FAIL line, not from a crash. Its output is the
        # provenance the runner reads beside the traced blueprint.
        registryBlueprintCorrespondence =
          pkgs.runCommand "singular-registry-blueprint-correspondence"
            {
              nativeBuildInputs = [
                pkgs.jq
                pkgs.diffutils
              ];
            }
            ''
              set -euo pipefail
              identity=${pkgs.lib.getExe registryIdentityCheck}
              correspondence=${pkgs.lib.getExe registryTraceCorrespondenceCheck}
              "$identity" ${registryManifest} ${registryUntracedBlueprint}
              "$correspondence" ${registryUntracedBlueprint} ${registryTracedPlutus}

              refuses() {
                label="$1"
                pattern="$2"
                shift 2
                if output="$("$@" 2>&1)"; then
                  echo "FAIL: control $label: the check accepted it" >&2
                  exit 1
                fi
                if ! grep -qE "$pattern" <<<"$output"; then
                  echo "FAIL: control $label: refused, but not by the comparison:" >&2
                  printf '%s\n' "$output" >&2
                  exit 1
                fi
                echo "control $label: refused: $(grep -E "$pattern" <<<"$output" | head -n 1)"
              }

              mutant() {
                if cmp -s "$1" "$2"; then
                  echo "FAIL: control mutant $2 is identical to its original" >&2
                  exit 1
                fi
              }

              refuses moved-hash '^FAIL: validator witness\.witness\.mint moved' \
                "$identity" ${registryManifest} ${registryMismatchedBlueprint}
              refuses untraced-as-traced '^FAIL: no traced validator hash differs' \
                "$correspondence" ${registryUntracedBlueprint} ${registryUntracedBlueprint}

              jq 'del(.validators[-1])' ${registryTracedPlutus} > missing.json
              mutant ${registryTracedPlutus} missing.json
              refuses missing-validator '^FAIL: validator .* is only in the untraced build' \
                "$correspondence" ${registryUntracedBlueprint} missing.json

              jq '(.validators | map(.parameters != null) | index(true)) as $i
                  | .validators[$i].parameters[0].schema = {"$ref": "#/definitions/Int"}' \
                ${registryTracedPlutus} > reparameterized.json
              mutant ${registryTracedPlutus} reparameterized.json
              refuses parameter-schema '^FAIL: validator .* parameters differ' \
                "$correspondence" ${registryUntracedBlueprint} reparameterized.json

              mkdir -p "$out"
              jq -n \
                --arg source ${registrySrc} \
                --arg flags ${pkgs.lib.escapeShellArg registryTraceFlags} \
                --slurpfile u ${registryUntracedBlueprint} \
                --slurpfile t ${registryTracedPlutus} \
                '{
                  source: $source,
                  compiler: $u[0].preamble.compiler.version,
                  flags: $flags,
                  untracedHashes: ($u[0].validators | map({key: .title, value: .hash}) | from_entries),
                  validators: ($t[0].validators | map({title, parameters}))
                }' > "$out/provenance.json"
            '';

        # The traced blueprint the runner replays with (FR-02), with its
        # provenance beside it. It depends on the correspondence check, so a
        # build that failed the check is never handed to a run.
        registryTracedBlueprint = pkgs.runCommand "singular-registry-traced-blueprint" { } ''
          mkdir -p "$out"
          cp ${registryTracedPlutus} "$out/plutus.json"
          cp ${registryBlueprintCorrespondence}/provenance.json "$out/provenance.json"
        '';

        # -------------------------------------------------------
        # Coverage gate root (issue #80)
        # -------------------------------------------------------
        # Separate from `src` above so the coverage gate's inputs — the
        # frozen lean/ contract, tools/ (check_model.py) and the gate itself
        # — are hash-bound for the snapshot tests WITHOUT touching the
        # Haskell build graph: `nix build .#conformance` stays byte-identical.
        coverageSrc = pkgs.runCommand "coverage-src" { } ''
          mkdir -p $out/conformance
          cp -r ${../lean} $out/lean
          cp -r ${../tools} $out/tools
          cp -r ${./.}/coverage $out/conformance/coverage
        '';

        coverageGate =
          pkgs.runCommand "coverage-gate"
            {
              # git rides the closure: the release boundary binds the tree via
              # git and is fail-closed on unknown identity. A missing git must
              # never stand in for honest debt.
              buildInputs = [
                pkgs.makeWrapper
                pkgs.python3
                pkgs.git
              ];
              meta = {
                mainProgram = "coverage-gate";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.python3}/bin/python3 $out/bin/coverage-gate \
                --prefix PYTHONPATH : ${coverageSrc}/conformance/coverage \
                --prefix PATH : ${pkgs.git}/bin \
                --add-flags "-m singular_coverage.gate"
            '';

        # Gate unit suite over the frozen snapshot, including every armed
        # failure control and the real-tree discovery/inventory assertions.
        # git rides along so the real-git candidate-binding controls run,
        # not skip, in this derivation.
        coverageGateTests =
          pkgs.runCommand "coverage-gate-tests"
            {
              buildInputs = [
                pkgs.python3
                pkgs.git
              ];
            }
            ''
              cd ${coverageSrc}/conformance/coverage
              PYTHONPATH=$PWD ${pkgs.python3}/bin/python3 -m unittest discover -s tests
              touch $out
            '';

        # The gate's own verdicts against the same frozen snapshot: inventory
        # reconciles, ratchet passes, completion honestly refuses.
        coverageGateSnapshot =
          pkgs.runCommand "coverage-gate-snapshot"
            {
              buildInputs = [ pkgs.python3 ];
            }
            ''
              export PYTHONPATH=${coverageSrc}/conformance/coverage
              ${pkgs.python3}/bin/python3 -m singular_coverage.gate \
                --root ${coverageSrc} inventory > /dev/null
              ${pkgs.python3}/bin/python3 -m singular_coverage.gate \
                --root ${coverageSrc} ratchet > /dev/null
              if ${pkgs.python3}/bin/python3 -m singular_coverage.gate \
                  --root ${coverageSrc} completion > /dev/null 2>&1; then
                echo "coverage gate: completion unexpectedly passed a nonzero-debt snapshot"
                exit 1
              fi
              mkdir -p $out
            '';

        project = import ./nix/project.nix {
          inherit CHaP pkgs src;
        };

        inherit (project.project.hsPkgs.conformance) components;

        cardanoNode = cardano-node.packages.${system}.cardano-node;

        # Compile the observation and its proof against this checkout's model.
        # The executable transports abstract IDs; Cardano bytes stay in Haskell.
        modelLock = builtins.fromJSON (builtins.readFile ../flake.lock);
        modelPkgs = import (builtins.fetchTree modelLock.nodes.nixpkgs.locked) {
          inherit system;
        };
        # The generic evaluator: the DSL's abstract scenario and the context
        # the caller established, through the model's own driver. Edge-agnostic
        # on purpose, so #223's connected retirement is the same call with a
        # setup trace rather than a second adapter.
        driverTransport =
          modelPkgs.runCommand "singular-driver-transport"
            {
              nativeBuildInputs = [
                modelPkgs.lean4
                modelPkgs.stdenv.cc
              ];
              meta.mainProgram = "driver-transport";
            }
            ''
              mkdir work
              cp -r ${../lean} work/lean
              cp ${../lakefile.toml} work/lakefile.toml
              chmod -R u+w work
              cp ${./lean/DriverTransport.lean} work/lean/DriverTransport.lean
              cat >> work/lakefile.toml <<'EOF'

              [[lean_exe]]
              name = "driver-transport"
              root = "DriverTransport"
              EOF
              cd work
              lake build driver-transport
              mkdir -p $out/bin
              cp .lake/build/bin/driver-transport $out/bin/
            '';

        # The row runner, wrapped so it brings the locked cardano-node
        # on its own PATH like the offchain journey runners, with the
        # devnet genesis defaulting to this suite's own copy
        # (E2E_GENESIS_DIR still overrides). The deployed blueprint comes
        # from the caller at run time (REGISTRY_BLUEPRINT); no store path is
        # baked in for it. The traced blueprint (#287) defaults to this
        # flake's own, provenance beside it (REGISTRY_TRACED_BLUEPRINT).
        #
        # The copy differs from offchain/e2e-test/genesis in one field:
        # shelley epochLength, 500 slots raised to 20000. At 0.1s a slot
        # the original gives a two-epoch conversion horizon of a hundred
        # seconds, and a ten-row registry-mode session — which books an
        # approval and folds an edge per row, each its own transaction —
        # runs past it and cannot convert a deadline to a slot. Every
        # other file and parameter is byte-identical.
        conformance =
          pkgs.runCommand "conformance"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta = (components.exes.conformance.meta or { }) // {
                mainProgram = "conformance";
              };
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.conformance} $out/bin/conformance \
                --prefix PATH : ${cardanoNode}/bin \
                --set CONFORMANCE_DRIVER_CORPUS ${../lean/driver-corpus.json} \
                --set CONFORMANCE_MODEL_EVALUATOR ${pkgs.lib.getExe driverTransport} \
                --set-default E2E_GENESIS_DIR ${src}/conformance/genesis \
                --set-default NAMING_BLUEPRINT ${naming-blueprint} \
                --set-default REGISTRY_TRACED_BLUEPRINT ${registryTracedBlueprint}/plutus.json
            '';

        # A separate test binary owns the deliberately insufficient budget.
        # The public conformance executable never links its fixture module.
        foldBudgetRegression =
          pkgs.runCommand "fold-budget-regression"
            {
              buildInputs = [ pkgs.makeWrapper ];
              meta.mainProgram = "fold-budget-regression";
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.exes.fold-budget-regression} $out/bin/fold-budget-regression \
                --prefix PATH : ${cardanoNode}/bin \
                --set CONFORMANCE_DRIVER_CORPUS ${../lean/driver-corpus.json} \
                --set CONFORMANCE_MODEL_EVALUATOR ${pkgs.lib.getExe driverTransport} \
                --set-default E2E_GENESIS_DIR ${src}/conformance/genesis \
                --set-default NAMING_BLUEPRINT ${naming-blueprint} \
                --set-default REGISTRY_TRACED_BLUEPRINT ${registryTracedBlueprint}/plutus.json
            '';

        # The appendix suite compares against the committed driver corpus, so
        # the corpus travels with the binary rather than being copied into the
        # test tree where it could drift from the model.
        appendixTests =
          pkgs.runCommand "conformance-appendix-tests"
            {
              nativeBuildInputs = [ pkgs.makeWrapper ];
              meta.mainProgram = "conformance-tests";
            }
            ''
              mkdir -p $out/bin
              makeWrapper ${pkgs.lib.getExe components.tests.conformance-tests} $out/bin/conformance-tests \
                --set CONFORMANCE_DRIVER_CORPUS ${../lean/driver-corpus.json}
            '';

        # The public test command executes the book, including fresh devnet
        # transactions. The cheap evidence-checker suite remains available by
        # its explicit appendix name; it cannot generate the product book.
        runningBook = pkgs.writeShellApplication {
          name = "conformance-tests";
          runtimeInputs = [
            pkgs.nix
            pkgs.git
            pkgs.coreutils
          ];
          text = ''
            book_args=()
            if [ "$#" -eq 2 ] && [ "$1" = "--book" ]; then
              book_args=(--output "$2")
            elif [ "$#" -ne 0 ]; then
              echo 'usage: conformance-tests [--book BOOK.md]' >&2
              echo 'For report-unit-test filters, use conformance-appendix-tests.' >&2
              exit 2
            fi
            if [ -z "''${REGISTRY_BLUEPRINT:-}" ]; then
              REGISTRY_BLUEPRINT="$(nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint)"
              export REGISTRY_BLUEPRINT
            fi
            if [ ! -r "$REGISTRY_BLUEPRINT" ]; then
              echo "Live story needs a readable validator blueprint: $REGISTRY_BLUEPRINT" >&2
              exit 1
            fi
            ${pkgs.lib.getExe appendixTests}
            echo 'Harness appendix: honest fold budget regression'
            budget_receipts="$(mktemp -d -t singular-budget-regression.XXXXXX)"
            ${pkgs.lib.getExe foldBudgetRegression} --receipts-dir "$budget_receipts"
            receipts="$(mktemp -d -t singular-running-book.XXXXXX)"
            ${pkgs.lib.getExe conformance} book --receipts-dir "$receipts" "''${book_args[@]}"
          '';
        };

        # #278 S2: the pinned house formatter, extracted from this tree's
        # locked dev-shell tool set — the same Fourmolu version the
        # off-chain lint resolves (the two locks are byte-identical), so
        # the two format checks cannot drift. Fail-closed on anything but
        # exactly one Fourmolu tool in the shell.
        shellTool =
          pattern:
          let
            matches = builtins.filter (
              p: builtins.match pattern (p.name or "") != null
            ) project.project.shell.nativeBuildInputs;
          in
          assert builtins.length matches == 1;
          builtins.head matches;
        fourmoluTool = shellTool "fourmolu-exe-fourmolu-.*";
        # #278 S3: HLint from the same locked dev-shell tool set, so the
        # Conformance lint resolves the HLint the off-chain lint runs.
        hlintTool = shellTool "hlint-exe-hlint-.*";

        # #278 S2: the Conformance Haskell format check. Discovery mirrors
        # the off-chain lint: every hs-source-dirs the Cabal manifests
        # declare (conformance.cabal and the #80 evaluation spike's
        # spike.cabal), visited recursively, so a new component or source
        # directory is covered with no list to edit; empty discovery or a
        # missing declared directory fails closed. The house configuration
        # is the committed fourmolu.yaml at the repository root, passed
        # explicitly so a missing configuration fails loudly instead of
        # silently falling back to Fourmolu defaults. Like the off-chain
        # lint, the check runs over the FLAKE SOURCE (a store copy), so
        # the bytes it checks are candidate-bound; the root `just
        # format-check` carries the whole-tree checkout-context carrier.
        # The Conformance Haskell extent, shared by the format and lint
        # checks so the two cannot visit different files.
        haskellDiscovery = ''
          cd "${./.}"
          conf_dirs=$(
            awk '/^[ \t]*hs-source-dirs:/ {
              sub(/^[ \t]*hs-source-dirs:[ \t]*/, "")
              for (i = 1; i <= NF; i++) print $i
            }' conformance.cabal
          ) || { echo "format-check: source discovery failed: cannot read conformance.cabal (awk exit $?)" >&2; exit 1; }
          [ -n "$conf_dirs" ] || { echo "format-check: source discovery found no hs-source-dirs in conformance.cabal" >&2; exit 1; }
          spike_dirs=$(
            awk '/^[ \t]*hs-source-dirs:/ {
              sub(/^[ \t]*hs-source-dirs:[ \t]*/, "")
              for (i = 1; i <= NF; i++) print "coverage/evaluation/" $i
            }' coverage/evaluation/spike.cabal
          ) || { echo "format-check: source discovery failed: cannot read coverage/evaluation/spike.cabal (awk exit $?)" >&2; exit 1; }
          [ -n "$spike_dirs" ] || { echo "format-check: source discovery found no hs-source-dirs in coverage/evaluation/spike.cabal" >&2; exit 1; }
          dirs=$(printf '%s\n%s\n' "$conf_dirs" "$spike_dirs" | sort -u)
          [ -n "$dirs" ] || { echo "format-check: discovered no source directories" >&2; exit 1; }
          for d in $dirs; do
            [ -d "$d" ] || { echo "format-check: declared source directory missing: $d" >&2; exit 1; }
          done
          files=$(find $dirs -name '*.hs' | sort -u)
          [ -n "$files" ] || { echo "format-check: no Haskell sources in the discovered extent" >&2; exit 1; }
          echo "conformance haskell extent: $(printf '%s\n' $files | wc -l) Haskell sources over $(printf '%s\n' $dirs | wc -l) dirs, house fourmolu.yaml, no exclusions" >&2
        '';

        formatCheck = pkgs.writeShellApplication {
          name = "format-check";
          runtimeInputs = [
            fourmoluTool
            pkgs.coreutils
            pkgs.gawk
            pkgs.findutils
          ];
          excludeShellChecks = [
            "SC2046"
            "SC2086"
          ];
          text = ''
            ${haskellDiscovery}
            # The GHC option matches the off-chain lint invocation so the
            # two checks share one formatter dialect.
            fourmolu --config ${../fourmolu.yaml} --ghc-opt=-XImportQualifiedPost -m check $files
          '';
        };

        # #278 S3: HLint over exactly the extent the format check visits
        # (the Conformance Cabal stanzas plus the #80 evaluation spike),
        # discovered at check time, with no exclusions and no ignore file.
        hlintCheck = pkgs.writeShellApplication {
          name = "hlint-check";
          runtimeInputs = [
            hlintTool
            pkgs.coreutils
            pkgs.gawk
            pkgs.findutils
          ];
          excludeShellChecks = [
            "SC2046"
            "SC2086"
          ];
          text = ''
            ${haskellDiscovery}
            hlint $files
          '';
        };

        hlintCheckRun = pkgs.runCommand "singular-conformance-hlint-check" { } ''
          ${pkgs.lib.getExe hlintCheck}
          touch "$out"
        '';

        # #278 S2, audit F003: the flake check EXECUTES the same app over
        # the flake source it was built from — `nix build`/`nix flake
        # check` on this attribute runs Fourmolu over the store copy, it
        # does not merely build and shellcheck a wrapper. The app stays
        # the single carrier (same binary CI runs); no divergent inline
        # logic, strict runtime closure preserved.
        formatCheckRun = pkgs.runCommand "singular-conformance-format-check" { } ''
          ${pkgs.lib.getExe formatCheck}
          touch "$out"
        '';

      in
      {
        packages = {
          inherit conformance driverTransport foldBudgetRegression;
          # #299: the ordinary CLI's refusal controls runner.
          inherit (components.exes) cli-controls;
          # Generated Haddock reference for the Conformance library, consumed
          # by the root documentation build. Same source tree, same lock: the
          # docs manifest can bind the reference to this candidate's content.
          # The flag pair follows the off-chain reference's proven recipe:
          # --internal hands the library's package-internal modules (the
          # asset-evidence owner) to Haddock, and --haddock-option=--show-all
          # cancels the hide attribute so every module of the library extent
          # gets both a module page and a hyperlinked source page. The flags
          # are scoped to this documentation output alone, through a project
          # that only appends them as an extra package module: every other
          # build output keeps the untouched closure.
          library-haddock =
            (project.project.appendModule {
              modules = [
                {
                  packages.conformance.setupHaddockFlags = [
                    "--internal"
                    "--haddock-option=--show-all"
                  ];
                }
              ];
            }).hsPkgs.conformance.components.library.haddock;
          # #157 D-BOOT: the naming partition's blueprint, so the four
          # pins are derived rather than typed.
          inherit naming-blueprint;
          # #287: the traced registry blueprint the runner replays refusals
          # with, and the check it is built behind.
          registry-traced-blueprint = registryTracedBlueprint;
          registry-blueprint-correspondence = registryBlueprintCorrespondence;
          # Mechanical adapter (D-008): exposes the cardano-node already
          # locked as this flake's input, so the devnet run consumes the
          # locked identity instead of re-resolving a remote tag.
          cardano-node = cardanoNode;
          # Theorem-coverage gate (issue #80): app + its two verification
          # derivations, buildable without touching the Haskell graph.
          inherit coverageGate coverageGateTests coverageGateSnapshot;
        };

        checks = {
          format-check = formatCheckRun;
          hlint-check = hlintCheckRun;
          conformance-exe = components.exes.conformance;
          inherit (components.tests) conformance-tests;
          coverage-gate-tests = coverageGateTests;
          coverage-gate-snapshot = coverageGateSnapshot;
          registry-blueprint-correspondence = registryBlueprintCorrespondence;
        };

        apps = {
          format-check = {
            type = "app";
            program = pkgs.lib.getExe formatCheck;
          };
          hlint-check = {
            type = "app";
            program = pkgs.lib.getExe hlintCheck;
          };
          fold-budget-regression = {
            type = "app";
            program = pkgs.lib.getExe foldBudgetRegression;
          };
          conformance = {
            type = "app";
            program = pkgs.lib.getExe conformance;
          };
          conformance-tests = {
            type = "app";
            program = pkgs.lib.getExe runningBook;
          };
          conformance-appendix-tests = {
            type = "app";
            program = pkgs.lib.getExe appendixTests;
          };
          coverage-gate = {
            type = "app";
            program = "${coverageGate}/bin/coverage-gate";
          };
        };

        devShells = {
          inherit (project.devShells) default;
        };
      }
    );
}
