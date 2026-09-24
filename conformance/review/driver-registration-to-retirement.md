# Registration to retirement, run through the model driver

A reader asked to trust the registry wants one thing first: show me a
registration, then show me that same registration retired, and tell me what
you compared. This is that story, and every value below is read out of
`lean/driver-corpus.json` — the corpus the driver produced by executing the
model — rather than typed here.

- driver corpus payload: `4d3d3c33babaed50de04ccf63c3dd5984b035fcfbea95f7477014fd8cf681609`
- model: `2ec6f813d3a09cfa25d10437caaadf6c13cdace0b59d19694e574d0a09207a27`
- surface: `Singular.Driver.runSurface`, protocol version 2, digest `13998092095361678048`

## What the driver is

One executable over the model's own law, not one adapter per theorem. It
reaches a scenario's starting state by *running* the law over a setup trace,
checks the law premise on the state it arrived at, takes the scenario's exit on
the request through `Singular.exitStep`, and reports the whole declared boundary
of what the law did.

Declared operations: `insertAbsent`, `insertActive`, `updateActive`, `updateTerminal`, `deleteAbsent`, `deleteActive`, `witnessTerminal`, `reject`, `retract`.

Declared observations: `config`, `custody`, `held`, `leaf`, `mint`, `paid`, `root`, `state`, `tx`.
Every accepted row reports all nine. A row reporting a subset is a per-theorem
projection and the model check rejects it.

## The registration

`DR02-register-active`, bound to `Singular.Statements.insert_active_transaction_row` at statement `f1f50ac910b0ff0f5abb8d371bd82ce5007e8bfe861939c5972d62e8c85e8508`.
The request is `insertActive` on key 42, owner
42, routed to output 555, with a deposit of 55 and carrying an
approval scoped to exactly that tuple. It starts from the empty registry, so
its setup trace is empty and `requiresReachableState` is false.

Outcome: **accepted**. The complete declared boundary:

| observation | value the law produced |
|---|---|
| `leaf` | `active` |
| `root` | `[26, 122, 121, 111, 253, 168, 231, 64]` |
| `mint` | `[{"assetName": 42, "key": 42, "kind": "active", "policy": 8, "quantity": 1}]` |
| `paid` | `[{"address": 555, "value": 55}]` |
| `held` | `[{"key": 42, "kind": "active", "output": 555}]` |
| `custody` | `[]` |
| `config` | root `[26, 122, 121, 111, 253, 168, 231, 64]`, maxFee 0, application policy 7, active policy 8, absent policy 9, terminal policy 10 |
| `state` | 1 leaf, 0 custody, 1 held |
| `tx` | inputs ['state', 'request'], outputs (role, lovelace) state 0, destination 55, mint `[{"assetName": 42, "key": 42, "kind": "active", "policy": 8, "quantity": 1}]`, signers `[]`, refunds `[{"address": 555, "value": 55}]` |

## The retirement of that same registration

`DR03-retire-registered`, bound to `Singular.Statements.update_terminal_transaction_row` at statement `6792444e9887f9e579975eae2cca2be00048db6d5a7a8c147b72fe6462eb3068`.

This is the row the constitution's lifecycle rule is about. Its starting state
is not constructed: its setup trace is the registration above, re-executed
through the law, and the driver records what that step produced.

| setup step | request | accepted | leaf it produced |
|---|---|---|---|
| 0 | `insertActive` key 42 | true | `active` |

Premise checked before observing: `Singular.Driver.consistentB` = true.

Outcome: **accepted**. The complete declared boundary:

| observation | value the law produced |
|---|---|
| `leaf` | `terminal` |
| `root` | `[26, 122, 121, 112, 0, 168, 235, 249]` |
| `mint` | `[{"assetName": 42, "key": 42, "kind": "active", "policy": 8, "quantity": -1}]` |
| `paid` | `[{"address": 42, "value": 55}]` |
| `held` | `[]` |
| `custody` | `[]` |
| `config` | root `[26, 122, 121, 112, 0, 168, 235, 249]`, maxFee 0, application policy 7, active policy 8, absent policy 9, terminal policy 10 |
| `state` | 1 leaf, 0 custody, 0 held |
| `tx` | inputs ['state', 'request', 'witness'], outputs (role, lovelace) state 0, destination 0, owner 55, mint `[{"assetName": 42, "key": 42, "kind": "active", "policy": 8, "quantity": -1}]`, signers `[]`, refunds `[{"address": 42, "value": 55}]` |

The key moves `active` to `terminal`, the active holding is released, and the
mint is exactly the keyed burn of the token that registration created — same
policy, same asset name, quantity -1. A retirement delivers nothing, so its
deposit goes back to the owner: one owner output, with no datum, carrying the
deposit and naming the approval it returns, and that payment is the row's
`paid`. The registration's deposit instead goes with the token, in the
destination output. No terminal token is minted, because the
model's R2 table mints one only for `witnessTerminal`.

## The refusals beside them

| scenario | mutates | request | outcome | reason the model gave |
|---|---|---|---|---|
| `DR04-register-absent-unapproved` | `DR01-register-absent` | `insertAbsent` key 5 | refused | `no-approval` |
| `DR05-register-active-twice` | `DR02-register-active` | `insertActive` key 42 | refused | `key-exists` |
| `DR06-retire-unregistered` | `DR03-retire-registered` | `updateTerminal` key 42 | refused | `key-unknown` |

Each reason is one `Singular.refusal` can actually produce. The model check
reads that vocabulary off the model source, so a transport or process failure
cannot be recorded as a ledger refusal.

## What this does not establish

The `root` above is `Singular.rootOf` — FNV-1a over the sorted (key, leaf byte)
list. It is the model's own commitment function and **not** the concrete trie
hash a chain carries. Nothing here claims byte agreement with a real registry
root. The constitution names that limit, with `registryAddress`,
`requiredSigners`, `scriptExecutionUnits`, `transactionId` and `utxoReference`,
as fields the model has no vocabulary for — which is why `signers` is empty
above rather than filled with an invented value.

This is a driver over the model. It is not a run against a devnet: no
transaction here was submitted to a ledger. Comparing these observations with
a real registry is the next slice's work, and until it has evidence the
registry's conformance to these rows remains unestablished.
