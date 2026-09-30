#!/usr/bin/env bash
# demo1-cli-controls (#299): the ordinary CLI's refusal controls from this
# checkout — a second insertion of an Active key and an insertion of a
# Terminal key, each beside an accepting control — on one fresh
# development node.
#
# usage: demo1_cli_controls_check.sh REPO-ROOT
#
# `singular` and the development node come from the offchain flake, the
# controls runner from the conformance flake, the blueprint from the
# onchain flake, and the bound statements from the application's own
# statement ledger. The verdict section is printed; the receipts stay in
# the run's directory, which is named on the last line.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$(cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
controls_sh="${DEMO1_CONTROLS:-$here/demo1_cli_controls.sh}"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-controls.XXXXXX")"
build() { nix build --quiet --no-link --print-out-paths "$@"; }

cd "$root/offchain"
singular="$(build .#singular)/bin/singular"
devnet="$(build .#devnet)/bin/devnet"
controls="$(build ../conformance#cli-controls)/bin/cli-controls"
blueprint="$(build ../onchain#plutus-blueprint)"

status=0
bash "$controls_sh" "$singular" "$devnet" "$controls" "$blueprint" \
  "$root/applications/open-datum/ledgers.json" "$scratch/run" || status=$?
cat "$scratch/run/controls.md" 2>/dev/null || true
echo "demo1-cli-controls: receipts in $scratch/run/receipts (exit $status)"
exit "$status"
