{
  pkgs,
  components,
  shell,
  cardanoNode,
  ghc,
  namingBlueprint,
}:
let
  # Recorded tests read fixtures relative to cwd and copy them for mutation.
  # Stage writable copies so their corruption controls work from any cwd.
  cageTestsWrapped = pkgs.writeShellApplication {
    name = "cage-tests";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      fixture_dir=$(mktemp -d)
      trap 'rm -rf "$fixture_dir"' EXIT
      mkdir -p "$fixture_dir/test"
      cp -R ${../test/fixtures} "$fixture_dir/test/fixtures"
      chmod -R u+w "$fixture_dir/test/fixtures"
      cd "$fixture_dir"
      ${pkgs.lib.getExe components.tests.cage-tests} "$@"
    '';
  };
  # The devnet end-to-end spawns cardano-node as a subprocess via
  # System.Process.proc, which looks the binary up on PATH.
  # Wrap the test binary so it brings its own cardano-node —
  # pinned in the top-level flake.nix to match the devnet
  # Dockerfile.
  e2eTestsRaw = components.tests.e2e-tests;
  e2eTestsWrapped =
    pkgs.runCommand "cage-tests-e2e"
      {
        buildInputs = [ pkgs.makeWrapper ];
        meta = (e2eTestsRaw.meta or { }) // {
          mainProgram = "cage-tests-e2e";
        };
      }
      ''
        mkdir -p $out/bin
        makeWrapper ${pkgs.lib.getExe e2eTestsRaw} $out/bin/cage-tests-e2e \
          --prefix PATH : ${cardanoNode}/bin
      '';
  # A check executes the same binary as its app and retains its output.
  # No devnet process belongs in these sandboxed unit checks.
  unitCheck =
    name: app:
    pkgs.runCommand "${name}-check"
      {
        nativeBuildInputs = [ pkgs.glibcLocales ];
        LANG = "C.UTF-8";
        LC_ALL = "C.UTF-8";
      }
      ''
        ${pkgs.lib.getExe app} > "$out" 2>&1 || { cat "$out"; exit 1; }
      '';
  # #326 R4: a SignedTx is constructible only by signing. The project's
  # GHC type-checks the fixtures under signed-tx-control against the
  # defining Signing module, with local-services'
  # compiled dependencies: no cabal, no package index (D-011).
  signedTxControl =
    pkgs.runCommand "signed-tx-control"
      {
        nativeBuildInputs = [ ghc ];
        src = pkgs.lib.fileset.toSource {
          root = ../..;
          fileset = pkgs.lib.fileset.unions [
            ../../tools/signed_tx_control.sh
            ../../tools/signing-exports.allow
            ../signed-tx-control
            ../local-services/Singular/Registry/Signing.hs
          ];
        };
      }
      ''
        # Every library local-services was built against: its propagated
        # build inputs, followed transitively.
        dbs=()
        declare -A seen=()
        queue=(${components.sublibs.local-services})
        while [ ''${#queue[@]} -gt 0 ]; do
          p=''${queue[0]}
          queue=("''${queue[@]:1}")
          [ -n "''${seen[$p]:-}" ] && continue
          seen[$p]=1
          [ -d "$p/package.conf.d" ] && dbs+=(-package-db "$p/package.conf.d")
          if [ -f "$p/nix-support/propagated-build-inputs" ]; then
            read -r -a next < "$p/nix-support/propagated-build-inputs" || true
            queue+=("''${next[@]}")
          fi
        done
        # Expose exactly local-services's own dependencies, as Cabal does
        # when it compiles Signing.hs.
        for id in $(sed -n '/^depends:/,/^[a-z-]*:/p' \
            ${components.sublibs.local-services}/package.conf.d/*-local-services.conf \
            | grep -v '^[a-z-]*:' ); do
          dbs+=(-package-id "$id")
        done
        bash $src/tools/signed_tx_control.sh "$src" -- -hide-all-packages "''${dbs[@]}" | tee $out
      '';
  # #528 slice 1: the registry library names no application. The check
  # scans the library's sources and its build-depends; the controls plant
  # an import and a dependency in a throwaway copy and must fail there.
  applicationBoundaryCheck = pkgs.writeShellApplication {
    name = "application-boundary-check";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = builtins.readFile ./application-boundary-check.sh;
  };
  applicationBoundaryControls = pkgs.writeShellApplication {
    name = "application-boundary-controls";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    text =
      "check=${pkgs.lib.getExe applicationBoundaryCheck}\n"
      + builtins.readFile ./application-boundary-controls.sh;
  };
in
{
  inherit (components) library;
  signed-tx-control = signedTxControl;
  apps = {
    cage-tests = cageTestsWrapped;
    inherit (components.tests) record-value-tests;
    inherit (components.exes) cage-test-vectors;
    application-boundary-check = applicationBoundaryCheck;
    application-boundary-controls = applicationBoundaryControls;
  };
  cage-tests = unitCheck "cage-tests" cageTestsWrapped;
  record-value-tests =
    pkgs.runCommand "record-value-tests-check"
      {
        nativeBuildInputs = [ pkgs.glibcLocales ];
        LANG = "C.UTF-8";
        LC_ALL = "C.UTF-8";
        NAMING_BLUEPRINT = namingBlueprint;
      }
      ''
        ${pkgs.lib.getExe components.tests.record-value-tests} > "$out" 2>&1 || { cat "$out"; exit 1; }
      '';
  cage-tests-e2e = e2eTestsWrapped;
  cage-test-vectors = unitCheck "cage-test-vectors" components.exes.cage-test-vectors;
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
    excludeShellChecks = [
      "SC2046"
      "SC2086"
    ];
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
        printf '%s\n' "$cabal_dirs" naming/test naming/drift signed-tx-control
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
      # #278 terminal-attestation-permanent: Fourmolu covers the WHOLE discovered extent under the
      # house configuration — the committed fourmolu.yaml at the
      # repository root, passed explicitly so a missing configuration
      # fails loudly instead of silently falling back to Fourmolu
      # defaults. The #264 A-003 source fence (journey/verifier and
      # journey/retire-verify kept at their intake bytes) is removed by
      # #278 terminal-attestation-permanent: every discovered Haskell source is formatted and checked,
      # with no directory exclusions.
      # The GHC option only lets fourmolu parse the postpositive-qualified
      # imports of the two direct-GHC naming sources; sources without that
      # syntax format exactly as before (ruling A-002, configuration only).
      fourmolu --config ${../../fourmolu.yaml} --ghc-opt=-XImportQualifiedPost -m check $files
      # #278 supply-matches-leaf-state: HLint runs over the SAME discovered extent as Fourmolu,
      # with no directory exclusions: the #264 baseline hint debt in the
      # journey, naming/test, naming/drift and update-terminal trees is
      # resolved at the source. A newly added directory joins HLint
      # automatically through the Cabal manifest.
      echo "lint inventory: $(printf '%s\n' $files | wc -l) files in $(printf '%s\n' $dirs | wc -l) dirs; fourmolu and hlint over the same files, house fourmolu.yaml, no exclusions" >&2
      hlint $files
    '';
  };
}
