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
    # Strict runtime closure for every external tool the text execs. The
    # wrapper prepends these and then falls through to the host PATH, so a
    # missing tool passes on a dev host that happens to supply it and fails
    # on a clean CI runner — the exact-head Off-chain lint RED at e3b052e
    # (awk: command not found, then the fail-closed exclusion check
    # reporting an empty discovered extent). shell.nativeBuildInputs
    # already carries fourmolu and hlint; coreutils (sort/tr/wc), gawk,
    # gnugrep and findutils (find) close the rest, the same explicit
    # closure the component-inventory checker uses.
    runtimeInputs = shell.nativeBuildInputs ++ [
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.findutils
    ];
    excludeShellChecks = [ "SC2046" "SC2086" ];
    text = ''
      cd "${../. + "/"}"
      # Active Haskell source extent, discovered at run time: every
      # hs-source-dirs the Cabal package declares, plus the two direct-GHC
      # naming check sources (naming/run-suite.sh and
      # naming/run-drift-check.sh compile naming/test and naming/drift with
      # the dev-shell GHC outside any Cabal stanza). A new Cabal component
      # or naming source is therefore linted without editing this app.
      # P2 (finding 024, verdict 025): the discovery step's own failure must
      # end the run here, with a discovery-specific reason. The assignment
      # carries awk's exit status, so a missing or unreadable Cabal file or a
      # broken awk program can no longer be swallowed by the trailing printf
      # of the naming dirs and resurface later as an incidental
      # Fourmolu/HLint exclusion failure over a partial naming-only extent.
      # Empty discovery is refused directly too: a Cabal parse miss must not
      # degrade to the two literal naming dirs.
      cabal_dirs=$(
        awk '/^[ \t]*hs-source-dirs:/ {
          sub(/^[ \t]*hs-source-dirs:[ \t]*/, "")
          for (i = 1; i <= NF; i++) print $i
        }' singular-registry.cabal
      ) || { echo "lint: source discovery failed: cannot read singular-registry.cabal (awk exit $?)" >&2; exit 1; }
      [ -n "$cabal_dirs" ] || { echo "lint: source discovery found no hs-source-dirs in singular-registry.cabal" >&2; exit 1; }
      dirs=$(
        printf '%s\n' "$cabal_dirs" naming/test naming/drift
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
      # #278 S2: Fourmolu covers the WHOLE discovered extent under the
      # house configuration — the committed fourmolu.yaml at the
      # repository root, passed explicitly so a missing configuration
      # fails loudly instead of silently falling back to Fourmolu
      # defaults. The #264 A-003 source fence (journey/verifier and
      # journey/retire-verify kept at their intake bytes) is removed by
      # #278 S2: every discovered Haskell source is formatted and checked,
      # with no directory exclusions.
      # The GHC option only lets fourmolu parse the postpositive-qualified
      # imports of the two direct-GHC naming sources; sources without that
      # syntax format exactly as before (ruling A-002, configuration only).
      fourmolu --config ${../../fourmolu.yaml} --ghc-opt=-XImportQualifiedPost -m check $files
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
      # Every exclusion here and the retained debt are owned by #278 S3; a newly added directory joins HLint
      # automatically, and adding one of these names back requires
      # clearing its debt.
      hlint_excluded="journey journey/li01 journey/lmlc journey/recovery journey/retirement journey/register journey/li-refusals journey/repair journey/retire-verify journey/verifier naming/test naming/drift update-terminal"
      hlint_dirs=$(printf '%s\n' $dirs | grep -vxF -f <(printf '%s\n' $hlint_excluded))
      [ -n "$hlint_dirs" ] || { echo "lint: HLint covered set is empty" >&2; exit 1; }
      echo "lint inventory: $(printf '%s\n' $files | wc -l) files in $(printf '%s\n' $dirs | wc -l) dirs; fourmolu over $(printf '%s\n' $files | wc -l) files under the house fourmolu.yaml, no exclusions; hlint over $(printf '%s\n' $hlint_dirs | wc -l) dirs ($(printf '%s\n' $hlint_excluded | wc -w) excluded, debt to #278 S3)" >&2
      hlint $hlint_dirs
    '';
  };
}
