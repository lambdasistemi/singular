# Tasks

One group per slice, grouped by pull request (the cut of 2026-10-11: pull request 1, then the readers and pages as pull request 2, then many per fold as pull request 3). A task is checked when its slice's candidate gate is green at the slice head and its checkpoint is approved. Read the [plan](plan.md) for the slices and the [touch list](touch-list.md) for the files.

## Pull request 1: each request judged alone, one settled per fold

### selection-in-the-library

- [x] selection-red-tests: the four-request example at several bounds, independence of other keys with a failing control, one per key, the vocabularies, the capacity prefix, the model-agreement check with its same-key control
- [x] judge-each-request-alone
- [x] one-request-per-key
- [x] two-vocabularies-in-the-exclusions
- [x] capacity-bound-as-an-argument
- [x] selection-agrees-with-the-model-batch

### fold-the-first-selected

- [ ] builder-over-one-chosen-request (run: builder)
- [ ] a-chosen-request-that-is-not-pending-is-refused-at-every-pending-size (run: builder)
- [ ] named-request-guard-and-nothing-to-fold (run: command-line rules)
- [ ] spend-check-states-the-state-and-every-selected-request-and-no-other-pending-request (run: command-line rules)
- [ ] mismatched-selection-and-pairing-is-refused-never-dropped (run: command-line rules)
- [ ] registry-fold-takes-the-first-included-request (run: fold routine and entry)
- [ ] a-built-fold-that-spends-another-pending-request-is-refused-before-signing (run: fold routine and entry)
- [ ] a-termination-under-the-neutral-value-is-excluded-application-required (run: fold routine and entry)
- [ ] combined-forms-take-the-same-selection (run: fold routine and entry)
- [ ] receipt-lists-settled-and-excluded-beside-the-earlier-fields (run: fold routine and entry)
- [ ] delete-the-one-pending-rule (run: fold routine and entry)
- [ ] no-existing-reader-breaks-or-its-minimal-fix-is-named (run: fold routine and entry)

### devnet-unsettleable-left-and-named

- [ ] an-unsettleable-request-is-left-and-named-while-an-eligible-one-settles

### docs-of-what-ships-first

- [ ] the-registry-fold-page-states-this-pull-request-and-its-limits
- [ ] that-page-narration-regenerated-and-speech-restamped

## Pull request 2: the receipt readers and the other pages

### readers-move-to-the-list

- [x] conformance-controls-and-fixtures-read-the-settled-list
- [x] journey-script-and-command-run-specs-read-the-settled-list
- [x] two-actor-journey-and-its-status-test-read-the-settled-list

### duplicates-removed

- [x] fold-receipt-no-longer-prints-the-single-request-fields
- [x] combined-forms-no-longer-print-the-fold-derived-duplicates
- [x] receipt-rows-pin-the-absence-and-the-list

### docs-of-the-other-pages

The cut point of this pull request: if the forecast passes the allowance, the preprod page, the fold responsibilities page and the rehearsal document leave for a docs-only pull request; the node guide sentence stays.

- [x] the-node-guide-states-the-list-receipt-and-the-removal
- [ ] the-other-pages-state-the-list-receipt
- [x] speech-restamped-and-narration-regenerated

## Pull request 3a: the fold over several requests, the journal listing every transition

The bound stays 1. Re-derived on 2026-10-13 against `main` at `e7b55ac9` and rebased onto main `af16bad4`; the runs are named in the [plan](plan.md).

### journal-carries-the-transitions

- [ ] journal-line-carries-the-chained-transitions
- [ ] the-expectation-carries-the-transitions
- [ ] scalar-fields-mirror-the-first-and-last-transition
- [ ] a-journal-line-written-by-main-still-decodes

### fold-over-several-requests

- [ ] builder-spends-exactly-two-and-three-chosen-requests (run: builder)
- [ ] validity-bound-follows-the-earliest-deadline-not-the-first (run: builder)
- [ ] fold-result-lists-its-settled-requests (run: fold routine)
- [ ] roots-between-transitions-come-from-a-walk-per-prefix (run: fold routine)
- [ ] one-delivery-readback-per-settled-request (run: fold routine)
- [ ] application-context-covers-every-release (run: fold routine)
- [ ] combined-forms-and-the-keri-stub-read-their-own-settled-entry (run: fold routine)
- [ ] receipt-lists-each-settled-request (run: fold routine)
- [ ] a-lost-race-over-several-requests-is-stale-state (run: fold routine)
- [ ] the-bound-is-an-argument-of-the-fold-routine-for-tests (run: fold routine)

### docs-of-the-reason-for-the-bound

- [ ] provenance-of-bound-one-states-the-recovery-reason
- [ ] node-guide-sentence-matches-it-narration-regenerated-speech-restamped

## Pull request 3b: recovery of many, bound 9, executed evidence

### reconcile-reads-every-transition

- [ ] an-earlier-line-reads-as-a-batch-of-one
- [ ] observe-each-key-against-its-last-transition
- [ ] the-state-output-carries-the-last-root-after
- [ ] rollback-names-every-request-and-restores-the-first-root-before
- [ ] scalar-and-list-disagreement-is-not-observed

### capacity-nine

- [ ] bound-of-nine-with-its-provenance
- [ ] journey-assertions-of-the-bound-move-to-nine
- [ ] a-termination-that-is-not-first-settles-and-pays-its-holding
- [ ] a-regression-passing-only-the-first-holding-fails-a-row
- [ ] every-reader-of-the-settled-list-finds-its-request-or-has-one-pending-by-construction

### devnet-two-actors-one-fold

- [ ] two-actors-book-concurrently-and-one-fold-settles-both-each-payout-to-its-owner
- [ ] tampered-receipts-of-the-two-request-fold-are-refused

### devnet-interrupted-two-request-fold

- [ ] an-interrupted-two-request-fold-reconciles-both-keys-once
- [ ] the-part-is-hosted-by-the-partition-list

### docs-of-many-per-fold

- [ ] pages-state-the-bound-the-whole-behaviour-and-its-limits
- [ ] speech-restamped-and-narration-regenerated
