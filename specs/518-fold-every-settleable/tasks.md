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

### receipt-readers

- [ ] conformance-controls-read-the-list-receipt
- [ ] recovery-and-control-scripts-read-the-list-receipt
- [ ] the-top-level-single-request-fields-are-removed

### docs-of-the-other-pages

- [ ] the-other-pages-state-the-list-receipt
- [ ] speech-restamped-and-narration-regenerated

## Pull request 3: many per fold

### builder-over-many

- [ ] build-over-several-chosen-requests
- [ ] validity-bound-follows-the-earliest-deadline

### journal-and-recovery-for-many

- [ ] journal-carries-chained-transitions
- [ ] an-earlier-line-reads-as-a-batch-of-one
- [ ] observe-every-key-against-its-last-transition
- [ ] rollback-returns-every-included-request
- [ ] lost-race-is-stale-state

### capacity-nine-and-the-command

- [ ] capacity-bound-of-nine-with-its-provenance
- [ ] registry-fold-takes-the-whole-selection

### devnet-two-actors-and-interruption

- [ ] two-actors-book-concurrently-and-one-fold-settles-both
- [ ] an-interrupted-two-request-fold-reconciles-both

### docs-of-many-per-fold

- [ ] pages-state-the-whole-behaviour-and-its-limits
- [ ] speech-restamped
