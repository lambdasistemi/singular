# Opus review follow-up

The operator commissioned an Opus source review and then directed repair of the
merge blockers. The first review was Claude Opus 5.5, a fresh read-only context;
it did not run the author's gates. Its seven observations are addressed below.

| Observation | Disposition and evidence |
| --- | --- |
| F1: two submission times permit inconsistent reclaim/expiry windows | Retraction now reads `Request.submittedAt`, just as expiry does. The legacy witness field cannot shift admission. `expiry_after_reclaim` proves the interval ordering for every admitted retraction and expiry rejection of the same request. Two corpus cases cover a forged witness time and an irrelevant witness-time change. The timestamp mutation restores the defect and must fail the guards. |
| F2: live consumers are unmigrated | Explicitly retained integration limit. This model-only slice does not implement validators, builders or the live caller migration. Their comparisons cannot claim protocol-7 protection; dependent acceptance remains held. No live coverage row is promoted. |
| F3: missing metadata defaults to zero | The JSON transport requires explicit request booking time and registry identity on protected exits, plus identities in rejection evidence and state configuration. Explicit zero remains valid, but missing/null values fail decoding. The replay script tests both forms of omission. Authentication of supplied data remains the concrete consumer's duty. |
| F4: batch protection lacks a theorem | `process_actions_split`, `process_actions_reject_admitted`, `process_batch_reject_admitted` and `process_batch_live_compatible_protected` establish admission at every intermediate prefix state. All-reject batches now share the action engine; `reject_batch_execution` binds the driver to it. |
| F5: Boolean equality weakens the stated binding | Rejection now uses decidable structural equality for configuration and request. `rejection_admitted_iff` states actual equality for both. |
| F6: coverage narrower than the description | Added a foreign request-registry case, mixed mint-claim failure, and separate mutations for request identity, the timestamp defect and mixed mint checking. The README explicitly states that the Python derivation uses tables parsed from the same model and assumes legal mixed-fold inputs. Eight model-definition mutants are a bounded fault set, not exhaustive coverage or independent transport mutations. |
| F7: rejection evidence ignored on other exits | The single-exit JSON decoder rejects a rejection witness on a fold or retraction. The transport checks exercise this refusal. |

The original choices remain: missing rejection evidence is a refusal, not a
new permission to cancel; expiry uses both configured durations for every edge.
Neither review question authorizes a new rejection ground. #500 and #361 remain
separate. These changes and checks establish model behavior, not live protection.

## Focused re-review

Claude Opus 5.5 found no remaining model-only blocker and marked F1, F3, F4, F5
and F7 resolved, F6 addressed within its declared bounds, and F2 an explicit
integration limit. This was again source review, not independent gate execution.

Its additional N1 disclosure is recorded here and in the README: the existing
live retraction encoder supplies booking time only in the witness and omits
`Request.submittedAt` and `registryId`. Those questions now fail decoding;
previously working live retraction comparisons, including outside-window cases,
are held until encoder migration. Historical receipts are not evidence for the
new model revision. No consumer migration or live acceptance is claimed.
