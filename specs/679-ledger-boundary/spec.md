# The ledger boundary: who may move a registry's tokens

Issue 679, first child of issue 676. This page records the story, the requirements, the rulings in force and the cases the witness policies decide. It changes the Lean model only: no validator, builder or command changes behaviour.

## Story

As a KERI integrator, I resolve a registry and read, as proved statements:

- a token under its active policy moves only in a transaction that spends the registry's state token with a fold the state script accepts;
- each key's token has the key itself as its asset name;
- no token policy of the registry consults a stake credential, a withdrawal or a certificate.

As the holder of a terminal attestation, I may destroy it without anyone folding the registry. A terminal attestation is its holder's; destroying it returns its deposit and does not change what the registry says about the key.

## Requirements

- registry-free-ledger-layer: a Lean library with no Singular import and no Singular name models a Cardano transaction at the ledger boundary: values as policy identifier, asset name and quantity; inputs and outputs whose addresses have a payment credential and an optional stake credential; mint; withdrawals; certificates; redeemers by script purpose; script identity by script hash.
- named-premises-not-axioms: each ledger assumption is a named proposition in the signature of every statement that needs it. The repository's refusal of the axiom keyword and the compiled gate on the three standard axioms stay exactly as they are.
- hash-premise-on-occurring-preimages: collision-freedom is stated over the scripts that occur (those a transaction supplies and the registry's own), never as injectivity of the hash.
- scripts-run-premise: the ledger accepts a transaction only when every script it invokes is supplied, is found by its hash, has its redeemer, and returns true.
- names-within-limit-premise: the ledger accepts no asset name longer than 32 bytes.
- state-script-folds-premise: when the state script accepts the fold spend of an input carrying a registry's state token, that input's datum is a model registry state and the transaction is an admitted model fold of it whose ledger mint, kind by kind and key by key, equals the fold's mint. This is the trusted-base agreement between the compiled state validator and the model's fold, named, not proved here.
- premises-satisfiable: one proved example meets every premise at once, and in it the ledger accepts a transaction that mints one active token under the bound policy and a transaction that is a terminal pure burn. No statement is vacuously true.
- registry-instance: over that library, the registry's scripts, the witness policies' decision per kind, each policy identifier as the script hash of the witness script applied to the kind and the registry identity, the key-to-asset-name map, and the bound-registry predicate.
- witness-decision-per-kind: the active and absent policies accept a mint or a burn only when the transaction spends this registry's state output under the fold redeemer; the terminal policy accepts a transaction whose every movement under it is a burn without a fold, and otherwise needs the fold.
- fold-required-statement: a transaction the ledger accepts that mints or burns under a bound registry's active or absent policy spends an input at the state script's address carrying exactly one unit of the registry's state token, under the fold redeemer, and the state script accepts that spend.
- key-names-its-token-statement: each key's token under the bound active policy has the key's bytes as its asset name; keys and byte strings correspond one to one, so the key alone finds the token and the token names its key; in a reachable state the key has exactly one such token while it is active and none otherwise; a key whose bytes exceed 32 has no token any accepted transaction mints.
- unknown-key-mint-statement: an accepted transaction that mints under the bound active policy mints only at keys that were unknown in the spent registry state: never for an active key, never again for a terminal key; from a reachable state the key then holds exactly one active token.
- token-policies-read-no-staking-statement: the decision of each of the three token policies is unchanged by any change of withdrawals, certificates, the redeemers of the withdrawal and certificate purposes, and the stake credential of any input or output, destinations included.
- terminal-discard-statement: a holder's discard of a terminal attestation changes no registry state: every key's leaf, the root, the configuration and the custody stay as they were, and every active count is unchanged, so the termination's accounting and the supply statements are unaffected. A proved example discards a real attestation.
- registry-free-import-check: a hosted check refuses any module of the registry-free library that imports a Singular module or declares or opens the Singular namespace, and its control shows the refusal.
- consumers-regenerated: the statement manifest and corpora, the theorem page and the README counts, the simulator mirror, the coverage record and its population counts, the open-datum application model, the economics paper's register and narration follow the model in the same pull request.
- no-behaviour-change: nothing under the on-chain and off-chain trees, the application sources, the blueprint or the script identity file changes.

## Rulings in force

- Assumptions are named premises proved from the three standard axioms, each with a proved satisfying example; collision-freedom is stated on the preimages that occur (epic answer A-001, first decision).
- The statements hold for a bound registry: its three witness pins equal the policy identifiers of the witness script applied to its own identity, which is what the client checks when it resolves a registry. Genesis enforcing the pins is filed for the 1.x line (A-001, second decision).
- The name guarantee reads: each key's token has the key itself as its asset name, under the registry's bound active policy. Mapping a KERI identifier to a key is the consumer's (A-001, third decision).
- The ledger layer is its own module with no dependency on Singular's types, so that lambdasistemi/lockness#42 can extract it after the review (operator, through the desk).
- The staking statement covers the three token policies in this child; the state and request rules are stated in issue 680 and checked in issue 681; a delivered output keeps binding the whole address its request names, stake part included (epic answer A-003 on the staking reading).
- The witness decision is specified from the model's guarantee and its existing clauses, never read off the compiled script; anything the compiled code does that the model does not name is a question, never a new clause (epic note on model first).
- The terminal pure burn is the holder's, and the model gains it; terminal attestations of a key are zero or many, and no statement fixes their count (operator ruling relayed in epic answer A-002).
- Model only, in the 0.x line; the 1.x request tag and asset-name commitments are not modelled, and the policy model stays general enough for the tag policy to be one more instance.

## Cases the witness policies decide

The table is the predicate in cases, for issue 681 to run against the compiled policy without reading Lean. Movement is what the transaction does under this policy: mint only, burn only, or a mint beside a burn. The fold condition is one of six:

- present: some spent input sits at the state script's address, carries exactly one unit of this registry's state token, and is spent under the fold redeemer;
- absent: no input carries this registry's state token;
- foreign: the only state input spent under the fold redeemer carries another registry's state token;
- wrong redeemer: this registry's state input is spent under a redeemer other than the fold;
- wrong address: this registry's state token sits at an address that is not the state script;
- two units: the state input carries two units of this registry's state token.

| Policy kind | Movement | Fold condition | Decision |
|---|---|---|---|
| active or absent | mint only, burn only, or a mint beside a burn | present | accept |
| active or absent | mint only, burn only, or a mint beside a burn | absent | refuse |
| active or absent | mint only, burn only, or a mint beside a burn | foreign | refuse |
| active or absent | mint only, burn only, or a mint beside a burn | wrong redeemer | refuse |
| active or absent | mint only, burn only, or a mint beside a burn | wrong address | refuse |
| active or absent | mint only, burn only, or a mint beside a burn | two units | refuse |
| terminal | burn only | present | accept |
| terminal | burn only | absent, foreign, wrong redeemer, wrong address or two units | accept |
| terminal | mint only | present | accept |
| terminal | mint only | absent, foreign, wrong redeemer, wrong address or two units | refuse |
| terminal | a mint beside a burn | present | accept |
| terminal | a mint beside a burn | absent, foreign, wrong redeemer, wrong address or two units | refuse |
| any | any | any, with other withdrawals, certificates, staking redeemers or stake credentials | the same decision as without them |

The table covers every combination of kind, movement (mint only, burn only, both) and fold condition (present, absent, foreign, wrong redeemer, wrong address, two units).

The policy decides co-presence only. Quantities, names and whether the fold is admitted are the state script's, through the state-script-folds premise.

## Checked under the zero-or-many ruling

No existing statement fixes a count of terminal attestations for a terminal key. The disjointness statement for the three kinds says a key that is active or absent has no terminal attestation, and the soundness statement says every attestation is about a terminal key: both allow zero or many for a terminal key. The permanence statement keeps a held attestation through later folds; a holder's discard is not a fold, so it stays true and says nothing about discards.

## Limits recorded

- The state token's uniqueness over ledger histories and the spent-at-most-once premise are issue 680's.
- The agreement of the compiled witness and state scripts and of the off-chain derivations with this model is issue 681's, using the table above.
- Removing the always-true staking validator from the blueprint is issue 682's.
- The model's key is an abstract number; this child fixes a one-to-one correspondence between keys and byte strings, which issue 681 uses as the key abstraction for asset names.
- The registry identity is the state token's asset class; relating it to the model configuration's abstract identity is issue 681's.
