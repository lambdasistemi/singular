# Data for the ledger boundary

As the writer of the next child or of the 1.x tag policy, I build on one fixed vocabulary for transactions, scripts and registry identities.

## The registry-free library

| Entity | Fields and meaning | Constraints |
|---|---|---|
| bytes | a list of bytes | the representation of every hash, identifier and name below |
| script hash, key hash | bytes | produced by the ledger's hash; no length is assumed by any statement |
| policy identifier | a script hash | |
| asset name | bytes | the ledger accepts at most 32 bytes (the names-within-limit premise) |
| asset class | policy identifier and asset name | equality is equality of both parts |
| assets | a list of asset classes with signed quantities | the quantity of an asset class is the sum of its entries; used for output values and for the mint |
| value | lovelace and assets | |
| credential | a key hash or a script hash | |
| address | payment credential and optional stake credential | the stake part never takes part in script lookup |
| output reference | transaction identifier bytes and an index | |
| output | address, value and an optional datum of the instance's datum type | |
| input | output reference and the output it resolves to | |
| withdrawal | reward account credential and an amount | |
| certificate | credential and an opaque action number | |
| purpose | spend an output reference, mint under a policy, withdraw from an account, or certify the certificate at an index | |
| transaction | inputs, reference inputs, outputs, mint, withdrawals, certificates, redeemers by purpose, supplied scripts, signatories, optional validity bounds | parametric in the datum, redeemer and script types; a purpose's redeemer is the first entry naming it |
| script context | purpose, redeemer and transaction | what a script sees when run |
| ledger | a script hash function, a script evaluation, and the acceptance predicate the ledger is observed to apply | the premises below constrain it |

Invoked purposes of a transaction: the spend of every input whose payment credential is a script, the mint of every policy the mint moves, every withdrawal and certificate whose credential is a script.

Premises, each a named proposition:

| Premise | Meaning |
|---|---|
| collision-free on a set | two members of the set with the same hash are equal |
| runs scripts | in every accepted transaction, each invoked purpose has a redeemer and a supplied script whose hash is the purpose's, and that script returns true on that purpose and redeemer |
| keeps names within limit | every asset name an accepted transaction mints or outputs has at most 32 bytes |

The staking-free view of a transaction clears the stake credential of every address in inputs, reference inputs and outputs, drops withdrawals and certificates, and drops the redeemers of withdrawal and certificate purposes.

## The registry instance

| Entity | Fields and meaning | Constraints |
|---|---|---|
| registry script | the state script, the witness script applied to a token kind and a registry identity, or any other script by its code | two witness scripts are equal exactly when kind and identity are |
| registry redeemer | the fold, or any other redeemer by its code | |
| registry datum | a model registry state, or any other datum by its code | |
| registry identity | the asset class of the registry's state token | its policy is the state token's policy, its name the token name |
| registry world | script hash function, the state script's rule, the rule of every other script, and the observed acceptance | the witness scripts' rule is not a field: it is the witness decision below, fixed by the model |
| pins | the three policy identifiers a registry's datum names, for the absent, active and terminal kinds | |
| bound | each pin equals the hash of the witness script applied to its kind and the registry identity | what resolving a registry checks |
| key name | the asset name of a model key | a fixed one-to-one correspondence between keys and byte strings, proved both ways; its numeral system is stated in the Lean doc comment and is the key abstraction issue 681 uses |
| registry's token of a key | the policy identifier of the kind and the key name | |
| occurring scripts | the scripts a transaction supplies, the state script and the registry's three witness scripts | the set the hash premise is stated on |
| state-script folds | the premise named in the spec | over every world and registry identity |
| terminal discard | a model registry state with one terminal holding of a key at an output removed | every other component unchanged |

Witness decision, per kind:

- fold present: some input sits at the address whose payment credential is the state script's hash, carries exactly one unit of the registry identity, and its spend's redeemer is the fold;
- active and absent: fold present;
- terminal: every movement under its own policy in the mint is a burn and there is at least one, or fold present.

Invariants the statements rely on:

- The witness decision reads only spent inputs' payment credentials, values and output references, spend redeemers, and the mint under the policy's own identifier.
- A terminal attestation is the holder's: the discard touches only the holdings list, and only that one terminal entry.
