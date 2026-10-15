# Tasks

One group per slice, grouped by pull request. A task is checked when its slice's candidate gate is green at the slice head and its checkpoint is approved. Read the [plan](plan.md) for the slices and the [touch list](touch-list.md) for the files.

## Pull request 1: the model refuses what a batch creates and consumes

### batch-statements-first

- [x] batch-statements-red: an insertion then a termination of one key refused `token-missing`; a termination of a holding that existed before the batch accepted; an accepted batch burning only live holdings; independent requests folding as a batch; each committed failing

### created-holdings-in-foldBatch

- [x] track-the-holdings-a-batch-has-created
- [x] refuse-a-termination-of-a-created-holding-after-the-mint-check
- [x] repair-the-batch-proofs-and-restate-fold-batch-cons
- [x] reselect-the-permanent-contract-accepted-batch-on-two-keys

### consumers-follow-the-batch-rule

- [x] rows-for-every-same-key-pair
- [x] corpora-regenerated-in-two-passes
- [x] simulator-mirror-rules-and-gate
- [x] coverage-record-and-fixed-counts
- [x] open-datum-application-proofs-repaired
- [x] register-readme-counts-and-narration
- [x] constitution-amendment-for-the-batch-rule

## Pull request 2: the model admits a fold only inside its window

### admission-statements-first

- [x] admission-statements-red: the boundary, any expired request, each request by its own submission time, admission before the law, a reject reading no time; each committed failing

### fold-admission-in-the-model

- [x] request-carries-its-submission-time
- [x] fold-witness-and-window-predicate
- [x] fold-admission-and-the-fold-arm-of-exit-admission
- [x] batch-under-a-witness
- [x] permanent-contract-statements-follow-the-admission-order

### driver-and-corpora-under-a-witness

- [x] every-fold-scenario-and-batch-carries-a-witness
- [x] a-fold-without-a-witness-is-unsupported
- [x] rows-for-the-boundary-an-expired-request-and-a-batch-in-and-past-its-window
- [x] corpora-regenerated-in-two-passes

### transport-live-driver-simulator

- [x] transport-reads-the-submission-time-and-the-fold-witness
- [x] live-driver-reads-the-bound-off-the-built-transaction-and-the-time-off-the-datum
- [x] simulator-schema-actions-rules-gate-and-playable-fold
- [x] simulator-mirror-regenerated

### register-book-constitution

- [x] coverage-record-and-fixed-counts
- [x] register-readme-counts-and-narration
- [x] conformance-book-no-longer-calls-the-window-a-discrepancy
- [x] constitution-amendment-for-the-fold-admission

## Pull request 3: the builder enforces it and the receipt names it

### admission-in-the-library

- [x] admission-red-tests: the boundary, many requests, the first offender named, the within-batch pair, the agreement with the model at the boundary and one past with its failing control
- [x] pure-fold-admission
- [x] pure-batch-consumes-created
- [x] library-agrees-with-the-model-question

### builder-refuses-before-signing

- [x] builder-refuses-a-bound-past-a-deadline-reading-the-built-body
- [x] builder-refuses-a-termination-of-a-key-an-earlier-insertion-creates
- [x] connected-fold-refuses-the-same-way

### selection-and-receipt-in-the-models-words

- [x] selection-window-rule-is-the-model-admission-at-the-probe-bound
- [x] delete-window-closed-from-code-readers-scripts-and-pages
- [x] post-build-decision-calls-the-library
- [x] receipt-names-the-request-reason-source-deadline-and-probe-bound

### devnet-expired-request-named-by-the-model

- [x] the-expired-request-is-named-not-phase1-by-the-model-beside-a-settled-in-window-request-on-a-devnet

### docs-of-what-ships

- [x] pages-state-the-window-rule-the-vocabularies-and-the-residuals
- [x] speech-restamped-and-narration-regenerated

## Pull request 4: the compiled validator is shown to refuse the mutated transaction

### validator-window-and-same-key-tests

- [ ] window-boundary-under-an-excluded-upper-bound-with-its-twin
- [ ] different-submission-times-an-open-bound-and-an-expired-reject
- [ ] reason-precedence
- [ ] the-four-same-key-pairs-with-their-reasons

### compiled-contexts-and-fault-control

- [ ] export-the-new-labelled-contexts
- [ ] checker-evaluates-them-against-the-compiled-bytes
- [ ] the-always-accept-program-fails-the-new-labels
- [ ] label-counts-derived-from-the-discovered-set

### live-fold-window-row

- [ ] a-fold-past-a-deadline-is-refused-by-the-ledger-and-answered-not-phase1-by-the-model

### book-and-docs

- [ ] book-and-pages-follow-and-narration-regenerated
