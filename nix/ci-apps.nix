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
    builtins.filter (p: (p.pname or "") == "aiken") onchain.devShells.${system}.default.nativeBuildInputs
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

  naming-drift-check = app (
    pkgs.writeShellApplication {
      name = "naming-drift-check";
      runtimeInputs = [ namingGhc ];
      text = ''bash offchain/naming/run-drift-check.sh "$@"'';
    }
  );
}
