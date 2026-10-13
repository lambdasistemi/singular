# Functions model

New or changed signatures only: names, explicit arguments, argument and result types, constraints and effects. No bodies. Output ceiling: 6 KB.

## Registry library

| name | arguments | result | constraint |
|---|---|---|---|
| `selectFold` | `capacity`: capacity bound; `nowMs`: POSIX milliseconds; `marginMs`: milliseconds; `facts`: live facts; `pending`: pending requests with their output references | selection | pure; ledger input order; the seven checks in the spec's order; every pending request is in exactly one list |
| `judgeAlone` | `nowMs`; `marginMs`; `facts`; `pending request` | exclusion or selected request | no argument names any other pending request |
| `foldCapacity` | none | capacity bound | 1 with its provenance in pull request 1; 9 with the provenance text of the spec in pull request 2 |
| `exclusionName`, `exclusionSource` | `exclusion` | text; `model-refusal` or `selection-policy` | total over the fourteen reason names (eight model refusals, six selection policy) |
| `updateTokenSelected` | `cfg`; `view`; `snapshot`; `token`; `address`; `context`; `selected`: non-empty list of request output references | transaction | spends the state output and exactly the selected request outputs among those pending; fails naming a selected reference that is not pending; one request in pull request 1; the upper bound follows the earliest deadline among the selected requests in pull request 2 |

## Command line

| name | arguments | result | constraint |
|---|---|---|---|
| `foldRequests` | `named`: optional request reference; `selection` | non-empty list of selected requests or a fold refusal | a named request that is not selected is refused with its exclusion; nothing selected is `nothing-to-fold` listing every exclusion |
| `spendsSelection` | `state`: reference; `selected`: references; `pending`: references; `spent`: references | ok or why not | the state output and every selected request are spent; no other pending request is |
| `applicationStep` | `application`: application value; `view`; `registry`; `selected request` | settlement inputs or an exclusion | the only function that reaches application knowledge, and only through the value; an unreadable carried datum is `application-datum-unreadable`; a termination under a value with no holding rules is `application-required`, its detail naming the application's executable |
| `foldPending` (changed) | as today (it takes the application value first at the base) | a fold receipt value with a non-empty settled list and an excluded list | takes the selection (its first request in pull request 1, all of it in pull request 2); the combined origin stops partial, naming its own request, when that request is excluded |
| `foldedFields` (changed) | the fold receipt value | receipt fields | the list shape of the data model |
| `Expectation` (changed, pull request 2) | the list of fold transitions | | replaces the single key, edge and root pair |
| `observe`, rollback (changed, pull request 2) | the prepared line | one verdict per transition; the restored root | each key is read against its last transition |

## Conformance

| name | arguments | result | constraint |
|---|---|---|---|
| model-agreement example | a state, a pending list, a capacity bound | pass or fail | runs `selectFold`, asks the model's `foldBatch` question (driver `runFoldBatch`) about the selected batch, requires acceptance and equal state, mint and paid; a same-key batch is refused with the first refusing step's reason |

Removed: `foldTarget`, `FoldTargetRefusal`, `renderTargetRefusal`.

## Pull request 3 at `e7b55ac9`

New and changed signatures of pull request 3a (3b changes no signature; it changes what `observe` does with the list). Names and fields are in the [data model](data-model.md).

| name | arguments | result | constraint |
|---|---|---|---|
| `foldPendingBounded` | `bound`: capacity bound; the arguments of `foldPending` | fold result | `foldPending` is this with the production bound; another bound is used only by a test |
| `Folded` (changed) | | a non-empty list of settled entries and the facts of the transaction | replaces the single-request fields (the swap rule); the fold deadline is the earliest among the settled entries |
| `settledEntryFor` | `folded`: fold result; `request`: reference | the settled entry or nothing | how a combined form finds its own booking |
| `foldTransitions` (pull request 3b) | `entry`: journal entry | list of fold transitions | the entry's list; without one, the scalar fields as a list of one; empty for a line that carries neither |
| `chainTransitions` | `rootBefore`; per request: reference, key, edge, expectation, root after | list of fold transitions | each root before is the previous root after |
| `Expectation` (changed) | a second constructor `FoldExpectation`: the non-empty list of fold transitions | | the first constructor and its fields are unchanged; the journal scalars of a `FoldExpectation` are the first transition's key, expectation, edge and root before and the last transition's root after |
