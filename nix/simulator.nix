{ pkgs, src }:
let
  checker = pkgs.writeShellApplication {
    name = "simulator-check";
    runtimeInputs = [ pkgs.nodejs ];
    text = ''
      cd ${src}
      node simulator/build.mjs --check
      node simulator/gate.mjs
      node simulator/gate.mjs --selftest
    '';
  };
in {
  apps.simulator-check = { type = "app"; program = pkgs.lib.getExe checker; };
  check = pkgs.runCommand "singular-simulator-check" {} ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
