# Functions model: the callable surface this ticket adds or changes

This page owns only new or changed function names, their argument names, argument and result
types, and signature-level constraints. It contains no bodies, no algorithm and no proof; the
coder owns those. Only changed functions appear. Each group names its module in the
[modules model](modules-model.md) and the slice of the [plan](plan.md) that adds it.

## Story

As the coder who ports the rule, I read the exact call surface the validators' authors and the
conformance harness will depend on, so that I can implement it without choosing a name, an
argument order or an error channel that a later ticket then has to reverse.

## Singular.Model: retraction window (slice one)

| Name | Arguments | Result | Constraint |
|---|---|---|---|
| `inPhase2` | `c : Config`, `r : Request`, `w : RetractWitness` | `Bool` | Changed: reads `r.submittedAt`, never the witness's legacy field. Lower bound included, upper bound reaches and does not pass the end of the reclaim window. |
| `retractAdmission` | `c : Config`, `r : Request`, `w : RetractWitness` | `Option String` | Signature unchanged; order of reasons unchanged: not retractable, not signed by the owner, not inside the window. |

## Singular.Model: rejection admission (slice two)

| Name | Arguments | Result | Constraint |
|---|---|---|---|
| `rejectAdmission` | `s : RegistryState`, `r : Request`, `w : Option RejectWitness` | `Option String` | `none` admits; `some reason` refuses. Reports the first failing check in the order of the data model. Reads only its arguments. |
| `exitAdmission` | `s : RegistryState`, `exit : Exit`, `r : Request`, `w : RetractWitness`, `rejection : Option RejectWitness` (default none) | `Option String` | Changed: takes the whole state, not only its configuration. A fold has no admission, a retraction uses `retractAdmission`, a rejection uses `rejectAdmission`. |
| `admittedExitStep` | `state : RegistryState`, `exit : Exit`, `request : Request`, `witness : RetractWitness`, `rejection : Option RejectWitness` (default none) | `Except String Result` | Admission first; after admission exactly `exitStep`. |
| `admittedTxOfExit` | the arguments above plus `lovelace : Nat`, in that order, `rejection` last | `Except String Tx` | Admission first; after admission exactly `txOfExit`. |
| `exitRefusal` | `s : RegistryState`, `exit`, `request`, `witness`, `inputs : List TxInput`, `outputs : List TxOutput`, `rejection` (default none) | `Option String` | Changed: first argument is the state. Order: admission, then spending, then settlement. |

## Singular.Model: the action engine and the mixed batch (slice four)

Withdrawn on 14 October 2026: a rejection never spends the registry state output and never shares a transaction with a fold, so no batch holds both. The rows below describe the withdrawn slice.

| Name | Arguments | Result | Constraint |
|---|---|---|---|
| `ProcessAction.request` | `a : ProcessAction` | `Request` | Slice four. Total. |
| `ProcessAction.exit` | `a : ProcessAction` | `Exit` | Slice four. A fold names its request's edge; a rejection is `Exit.reject`. |
| `processAction` | `s : RegistryState`, `validFrom validTo : Nat`, `a : ProcessAction` | `Except String Result` | Slice four. One action through `admittedExitStep`; a rejection's witness is its evidence with the shared interval; a fold carries none. |
| `processActions` | `s`, `validFrom validTo`, `actions : List ProcessAction` | `Except String Result` | Slice four. Each action sees the state its predecessors left; results combine as a fold batch's do; no partial result on a refusal. |
| `processBatch` | `s`, `validFrom validTo`, `actions` | `Except String Result` | Slice four. Refuses an empty batch (`empty-process-batch`) and an empty interval (`reject-invalid-interval`); refuses `net-mint-mismatch` when the folds' claimed mint differs from what they mint per asset. |

## Singular.Driver and the transport (slices two and four)

| Name | Arguments | Result | Constraint |
|---|---|---|---|
| `Scenario.rejection` | field of `Scenario` | `Option RejectWitness` | Slice two. A rejection scenario without it is refused `reject-evidence-missing`, never `unsupported`. |
| `BatchScenario.rejections` | field of `BatchScenario` | `List (Option RejectWitness)` | Slice two. One entry per request of an all-reject batch. |
| `rejectBatchStep` | `s : RegistryState`, `requests : List Request`, `witnesses : List (Option RejectWitness)` | `Except String Result` | Slice two. Changed: refuses when the lists differ in length or the witnesses name different intervals; otherwise judges each request in order by `admittedExitStep` on the state its predecessor left. Slice four replaces that loop with `processActions` in the same diff, so one admission path remains. |
| `runRejectBatch` | `start`, `setup`, `batch`, `witnesses` | driver result | Slice two. Changed to pass the witnesses. |
| `BatchQuestion.processBatch` | `validFrom validTo : Nat`, `actions : List ProcessAction` | batch question | Slice four. Added; named `processBatch`; appears in the declared batch questions with the same observation extent. |
| `runProcessBatch` | `start`, `setup`, `validFrom validTo`, `actions` | driver result | Slice four. |
| `surface.protocolVersion` | field | `Nat` | Moves from 6 to 7 once, in slice one, and stays 7 through slices two to four; the surface digest is re-pinned by the slice that changes the declared surface. |
| `ToJson RejectEvidence`, `ToJson RejectWitness` | instances | JSON | Slice two. Every field of the data model appears; absent metadata fails decoding on a rejection and is ignored on a fold. |

## Statements the coder must state and prove

The names are fixed so that the register and the requirement pages agree. Each is a Lean
statement of the requirement of the same name in the [specification](spec.md).

| Statement | Requirement | Slice |
|---|---|---|
| `inPhase2_iff`, restated over the request | one-booked-clock | one |
| `expiry_after_reclaim` | one-booked-clock, expiry-follows-both-windows | two |
| `rejection_admitted_iff` | evidence-is-bound, two-grounds-only, mismatch-means-no-transition | two |
| `live_compatible_request_protected` | foldable-request-is-protected | two |
| `rejection_without_evidence` | rejection-needs-evidence | two |
| `protected_rejection_effects` | rejection-effects-unchanged | two |
| `admitted_exit_is_the_exit`, `admission_refuses_first` (restated) | admission-changes-no-effect | two |
| `process_actions_cons`, `process_actions_split`, `process_actions_reject_admitted`, `reject_batch_execution` | batch-judged-action-by-action | four |
| `process_batch_nonempty`, `process_batch_reject_admitted`, `process_batch_live_compatible_protected` | batch-judged-action-by-action, foldable-request-is-protected | four |

The statements are named as the earlier candidate named them, because the reviewed design is
the reference; the coder may restate one only if the two-edge model makes the earlier wording
false, and says which and why in the receipt.
