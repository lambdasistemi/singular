# Tool, not a guarantee: the one-command Demo 1 rehearsal
{
  pkgs,
  rehearsal,
}:
let
  # The wrapper the presenter runs: everything below the flake's app of this
  # name. The scripts themselves live in the repository's own rehearsal
  # directory (the `rehearsal` argument), so the app is self-contained: it
  # carries the scenes, the harness and WORKAROUNDS.md from this checkout.
  #
  # The wrapper owns two directories and nothing else: the output directory
  # (the casts, the gate output and the run log; `--out`, default
  # ./demo1-rehearsal-out in the working directory, git-ignored) and a
  # scratch directory created under TMPDIR and removed on every exit (the
  # release, the extracted archive, the devnet and the two players'
  # directories). A run leaves no process behind: the devnet is stopped by
  # the pids its own bring-up recorded, in an exit trap that fires on failure
  # too. Devnet only; run it from the repository root.
  app = pkgs.writeShellApplication {
    name = "demo1-rehearsal";
    runtimeInputs = with pkgs; [
      asciinema
      bash
      coreutils
      diffutils
      findutils
      gawk
      git
      gnugrep
      gnused
      gnutar
      gzip
      jq
      nix
      procps
      systemd
      tmux
    ];
    text = ''
      usage() {
        cat <<'USAGE'
      demo1-rehearsal: record the Demo 1 play in one command

      usage: demo1-rehearsal [--out DIR]

      Builds the on-chain release from this checkout, builds the release's
      own binaries from the archive's flakes, starts a fresh private devnet,
      records one cast per scene of the play (the vault; named; unique;
      permanent; permissionless; reusable), runs the cast gate on every cast
      and the chain assertions on the finished chain, stops the devnet, and
      prints one result line per scene and the totals. It exits non-zero on
      any failure, naming the first failing phase.

        --out DIR   where the casts, the gate output and the run log go
                    (default: ./demo1-rehearsal-out, git-ignored)

      Environment:
        REHEARSAL_PAUSE_SCALE  multiplies every read pause (default 1; any
                               other value ends the run with the line
                               NOT THE PRESENTER'S TIMING and exit 0 only if
                               everything else passed)

      Run it from the repository root, through the flake's app of this name.
      Devnet only: it never touches any other network, and it stops only the
      processes it recorded. The scratch directory lives under TMPDIR and is
      removed on every exit; the memory cap is 48 GB and the whole run is
      bounded at 30 minutes through systemd-run when the host has it (one
      line says so when it does not).
      USAGE
      }

      out=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --out)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            out=$2; shift 2
            ;;
          --help | -h) usage; exit 0 ;;
          *) usage >&2; exit 2 ;;
        esac
      done
      [ -n "$out" ] || out=./demo1-rehearsal-out
      mkdir -p "$out"
      out="$(cd "$out" && pwd)"
      root="$PWD"
      [ -f "$root/applications/open-datum/offchain/flake.nix" ] || {
        echo "demo1-rehearsal: run from the repository root" >&2
        exit 3
      }

      # The release assembly runs the checkout's own Python tools; keep their bytecode out of the checkout.
      export PYTHONDONTWRITEBYTECODE=1

      # One memory-capped, time-bounded scope for the whole run.
      if [ -z "''${DEMO1_REHEARSAL_UNDER_SCOPE:-}" ]; then
        if command -v systemd-run >/dev/null 2>&1; then
          exec systemd-run --user --scope -q -p MemoryMax=48G -p MemorySwapMax=0 \
            timeout 1800 env DEMO1_REHEARSAL_UNDER_SCOPE=1 "$0" --out "$out"
        fi
        echo "demo1-rehearsal: no systemd-run on this host; running without the memory cap and the 30-minute bound"
      fi

      export REHEARSAL_ROOT="$root"
      export REHEARSAL_PAUSE_SCALE="''${REHEARSAL_PAUSE_SCALE:-1}"
      exec bash "${rehearsal}/run-rehearsal.sh" "${rehearsal}" "$out"
    '';
  };
in
{
  demo1-rehearsal = {
    type = "app";
    program = pkgs.lib.getExe app;
  };
}
