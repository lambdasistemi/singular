{ pkgs, src }:
let
  package = pkgs.stdenv.mkDerivation {
    pname = "singular-model";
    version = "0.1.0";
    src = pkgs.lib.cleanSourceWith {
      inherit src;
      filter = path: type: !(builtins.elem (builtins.baseNameOf path) [ ".lake" ".git" "site" "result" "__pycache__" ]);
    };
    nativeBuildInputs = [ pkgs.lean4 pkgs.python3 ];
    buildPhase = ''
      lake build
      python3 tools/check_model.py
    '';
    installPhase = ''
      mkdir -p "$out/bin" "$out/share"
      cp .lake/build/bin/singular-corpus "$out/bin/"
      cp lean/corpus.json lean/theorem-debt.json "$out/share/"
    '';
  };
  checker = pkgs.writeShellApplication {
    name = "model-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''python3 ${src}/tools/check_model.py --binary ${package}/bin/singular-corpus --root ${src}'';
  };
in {
  inherit package;
  apps.model-check = { type = "app"; program = pkgs.lib.getExe checker; };
  check = pkgs.runCommand "singular-model-check" {} ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
