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
  record-value-tests = components.tests.record-value-tests;
  cage-tests-e2e = e2eTestsWrapped;
  cage-test-vectors = components.exes.cage-test-vectors;
  lint = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = shell.nativeBuildInputs;
    excludeShellChecks = [ "SC2046" "SC2086" ];
    text = ''
      cd "${../. + "/"}"
      # Active Haskell source extent, discovered at run time: every
      # hs-source-dirs the Cabal package declares, plus the two direct-GHC
      # naming check sources (naming/run-suite.sh and
      # naming/run-drift-check.sh compile naming/test and naming/drift with
      # the dev-shell GHC outside any Cabal stanza). A new Cabal component
      # or naming source is therefore linted without editing this app.
      dirs=$(
        awk '/^[ \t]*hs-source-dirs:/ {
          sub(/^[ \t]*hs-source-dirs:[ \t]*/, "")
          for (i = 1; i <= NF; i++) print $i
        }' singular-registry.cabal
        printf '%s\n' naming/test naming/drift
      )
      # Deduplicate nested declarations (journey contains journey/li01 and
      # friends, so every file must be listed once), then fail closed: a
      # Cabal parse miss or a renamed directory must never lint nothing
      # and exit 0.
      dirs=$(printf '%s\n' "$dirs" | sort -u)
      [ -n "$dirs" ] || { echo "lint: discovered no source directories" >&2; exit 1; }
      for d in $dirs; do
        [ -d "$d" ] || { echo "lint: declared source directory missing: $d" >&2; exit 1; }
      done
      files=$(find $dirs -name '*.hs' | sort -u)
      [ -n "$files" ] || { echo "lint: no Haskell sources in the discovered extent" >&2; exit 1; }
      # Fourmolu covers the discovered extent except the two independent
      # verifier sources (epic ruling A-003): journey/verifier and
      # journey/retire-verify are inside this ticket's source fence, so
      # their intake bytes are preserved (forward restoration after the
      # format pass) and formatting them is owned by the final
      # integration child #278. This exclusion is about the source fence,
      # not about formatter capability; both components stay in the Cabal
      # inventory and the component-build closure.
      fourmolu_excluded="journey/verifier journey/retire-verify"
      fmt_files=$(printf '%s\n' $files | grep -vE "^($(echo $fourmolu_excluded | tr ' ' '|'))/")
      [ -n "$fmt_files" ] || { echo "lint: formatter extent is empty" >&2; exit 1; }
      # Fail closed on an inert exclusion: every configured exclusion must
      # provably remove at least one discovered file, so a pattern that
      # matches nothing (the F-003-1 defect) fails the command instead of
      # silently widening the formatter extent.
      for x in $fourmolu_excluded; do
        printf '%s\n' $files | grep -q "^$x/" || { echo "lint: configured Fourmolu exclusion removed no discovered file: $x" >&2; exit 1; }
      done
      # The GHC option only lets fourmolu parse the postpositive-qualified
      # imports of the two direct-GHC naming sources; sources without that
      # syntax format exactly as before (ruling A-002, configuration only).
      fourmolu --ghc-opt=-XImportQualifiedPost -m check $fmt_files
      # HLint runs on the discovered extent minus the directories carrying
      # baseline hint debt (ruling A-002 D1-a). The debt is retained, not
      # reclassified green and not blanket-ignored. Measured per directory
      # at cc6ea00 for the formatted sources and at intake b382604 for the
      # two restored verifier sources: journey 104, journey/retirement 24,
      # journey/retire-verify 19 (intake bytes), journey/lmlc 14,
      # journey/recovery 13, journey/verifier 11 (intake bytes),
      # journey/register 9, journey/repair 7, journey/li-refusals 5,
      # journey/li01 3, naming/test 2, naming/drift 2, update-terminal 1
      # — 214 hints, all semantic (eta-reduce, use-void, fewer-imports
      # class), unfixable inside this ticket's no-semantic-rewrite fence.
      # Every exclusion here and the retained debt are owned by the final
      # integration child #278; a newly added directory joins HLint
      # automatically, and adding one of these names back requires
      # clearing its debt.
      hlint_excluded="journey journey/li01 journey/lmlc journey/recovery journey/retirement journey/register journey/li-refusals journey/repair journey/retire-verify journey/verifier naming/test naming/drift update-terminal"
      hlint_dirs=$(printf '%s\n' $dirs | grep -vxF -f <(printf '%s\n' $hlint_excluded))
      [ -n "$hlint_dirs" ] || { echo "lint: HLint covered set is empty" >&2; exit 1; }
      echo "lint inventory: $(printf '%s\n' $files | wc -l) files in $(printf '%s\n' $dirs | wc -l) dirs; fourmolu over $(printf '%s\n' $fmt_files | wc -l) files ($(( $(printf '%s\n' $files | wc -l) - $(printf '%s\n' $fmt_files | wc -l) )) files removed by A-003 exclusion); hlint over $(printf '%s\n' $hlint_dirs | wc -l) dirs ($(printf '%s\n' $hlint_excluded | wc -w) excluded, debt to #278)" >&2
      hlint $hlint_dirs
    '';
  };
}
