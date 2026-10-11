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
  # #562 item 5a: the inventory orphan controls only. The test-tag controls
  # already run inside inventory-check above; they are not added a second
  # time. The script owns its scratch exports (mktemp with trap cleanup,
  # bounded to the run, no process stopped) and never touches the tree.
  apps.inventory-controls = {
    type = "app";
    program = pkgs.lib.getExe (
      pkgs.writeShellApplication {
        name = "inventory-controls";
        runtimeInputs = with pkgs; [
          bash
          coreutils
          git
          gnugrep
          gnused
          python3
        ];
        text = ''bash tools/code_inventory_controls.sh'';
      }
    );
  };
  check = pkgs.runCommand "singular-inventory-check" { } ''
    ${pkgs.lib.getExe checker}
    touch "$out"
  '';
}
