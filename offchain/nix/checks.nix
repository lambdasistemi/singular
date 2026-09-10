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
in
{
  library = components.library;
  cage-tests = components.tests.cage-tests;
  cage-tests-e2e = e2eTestsWrapped;
  cage-test-vectors = components.exes.cage-test-vectors;
  lint = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = shell.nativeBuildInputs;
    excludeShellChecks = [ "SC2046" "SC2086" ];
    text = ''
      cd "${../. + "/"}"
      fourmolu -m check $(find lib app test e2e-test -name '*.hs')
      hlint lib app test e2e-test
    '';
  };
  vectors-freshness = pkgs.runCommand "vectors-freshness" {
    nativeBuildInputs = [ pkgs.aiken ];
  } ''
    ${pkgs.lib.getExe components.exes.cage-test-vectors} --aiken > "$TMPDIR/cage_vectors.ak"
    aiken fmt "$TMPDIR/cage_vectors.ak"
    diff -u ${../../validators/cage_vectors.ak} "$TMPDIR/cage_vectors.ak" \
      || (echo "ERROR: committed vectors are stale" && exit 1)
    touch $out
  '';
}
