# Data for registry writes that end in a bundle

## Signer

One of: a key file (the path, as today); an external signer (an address whose payment part is a key, and the bundle file path); a vault (the vault file path and where the passphrase comes from, the terminal or a descriptor).

## Staged transaction

The unsigned body as built, the step that built it, and its effect lines in the order the command's readbacks produced them. Its identity is the body's hash, fixed before any signature.

## Chained view

A list of staged transactions in build order over a real session. Its answers: the chain's answer without the references the staged bodies spend, plus the outputs the staged bodies create that the query selects, for every query form; a reference a staged body creates is answered without asking the chain, and one a staged body spends answers as missing. The asset history is the chain's followed by one block per staged body that spends or creates an output holding that asset. The mint record of an asset a staged body mints comes from that body. Tip, protocol parameters, time and script registration are the chain's.

## Bundle

The existing version 1 format: the command name, the network magic, the registry state token (none for create, whose registry does not exist before the bundle lands), the signers (the run's one address), and per transaction its identity, envelope, deadline and effect lines.

## Journal lines

- waiting-for-signatures: one per transaction, with the step, the identity, the bundle's hash in the detail, the saved body's path and hash, the network and the era.
- landed: the chain point and confirmations at which the identity was found, and the tip observed.
- dead: the reason (expired, rebuild; refused by the node, with its answer; or its bundle died) and the tip observed.

The bundle's own bytes are saved beside the journal under its hash.

## Bundle state

For each bundle hash in the journal: pending, with the members awaited and their deadlines; landed, with each member's chain point; or dead, with the reason, the members that died and the members that went through. Membership: every identity a waiting line names, for all its lines.

## Outcome

waiting-for-signatures, status 19.

## Receipt

External mode: the outcome, the bundle (hash, the written path, the saved path, signers, and per transaction its step, identity, deadline and effects) and the command's own fields under expected. Vault mode: the outcome of the submission, the bundle, the submit core's per-transaction chain facts, and the command's own fields as fact when the whole bundle landed, under expected otherwise. A write stopped by a pending bundle: the outcome, that bundle's hash, saved path, awaited members and deadlines.
