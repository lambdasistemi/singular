{ pkgs, src }:
let
  # The gate invokes git at the release boundary (candidate binding is
  # fail-closed on unknown identity), so git rides in every gate closure.
  # A missing git must never stand in for honest debt.
  gateInputs = [ pkgs.python3 pkgs.git ];
  checker = pkgs.writeShellApplication {
    name = "coverage-check";
    runtimeInputs = gateInputs;
    text = ''
      cd ${src}/conformance/coverage
      python3 -m singular_coverage.gate --root ${src} completion \
        --expect INCOMPLETE
    '';
  };
  gate = pkgs.writeShellApplication {
    name = "coverage-gate";
    runtimeInputs = gateInputs;
    text = ''
      cd ${src}/conformance/coverage
      python3 -m singular_coverage.gate "$@"
    '';
  };
  tests = pkgs.writeShellApplication {
    name = "coverage-tests";
    runtimeInputs = gateInputs;
    text = ''
      cd ${src}/conformance/coverage
      python3 -m unittest discover -s tests
    '';
  };
in {
  apps.coverage-check = { type = "app"; program = pkgs.lib.getExe checker; };
  apps.coverage-gate = { type = "app"; program = pkgs.lib.getExe gate; };
  apps.coverage-tests = { type = "app"; program = pkgs.lib.getExe tests; };
  check = pkgs.runCommand "singular-coverage-check" {} ''
    ${pkgs.lib.getExe checker}
    ${pkgs.lib.getExe tests}
    touch "$out"
  '';
}
