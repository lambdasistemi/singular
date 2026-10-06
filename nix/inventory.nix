{ pkgs, src }:
let
  # #278 slice 1: the repository code inventory. The checker runs the tool
  # over the FLAKE SOURCE — a store copy with no .git directory — which is
  # one of the two contexts the inventory must reproduce (the other is the
  # tracked checkout, carried by `just inventory` inside `just ci`). The
  # tool reads only Python's standard library and the source tree.
  checker = pkgs.writeShellApplication {
    name = "inventory-check";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      python3 ${src}/tools/code_inventory.py --root ${src}
      python3 ${src}/tools/test_tags_controls.py
    '';
  };
in
{
  apps.inventory-check = {
    type = "app";
    program = pkgs.lib.getExe checker;
  };
  check = pkgs.runCommand "singular-inventory-check" { } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
