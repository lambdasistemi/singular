#!/usr/bin/env bash
# Silent-on-success assertions over the finished chain and the vault files, computed from receipts,
# journals and the node. Not part of any cast. Scene order: 0 (both players' vaults), 2 (Alice registers
# alice from her vault), 3 (Bob is refused), 4 (Alice terminates alice), 5 (Alice books alice-cert from her
# vault; Bob books bob and folds both, the external way: staged, signed, submitted), 6 (the closed
# registry: insert --fold, read back, update refused, terminate --fold).
# Needs the devnet still running (the live-output reads probe its node).
# shellcheck disable=SC2015  # the grep chains report through bad, whose exit is the assertion's own
# shellcheck disable=SC2086  # the journal paths are globs over the run's directories the shell must expand
set -euo pipefail
: "${REHEARSAL_WORK:?verify.sh needs the run scratch directory}"
: "${REHEARSAL_BIN:?verify.sh needs the built binaries directory}"
RUN="$REHEARSAL_WORK"
bin="$REHEARSAL_BIN"
cd "$RUN/play"
export PATH="$bin:$PATH"
bad() {
  echo "verify: FAIL: $*" >&2
  exit 1
}
sock=$(cat "$RUN/probe.sock")
live() { "$bin/devnet" probe --node-socket "$sock" --network-magic 42 --tx-in "$1" | jq -e --arg o "$1" 'any(.live[]; .==$o)' >/dev/null; }
A=alice B=bob
policy=$(jq -r .stateToken $A/create.json | cut -d. -f1)
# a vault write that signed and sent its whole bundle in one command: the bundle's steps in order, each sent
sent_steps() { jq -e --argjson want "$1" '.outcome=="success" and ([.bundle.transactions[].step]==$want) and ([.submissions[].identity]==[.bundle.transactions[].identity]) and all(.submissions[]; .how=="sent")'; }

# ---- scene 0: two vaults, passphrases never on any output, addresses read back equal
for p in alice bob; do
  [ -f "$p/$p.vault" ] || bad "scene 0: $p's vault file is missing"
  [ "$(stat -c %a "$p/$p.vault")" = 600 ] || bad "scene 0: $p's vault is not mode 600"
  ! grep -aq cborHex "$p/$p.vault" || bad "scene 0: $p's vault holds a key envelope in the clear"
  grep -qE '^addr_test1[a-z0-9]+$' "$RUN/play/holds/$p-create.out" || bad "scene 0: $p's create printed no bech32 address"
  cmp -s "$RUN/play/holds/$p-create.out" "$RUN/play/holds/$p-address.out" || bad "scene 0: $p's address read differs from create's"
done
grep -rqF -f "$RUN/play/vault-pass/alice" "$RUN/play/holds" "$A" "$B" 2>/dev/null && bad "scene 0: alice's passphrase text appears in an output"
grep -rqF -f "$RUN/play/vault-pass/bob" "$RUN/play/holds" "$A" "$B" 2>/dev/null && bad "scene 0: bob's passphrase text appears in an output"
[ "$(wc -l <"$RUN/play/holds/alice-create.out")" = 1 ] || bad "scene 0: create printed more than one line"
# the players hold no key file anywhere in their directories: the vault is the only place a key lives
[ -z "$(find $A $B -type f \( -name '*.key' -o -name '*.skey' \))" ] || bad "a key file sits in a player's directory"

# ---- scene 2: create, and alice registered by one insert --fold, both from Alice's vault
jq -e '.outcome=="success" and .processTime==600000 and .retractTime==300000' $A/create.json >/dev/null || bad "create: not success, or not the default windows"
jq -e '.wallet==$a' --arg a "$(cat "$RUN/play/holds/alice-create.out")" $A/create.json >/dev/null || bad "create did not run as the wallet of Alice's vault"
jq -e 'all(.submissions[]; .how=="sent")' $A/create.json >/dev/null || bad "create did not send every transaction of its bundle"
jq -e '.keyText=="alice" and (.settled|length)==1 and .settled[0].edge=="insertActive"' $A/insert.json >/dev/null || bad "alice's insert --fold: not one settled insertActive"
sent_steps '["book","fold"]' <$A/insert.json >/dev/null || bad "alice's insert --fold: not one bundle of a booking and a fold, sent from the vault"
jq -e --slurpfile i $A/insert.json '.leaf=="active" and .keyText=="alice" and .applicationOutput.controller==$i[0].settled[0].owner and .applicationOutput.output==$i[0].settled[0].settlement.liveOutput' $A/inspect-alice.json >/dev/null || bad "alice is not active under alice's key at the fold's output"
jq -e '.state.activeKeys==1 and .state.foldsSinceCreate==1 and (.state.pendingRequests|length)==0' $A/page.txt >/dev/null || bad "scene 2 page: counts"
# the vault run leaves, for each transaction of its bundle, one waiting-for-signatures line and one landed line
jq -s -e '[.[] | select(.journalCommand=="insert") | .journalEvent][0:4] == ["waiting-for-signatures","waiting-for-signatures","landed","landed"]' $A/state/net-42/*/wallets/*/journal.jsonl >/dev/null || bad "alice's insert --fold did not leave two waiting-for-signatures lines and then two landed lines"

# ---- scene 3: the refusal, twice, from a directory that stays empty
jq -e '.leaf=="active"' $B/inspect-before.json >/dev/null || bad "bob does not see alice active"
jq -e '.outcome=="client-refusal" and .leafFound=="active" and .leafRequired=="unknown" and .policy=="client"' $B/refused.json >/dev/null || bad "bob's client refusal"
[ ! -e $B/refused.bundle ] || bad "bob's refused write left a bundle"
jq -e --arg h "$policy" '
  .outcome=="ledger-refusal" and .fold=="none" and .key=="616c696365"
  and (.failedScripts|length)==1 and .failedScripts[0].role=="state-validator" and .failedScripts[0].hash==$h
  and .before.state.root==.after.state.root' $B/forged.json >/dev/null || bad "the forged attempt was not refused by the state validator with the root unchanged"
jq -e 'select(.journalStep=="fold" and .journalEvent=="rejected")' $B/forged-state/net-42/*/wallets/*/journal.jsonl >/dev/null || bad "the forged fold was not rejected in the host's journal"
jq -e '.leaf=="active"' $B/inspect-after.json >/dev/null || bad "alice not active after the forged attempt"
[ "$(jq -c .applicationOutput $B/inspect-before.json)" = "$(jq -c .applicationOutput $B/inspect-after.json)" ] || bad "alice's application output changed across the attempts"

# ---- scene 4: terminate --fold, burn, refund, refused re-registration
jq -e --slurpfile f $B/forged.json '
  .keyText=="alice" and (.settled|length)==1 and .settled[0].edge=="updateTerminal"
  and .settled[0].settlement.deposit==2000000
  and (.excluded|length)==1 and .excluded[0].request==$f[0].requests[0] and .excluded[0].reason=="key-exists"' $A/terminate.json >/dev/null || bad "the termination: not one settled alice, with the forged request excluded"
sent_steps '["book","fold"]' <$A/terminate.json >/dev/null || bad "the termination: not one bundle of a booking and a fold, sent from the vault"
rel=$(jq -r '.settled[0].settlement.released' $A/terminate.json)
[ "$rel" = "$(jq -r .applicationOutput.output $A/inspect-alice.json)" ] || bad "the released output is not alice's application output"
live "$rel" && bad "alice's application output is still live after the termination"
jq -e '.leaf=="terminal" and (.applicationOutput.holdings|length)==0' $A/inspect-terminal.json >/dev/null || bad "alice is not terminal with no holder"
jq -e '.outcome=="client-refusal" and .leafFound=="terminal"' $A/reregister.json >/dev/null || bad "re-registration of a terminal name was not refused"
jq -e '.state.activeKeys==0 and .state.terminalKeys==1 and .state.foldsSinceCreate==2' $A/page-after.txt >/dev/null || bad "the page after scene 4: counts"

# ---- scene 5: alice-cert pending (Alice's vault), then Bob stages, signs and sends his booking and the fold of both
jq -e '.outcome=="success" and .keyText=="alice-cert"' $A/cert.json >/dev/null || bad "alice-cert booking"
jq -e 'all(.submissions[]; .how=="sent") and (.submissions|length)==1' $A/cert.json >/dev/null || bad "alice-cert's booking was not sent from the vault as one transaction"
# Bob's two writes are staged (exit 19, outcome waiting-for-signatures), signed by his vault and sent by submit
staged() { # staged RECEIPT SUBMITTED STEP: the staged receipt names Bob's address as the only signer and the one step; submit found it all on chain, sent
  jq -e --arg a "$(cat "$RUN/play/holds/bob-create.out")" --arg s "$3" '.outcome=="waiting-for-signatures" and .bundle.signers==[$a] and ([.bundle.transactions[].step]==[$s]) and (has("submissions")|not)' "$1" >/dev/null || bad "$1 is not Bob's staged $3"
  jq -e --slurpfile s "$1" '.command=="submit" and .outcome=="success" and .bundleHash==$s[0].bundle.hash and ([.submissions[].identity]==[$s[0].bundle.transactions[].identity]) and all(.submissions[]; .how=="sent")' "$2" >/dev/null || bad "$2 did not send the whole bundle of $1"
}
staged $B/booking.json $B/insert-bob.submitted.json book
staged $B/fold.json $B/fold-all.submitted.json fold
jq -e '.expected.keyText=="bob"' $B/booking.json >/dev/null || bad "bob's staged booking does not expect the key bob"
jq -e --slurpfile a $A/cert.json --slurpfile b $B/booking.json '
  (.expected.settled|length)==2
  and ([.expected.settled[].request]|sort)==([$a[0].request,$b[0].expected.request]|sort)
  and ([.expected.settled[].owner]|sort)==([$a[0].requester,$b[0].expected.requester]|sort)
  and .expected.folder==$b[0].expected.requester' $B/fold.json >/dev/null || bad "bob's fold does not settle both requests for both owners"
dl=$(jq -r .foldDeadline.posixMs $A/cert.json)
at=$(jq -r .expected.hostClockMs $B/fold.json)
[ "$at" -lt "$dl" ] || bad "alice-cert was folded after its deadline"
echo "verify: alice-cert folded $(((dl - at) / 1000)) s before its deadline" >&2
jq -e --slurpfile a $A/cert.json '.leaf=="active" and .keyText=="alice-cert" and .applicationOutput.controller==$a[0].requester' $B/inspect-cert.json >/dev/null || bad "alice-cert is not active under alice's key"
live "$(jq -r .applicationOutput.output $B/inspect-cert.json)" || bad "alice-cert's application output is not live"
jq -e '.state.activeKeys==2 and .state.terminalKeys==1 and .state.foldsSinceCreate==3' $B/page-after.txt >/dev/null || bad "the page after scene 5: counts"
# independence: the two players share no wallet partition
part=$(jq -r .stateToken $A/create.json | tr . -)
[ "$(ls $A/state/net-42/$part/wallets)" != "$(ls $B/state/net-42/$part/wallets)" ] || bad "the two players share one wallet partition"

# ---- scene 6: the closed registry (shapes follow the repository's closed-datum journey), all from Alice's vault
jq -e '.outcome=="success" and .application=="open_datum.closed_datum"' $A/closed-create.json >/dev/null || bad "the closed create does not name the closed application"
jq -e '.keyText=="checkpoint" and (.settled|length)==1 and .settled[0].edge=="insertActive"' $A/closed-insert.json >/dev/null || bad "checkpoint's insert --fold: not one settled insertActive"
sent_steps '["book","fold"]' <$A/closed-insert.json >/dev/null || bad "checkpoint's insert --fold: not one bundle of a booking and a fold, sent from the vault"
jq -e --slurpfile i $A/closed-insert.json '.leaf=="active" and .keyText=="checkpoint"
  and .applicationOutput.controller==$i[0].settled[0].owner
  and .applicationOutput.payload==$i[0].settled[0].settlement.envelope.fields[1]' $A/closed-inspect.json >/dev/null || bad "checkpoint does not read back its controller and payload"
jq -e --arg t "$(jq -r .stateToken $A/closed-create.json)" '.outcome=="client-refusal"
  and (.reason|contains($t) and contains("is closed") and contains("written once"))' $A/closed-update.json >/dev/null || bad "the closed update refusal does not name the closed registry"
# WORKAROUND: a find -newer update-wrote-nothing check is defeated by the terminate that follows on the same chain -> the proof reads the journal: no update command line exists in state-closed at all; the cast's own nothing-new frame runs before the terminate, where -newer is honest.
jq -e 'select(.journalCommand=="update")' $A/state-closed/net-42/*/wallets/*/journal.jsonl >/dev/null && bad "the closed journal names an update command that never ran"
jq -e '(.settled|length)==1 and .settled[0].edge=="updateTerminal"
  and (.settled[0].settlement.deposit|type)=="number" and .settled[0].settlement.deposit>0' $A/closed-terminate.json >/dev/null || bad "checkpoint's termination: not one settled updateTerminal with a deposit"
sent_steps '["book","fold"]' <$A/closed-terminate.json >/dev/null || bad "checkpoint's termination: not one bundle of a booking and a fold, sent from the vault"
jq -e '.leaf=="terminal" and .applicationOutput.absent' $A/closed-terminal.json >/dev/null || bad "checkpoint is not terminal with the holding gone"
closed_out=$(jq -r '.settled[0].settlement.released' $A/closed-terminate.json)
live "$closed_out" && bad "checkpoint's application output is still live after the termination"
echo "verify: all assertions hold"
