{ pkgs, checks }:
let
  runnable = {
    inherit (checks.apps)
      cage-tests
      record-value-tests
      cage-test-vectors
      ;
    inherit (checks)
      cage-tests-e2e
      lint
      ;
  };
in
builtins.mapAttrs (name: check: {
  type = "app";
  meta.description = check.meta.description or "Run ${name}";
  program = pkgs.lib.getExe check;
}) runnable
