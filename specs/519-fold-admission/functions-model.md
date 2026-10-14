# Functions model

New or changed signatures only: names, explicit arguments, argument and result types, constraints and effects. No bodies. Data are in the [data model](data-model.md). Output ceiling: 6 KB.

## The model (Lean, pull requests 1 and 2)

Pull request 1 carries `batchConsumesCreated`, the changed `foldBatch` and the statements `batch_cannot_consume_what_it_creates`, `batch_burns_only_live_holdings` and `independent_requests_fold_as_a_batch`. Pull request 2 carries everything else in this table.

| name | arguments | result | constraint |
|---|---|---|---|
| `Request.submittedAt` | the request | natural number | field; written by the request's serialization |
| `FoldWitness` | `validTo` | structure | one field; serializes as the scenario's `foldWitness` |
| `inPhase1` | `config`; `submittedAt`; `validTo` | boolean | the upper bound is at or before `submittedAt + processTime` |
| `foldAdmission` | `config`; `batch`: requests; `witness`: fold witness | none or a reason | `edge-inadmissible` when a member's edge is not admitted, then `not-phase1` unless every request of the batch is in phase 1; total on the empty batch |
| `admittedFoldBatch` | `state`; `batch`; `witness` | result or reason | admission first, otherwise exactly `foldBatch` |
| `exitAdmission` (changed) | `config`; `exit`; `request`; `witness` | none or a reason | a fold exit is admitted by `foldAdmission` of its one request under the witness's upper bound; a reject has none; a retraction is unchanged |
| `batchConsumesCreated` | `batch`: requests | none or a reason | the first termination of a key an earlier insertion of the batch created is `token-missing` |
| `foldBatch` (changed) | `state`; `batch` | result or reason | the existing refusals, then `batchConsumesCreated` |

Statements, named by what they say: `fold_admitted_up_to_the_deadline`, `fold_refused_past_any_deadline`, `fold_admission_judges_each_request_by_its_own_time`, `fixed_edge_set_precedes_the_window`, `fold_admission_precedes_the_law`, `reject_reads_no_time`, `batch_cannot_consume_what_it_creates`, `batch_burns_only_live_holdings`, `independent_requests_fold_as_a_batch`. The existing statements about `admittedExitStep`, the batch of one and the excluded-edge fold gain the premise that the fold is admitted.

## The model's consumers (pull requests 1 and 2)

Pull request 1 changes rows and anchors only; the witness and the transport question are pull request 2.

| name | arguments | result | constraint |
|---|---|---|---|
| driver scenario (changed) | gains `foldWitness` | scenario | a fold scenario or a fold batch with no witness is `unsupported` with the reason `fold-without-witness`, never a refusal |
| `runFoldBatch` (changed) | gains `witness` | steps and answer | admission first, then `foldBatch`; the declared observation extent is unchanged |
| transport question (changed) | the request's `submittedAt` and the fold's upper bound | model answer | read by the conformance transport; the live driver supplies them off the built transaction and the request datum |

## Registry library (pull request 3)

| name | arguments | result | constraint |
|---|---|---|---|
| `foldAdmission` (library) | `processTimeMs`; `upperBoundMs`; `included`: non-empty list of request output reference with `submittedAtMs` | admitted, or the admission refusal | pure, in POSIX milliseconds; mirrors the model's function of the same name; names the first request in input order whose deadline the bound passes |
| `batchConsumesCreated` (library) | `included`: ordered list of key with edge | ok, or the batch-consumption refusal | pure; mirrors the model's function |
| builder entry points (changed) | as the subset entry point of #518 | transaction | refuse before returning a transaction when either function refuses; the bound is read from the built body, not from the intended value |
| selection window rule (changed) | `nowMs`; `marginMs`; the request's deadline | included, or excluded `not-phase1` | evaluates `foldAdmission` at `nowMs + marginMs`; `window-closed` is gone |
| post-build decision (changed) | the built body; the included requests | go, or a refusal | calls `foldAdmission` for the deadline comparison; keeps its client refusals for what the model has no vocabulary for |

## Validator evidence (pull request 4)

| name | arguments | result | constraint |
|---|---|---|---|
| Aiken window and same-key tests | fixtures with a submission time per request and an upper bound per transaction | pass or fail | each refusal asserts the traced reason through the state's refusal function, then the spend handler; each has an accepted twin |
| compiled-context export and checker rows | exported labels | accepted or refused per label | evaluated against compiled bytes; the always-accept fault control fails them |
| live window row | a registry of its own | receipt | chain refusal attributed by script hash; model answer `not-phase1` compared |

Removed: the sentence in the constitution and the conformance book that a fold of an update outside its window is accepted by the model and refused by the validator.
