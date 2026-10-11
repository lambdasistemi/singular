#!/usr/bin/env bash
# cli-recovery-controls (#325): the ordinary CLI's recovery controls from
# this checkout — a lost acknowledgement, a confirmed fold interrupted
# before public replay or observation, a transaction never sent, and an
# accepting control — on one fresh development node.
#
# usage: cli_recovery_controls_check.sh REPO-ROOT
#
# `singular` and the development node come from the offchain flake,
# `open-datum` from the application's flake (as the journey wires it), and
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
  local record
  trap - EXIT
  if [ -n "${scratch:-}" ] && [ -e "$scratch" ]; then
    # The controller joins its children; this wrapper checks exact retained
    # identities before removing evidence. A broad pkill cannot prove cleanup.
    for record in "$scratch"/run/original-node.json "$scratch"/run/replacement-node-*.json "$scratch"/run/devnet-process.json; do
      [ -f "$record" ] || continue
      if ! python3 "$(dirname "$controls_sh")/fixture_process.py" assert-gone "$record"; then
        echo "cleanup incomplete; retained $scratch" >&2
        [ "$code" -ne 0 ] || code=1
        exit "$code"
      fi
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
singular="$(build .#singular-test-harness)/bin/singular"
devnet="$(build .#devnet)/bin/devnet"
# The raw devnet reads its genesis from E2E_GENESIS_DIR, falling back to a
# relative `e2e-test/genesis` that only resolves from the registry tree.
# The build below leaves the caller in the application's tree, so point the
# devnet at the registry tree's genesis regardless of the working directory.
export E2E_GENESIS_DIR="$root/offchain/e2e-test/genesis"
# S5.2: recovery runs open-datum alongside singular, so the blueprint is
# the merged deployment document (application + witnesses, one build).
blueprint="$(build ../applications/open-datum/onchain#open-datum-blueprint)"
cd "$root/applications/open-datum/offchain"
open_datum="$(build .#open-datum-test-harness)/bin/open-datum"

echo "explicit test-build executables: singular=$singular open-datum=$open_datum"
sha256sum "$singular" "$open_datum"
status=0
bash "$controls_sh" "$singular" "$open_datum" "$devnet" "$blueprint" "$scratch/run" "$root" || status=$?
echo "cli-recovery-controls: receipts and registry in $scratch/run (exit $status)"
exit "$status"
