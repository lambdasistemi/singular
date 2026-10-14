#!/usr/bin/env bash
# demo1-cli-check (#299): the Demo 1 journey from the extracted release
# archive, with no checkout in sight.
#
# usage: demo1_cli_check.sh REPO-ROOT
#
# 1. The normal release archive is assembled from REPO-ROOT by the same
#    `release-artifacts` app CI runs.
# 2. Those assets are verified by `verify-release` (#326) exactly as a
#    published release is, presented as its download input: the sums, the
#    stated model revision, the archive members, and the journey
#    (demo1_cli_journey.sh) — `singular`, `open-datum` and the development
#    node built from the archive's own offchain flake and the application's
#    offchain flake, extracted OUTSIDE the checkout,
#    and the commands run as separate processes against ONE node, a booking
#    and its fold by another wallet among them, with the archive's own
#    blueprint. Injected process controls run in the separate explicit test carrier.
# 3. The run page, DEMO1.md, in that extraction must number exactly the
#    sixteen commands, each in its position: create, the page reading,
#    insert, fold, inspect, update, inspect, terminate, fold, inspect,
#    reject, insert, fold, reclaim, insert, fold. Copies of the
#    page without the page reading, without the fold of the insertion, without
#    update, without the inspection that follows update, without the
#    termination and without the reject must each fail that same
#    check (its own controls).
# 4. The retained insert-active and update-terminal archive commands run
#    from the same extracted archive with their accepting and refusing
#    controls, asserted by the same observation programs their CI steps
#    use.
set -euo pipefail

[ "$#" -eq 1 ] || {
  echo "usage: $0 REPO-ROOT" >&2
  exit 2
}
root="$1"
verify="${DEMO1_VERIFY_RELEASE:?demo1-cli-check needs DEMO1_VERIFY_RELEASE}"
fail() {
  echo "demo1-cli-check: FAIL: $*" >&2
  exit 1
}

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/demo1.XXXXXX")"
# Stop the node before removing the tree: a live node and a mode-000
# directory (the two-actor run) both make a plain removal fail.
# DEMO1_KEEP_SCRATCH=1 keeps the tree and names it.
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
release_dir="$scratch/release"
mkdir -p "$release_dir"
(cd "$root" && nix run --quiet .#release-artifacts -- "$release_dir")
version="$(cat "$root/version.txt")"
"$verify" --assets "$release_dir" --work "$scratch/verify" "v$version"
extracted="$scratch/verify/extracted"
# The archive itself carries no git checkout: assert on the tarball's member
# list, not on the extraction directory. verify-release deliberately turns the
# extraction into a temporary git worktree (git init/add/commit) so the
# application's relative registry source path can evaluate, and with an
# explicit --work it retains that directory; a `.git` there is verifier-created
# working state, not archive contents. The listing goes to a file first so a
# failed `tar` fails the check with its own message instead of reading as
# absent, and `grep` never closes the producer early (pipefail/SIGPIPE).
members="$scratch/tar-members.txt"
tar -tzf "$release_dir/singular-onchain-$version.tar.gz" >"$members" 2>"$scratch/tar-members.err" \
  || fail "the archive does not list its members: $(tail -n 3 "$scratch/tar-members.err" | tr '\n' ' ')"
if grep -qE '(^|/)\.git($|/)' "$members"; then
  fail "the archive carries a git checkout"
fi

# The page's numbered steps, each "N. **`singular registry CMD`**" or
# "N. **`open-datum CMD`**", read as "N:BINARY:CMD" in page order, where
# BINARY is `singular` or `open-datum`. Only those steps count: a command
# named in prose, in a code block or at another position covers no step.
page_steps() {
  # shellcheck disable=SC2016 # the backticks are the page's own Markdown
  sed -n -e 's/^\([0-9][0-9]*\)\. \*\*`singular registry \([a-z][a-z]*\)`\*\*.*/\1:singular:\2/p' -e 's/^\([0-9][0-9]*\)\. \*\*`open-datum \([a-z][a-z]*\)`\*\*.*/\1:open-datum:\2/p' "$1" | tr '\n' ' '
}
# The page documents exactly the sixteen commands of the journey, in position,
# per binary: create and the page reading after it, every open-datum verb
# through `open-datum`, describe, reject and reclaim through `singular registry`.
page_ok() {
  [ "$(page_steps "$1")" = "1:open-datum:create 2:singular:describe 3:open-datum:insert 4:open-datum:fold 5:open-datum:inspect 6:open-datum:update 7:open-datum:inspect 8:open-datum:terminate 9:open-datum:fold 10:open-datum:inspect 11:singular:reject 12:open-datum:insert 13:open-datum:fold 14:singular:reclaim 15:open-datum:insert 16:open-datum:fold " ]
}
# without STEP: the page with its numbered step STEP removed, either binary.
# shellcheck disable=SC2016 # the backticks are the page's own Markdown
without() { grep -v "^$2"'\. \*\*`\(singular registry \|open-datum \)' "$1"; }
test -f "$extracted/DEMO1.md" || fail "the archive carries no DEMO1.md run page"
page_ok "$extracted/DEMO1.md" \
  || fail "DEMO1.md's numbered steps are not the sixteen commands in position: $(page_steps "$extracted/DEMO1.md")"
for control in "2 describe" "8 terminate" "4 fold-of-the-insertion" "6 update" "7 inspect-after-update" "11 reject" "14 reclaim" "16 fold-after-reclaim"; do
  step="${control%% *}" what="${control#* }"
  without "$extracted/DEMO1.md" "$step" >"$scratch/DEMO1-without-$what.md"
  if page_ok "$scratch/DEMO1-without-$what.md"; then
    fail "control: a page without $what passed the page check"
  fi
done
# Control: the ordinary journey refuses by name when the archive's version
# file is absent, instead of reading a page; the harness path skips the page
# steps instead. The check runs the journey's own function, read from the
# journey the archive run uses.
eval "$(sed -n '/^require_archive_layout() {/,/^}$/p' "$root/tools/demo1_cli_journey.sh")"
mkdir -p "$scratch/no-version/onchain"
: >"$scratch/no-version/onchain/plutus.json"
if require_archive_layout "$scratch/no-version/onchain/plutus.json" ordinary 2>"$scratch/no-version.err"; then
  fail "control: the ordinary journey read past a missing version file"
fi
grep -q "the archive's blueprint has no version.txt beside it" "$scratch/no-version.err" \
  || fail "control: the refusal names another cause"
require_archive_layout "$extracted/onchain/plutus.json" ordinary \
  || fail "control: the archive layout failed its own version check"
require_archive_layout "$extracted/onchain/plutus.json" test-harness \
  || fail "control: the harness path refused a present version file"
if require_archive_layout "$scratch/no-version/onchain/plutus.json" test-harness; then
  fail "control: the harness path ran past a missing version file"
fi

cd "$extracted/offchain"

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
' "$observed" >/dev/null || fail "insert-active did not observe one active token at the named wallet"

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
    and ($r.terminal.detail | text)
    and ($r.terminal.trace == null or $r.terminal.trace == "terminal-immutable")
    and ($r.terminal.controlTxid | txid)
  )
' "$observed" >/dev/null || fail "update-terminal observation moved"

echo "demo1-cli-check: PASS from $extracted — the release verified as published (sums, model revision, members, the singular journey as separate processes on one node), the page, and the retained insert-active and update-terminal controls"
