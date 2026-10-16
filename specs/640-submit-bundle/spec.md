# Submit a signed bundle without sending anything twice

Issue 640, third of five tickets under issue 490. This page records the story, the requirements and the refusals. The write commands that produce bundles (issue 641) and the open-datum commands (issue 642) are not part of it.

## Story

As Bob, I hand back the witnesses for a bundle and run `singular submit --witnesses FILE ... BUNDLE` with the node settings. The command sends the transactions in the bundle's order and prints a receipt written from what the chain shows. If I run it again after a crash, it sends only the transactions that are still missing. If a body has expired it says "rebuild" and sends nothing. The command needs no wallet key and keeps no state of its own.

## Requirements

- witness-matches-its-body: each witness is matched to a transaction by verifying its signature over that body's identity, never by its file name.
- different-body-witness-refused: a witness that verifies against no body of the bundle is refused by name.
- needed-keys-all-witnessed: for each transaction, the key hashes that need a witness (its required signers and the payment key hashes of its inputs and collateral) each have exactly one verified witness; a missing one is refused as incomplete. Inputs produced by an earlier body of the bundle are read from that body; the others are resolved on the chain; a script-locked input needs no key witness.
- unneeded-key-witness-refused: a witness for a key that no transaction needs is refused as a different key.
- nothing-sent-before-all-checks: every refusal above and the expiry refusal happen before the first send.
- expired-body-refused-with-rebuild: when the chain tip is at or beyond the exclusive validity upper bound of a transaction that is not yet on chain, the command refuses with the word rebuild and sends nothing.
- transactions-sent-in-bundle-order: sends happen in the bundle's order.
- on-chain-transaction-skipped-by-identity: a transaction the provider reports found, with confirmations, is not sent.
- no-resubmission-after-uncertainty: an uncertain answer stops the run as partial; nothing is retried within the run.
- assembly-preserves-the-body: the signed transaction has the bundle's body bytes and identity, plus exactly the verified witnesses.
- receipt-from-the-chain: the receipt states, per transaction, whether this run sent it or found it, and its chain point, confirmations and outputs as read from the chain after the run.
- effects-are-echoed-not-confirmed: the bundle's effect lines are shown beside the receipt as claims; the receipt never says they were confirmed.
- submit-needs-no-wallet-key: the command takes no wallet key and no vault.
- no-secret-in-output: nothing printed or written carries a key or a passphrase; witnesses carry the public key and the signature only.
- existing-commands-unchanged: every other command behaves as before.
- committed-controls-bounded: every run command of a committed control is bounded in time and memory.

## Refusals

Exit with a named refusal and nothing sent: bundle unreadable or inconsistent (as in the signing step); witness unreadable; witness for a different body; witness for a key no transaction needs; needed witness missing; expired body (rebuild); input neither in an earlier body nor on the chain.

## Limits recorded

The effect lines are the writer's claims, shown and not confirmed; structured effects belong to a later bundle version.

The journal phase "waiting for signatures", its reconciliation and the three ways a bundle dies (a rejected transaction, an excluded transaction, expiry) are not part of this ticket: the command reads no journal, and the phase belongs with the write commands that produce bundles (issue 641).
