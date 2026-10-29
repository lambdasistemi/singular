{
  description = "Pinned Singular archive reproduction checks";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/117cc7f94e8072499b0a7aa4c52084fa4e11cc9b";
  inputs.nixpkgs-lean.url = "github:NixOS/nixpkgs/7f4e8517083e42a1b38907598dadc02c7235b30e";

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-lean,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          leanPkgs = import nixpkgs-lean { inherit system; };
          checked = pkgs.stdenv.mkDerivation {
            pname = "singular-archive-review";
            version = "0.1.0";
            src = self;
            nativeBuildInputs = [
              leanPkgs.lean4
              pkgs.nodejs
              pkgs.python3
            ];
            buildPhase = ''
              runHook preBuild
              toolchain="$(cat lean-toolchain)"
              expected_version="''${toolchain#leanprover/lean4:v}"
              actual_version="$(lean --version)"
              echo "$actual_version" | grep -F "version $expected_version" \
                || { echo "compiler mismatch: lean-toolchain wants version $expected_version but lean reports: $actual_version" >&2; exit 1; }
              lake build
              lake env lean tools/axioms.lean > axioms-report.txt
              python3 tools/check_model.py \
                --binary .lake/build/bin/singular-corpus \
                --naming-binary .lake/build/bin/naming-corpus \
                --lifecycle-binary .lake/build/bin/lifecycle-corpus \
                --axioms-report axioms-report.txt \
                --root . > model-check.txt
              lake env lean tools/m1_axioms.lean > m1-axioms-report.txt
              python3 tools/check_m1.py --axioms-report m1-axioms-report.txt --root . > m1-check.txt
              node simulator/build.mjs --check > page-build-check.txt
              node simulator/gate.mjs > replay-check.txt
              node simulator/gate.mjs --selftest > replay-selftest.txt
              node simulator/mirror-check.mjs > mirror-check.txt
              runHook postBuild
            '';
            installPhase = ''
              mkdir -p "$out"
              {
                node --version
                lean --version
                cat model-check.txt
                cat m1-check.txt
                cat page-build-check.txt
                tail -n 28 replay-check.txt
                grep -F 'PASS selftest: a law without applicable examples is not reported as exercised' replay-selftest.txt
                grep -F 'PASS selftest: a witnessless supply violation stays applicable and reads as violated' replay-selftest.txt
                grep -F 'PASS selftest: the gate fails when it should' replay-selftest.txt
                grep -F 'PASS simulator: the transcription reproduces the model on every exported row' replay-selftest.txt
                printf '%s\n' 'PASS archive model and replay reproduction'
              } > "$out/receipt.txt"
            '';
          };
          runner = pkgs.writeShellApplication {
            name = "singular-archive-check";
            text = "cat ${checked}/receipt.txt";
          };
        in
        {
          default = checked;
          check = checked;
          inherit runner;
        }
      );

      apps = nixpkgs.lib.genAttrs systems (system: {
        default = {
          type = "app";
          meta.description = "Check the standalone release archive";
          program = "${self.packages.${system}.runner}/bin/singular-archive-check";
        };
        check = {
          type = "app";
          meta.description = "Check the standalone release archive";
          program = "${self.packages.${system}.runner}/bin/singular-archive-check";
        };
      });
    };
}
