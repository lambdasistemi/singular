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
in
{
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
}
