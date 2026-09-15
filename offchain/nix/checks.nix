{ pkgs, components, shell, cardanoNode }:
let
  # The devnet E2E spawns cardano-node as a subprocess via
  # System.Process.proc, which looks the binary up on PATH.
  # Wrap the test binary so it brings its own cardano-node —
  # pinned in the top-level flake.nix to match the devnet
  # Dockerfile.
  e2eTestsRaw = components.tests.e2e-tests;
  e2eTestsWrapped = pkgs.runCommand "cage-tests-e2e" {
    buildInputs = [ pkgs.makeWrapper ];
    meta = (e2eTestsRaw.meta or { }) // {
      mainProgram = "cage-tests-e2e";
    };
  } ''
    mkdir -p $out/bin
    makeWrapper ${pkgs.lib.getExe e2eTestsRaw} $out/bin/cage-tests-e2e \
      --prefix PATH : ${cardanoNode}/bin
  '';
  lintRunner = files: pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = shell.nativeBuildInputs;
    text = ''
      cd "${../. + "/"}"
      ${if files == null then ''
        echo "Lint needs an explicit merge-base selection; run bash lint-changes.sh BASE" >&2
        exit 1
      '' else ""}
      sources=(${pkgs.lib.escapeShellArgs (if files == null then [] else files)})
      if (( ''${#sources[@]} == 0 )); then
        echo "No changed Haskell sources in lib/app/test/e2e-test"
        exit 0
      fi
      fourmolu -m check "''${sources[@]}"
      hlint "''${sources[@]}"
    '';
  };
in
{
  library = components.library;
  # A test component alone only builds. Execute it in the check builder.
  cage-tests = pkgs.runCommand "cage-tests-executed" {
    meta.mainProgram = "cage-tests";
  } ''
    ${pkgs.lib.getExe components.tests.cage-tests} > unit-tests.log 2>&1 || { cat unit-tests.log; exit 1; }
    cat unit-tests.log
    mkdir -p $out
    cp unit-tests.log $out/
    ln -s ${components.tests.cage-tests}/bin $out/bin
  '';
  cage-tests-e2e = e2eTestsWrapped;
  cage-test-vectors = components.exes.cage-test-vectors;
  # Preserve nix run .#lint while making nix build/check execute lint too.
  lint = pkgs.lib.makeOverridable ({ files ? null }: pkgs.runCommand "offchain-lint-executed" {
    meta.mainProgram = "lint";
  } ''
    ${pkgs.lib.getExe (lintRunner files)} > lint.log 2>&1 || { cat lint.log; exit 1; }
    cat lint.log
    mkdir -p $out
    cp lint.log $out/
    ln -s ${lintRunner files}/bin $out/bin
  '') {};
}
