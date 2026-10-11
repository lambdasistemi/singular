{ pkgs, checks }:
let
  runnable = {
    inherit (checks.apps)
      open-datum-tests
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
