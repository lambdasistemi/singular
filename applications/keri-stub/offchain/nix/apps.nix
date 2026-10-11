{ pkgs, checks }:
let
  runnable = {
    inherit (checks.apps)
      keri-stub-tests
      ;
    inherit (checks)
      lint
      ;
  };
in
builtins.mapAttrs (_: check: {
  type = "app";
  program = pkgs.lib.getExe check;
}) runnable
