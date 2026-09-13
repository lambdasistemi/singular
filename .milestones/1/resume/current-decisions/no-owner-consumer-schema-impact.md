# Consumer-side impact of removing registry-owner authority and its domain fields

Epic-18 response to epic 17's A-003, which directs: *"remove registry-owner authority and its domain
fields"*, *"your bounded plan must encompass owner-authorized `Sweep` as well as `End`/migration"*,
and *"coordinate schema/codec and consumer changes with epic 18 through durable owner handoffs"*.

This is that coordination input, filed before the repair lands so the schema consequence is not
discovered afterwards.

## The consequence that reaches furthest: the datum shape changes

`OnChainTokenState` currently carries **six** fields, and the first is the owner:

```haskell
data OnChainTokenState = OnChainTokenState
    { stateOwner :: !BuiltinByteString      -- payment key hash of the token owner (28 bytes)
    , stateStakeScript :: !(Maybe BuiltinByteString)
    , stateRoot :: !OnChainRoot
    , stateMaxFee :: !Integer
    , stateProcessTime :: !Integer
    , stateRetractTime :: !Integer
    }
```

Removing the owner **domain field** changes the on-chain datum's constructor arity and field order.
That is a wire-format change, and it lands on:

| surface | effect |
|---|---|
| `Cardano.MPFS.Cage.Types` `ToData`/`FromData` | hand-written instances encode six fields in order; they change |
| **CS08** (merged) | its requirement literally names *"`OnChainTokenState`'s six fields (owner, stake_script, …)"*. Its expectation becomes wrong the moment the field goes. |
| **CS01** (merged) | checks each type's constructor index and field order against the compiled blueprint schema — the blueprint changes with the validator |
| **CS02** (merged) | datum bytes submitted and read back byte-identical — different bytes |
| vendored v0.2.0 wire vectors and any golden fixtures | may no longer round-trip |
| `docs/consumer-conformance.md` and the `fold_iff` correspondence page | state registry-owner behaviour |

**None of those receipts is invalidated as history** — they recorded what was true of their
candidate. But their *expectations* become superseded at the repair commit, and the rows must be
re-executed against the repaired blueprint rather than inheriting a pass.

## Also affected, per A-003's explicit scope

- **CG16** (`Sweep`, owner-signed) and **CG17** (`Sweep` by a non-owner) assert registry-owner
  authority and are superseded by the same ruling.
- **CG13**'s owner-transfer observation is defect evidence; its control is withdrawn.
- **CG19** is *not* affected — its "owner" is the **request** owner, which A-003 preserves along with
  name/application control.
- **CG20** is strengthened, not disturbed.

## Merge order, which A-003 asks to be determined rather than assumed

The repair is **schema-affecting**, so:

1. it must land **before** any release that claims CS-row conformance, since CS01/CS02/CS08 receipts
   taken against the current blueprint describe a datum that will no longer exist;
2. epic 18 will **re-execute** the affected CS and CG rows against the repaired blueprint and record
   fresh receipts — coverage is not inherited across a wire-format change;
3. **#77 is active and interface-bearing**: it must not be accepted against a stale owner-bearing
   interface. That is epic 17's call to sequence, but epic 18 will refuse to count conformance
   evidence produced against the pre-repair datum once the repair exists.

## Documentation obligation epic 18 accepts

A-003 requires the present limitation stated plainly, without inflating it into a universal promise:

> this M1 design supplies no registry termination/migration or registry-deposit recovery operation

and **the locked-deposit consequence belongs plainly in the artifact documentation**. Epic 18 will
carry that into `docs/consumer-conformance.md` — as a present limitation of this design, explicitly
not a claim that future registries can never migrate.

## What epic 18 will not do

No parallel edits to shared validator files. No permissionless destructive replacement. No new
lifecycle transition. If a consumer requirement turns out to conflict with the no-owner limit, it goes
to the operator with its Lean clauses before anything changes.
