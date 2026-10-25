# CI steps that used to run inside `nix develop`, as plain apps run with
# `nix run`. Each runs from the repository root of the checkout.
{
  pkgs,
  offchain,
  onchain,
  system,
}:
let
  # The pinned Aiken the onchain flake's shell carries, so formatting
  # matches `aiken fmt` in that shell byte for byte.
  aiken = builtins.head (
    builtins.filter (
      p: (p.pname or "") == "aiken"
    ) onchain.devShells.${system}.default.nativeBuildInputs
  );
  namingGhc = pkgs.haskellPackages.ghcWithPackages (p: [
    p.bytestring
    p.crypton
    p.directory
    p.memory
  ]);
  app = drv: {
    type = "app";
    program = pkgs.lib.getExe drv;
  };
  # The Aiken tests that read the preimage byte vectors are made from the one
  # committed table, offchain/test/fixtures/preimage-vectors.json, which the
  # off-chain suite reads directly. `generate` writes the committed module;
  # `check` diffs it with a fresh one, both formatted with the pinned Aiken.
  preimageVectors = pkgs.writeShellApplication {
    name = "preimage-vectors";
    runtimeInputs = [
      aiken
      pkgs.coreutils
      pkgs.diffutils
      pkgs.python3
    ];
    text = ''
      # Tool, not a guarantee: writes the Aiken rows of the preimage byte vectors from the shared table; their freshness is enforced by the vectors-check job.
      table=offchain/test/fixtures/preimage-vectors.json
      committed=onchain/validators/singular_state_preimage_vectors.tests.ak
      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      python3 tools/preimage_vectors.py "$table" "$tmp/generated.ak"
      aiken fmt "$tmp/generated.ak"
      case "''${1:-}" in
        generate)
          cp "$tmp/generated.ak" "$committed"
          echo "preimage-vectors: wrote $committed"
          ;;
        check)
          if diff -u "$committed" "$tmp/generated.ak"; then
            echo "preimage-vectors: PASS — committed tests match the table"
          else
            echo "ERROR: the preimage vector tests are stale — run the preimage-vectors app with generate and commit" >&2
            exit 1
          fi
          ;;
        *)
          echo "usage: preimage-vectors generate|check" >&2
          exit 2
          ;;
      esac
    '';
  };
in
{
  preimage-vectors = app preimageVectors;

  presentation-check = app (
    pkgs.writeShellApplication {
      name = "presentation-check";
      runtimeInputs = [ pkgs.python3 ];
      text = ''python3 tools/check_presentation.py "$@"'';
    }
  );

  vectors-check = app (
    pkgs.writeShellApplication {
      name = "vectors-check";
      runtimeInputs = [
        aiken
        pkgs.coreutils
        pkgs.diffutils
      ];
      text = ''
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        cp ${offchain.packages.${system}.test-vectors} "$tmp/cage_vectors.ak"
        chmod u+w "$tmp/cage_vectors.ak"
        aiken fmt "$tmp/cage_vectors.ak"
        if diff -u onchain/validators/cage_vectors.ak "$tmp/cage_vectors.ak"; then
          echo "vectors-check: PASS — committed golden matches the pinned-Aiken-formatted generator output"
        else
          echo "ERROR: committed vectors are stale — run 'just generate-vectors' and commit" >&2
          exit 1
        fi
        ${pkgs.lib.getExe preimageVectors} check
      '';
    }
  );

  naming-wire-suite = app (
    pkgs.writeShellApplication {
      name = "naming-wire-suite";
      runtimeInputs = [ namingGhc ];
      text = ''bash offchain/naming/run-suite.sh "$@"'';
    }
  );

  e2e-lanes-proof = app (
    pkgs.writeShellApplication {
      name = "e2e-lanes-proof";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gawk
        pkgs.jq
        pkgs.nix
      ];
      text = builtins.readFile ../tools/e2e_parts_proof.sh;
    }
  );

  naming-drift-check = app (
    pkgs.writeShellApplication {
      name = "naming-drift-check";
      runtimeInputs = [ namingGhc ];
      text = ''bash offchain/naming/run-drift-check.sh "$@"'';
    }
  );

  # #562 item 1: the workflow command resolver and its controls. The controls
  # script first resolves the clean tree (every nix run, build and develop
  # reference in the workflows exists), then plants a missing app and a
  # missing package and requires both refused. One hosted job covers the
  # check and its controls. The single clean run's summary reaches the log.
  # Scratch owned: the controls script owns its plant directory under mktemp
  # with bounded lifetime and trap cleanup; no process is stopped.
  workflow-commands-resolve-controls = app (
    pkgs.writeShellApplication {
      name = "workflow-commands-resolve-controls";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gawk
        git
        gnugrep
        gnused
        nix
      ];
      text = ''bash tools/workflow_commands_resolve_controls.sh "$PWD"'';
    }
  );

  # #562 item 3: the publication boundary control. The control script
  # runs the publisher definition from nix/release.nix with only gh
  # replaced by a recorder, through its positive path and its mutated
  # cases; exit 0 with the final line ALL CASES HELD is the pass
  # criterion. The wrapper owns the outputs the control produces:
  # OUTDIR and EVIDENCE default into a scratch directory created and
  # removed on every exit (including setup failure), so the tracked
  # evidence log conformance/coverage/publication-boundary-evidence.log
  # is never written by this app and the tree stays clean; a caller may
  # still set either variable (the hosted job points them under
  # RUNNER_TEMP) to keep the evidence after the run. Setup failure
  # (scratch creation) is exit 2, never a verdict; the script's own exit
  # stays its verdict. Scratch owned: fixtures, mutant copies and the
  # recorder shim all live under OUTDIR inside the wrapper's scratch;
  # bounded to the run with trap cleanup; no process is stopped.
  publication-boundary-controls = app (
    pkgs.writeShellApplication {
      name = "publication-boundary-controls";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        findutils
        git
        gnugrep
        gnutar
        gnupg
        nix
        patch
      ];
      text = ''
        if ! work="$(mktemp -d)"; then
          echo "publication-boundary-controls: setup failed creating the scratch directory (TMPDIR=''${TMPDIR:-unset})" >&2
          exit 2
        fi
        trap 'rm -rf "$work"' EXIT
        export OUTDIR="''${OUTDIR:-$work/publication-boundary}"
        export EVIDENCE="''${EVIDENCE:-$work/publication-boundary-evidence.log}"
        bash conformance/coverage/publication-boundary-check.sh
      '';
    }
  );

  # #562 item 5b: the Haskell format check's negative and positive controls.
  # Supplies the pinned house Fourmolu the offchain lock resolves (the same
  # binary the lint checks run) plus git and core tools the script needs.
  # The script owns its scratch copies (mktemp with trap cleanup, bounded to
  # the run, no process stopped) and never touches the working tree.
  format-controls = app (
    pkgs.writeShellApplication {
      name = "format-controls";
      runtimeInputs = [
        offchain.packages.${system}.fourmolu
        pkgs.bash
        pkgs.coreutils
        pkgs.findutils
        pkgs.gawk
        pkgs.git
        pkgs.gnugrep
        pkgs.gnused
      ];
      text = ''bash tools/format_controls.sh'';
    }
  );

  # #562 item 20: the declared-checks-hosted census. The classifier is a
  # pure function over three plain files (declared entries, hosted
  # references, the exception list with the handed issue states): it reads
  # no flake, no git tree, no network and no clock. The controls feed its
  # table fixtures with no evaluation and drive the integration layer over
  # one offline fixture flake (no network); the whole command costs about
  # two seconds with a warm evaluation cache and about twenty seconds
  # cold, dominated by the fixture-flake evaluations. The live census
  # evaluates every tracked flake once and the shared workflow extraction
  # once, then calls the classifier. Each wrapper owns
  # a scratch directory created and removed on every exit (including setup
  # failure), so no build state lands in the checkout; setup failure is
  # exit 2, never a verdict; no process is stopped. The job runs the
  # table test before the live run.
  declared-checks-classify-controls = app (
    pkgs.writeShellApplication {
      name = "declared-checks-classify-controls";
      # The table test drives the classifier over fixtures, the resolver's
      # shared extraction over a fixture workflow, and the integration
      # layer over a scratch fixture repository, so git, nix and jq come
      # from here too (a stripped-PATH run refused the shadow case until
      # jq was declared).
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gawk
        git
        gnugrep
        gnused
        jq
        nix
      ];
      text = ''bash tools/declared_checks_classify_controls.sh'';
    }
  );

  # #562 item 20: the read-only issue-state query. Reads the pending
  # issue numbers from the declared-not-hosted list and writes
  # `<number> <open|closed>` lines to the caller's output file through a
  # read-only query of the repository's issues. Authentication travels
  # only through the environment (gh reads GH_TOKEN); the script binds,
  # stores and reads no credential itself. A failed query is a setup
  # failure, never a verdict. The wrapper owns a scratch directory created
  # and removed on every exit; the output file is the caller's
  # deliverable, not scratch. No process is stopped.
  declared-checks-issue-states = app (
    pkgs.writeShellApplication {
      name = "declared-checks-issue-states";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gh
        gnused
      ];
      text = ''bash tools/declared_checks_issue_states.sh "$PWD" "$@"'';
    }
  );

  declared-checks-hosted = app (
    pkgs.writeShellApplication {
      name = "declared-checks-hosted";
      # The wrapper runs the integration layer, which calls the resolver's
      # shared extraction as a subprocess in the same strict PATH, so the
      # resolver's grep, sed and awk come from here too (a stripped-PATH
      # run refused the census until they were declared).
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gawk
        git
        gnugrep
        gnused
        jq
        nix
      ];
      text = ''bash tools/declared_checks_collect.sh "$PWD" "$@"'';
    }
  );
}
