#!/usr/bin/env bash
# Scene 3, Unique: alice is active (scene 2). Bob asks to register alice with his address and a bundle
# file, the external signer's spelling: the client refuses before building anything, so no bundle is
# written; then the same attempt for real through the negative host, and the chain's validator refuses.
# WORKAROUND: the negative host's receipt is about 78 KB, and its reason member and the journal's rejection detail are multi-kilobyte raw node errors -> only outcome, key and failedScripts are shown, and the raw error text is never printed (it stays in the receipts).
# shellcheck disable=SC2086  # the journal paths are globs over the run's directories the shell must expand
# shellcheck disable=SC2016  # the typed commands are shown verbatim on screen and evaluated by the tour helper
set -euo pipefail
export DEMO_TOTAL=4
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
. "$(dirname "$0")/lib.sh"
JF='forged-state/net-42/*/wallets/*/journal.jsonl'
play_cd "Bob works from a directory of his own. The name alice is active, and it is Alice's." bob
play -p 5 $'The vault he made in scene 0, links to the same two public inputs, and his own payload.\nHis vault holds his key.' \
  'ls'
play -p 6 $'What he was given: the registry\'s state token, which is public. And his own address from\nscene 0, which names him when he signs the external way.' \
  'echo "$TOKEN" | short; echo "$bob_addr"'
play -p 5 "A directory for his commands' local state. No command has run in it yet, so it is empty." \
  'mkdir state && find state'
play -t -p 3 "Bob reads alice from the chain: a read; it writes nothing in his state directory." \
  'open-datum inspect --key alice --state-dir state $TOKEN $BLUEPRINT $NODE > inspect-before.json'
play -p 10 $'On chain: alice is active, held in this application output, controlled by Alice\'s key.' \
  'jq "{leaf, applicationOutput: (.applicationOutput | {output, controller})}" inspect-before.json | short'
play -p 5 "On disk: his state directory is still empty. A read writes nothing." \
  'find state'
play -f -p 4 $'Bob asks to register the key alice, booking and folding as Alice did, with his address and a\nbundle file. The command reads the registry first, finds alice taken, and stops.' \
  'open-datum insert --key alice --payload payload.json --state-dir state $TOKEN $BLUEPRINT $NODE --wallet-address "$bob_addr" --bundle refused.bundle --fold > refused.json'
play -p 8 "The refusal, from the receipt: alice is active, and a key being registered must be unknown." \
  'jq "{outcome, reason, leafFound, leafRequired}" refused.json'
play -p 6 $'On disk: his state directory is still empty and no bundle file was written: the refusal built\nnothing, so there is nothing to sign.' \
  'find state; find . -maxdepth 1 -name "*.bundle" | grep . || echo "no bundle written"'
test -z "$(find state -type f)"
test -z "$(find . -maxdepth 1 -name '*.bundle')"
play -f -p 5 $'A client check is not a proof. The negative host skips it, with a test wallet of its own: it\nbooks alice, then sends the fold. On chain: the booking lands; the node gets the fold.' \
  'singular-negative registry insert --key alice --payload payload.json --state-dir forged-state $TOKEN $BLUEPRINT $NODE $FORGER --receipt forged.json > forged.out'
play -p 14 $'On chain: the node refused the fold; the receipt names the script that failed:\nthe registry\'s state validator.' \
  'jq "{outcome, key, failedScripts}" forged.json | short'
play -p 6 "That hash is the policy of the state token Bob was given: the registry's own validator." \
  'echo "${TOKEN#--state-token }" | cut -d. -f1 | short'
play -p 12 $'On chain: the registry did not change, the same root before and after. Only the booking is new,\nand it stays pending.' \
  'jq "{before: .before.state.root, after: .after.state.root}" forged.json | short'
play -p 12 $'On disk: the host kept its own journal in forged-state. The booking went through; the fold\nwas prepared, then rejected by the node.' \
  "jq -c \"{journalStep, journalEvent, tx: (.journalTxId[0:8])}\" $JF"
play -p 10 $'And two signed transactions, kept for recovery in its submissions/: the booking and the\nrefused fold. Bob\'s own state directory is untouched.' \
  'find forged-state -type f | sort | short'
test -z "$(find state -type f)"
play -t -p 3 "Bob reads alice again: a read of the chain. The forged request is booked and still pending." \
  'open-datum inspect --key alice --state-dir state $TOKEN $BLUEPRINT $NODE > inspect-after.json'
play -p 6 "On chain: alice is still active, with the same application output and controller." \
  'jq "{leaf, applicationOutput: (.applicationOutput | {output, controller})}" inspect-after.json | short'
play -p 6 "Compared with Bob's read before the attempts: no difference." \
  'diff <(jq .applicationOutput inspect-before.json) <(jq .applicationOutput inspect-after.json) && echo "no difference"'
finish
