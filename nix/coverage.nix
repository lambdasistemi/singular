{ pkgs, src }:
let
  checker = pkgs.writeShellApplication {
    name = "coverage-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      cd ${src}/conformance/coverage
      python3 -m singular_coverage.gate --root ${src} completion \
        --expect INCOMPLETE
    '';
  };
in {
  apps.coverage-check = { type = "app"; program = pkgs.lib.getExe checker; };
  check = pkgs.runCommand "singular-coverage-check" {} ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
