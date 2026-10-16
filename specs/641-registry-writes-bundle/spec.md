# Registry write commands end in a bundle or sign from the vault

Issue 641, fourth of five tickets under issue 490. This page records the story, the two signer modes, the journal phase of a bundle, the requirements, the refusals and the limits. Retiring the key-file flag from these commands and moving the harnesses to the vault is a separate ticket; the open-datum commands are issue 642.

## Story

As Alice, I fold with my vault: I name the vault file, type my passphrase once, and the command builds the whole run as one bundle (the preparation, then the fold), signs it from the vault, sends it the way `singular submit` does and prints a receipt read from the chain. As Bob, I create a registry naming only my address and a bundle file: nothing is signed or sent, the command exits with its own status, and I sign the bundle elsewhere and send it with `singular submit`. Neither of us passes a key file.

## Signer modes

The write commands create, fold, reject and reclaim take exactly one of three signers:

- the external signer: an address (--wallet-address ADDR) and the file the bundle is written to (--bundle FILE). The command builds the run's whole chain, writes the bundle, journals it as waiting for signatures and exits with the outcome waiting-for-signatures, status 19. It reads no key.
- the vault: the vault file (--vault FILE) and, for scripts, the passphrase descriptor (--passphrase-fd FD); otherwise the passphrase is asked once at the terminal. The command builds the same bundle in memory, signs every transaction from the vault and sends it through the core of `singular submit`.
- the key file (--wallet-skey FILE), unchanged by this ticket: each transaction is built, signed and sent before the next is built, as today.

The shared flag group reads the signer for every binary, so the open-datum and keri-stub commands parse the new flags too; issue 642 documents them there.

A bundle holds the run's whole chain in the order the command builds it: create's state publication when no carrier is live, its boot, then its request, witness and, when pinned, application publications; or the preparation, when one is made, then the fold, the reject or the reclaim. Each later transaction spends the outputs of an earlier one by its identity.

## The journal phase

These rules come from the rulings on issue 640 (the dead-bundle authority, the third way a bundle dies, the cut of 16 October) and are stated here as they bind:

- A staged run, before it sends anything or exits, saves the bundle's bytes and each unsigned body beside the journal (a body as hex text, hashed over its raw bytes, as a prepared body is saved) and journals one waiting-for-signatures line per transaction, each carrying the bundle's hash.
- Membership is by identity, for the transaction's whole life: a transaction a waiting line names is a member of that bundle in every later line. The per-transaction reconciliation of the key-file path (rollback, inclusion from live outputs, the after-state readback, the unresolved selection, the receipt's submissions) never judges a member. A member is judged only by where the chain holds its identity and by the tip.
- A member's later lines are landed (found by its identity, with its chain point and confirmations) and dead (with the reason).
- A bundle is landed when every member is found on chain. It is dead when any member can never land: not found with the tip at or past its exclusive validity upper bound ("expired, rebuild"), or refused by the node when this command sent it from the vault. When a bundle dies, every member not yet landed gets a dead line, and the report names the members that went through. Otherwise it is pending. A bundle is never reported landed unless every member was found on chain.
- Admission and reporting read the same bundle state. A pending bundle stops the next write before it builds anything, with status 19, naming the bundle's hash, its saved path, the members awaited and their deadlines. A landed or dead bundle never blocks a new build. A failed inclusion or tip read leaves the bundle pending and stops the command naming the failure.
- Lines written by the key-file path and journals written before this ticket reconcile exactly as before.

## Requirements

- one-bundle-per-run: a staged run writes one bundle holding its whole chain, in build order, and nothing else.
- chained-view-answers-as-landed: while a run stages, every chain read answers as the chain would after the staged transactions landed: their outputs present, the inputs they spend absent, for every kind of output query, the asset history the trie replay reads and the mint record of what they mint; the tip, protocol parameters and time are the chain's.
- nothing-signed-or-sent-while-building: no transaction is signed, journalled as prepared or sent before the whole bundle is built.
- bodies-equal-the-existing-builds: each bundle body is the transaction the key-file path builds when every earlier body has landed, validity bounds aside where the tip differs.
- external-mode-reads-no-key: the external signer mode opens no key file and no vault; the bundle's only signer is the given address.
- signer-is-a-payment-key: an address whose payment part is a script is refused before anything is read; the state directory partition is the address's payment key hash, the same one a key file or vault of that key resolves.
- bundle-file-created-exclusively: an existing bundle file is refused before anything is read; the bundle is created exclusively and its bytes are also saved beside the journal.
- waiting-for-signatures-status: the external mode, and any write stopped by a pending bundle, end with the outcome waiting-for-signatures and status 19.
- receipt-states-only-what-landed: a field derived from a body is stated as fact only once that body is found on chain by its identity; otherwise the command's fields sit under expected, beside the bundle's hash, paths, signers and per transaction its step, identity, deadline and effects.
- effects-are-the-readbacks-as-claims: a staged transaction's effect lines are what the command's readback says on the chained view; they are claims, shown and never trusted.
- vault-builds-the-same-bundle: at the same chain state the vault mode builds the bundle bytes the external mode writes for the vault's address.
- vault-sends-through-submit: the vault mode signs every transaction from the vault and sends through the core of `singular submit`, in order; the whole bundle landed journals every member landed; a node refusal journals the bundle dead and ends as a ledger refusal; an uncertain answer ends partial, and the next run settles the bundle by identity.
- membership-by-identity-for-life, one-bundle-state-for-admission-and-report, pending-bundle-stops-the-next-write, dead-bundle-releases-every-member, landed-bundle-settles: as the journal phase states.
- waiting-line-read-by-its-consumer: the waiting lines and saved bodies the real staged run writes are read by the real reconciliation and admission.
- legacy-journals-reconcile-as-before: the key-file path's lines and older journals reconcile as before this ticket.
- no-secret-in-output: no bundle, journal line, receipt, trace or error carries a passphrase or a key byte.
- existing-commands-unchanged: the key-file path, the read-only commands, preview and the open-datum and keri-stub commands behave as before for every command line they accepted before.
- committed-controls-bounded: every run command of a committed control is bounded in time and memory.

## Refusals

Before anything is read or built, a named refusal and nothing written: two signer modes together; outside a preview, an address without a bundle file; a bundle file without an address, or with a preview; a script address; an existing bundle file; the passphrase descriptor without a vault; the vault unreadable or the passphrase wrong. Before building: a pending bundle (status 19). After building, before anything is sent: the bundle file not writable.

## Limits recorded

- The builders' validity bounds are unchanged. A reject bundle expires about two minutes after it is built, a fold at the earliest included request's processing deadline, a reclaim at the end of the request's retract window. A create bundle has no deadline, because its transactions carry no upper bound: it stays reported for its own token until it lands, and blocks nothing else, because the state directory is keyed by that token.
- A bundle submitted elsewhere and refused by the node is not seen by the writer's journal, since `singular submit` keeps no state: it dies by expiry.
- A landed member is settled; a later rollback of it is not detected again.
- The effect lines are claims computed on the chained view.
