# Deliver the batch questions

As the ticket owner, I want each slice accepted on reviewed checkpoints and green CI.

## Implementation

- [x] driver-answers-foldbatch-rejectbatch-through-transport-preservation (driver-answers-both-questions): the driver answers `foldBatch` and `rejectBatch` through the transport, with preservation proofs, corpus controls, check_model reconciliation, the translation table and every moved consumer.
- [x] story-language-says-multi-request-fold-multi (story-language-says-batch): the story language says a multi-request fold and a multi-request reject; validation, rendering and execution are total and the executor asks the batch question.

## Acceptance

Every requirement needs approved checkpoints at an ancestor of the pushed head and exact-head CI.
