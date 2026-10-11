{ pkgs }:
let
  pairsJson = ./../applications/open-datum/negative/pairs.json;
  parts = pkgs.writeShellApplication {
    name = "negative-host-parts";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      jq
    ];
    text = ''
      set -euo pipefail
      parts="$(cat ${pairsJson})"
      count=$(printf '%s' "$parts" | jq -r '.part | length')
      if [ "$count" -eq 0 ]; then
        echo "negative-host-parts: FAIL: empty part list" >&2
        exit 1
      fi
      printf '%s\n' "$parts"
    '';
  };
  part = pkgs.writeShellApplication {
    name = "negative-host-part";
    runtimeInputs = with pkgs; [
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
      python3
    ];
    text = ''
      [ "$#" -eq 1 ] && [ -n "$1" ] || { echo "usage: negative-host-part PART" >&2; exit 2; }
      bash ${./../tools/negative_host_part.sh} "$PWD" "$1"
    '';
  };
  ordinary = pkgs.writeShellApplication {
    name = "negative-host-ordinary";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      diffutils
      findutils
      gnugrep
      jq
      nix
      binutils
    ];
    text = ''
      bash ${./../tools/negative_host_ordinary.sh} "$PWD"
    '';
  };
  lint = pkgs.writeShellApplication {
    name = "negative-host-lint";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      findutils
      gnugrep
      nix
      yq-go
    ];
    text = ''
      bash ${./../tools/negative_host_lint.sh} "$PWD"
    '';
  };
  mutants = pkgs.writeShellApplication {
    name = "negative-host-mutants";
    runtimeInputs = with pkgs; [
      bash
      coreutils
      diffutils
      findutils
      gawk
      git
      gnugrep
      gnutar
      gzip
      jq
      just
      nix
      procps
    ];
    text = ''
      bash ${./../tools/negative_host_mutants.sh} "$PWD" "$@"
    '';
  };
in
{
  negative-host-parts = {
    type = "app";
    program = pkgs.lib.getExe parts;
  };
  negative-host-part = {
    type = "app";
    program = pkgs.lib.getExe part;
  };
  negative-host-ordinary = {
    type = "app";
    program = pkgs.lib.getExe ordinary;
  };
  negative-host-lint = {
    type = "app";
    program = pkgs.lib.getExe lint;
  };
  negative-host-mutants = {
    type = "app";
    program = pkgs.lib.getExe mutants;
  };
}
