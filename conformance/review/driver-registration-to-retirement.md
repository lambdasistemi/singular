# Registration to retirement, run through the model driver

A reader asked to trust the registry wants one thing first: show me a
registration, then show me that same registration retired, and tell me what
you compared. This is that story, and every value below is read out of
`lean/driver-corpus.json` — the corpus the driver produced by executing the
model — rather than typed here.

- driver corpus payload: `5f63893972e779550554ea8ecca7f7dc7ef155e0d50e500d682004fa50c8c1c3`
- model: `3d1f0b1ec8670fabbf825d78b23f1a5c5fb865aafdbbfaaabdeb614198c95b89`
- surface: `Singular.Driver.runSurface`, protocol version 1, digest `15532557153383378181`

## What the driver is

One executable over the model's own law, not one adapter per theorem. It
reaches a scenario's starting state by *running* the law over a setup trace,
checks the law premise on the state it arrived at, applies the request through
`Singular.step`, and reports the whole declared boundary of what the law did.

Declared operations: `insertAbsent`, `insertActive`, `updateActive`, `updateTerminal`, `deleteAbsent`, `deleteActive`, `witnessTerminal`.

Declared observations: `config`, `custody`, `held`, `leaf`, `mint`, `paid`, `root`, `state`, `tx`.
Every accepted row reports all nine. A row reporting a subset is a per-theorem
projection and the model check rejects it.

## The registration

`DR02-register-active`, bound to `Singular.Statements.insert_active_transaction_row` at statement `bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737`.
The request is `insertActive` on key 42, owner
42, routed to output 555, carrying an
approval scoped to exactly that tuple. It starts from the empty registry, so
its setup trace is empty and `requiresReachableState` is false.

Outcome: **accepted**. The complete declared boundary:

| observation | value the law produced |
|---|---|
| `leaf` | `active` |
| `root` | `[26, 122, 121, 111, 253, 168, 231, 64]` |
| `mint` | `[{"assetName": 42, "key": 42, "kind": "active", "policy": 8, "quantity": 1}]` |
| `paid` | `[]` |
| `held` | `[{"key": 42, "kind": "active", "output": 555}]` |
| `custody` | `[]` |
| `config` | root `[26, 122, 121, 111, 253, 168, 231, 64]`, maxFee 0, application policy 7, active policy 8, absent policy 9, terminal policy 10 |
| `state` | 1 leaf, 0 custody, 1 held |
| `tx` | inputs ['state', 'request'], outputs ['state', 'destination'], mint `[{"assetName": 42, "key": 42, "kind": "active", "policy": 8, "quantity": 1}]`, signers `[]`, refunds `[]` |

## The retirement of that same registration

`DR03-retire-registered`, bound to `Singular.Statements.update_terminal_transaction_row` at statement `3448ca20f33bba9c3b5092136124f4cb0bf196132f485cae8b1a44343523963b`.

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
| `paid` | `[]` |
| `held` | `[]` |
| `custody` | `[]` |
| `config` | root `[26, 122, 121, 112, 0, 168, 235, 249]`, maxFee 0, application policy 7, active policy 8, absent policy 9, terminal policy 10 |
| `state` | 1 leaf, 0 custody, 0 held |
| `tx` | inputs ['state', 'request', 'witness'], outputs ['state', 'destination'], mint `[{"assetName": 42, "key": 42, "kind": "active", "policy": 8, "quantity": -1}]`, signers `[]`, refunds `[]` |

The key moves `active` to `terminal`, the active holding is released, and the
mint is exactly the keyed burn of the token that registration created — same
policy, same asset name, quantity -1. No terminal token is minted, because the
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
