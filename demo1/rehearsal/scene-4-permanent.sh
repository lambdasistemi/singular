#!/usr/bin/env bash
# Scene 4, Permanent: Alice terminates alice in one command from her vault (terminate --fold: book and
# fold), the token is gone, the deposit is back; then she tries to register alice again and is refused;
# the page counts alice as terminal. The deposit's own frame says it is today's 0.x application: under
# the ruled economics a termination donates what the request held to the treasury, except the declared tip.
# shellcheck disable=SC2086  # the journal paths are globs over the run's directories the shell must expand
# shellcheck disable=SC2016  # the typed commands are shown verbatim on screen and evaluated by the tour helper
set -euo pipefail
export DEMO_TOTAL=4
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
. "$(dirname "$0")/lib.sh"
J='state/net-42/*/wallets/*/journal.jsonl'
play_cd $'Alice is back in her directory. She will terminate alice.\nFor KERI, termination is conviction.' alice
play -t -p 8 $'She terminates alice, booking and folding in one command: one bundle from her vault. The booking\nlocks a request, and the fold burns alice\'s token and records alice as terminal.' \
  'open-datum terminate --key alice --state-dir state $TOKEN $BLUEPRINT $NODE $VAULT --fold 3< ../vault-pass/alice > terminate.json'
# WORKAROUND: the forged request from the negative host stays pending on the registry (a reclaim needs the processing window to pass first) -> shown and named in the comments (this receipt names it and leaves it out); it cannot be cleared inside the flow
play -p 24 $'On chain: the termination is settled; the token is burned and alice is terminal.\nThe forged request is named and left out: its key was already booked.' \
  'jq "{outcome, keyText, booking, fold, settled: [.settled[] | {edge, owner, settlement}], excluded}" terminate.json | short'
play -p 12 $'The deposit back to Alice is today\'s 0.x application; the ruled economics donate\nwhat the request held to the treasury, except the declared tip.' \
  'jq "{settled: [.settled[] | {edge, deposit: .settlement.deposit, released: .settlement.released}]}" terminate.json | short'
play -p 14 $'On disk: four new journal lines, for the two transactions: step book, then step fold, each\nwaiting-for-signatures when the bundle was built, then landed.' \
  "tail -n 4 $J | jq -c \"{journalCommand, journalStep, journalEvent, tx: (.journalTxId[0:8])}\""
play -p 14 $'What the command wrote in her state directory: the journal grew, and the bundle and its two\ntransactions are kept in submissions/ for recovery.' \
  'find state -type f -newer insert.json | sort | short'
play -t -p 3 "She reads alice from the chain: a read; it writes nothing in her state directory." \
  'open-datum inspect --key alice --state-dir state $TOKEN $BLUEPRINT $NODE > inspect-terminal.json'
play -p 24 $'On chain: alice is terminal, and no live output holds its token any more: the token was\nburned.' \
  'jq "{leaf, keyText, applicationOutput}" inspect-terminal.json'
play -f -p 8 $'Alice tries to register alice again, booking and folding. The command reads the registry\nfirst and stops: nothing is built, signed or sent.' \
  'open-datum insert --key alice --payload payload.json --state-dir state $TOKEN $BLUEPRINT $NODE $VAULT --fold 3< ../vault-pass/alice > reregister.json'
play -p 20 "The refusal, from the receipt: the registry has alice recorded as retired. It cannot return." \
  'jq "{outcome, reason, leafFound, leafRequired}" reregister.json'
play -p 12 "On disk: nothing in her state directory is newer than the fold: the refusal wrote nothing." \
  'find state -type f -newer terminate.json | grep . || echo "nothing new"'
play -t -p 3 "The registry's page, read again from the chain." \
  'singular registry describe $BLUEPRINT $TOKEN $NODE > page-after.txt'
play -p 30 $'The registry\'s state on chain: one terminal key (alice), no active key, two folds, and the\nforged request, still pending.' \
  'section state < page-after.txt | short'
finish
