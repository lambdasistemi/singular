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
builtins.mapAttrs (name: check: {
  type = "app";
  meta.description = check.meta.description or "Run ${name}";
  program = pkgs.lib.getExe check;
}) runnable
