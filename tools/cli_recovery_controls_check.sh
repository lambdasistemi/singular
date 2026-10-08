#!/usr/bin/env bash
# cli-recovery-controls (#325): the ordinary CLI's recovery controls from
# this checkout — a lost acknowledgement, a confirmed fold interrupted
# before public replay or observation, a transaction never sent, and an
# accepting control — on one fresh development node.
#
# usage: cli_recovery_controls_check.sh REPO-ROOT
#
# `singular` and the development node come from the offchain flake and
# the blueprint from the onchain flake. The verdict table is printed. The
# scratch is removed on exit. DEMO1_KEEP_SCRATCH=1 keeps it and prints its
# path; the cross-wallet collection sets that while it copies the receipts.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$(cd "$1" && pwd)"
here="$(cd "$(dirname "$0")" && pwd)"
controls_sh="${CLI_RECOVERY_CONTROLS:-$here/cli_recovery_controls.sh}"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cli-recovery.XXXXXX")"
# The controls remove their own work directory unless the keep switch is
# set. This removes the parent scratch either way, after the controls return.
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
blueprint="$(build ../onchain#plutus-blueprint)"

status=0
bash "$controls_sh" "$singular" "$devnet" "$blueprint" "$scratch/run" "$root" || status=$?
echo "cli-recovery-controls: receipts and registry in $scratch/run (exit $status)"
exit "$status"
