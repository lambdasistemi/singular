# Ask Lean about a batch

As someone reading the conformance book, I want a fold of several requests and a reject of several requests compared with what Lean decides for that batch, not left as unsupported. This ticket exposes the batch laws Lean already states; #287 then compares empty-fold, request-value-and-refund-routing and register-active-key with them.

## Required behavior

| Requirement | Observable result |
|---|---|
| driver-answers-foldbatch-question-list-fold-requests (blocking) | The driver answers a `foldBatch` question: a list of fold requests after a setup trace. The answer is `Singular.foldBatch` verbatim: refused `empty-fold`, the first failing request's `step` reason, or `net-mint-mismatch`; otherwise accepted with `config`, `custody`, `held`, `leaf` for every request key, the summed `mint`, the concatenated custody `paid`, `root` and `state`. No transaction is observed or built for a batch. |
| driver-answers-rejectbatch-question-non-empty-list (blocking) | The driver answers a `rejectBatch` question: a non-empty list of requests, every one rejected. The state is unchanged and nothing is minted; given observed outputs, the one judgement is `Singular.settle` over the concatenated reject obligations of all the requests. A batch containing a retract, a fold or a mix of exits, and an empty reject batch, is `unsupported`. |
| lean-proves-for-one-request-lawful-claim (blocking) | Lean proves: for one request with a lawful claim, `foldBatch s [r] = step s r`; a one-request reject batch judges exactly as the single `reject` question does. Every existing single-request operation, observation, judgement, identity binding and unsupported outcome is unchanged, checked in both directions. |
| declared-driver-surface-transport-driver-corpus-tools (blocking) | The declared driver surface, the transport, the driver corpus, `tools/check_model.py` and the constitution's translation table move together: both questions are declared with their own observation extent, reconciled in both directions, and the surface digest and protocol version move. |
| corpus-rows-include-lawful-multi-request-fold (blocking) | Corpus rows include a lawful multi-request fold, an unlawful-claim batch refused `net-mint-mismatch`, an empty batch refused `empty-fold`, a batch whose later request fails `step`, one-request preservation rows for both questions, a multi-request reject judged paid and judged short, and an unsupported mixed batch. A batch row with a wrong expected refusal fails the model check. |
| story-language-can-say-multi-request-fold (blocking) | The story language can say a multi-request fold and a multi-request reject. Validation, rendering and execution are total over the instruction set, and the executor submits each batch and asks the model the matching batch question. |
| no-lean-law-changes-model-lean-byte (blocking) | No Lean law changes (`Model.lean` byte-identical), no new refusal string, no batch transaction observation, no conformance row state moves, no constitutional principle changes. |

## Model and evidence

Bind main `ffe68b6f7c10851bab3acfba58c633dfdc1eab6b`, `lean/Singular/Model.lean` blob `9c75b37380d5e6f56691345bcc50b60d3faf184b`, constitution 1.11.0. Authority: operator ruling 2026-10-02 "Foundation ticket first", and the placement answer recording this as a technical representation of existing laws under constitution principle II. A required change to a law, obligation or principle stops the ticket and returns the concrete wording upward.

The empty-fold, request-value-and-refund-routing and register-active-key comparisons stay unverified here; #287's traced replay supplies them.
