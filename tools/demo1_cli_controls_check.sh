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
# statement ledger. The verdict section is printed. The scratch is removed
# on exit; DEMO1_KEEP_SCRATCH=1 keeps it and prints its path. Before its exit is
# trusted, the run must have judged at least one clause
# (demo1_cli_controls_ran.sh), which also names every clause that does not
# hold or is uncovered and keeps the receipts in DEMO1_CONTROLS_RESULTS when
# that is set.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$(cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
controls_sh="${DEMO1_CONTROLS:-$here/demo1_cli_controls.sh}"
ran_sh="${DEMO1_CONTROLS_RAN:-$here/demo1_cli_controls_ran.sh}"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1-controls.XXXXXX")"
# Stop the node before removing the tree. A mode-000 directory left by the
# run is made writable first. DEMO1_KEEP_SCRATCH=1 keeps the tree and names it.
# shellcheck disable=SC2329 # the EXIT trap below invokes this
release_scratch() {
  local code=$?
  local _wait
  trap - EXIT
  if [ -n "${scratch:-}" ] && [ -e "$scratch" ]; then
    if command -v pkill >/dev/null 2>&1; then
      pkill -f "cardano-node run --config ${scratch}/" >/dev/null 2>&1 || true
    fi
    for _wait in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
      if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -f "cardano-node run --config ${scratch}/" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if [ "${DEMO1_KEEP_SCRATCH:-}" = 1 ]; then
      echo "kept scratch: $scratch" >&2
    else
      chmod -R u+rwx "$scratch" 2>/dev/null || true
      rm -rf "$scratch" || true
      if [ -e "$scratch" ]; then
        echo "scratch remains: $scratch" >&2
        code=1
      fi
    fi
  fi
  exit "$code"
}
trap release_scratch EXIT
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
bash "$ran_sh" "$scratch/run" "$status" || status=$?
echo "demo1-cli-controls: receipts in $scratch/run/receipts (exit $status)"
exit "$status"
