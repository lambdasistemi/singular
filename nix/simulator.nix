{ pkgs, src }:
let
  checker = pkgs.writeShellApplication {
    name = "simulator-check";
    runtimeInputs = [ pkgs.nodejs pkgs.python3 ];
    text = ''
      cd ${src}
      node simulator/build.mjs --check
      node simulator/gate.mjs
      node simulator/gate.mjs --selftest
      node simulator/lifecycle-gate.mjs
    '';
  };
in {
  apps.simulator-check = { type = "app"; program = pkgs.lib.getExe checker; };
  check = pkgs.runCommand "singular-simulator-check" {} ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
