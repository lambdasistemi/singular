#!/usr/bin/env bash
# Scene 5, Permissionless: Alice books a second name, alice-cert, without folding, from her vault. Bob,
# who did not create the registry, from a directory of his own with only the state token, signs the
# external way: each of his two writes (his own name, then the fold) names his address and a bundle
# file, exits 19 (waiting-for-signatures), is signed by his vault with `singular wallet sign` and is sent
# with `singular submit`. His fold settles Alice's second request too.
# shellcheck disable=SC2086  # the journal paths are globs over the run's directories the shell must expand
# shellcheck disable=SC2016  # the typed commands are shown verbatim on screen and evaluated by the tour helper
set -euo pipefail
export DEMO_TOTAL=10
# shellcheck disable=SC1091 # resolved from this script's own directory at runtime
. "$(dirname "$0")/lib.sh"
J='state/net-42/*/wallets/*/journal.jsonl'
play_cd "Alice books a second name, alice-cert, and does not fold it." alice
play -t -p 4 $'She books alice-cert with her payload from her vault, without --fold: one transaction locks her\ndeposit at the request address. The request stays pending; the registry is unchanged.' \
  'open-datum insert --key alice-cert --payload payload.json --payload-schema detailed --state-dir state $TOKEN $BLUEPRINT $NODE $VAULT 3< ../vault-pass/alice > cert.json'
play -p 8 "On chain: a request for alice-cert is pending, from Alice. Nobody has folded it." \
  'jq "{outcome, keyText, request, requester, foldDeadline}" cert.json | short'
play -p 5 $'On disk: two new journal lines for this one transaction (step book): waiting-for-signatures when\nthe bundle was built, then landed.' \
  "tail -n 2 $J | jq -c \"{journalCommand, journalStep, journalEvent, tx: (.journalTxId[0:8])}\""
play -p 6 $'What the booking wrote in her state directory: the journal grew, and the bundle with its\nbooking transaction is kept in submissions/ for recovery.' \
  'find state -type f -newer terminate.json | sort | short'
play_cd "Bob, who did not create the registry, works from his own directory. Nothing of Alice's is in it." ../bob
play -t -p 3 "Bob reads the registry's page: a node, the blueprint and the state token are all it needs." \
  'singular registry describe $BLUEPRINT $TOKEN $NODE > page-before.txt'
# WORKAROUND: the forged request from the negative host stays pending on the registry (a reclaim needs the processing window to pass first) -> this pending frame names it beside Alice's request
play -p 8 $'The registry\'s state on chain, pending requests: Alice\'s alice-cert (key 616c6963652d63657274)\nand the forged alice (616c696365) that the negative host left in scene 3.' \
  'jq ".state.pendingRequests[] | {request, owner, key, edge}" page-before.txt | short'
play -s -p 4 $'Bob books bob, the external way: his command names his address and a bundle file, builds the\nbooking, signs nothing, sends nothing and exits 19: waiting-for-signatures, not a failure.' \
  'open-datum insert --key bob --payload payload.json --payload-schema detailed --state-dir state $TOKEN $BLUEPRINT $NODE --wallet-address "$bob_addr" --bundle insert-bob.bundle > booking.json'
play -p 8 $'The receipt: the outcome waiting-for-signatures, the bundle holding the booking, and the request\nit expects once sent. Nothing is on the chain yet: Bob\'s request is not pending.' \
  'jq "{outcome, bundle: (.bundle | {signers, written, steps: [.transactions[].step]}), expected: (.expected | {keyText, request, requester})}" booking.json | short'
play -p 8 $'On disk: the bundle file beside his vault, and in his state directory the journal line\nwaiting-for-signatures with a copy of the bundle and its transaction.' \
  'ls *.bundle; find state -type f | sort | short'
# WORKAROUND: tokens, hashes and transaction ids run 56-64 hex characters and lines wrap at 100 columns -> `2>&1 | short` abbreviates what `wallet sign` prints to the first eight characters
play -t -p 4 $'His vault signs the bundle: one witness for each transaction. The passphrase arrives on\ndescriptor 3. Nothing is sent. The tool\'s own line reports what it signed.' \
  'singular wallet sign --vault bob.vault --passphrase-fd 3 --out witnesses-insert-bob insert-bob.bundle 3< ../vault-pass/bob 2>&1 | short'
play -p 5 "On disk: the witness, a file named by the transaction it signs." \
  'ls witnesses-insert-bob | short'
# WORKAROUND: `singular submit` prints its whole receipt, between forty and ninety lines of JSON, on the terminal -> stdout goes to /dev/null on screen; the receipt is kept by --receipt and the next frame shows its facts
play -t -p 4 $'`singular submit` sends the signed bundle: each transaction with its witness, returning once the\nchain holds it. Its receipt goes to the file named by --receipt.' \
  'singular submit --witnesses witnesses-insert-bob $BLUEPRINT $NODE --receipt insert-bob.submitted.json insert-bob.bundle > /dev/null'
play -p 8 $'On chain: Bob\'s booking landed, sent by `submit`. His request is pending beside Alice\'s;\nthe registry is unchanged.' \
  'jq "{outcome, landed: [.submissions[] | {identity, how, claims}]}" insert-bob.submitted.json | short'
play -s -p 4 $'Bob folds, as anyone may: one transaction settles every request it can, from public data.\nThe same way: his address and a new bundle file, built and not signed, exit 19.' \
  'open-datum fold --state-dir state $TOKEN $BLUEPRINT $NODE --wallet-address "$bob_addr" --bundle fold-all.bundle > fold.json'
play -p 10 $'The receipt expects this one fold to settle Bob\'s request and Alice\'s alice-cert, naming both\nowners and keys: 626f62 is bob, 616c6963652d63657274 is alice-cert. Nothing is on chain yet.' \
  'jq "{outcome, bundle: (.bundle | {signers, written, steps: [.transactions[].step]}), expected: (.expected | {fold, folder, settled: [.settled[] | {key, owner}]})}" fold.json | short'
play -p 6 $'On disk: the fold\'s bundle file beside the booking\'s, and its copy in the state directory, where\nthe journal now also holds the booking\'s landed line.' \
  "ls *.bundle; tail -n 3 $J | jq -c \"{journalStep, journalEvent, tx: (.journalTxId[0:8])}\""
# WORKAROUND: tokens, hashes and transaction ids run 56-64 hex characters and lines wrap at 100 columns -> `2>&1 | short` abbreviates what `wallet sign` prints to the first eight characters
play -t -p 4 $'His vault signs the fold the same way: passphrase on descriptor 3, one witness, nothing sent.' \
  'singular wallet sign --vault bob.vault --passphrase-fd 3 --out witnesses-fold-all fold-all.bundle 3< ../vault-pass/bob 2>&1 | short'
play -p 4 "On disk: the witness for the fold." \
  'ls witnesses-fold-all | short'
# WORKAROUND: `singular submit` prints its whole receipt, between forty and ninety lines of JSON, on the terminal -> stdout goes to /dev/null on screen; the receipt is kept by --receipt and the next frame shows its facts
play -t -p 4 $'And `submit` sends it, as before. Bob folded with his own wallet, and Alice signed nothing.' \
  'singular submit --witnesses witnesses-fold-all $BLUEPRINT $NODE --receipt fold-all.submitted.json fold-all.bundle > /dev/null'
play -p 8 "On chain: the fold landed, sent by submit; the registry moved to a new root." \
  'jq "{outcome, landed: [.submissions[] | {identity, how, slot: .chainPoint.slot}]}" fold-all.submitted.json | short'
play -t -p 3 "Bob reads alice-cert from the chain: a read; it writes nothing in his state directory." \
  'open-datum inspect --key alice-cert --state-dir state $TOKEN $BLUEPRINT $NODE > inspect-cert.json'
play -p 6 $'On chain: alice-cert is active. Its token is held in this application output, controlled by\nAlice\'s key, not Bob\'s.' \
  'jq "{leaf, keyText, applicationOutput: (.applicationOutput | {output, controller, deposit})}" inspect-cert.json | short'
play -t -p 3 "And the registry's page again, read from the chain." \
  'singular registry describe $BLUEPRINT $TOKEN $NODE > page-after.txt'
play -p 6 $'The registry\'s state on chain: two active keys (bob, alice-cert), one terminal (alice), three\nfolds since create, and the forged request, still pending.' \
  'jq .state page-after.txt | short'
finish
