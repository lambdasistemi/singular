# Functions and statements for the ledger boundary

As the auditor of this child, I read each new name with its arguments and its result, and each statement with its premises, before any proof exists.

## Registry-free library, namespace `CardanoLedger`

| Name | Arguments | Result |
|---|---|---|
| `AssetName.valid` | `name : AssetName` | proposition: at most 32 bytes |
| `Assets.quantity` | `assets : Assets`, `asset : AssetClass` | `Int` |
| `Assets.moves` | `assets : Assets`, `policy : PolicyId` | `Bool`: some entry under the policy has a nonzero quantity |
| `Assets.onlyBurns` | `assets : Assets`, `policy : PolicyId` | `Bool`: every movement under the policy is negative and there is one |
| `Tx.redeemerOf` | `tx`, `purpose : Purpose` | `Option Redeemer` |
| `Tx.purposeHash` | `tx`, `purpose : Purpose` | `Option ScriptHash` |
| `Tx.invoked` | `tx` | `List Purpose` |
| `Tx.withoutStaking` | `tx` | the staking-free view, same type |
| `CollisionFreeOn` | `hash : α → β`, `occurs : α → Prop` | proposition |
| `Ledger.RunsScripts` | `ledger` | proposition |
| `Ledger.KeepsNamesWithinLimit` | `ledger` | proposition |

Every transaction-level name is parametric in the datum, redeemer and script types.

## Registry instance, namespace `Singular.LedgerBoundary`

| Name | Arguments | Result |
|---|---|---|
| `RegistryWorld.ledger` | `world : RegistryWorld` | the ledger whose script evaluation runs the witness decision for witness scripts and the world's rules for the others |
| `RegistryWorld.policyId` | `world`, `kind : TokenKind`, `registry : AssetClass` | `PolicyId` |
| `foldPresent` | `world`, `registry : AssetClass`, `tx : RegistryTx` | `Bool` |
| `witnessDecision` | `world`, `kind : TokenKind`, `registry : AssetClass`, `ctx : RegistryContext` | `Bool` |
| `Bound` | `world`, `pins : Pins`, `registry : AssetClass` | proposition |
| `keyName` | `key : Key` | `AssetName` |
| `keyOfName` | `name : AssetName` | `Key` |
| `tokenOf` | `world`, `kind : TokenKind`, `registry : AssetClass`, `key : Key` | `AssetClass` |
| `ScriptsOccur` | `world`, `registry : AssetClass`, `tx : RegistryTx` | predicate on registry scripts |
| `StateScriptFolds` | `world`, `registry : AssetClass` | proposition |
| `discardTerminal` | `state : RegistryState`, `key : Key`, `output : Nat` | `RegistryState` |

## Statements, namespace `Singular.Statements`

Each is a theorem proved from `propext`, `Classical.choice` and `Quot.sound` alone. Premises are listed as they appear in the signature; a premise a proof does not use is dropped.

| Statement | Premises | Conclusion |
|---|---|---|
| `witness_decision_cases` | none | for each kind, the witness decision equals the per-kind rule of the data model, stated as an equivalence with its clauses |
| `fold_required_for_active_and_absent` | runs scripts; collision-free on the occurring scripts; bound; accepted; the mint moves the bound active or absent pin | some input at the state script's address carries exactly one unit of the registry identity, is spent under the fold redeemer, and the state rule returns true on that spend |
| `key_names_its_token` | bound; for the count clause, a reachable model state; for the limit clause, keeps names within limit and accepted | the active token of a key is the active pin with the key's name; key and name determine each other; the number of active holdings named by the key equals one exactly when the key is active, else zero; a name longer than 32 bytes is never minted |
| `active_mint_at_unknown_key` | the premises of the fold statement; state-script folds | every key minted positively under the active pin was unknown in the spent model state; for a reachable spent state the key holds exactly one active token after the fold |
| `token_policies_read_no_staking` | none | for every kind, registry identity, purpose and redeemer, two transactions with the same staking-free view get the same witness decision |
| `terminal_discard_changes_no_registry_state` | none | after a discard: every key's leaf, the root, the configuration and the custody are equal to before; every active count is equal to before; consistency is preserved |
| `ledger_boundary_premises_satisfiable` | none | a world, pins, registry identity and transactions exist meeting every premise above at once, the ledger accepts one minting a single active token under the bound pin and one terminal pure burn without a fold, and a discard there removes a real terminal holding |

The names are part of the vocabulary issues 680 and 681 cite; renaming one is a mandate change.
