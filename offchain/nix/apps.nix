{ pkgs, checks }:
let
  runnable = {
    inherit (checks.apps)
      cage-tests
      record-value-tests
      cage-test-vectors
      application-boundary-check
      application-boundary-controls
      ;
    inherit (checks)
      cage-tests-e2e
      lint
      ;
  };
in
builtins.mapAttrs (_: check: {
  type = "app";
  program = pkgs.lib.getExe check;
}) runnable
