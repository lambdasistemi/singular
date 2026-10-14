# Data model

Fields, relationships, validation and state invariants of the new or changed data. Signatures are in the [functions model](functions-model.md); responsibilities in the [modules model](modules-model.md). Output ceiling: 6 KB.

## The model (pull requests 1 and 2)

Pull request 1 carries the created holdings and the changed batch verdict; pull request 2 carries the request field, the fold witness and the fold admission verdict.

| name | fields | validation |
|---|---|---|
| request (changed) | gains `submittedAt`: the submission time of the request itself, POSIX milliseconds, as its chain datum records it (`submitted_at`) | a request that never takes part in a fold's admission carries the default; an exported row always writes the field |
| fold witness (new) | `validTo`: the fold transaction's finite validity upper bound, excluded as the ledger hands it to a script, POSIX milliseconds | finite only; there is no value for an open bound, which stays outside the model |
| created holdings (new, internal to a batch) | the keys of the active holdings that earlier requests of the batch created | empty at the start of a batch; an accepted insertion adds its key; read only by the rule that refuses a termination of such a key |
| fold admission verdict | none, or the reason `edge-inadmissible` or `not-phase1` | `edge-inadmissible` when some included request has an edge the registry does not admit, as the validator checks every updating request before anything else; otherwise `not-phase1` exactly when some included request has `validTo` greater than `submittedAt + processTime` |
| batch verdict (changed) | the existing reasons and, after the mint check, `token-missing` for a termination of a key in created holdings | the reason order is the validator's: admission, each step in order, mint balance, then burns |

State invariants. A fold's admission reads no registry state beyond the configuration's processing time. Inside the window a fold is exactly the law it was before. A batch accepted by the model burns only holdings that existed in the state it started from. A reject is admitted in any window.

## Builder and receipt (pull request 3)

| name | fields | validation |
|---|---|---|
| request deadline | the request output reference and `submittedAt + processTime` | read from the request datum and the state's processing time, never from the clock |
| probe bound | `nowMs + marginMs`: the earliest upper bound the processor will build | the selection excludes a request the model refuses at this bound |
| admission refusal | reason `not-phase1`, source `model-refusal`; the request output reference, its deadline, the bound | names the first included request, in input order, whose deadline the bound passes |
| batch-consumption refusal | reason `token-missing`, source `model-refusal`; the terminating request and the key | names the first termination of a key an earlier included insertion created |
| excluded request (changed) | the existing fields; reason `not-phase1` replaces `window-closed`; detail carries the deadline and the probe bound | `window-closed` appears in no value, receipt, page or script |
| client refusals kept | no upper bound, bound unconvertible to time, clock within the margin | labelled client policy, never model refusals: the model has no open bound |

Reason names by source after this ticket: model refusal gains `not-phase1`; selection policy loses `window-closed` and keeps `undecodable`, `application-datum-unreadable`, `key-in-batch`, `capacity`.

## Validator evidence (pull request 4)

| name | fields | validation |
|---|---|---|
| window case | the upper bound as the ledger hands it (finite excluded, finite included, open), each included request's submission time, the expected verdict | covers the deadline, one before and one past it, requests with different submission times, an expired reject beside an in-window update |
| same-key batch case | the ordered edges on one key (insertion then termination, termination then insertion, insertion twice, termination twice) and the expected reason | each refusal is the reason the model gives the pair |
| exported context | a label, the transaction context as Data, the expected verdict | evaluated against the blueprint's compiled state bytes; the always-accept program must make the checker fail on the new labels |
| live row | a registry of its own, requests booked at known times, a fold built with an upper bound past one deadline | the chain refuses it; the model answers `not-phase1`; the refusal is attributed by script hash |

State invariants. Every refused case has an accepted twin that differs in the one mutated field. Counts of exported contexts are derived from the discovered labels, not typed.
