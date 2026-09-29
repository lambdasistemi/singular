#!/usr/bin/env bash
# demo1-cli-check (#299): the Demo 1 journey from the extracted release
# archive, with no checkout in sight.
#
# usage: demo1_cli_check.sh REPO-ROOT
#
# 1. The normal release archive is assembled from REPO-ROOT by the same
#    `release-artifacts` app CI runs, and extracted OUTSIDE the checkout.
# 2. Its run page, DEMO1.md, must be there and must document the five
#    commands in order; a copy of the page with a command removed must
#    fail that same page check (the check's own control).
# 3. The archive's own offchain flake builds `singular` and the
#    development node, and the journey (demo1_cli_journey.sh, beside this
#    script) runs create, insert, inspect, terminate and inspect as five
#    processes against ONE node, with the archive's own blueprint.
# 4. The retained insert-active and update-terminal archive commands run
#    from the same extracted archive with their accepting and refusing
#    controls, asserted by the same observation programs their CI steps
#    use.
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 REPO-ROOT" >&2; exit 2; }
root="$1"
here="$(cd "$(dirname "$0")" && pwd)"
journey="${DEMO1_JOURNEY:-$here/demo1_cli_journey.sh}"
fail() { echo "demo1-cli-check: FAIL: $*" >&2; exit 1; }

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1.XXXXXX")"
release_dir="$scratch/release"; mkdir -p "$release_dir"
(cd "$root" && nix run --quiet .#release-artifacts -- "$release_dir")
version="$(cat "$root/version.txt")"
extracted="$scratch/extracted"; mkdir -p "$extracted"
tar -C "$extracted" -xzf "$release_dir/singular-onchain-$version.tar.gz"
test ! -e "$extracted/.git" || fail "the archive carries a git checkout"

# The page documents the five commands in the journey's order.
page_ok() {
    grep -o 'singular registry [a-z]*' "$1" | awk '{print $3}' | tr '\n' ' ' \
        | grep -q 'create .*insert .*inspect .*terminate .*inspect'
}
test -f "$extracted/DEMO1.md" || fail "the archive carries no DEMO1.md run page"
page_ok "$extracted/DEMO1.md" || fail "DEMO1.md does not document the five commands in order"
grep -v 'singular registry terminate' "$extracted/DEMO1.md" > "$scratch/DEMO1-without-terminate.md"
if page_ok "$scratch/DEMO1-without-terminate.md"; then
    fail "control: a page without terminate passed the page check"
fi

cd "$extracted/offchain"
singular="$(nix build --quiet --no-link --print-out-paths .#singular)/bin/singular"
devnet="$(nix build --quiet --no-link --print-out-paths .#devnet)/bin/devnet"
bash "$journey" "$singular" "$devnet" "$extracted/onchain/plutus.json" "$scratch/journey"

# The retained archive commands, from the same extraction.
observed="$scratch/insert-active.json"
REGISTRY_BLUEPRINT="$extracted/onchain/plutus.json" \
    nix run --quiet .#insert-active -- --observed "$observed"
jq -e '
  .edge == "insertActive"
  and (.fold.txid | test("^[0-9a-f]{64}$"))
  and .wallet.address == .requested.address
  and .wallet.assets == [{"policy": .active.policy, "name": .key, "quantity": 1}]
  and ."key-exists".outcome == "refused"
  and (."key-exists".control.outcome == "accepted")
  and (."key-exists".detail | type == "string" and length > 0)
' "$observed" > /dev/null || fail "insert-active did not observe one active token at the named wallet"

observed="$scratch/update-terminal.json"
REGISTRY_BLUEPRINT="$extracted/onchain/plutus.json" \
    nix run --quiet .#update-terminal -- --observed "$observed"
# shellcheck disable=SC2016
jq -e '
  def txid: type == "string" and test("^[0-9a-f]{64}$");
  def text: type == "string" and length > 0;
  .edge == "updateTerminal"
  and (.retirement != null)
  and (.retirement as $r |
    ($r.activePolicy | text) and ($r.key | text)
    and ($r.insertTxid | txid) and ($r.retireTxid | txid)
    and $r.insertTxid != $r.retireTxid
    and ([$r.roots.beforeInsert, $r.roots.active, $r.roots.terminal]
      | all(.[]; text) and (unique | length == 3))
    and $r.quantities == {"before": 1, "after": 0}
    and $r.mint == [{"policy": $r.activePolicy, "name": $r.key, "quantity": -1}]
    and ($r.source.outref | text)
    and $r.source.policy == $r.activePolicy
    and $r.source.name == $r.key
    and $r.source.quantity == 1
    and $r.leaf == "Terminal"
    and ($r.unknown.detail | text)
    and ($r.unknown.trace == null or $r.unknown.trace == "key-unknown")
    and ($r.unknown.controlTxid | txid)
    and ($r.absent.detail | text)
    and ($r.absent.trace == null or $r.absent.trace == "not-booked")
    and ($r.absent.controlTxid | txid)
  )
' "$observed" > /dev/null || fail "update-terminal observation moved"

echo "demo1-cli-check: PASS from $extracted — five singular processes on one node, the page, and the retained insert-active and update-terminal controls"
