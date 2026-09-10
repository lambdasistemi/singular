{
  description = "Pinned Singular archive reproduction checks";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/117cc7f94e8072499b0a7aa4c52084fa4e11cc9b";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
    in {
      packages = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          checked = pkgs.stdenv.mkDerivation {
            pname = "singular-archive-review";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [ pkgs.lean4 pkgs.nodejs pkgs.python3 ];
            buildPhase = ''
              runHook preBuild
              test "$(cat lean-toolchain)" = "leanprover/lean4:v4.25.0"
              lean --version | grep -F 'version 4.25.0'
              lake build
              lake env lean tools/axioms.lean > axioms-report.txt
              python3 tools/check_model.py \
                --binary .lake/build/bin/singular-corpus \
                --naming-binary .lake/build/bin/naming-corpus \
                --lifecycle-binary .lake/build/bin/lifecycle-corpus \
                --axioms-report axioms-report.txt \
                --root . > model-check.txt
              node simulator/build.mjs --check > page-build-check.txt
              node simulator/gate.mjs > replay-check.txt
              node simulator/gate.mjs --selftest > replay-selftest.txt
              node simulator/lifecycle-gate.mjs > lifecycle-replay-check.txt
              grep -F '"dynamicAddresses":24' lifecycle-replay-check.txt
              node --input-type=module <<'NODE'
              import assert from 'node:assert/strict';
              import {readFileSync} from 'node:fs';
              import {lifecycleCorpusIdentities} from './simulator/lifecycle.mjs';
              const lines = readFileSync('lifecycle-replay-check.txt', 'utf8').trim().split('\n');
              const receipt = JSON.parse(lines.at(-1));
              assert.deepEqual([...receipt.leanReplay.identities].sort(), [...lifecycleCorpusIdentities].sort());
              assert.equal(receipt.leanReplay.discovered, lifecycleCorpusIdentities.length);
              assert.equal(receipt.leanReplay.executed, lifecycleCorpusIdentities.length);
              NODE
              runHook postBuild
            '';
            installPhase = ''
              mkdir -p "$out"
              {
                node --version
                lean --version
                cat model-check.txt
                cat page-build-check.txt
                tail -n 28 replay-check.txt
                grep -F '"controlsDiscovered": 43' replay-selftest.txt
                grep -F '"controlsExecuted": 43' replay-selftest.txt
                cat lifecycle-replay-check.txt
                printf '%s\n' 'PASS archive model and replay reproduction'
              } > "$out/receipt.txt"
            '';
          };
          runner = pkgs.writeShellApplication {
            name = "singular-archive-check";
            text = ''cat ${checked}/receipt.txt'';
          };
        in {
          default = checked;
          check = checked;
          runner = runner;
        });

      apps = nixpkgs.lib.genAttrs systems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.runner}/bin/singular-archive-check";
        };
        check = {
          type = "app";
          program = "${self.packages.${system}.runner}/bin/singular-archive-check";
        };
      });
    };
}
