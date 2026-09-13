# The no-owner repair — bounded plan, inventory and merge order

Under `NOTE-028` (the ruling) and `A-003` (the M1 disposition: reject the
inherited `End` and migration operations, remove registry-owner authority and
its domain fields, preserve every supported modeled action, add no transition
the model lacks).

## Inventory — every owner-authorized entry point

Read from `onchain/validators/` and `offchain/lib/` at `5bd7c79`.

| # | entry point | what it does today | disposition |
|---|---|---|---|
| 1 | `state.ak:47` — `End` arm | `validateOwnership`, then burns the registry token | **reject**. No `End` transition exists in the model |
| 2 | `state.ak:256` — `validateMigration` | `validateOwnership` on the predecessor state | **reject**. No migration transition exists |
| 3 | `request.ak` — `validateSweep` | reads `State.owner`, requires `has(extra_signatories, owner)`, reclaims UTxOs at the cage address | **reject**. `A-003` names Sweep explicitly; it is owner authority under another name |
| 4 | `types.ak:216` — `State.owner` | the domain field the three above read | **remove**, subject to the wire-compatibility note below |
| 5 | `types.ak:217` — `State.stake_script` | "can authorize owner operations" — the alternative authorization path | **remove with it**. `A-003` forbids leaving a destructive back door under a stake authorization path |
| 6 | `types.ak` `UpdateRedeemer` — `End`, `Sweep` | constructors reaching 1 and 3 | see below |
| 7 | `types.ak` `MintRedeemer` — `Burning`, `Migrating`/`Migration` | the burn and migration branches those paths use | **audit and close**: no unused constructor may remain executable |
| 8 | `offchain/lib/.../TxBuilder/{End,Sweep}.hs` | builders that construct 1 and 3 | **remove**; they can only build refused transactions |
| 9 | `offchain/lib/.../{Ledger,Types}.hs`, `TxBuilder/{Retract,Reject}.hs` | read or carry `owner` | **audit**: carry-through only, no authority |
| 10 | `cage.tests.ak` owner-transfer and old-owner/new-owner `End` rows | assert the removed semantics | **mark superseded, keep visible**, replaced by refusal tests |

**Constructors versus helpers.** `A-003` leaves it to me whether to delete
unreachable helpers or keep explicit refusal arms where wire compatibility needs
them. My intent: **keep the `UpdateRedeemer` constructors** so the on-chain
datum/redeemer wire shape does not shift under epic 18's consumer work, and make
`End` and `Sweep` **explicit refusal arms** with refusal tests, rather than
silently unreachable ones. The `State` record is different — leaving a dead
`owner` field invites someone to read it as authority again, and it is what
`types.ak`'s prose still describes. Removing it changes the datum schema, which
is why merge order matters below.

## What must not happen

- No permissionless destructive replacement. `End`, migration and `Sweep` are
  **refused**, not opened up.
- No executable back door under an unused constructor, a mint/burn branch or the
  stake path.
- No Lean change. No new transition.
- Request refund authority and name/application control are untouched — separate
  domains.

## The claim, stated exactly

Not "registries can never migrate". The present limitation is: **this M1 design
supplies no registry termination, migration or deposit-recovery operation**, and
the locked-deposit consequence goes plainly in the artifact documentation. A
future operation, or a discovered required M1 story that conflicts with this,
goes to the operator with its Lean clauses first.

## Evidence owed

Actual-code and ledger-boundary refusal tests showing **neither the creator nor
any other party** can terminate, migrate or seize registry authority through any
inherited operation — each refusal attributed to the validator that refused it —
with **supported-action success controls** in the same runs proving the registry
still works: a fold, a request, a retraction of an insert.

## Merge order — the part that needs deciding now

Removing `State.owner` is a **datum schema change**. It touches:

- every runner that reads or builds a `StateDatum` — `journey`, `li01`,
  `li-refusals`, `repair-rows`, and **#77's in-flight `ConnectedFold`**, which
  builds a state continuation;
- epic 18's consumer expectations and serialization coverage.

So the order is:

1. **#77 lands first.** It is active, it does not depend on owner authority, and
   its mandate already forbids reading or asserting the field — it carries it
   through unchanged. Landing it against the current schema avoids rebasing a
   large in-flight slice onto a schema change mid-build.
2. **Then this repair**, as its own slice, rebased onto #77, updating every
   `StateDatum` producer and consumer in one change.
3. **Epic 18 coordinates through root** before it pins serialization or consumer
   expectations to the owner-bearing shape — a stale owner-bearing interface must
   not be accepted as complete.

If epic 18 needs the schema settled sooner than #77 can land, that is a real
conflict and root should say so; I would rather re-cut #77's remaining work than
have two slices editing `StateDatum` at once.
