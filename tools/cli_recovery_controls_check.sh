#!/usr/bin/env bash
# cli-recovery-controls (#325): the ordinary CLI's recovery controls from
# this checkout — a lost acknowledgement, a confirmed fold interrupted
# before public replay or observation, a transaction never sent, and an
# accepting control — on one fresh development node.
#
# usage: cli_recovery_controls_check.sh REPO-ROOT
#
# `singular` and the development node come from the offchain flake and
# the blueprint from the onchain flake. The verdict table is printed; the
# receipts and the registry stay in the run's directory, named on the
# last line.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$(cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
controls_sh="${CLI_RECOVERY_CONTROLS:-$here/cli_recovery_controls.sh}"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cli-recovery.XXXXXX")"
build() { nix build --quiet --no-link --print-out-paths "$@"; }

cd "$root/offchain"
singular="$(build .#singular)/bin/singular"
devnet="$(build .#devnet)/bin/devnet"
blueprint="$(build ../onchain#plutus-blueprint)"

status=0
bash "$controls_sh" "$singular" "$devnet" "$blueprint" "$scratch/run" "$root" || status=$?
echo "cli-recovery-controls: receipts and registry in $scratch/run (exit $status)"
exit "$status"
