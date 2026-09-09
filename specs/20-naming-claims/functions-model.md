# Functions

New public functions. No bodies here.

## Naming Lean

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `wellFormedFixture` | `fixture` | `Bool` | Payment destination is none, or some value distinct from `controlAddress`. The four field slots are present. |
| `namingStep` | `state`, `action` | `Except String Result` | Accepts the generic action JSON shape. Insert/createInsert/fold of Insert follow generic uniqueness. Delete, name-release and reuse refuse with `naming-no-delete`. |
| `namingResolve` | `state`, `key`, `authenticated` | observation | `authenticated = false` yields `unauthenticated`. Otherwise absent/active/pending from the naming state. |
| `namingReplay` | `state`, `actions` | state plus records | Each action is `namingStep`. |

## Simulator naming engine (`simulator/naming.mjs`)

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `namingInitial` | none | naming state | Empty registry, well-formed config, no pending claims. |
| `spellingKey` | `spelling` | natural number | `alice` is defined. Unknown spelling is refused. |
| `queueClaim` | `state`, `{spelling, fixture, accepted}` | `{accepted, reason, value, requestId}` | `accepted = false` refuses with `application-approval`. Two queues for `alice` may both accept. |
| `foldRequest` | `state`, `requestId` | `{accepted, reason, value}` | First valid absent-key Insert accepts. A later Insert for that key refuses with `occupied-key`. |
| `namingStep` | `state`, `action` | `{accepted, reason, value}` | Same refusals as the Lean function. A crafted generic Delete JSON is refused with `naming-no-delete`, not `invalid-shape`. |
| `namingResolve` | `state`, `spelling`, `authenticated` | observation | Matches the Lean function on `spellingKey(spelling)`. |

## Profile selection

| Function | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| `selectProfile` | `profileId` | engine | Only `generic` and `m1-naming`. No implicit fallback from one to the other. |

## Inventories

Generic `tools/check_model.py` still inventories `Statements.lean` into
`lean/theorem-debt.json` and must match the frozen forty-one records.
A separate path inventories `NamingStatements.lean` into
`lean/naming-theorem-debt.json`. Names in the naming inventory do not
appear in the generic inventory. Every naming record is `PROVED` from
the standard axioms only.
