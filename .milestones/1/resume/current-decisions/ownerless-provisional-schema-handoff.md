# Ownerless schema handoff — epic 18 and #87

**PROVISIONAL until accepted.** The subject below is a locally committed
antecedent, not an accepted candidate. #87 may plan its definitive input binding
from this; **no old witness becomes fresh repair evidence**, and nothing here is
final credit.

## Subject

| field | value |
|---|---|
| antecedent commit | `f3a68b1bcd63119f8db79548a7d15926bf408856` |
| its base | `56e0fcd` (the merged #79 repair) |
| branch | `feat/real-representative-fold` (#77 work restored on top — **the tip is not this commit**) |
| authority | operator ruling `NOTE-028`, disposition `A-003` |

## Generic `State` wire/schema delta — this is the breaking part

```
before (56e0fcd)                after (f3a68b1)
  owner: VerificationKeyHash      (removed)
  stake_script: Option<ScriptHash> (removed)
  root: ByteArray                 root: ByteArray
  tip: Int                        tip: Int
  process_time: Int               process_time: Int
  ...                             ...
```

Two fields removed from the head of the record. **Any consumer decoding
`StateDatum` positionally will mis-parse**, not merely lose fields.

## State parameter change

```
before:  validator state(previousPolicies: List<PolicyId>)
after:   validator state()
```

**The state validator is now parameterless.** Its applied identity is therefore
its unapplied identity, and any consumer that applies `previousPolicies` to
derive the state script address will derive the wrong one. This is separate from
the datum change and breaks independently.

## Identities

To be read from the accepted candidate, not from this draft — the tree has #77
work on top and the identities will move again when the connected journey and
verifier land. What epic 18 should bind later, from the accepted commit:

- `onchain/script-identity.json`: `state.state.*`, `request.request.*`,
  `staking.staking.*` with their `parameters` counts;
- `naming-onchain/script-identity.json`: application, representative, custody;
- the Aiken compiler version recorded in each manifest;
- the built blueprint store paths.

I will send the exact values with the accepted candidate SHA. Binding them now
would bind a moving draft.

## Which old observations require rerun

The commit message cites `li01`, `li-refusals`, `naming-rows` and `journey`
green "on the repaired tree". **Those runs predate the antecedent's extraction**
and I have not yet established whether pending #77 changes were present in the
tree at the time. Until that is settled they are **combined-tree evidence, not
proof of `f3a68b1` alone**, and I am treating them as such. The earlier raw
evidence is retained separately; the required bounded gate re-executes **once**
on the final coherent candidate.

So: rerun everything that touches `StateDatum` or the state script identity —
`li01`, `li-refusals`, `journey`, `naming-rows`, `repair-rows`, the cage E2E
suite, and epic 18's CS/CG serialization rows.

## Integration shape

The repair **cannot stand alone as a PR**: removing two datum fields and the
state parameter requires the consumer codec to move with it. The exact
dependency is epic 18's `StateDatum` decoder and any address derivation applying
`previousPolicies`. That is a **serial coordinated cut**, not an independent
merge — I am not declaring the repair accepted on its own.

Epic 18 should not freeze or claim serialization conformance against either the
six-field owner-bearing shape or this draft.

## What is preserved

Request and application authority, refund destinations, name/application
controllers and **ordinary funding signatures** are untouched and remain governed
by their own clauses. Historical owner behaviour is kept in
`onchain/validators/superseded-owner-authority.md` as defect witnesses, not
deleted. No permanence is claimed beyond the approved M1 action set: the precise
statement is that **this M1 design supplies no registry termination, migration or
deposit-recovery operation**.
