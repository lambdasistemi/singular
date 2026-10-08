{ pkgs, src }:
let
  package = pkgs.stdenv.mkDerivation {
    pname = "singular-model";
    version = "0.1.0";
    src = pkgs.lib.cleanSourceWith {
      inherit src;
      filter =
        path: _type:
        !(builtins.elem (builtins.baseNameOf path) [
          ".lake"
          ".git"
          "site"
          "result"
          "__pycache__"
        ]);
    };
    nativeBuildInputs = [
      pkgs.lean4
      pkgs.python3
    ];
    buildPhase = ''
      lake build
      lake env lean tools/axioms.lean > axioms-report.txt
      lake env lean tools/m1_axioms.lean > m1-axioms-report.txt
      python3 tools/check_m1_transport.py --root . --report m1-transport-report.json
    '';
    installPhase = ''
      mkdir -p "$out/bin" "$out/share"
      cp .lake/build/bin/singular-corpus "$out/bin/"
      cp .lake/build/bin/naming-corpus "$out/bin/"
      cp .lake/build/bin/lifecycle-corpus "$out/bin/"
      cp .lake/build/bin/singular-driver "$out/bin/"
      cp .lake/build/bin/singular-m1 "$out/bin/"
      cp lean/corpus.json lean/theorem-debt.json \
        lean/naming-corpus.json lean/naming-theorem-debt.json \
        lean/lifecycle-corpus.json lean/lifecycle-theorem-debt.json \
        lean/wire-theorem-debt.json lean/driver-corpus.json \
        axioms-report.txt "$out/share/"
      cp lean/m1-corpus.json lean/m1-theorem-debt.json m1-axioms-report.txt "$out/share/"
      cp m1-transport-report.json "$out/share/"
    '';
  };
  checker = pkgs.writeShellApplication {
    name = "model-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      python3 ${src}/tools/check_model.py \
        --binary ${package}/bin/singular-corpus \
        --naming-binary ${package}/bin/naming-corpus \
        --lifecycle-binary ${package}/bin/lifecycle-corpus \
        --driver-binary ${package}/bin/singular-driver \
        --axioms-report ${package}/share/axioms-report.txt \
        --root ${src}
      python3 ${src}/tools/check_m1.py \
        --binary ${package}/bin/singular-m1 \
        --axioms-report ${package}/share/m1-axioms-report.txt \
        --root ${src}
    '';
  };
in
{
  inherit package;
  apps.model-check = {
    type = "app";
    program = pkgs.lib.getExe checker;
  };
  check = pkgs.runCommand "singular-model-check" { } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
