# Deliver measurable recovery coverage

As a maintainer, I want delivery stamps tied to real checks and approved commits, so partial offline coverage cannot close the whole CI story.

## Offline recovery

The first slice adds composed recovery tests and proves each failure mode detects a relevant defect. Its fixtures disclose provenance and its test registration rejects empty selection.

- [ ] recorded-recovery-boundary: record fixture provenance and execute the production reconciliation composition.
- [ ] synthetic-saved-reconciliation-public-history: label synthetic fixture provenance, execute saved-registry reconciliation and keyed observation, and show missing or empty history turns it red; recorded saved-registry coverage remains uncovered.
- [ ] lost-acknowledgement-offline: observe an included uncertain transaction once without resend, with a real fault control.
- [ ] interrupted-confirmation-offline: reconcile durable confirmation before observation, preserving original evidence and detecting a controlled fault.
- [ ] expiry-offline: distinguish bounded live-input exclusion from unbounded and undetermined evidence, with a real fault control.
- [ ] rollback-offline: observe rollback from positive live-input evidence once, preserve the unresolved identity and block resend, with a real fault control.
- [ ] recovery-selection-and-receipts: register tagged tests, prove executed extent and retain RED/GREEN command receipts plus every checkpoint approval.

## Offline evidence mutations

The next slice receives its own gate and function bindings before dispatch. Its checks are over recorded evidence and do not remove a serial predecessor yet.

- [ ] recorded-evidence-mutations: original evidence passes and altered evidence is rejected by the corresponding clause, with nonempty discovered extent.

## Parallel hosted carriers

The final slice remains held for the sibling merges and accepted job mapping. Every replacement carries its successor and ran-proof in the same diff; no offline receipt implies ledger acceptance.

- [ ] successor-selection-and-ran-proof: map every removed serial scenario to a successor proven to execute.
- [ ] parallel-edge-smokes: independently selectable jobs add one node per edge without extending existing executions; every selected recovery part runs alone, with a cross-part dependency control.
- [ ] bounded-sequential-journey: retain one connected story and establish the accepted six-minute execution budget per node part.
- [ ] exact-head-hosted-acceptance: preserve sibling parts, union receipts, verify all checkpoints and hosted checks, and merge through merge-guard.

## Completion limits

Only the ticket owner stamps a task after evidence-bound acceptance. An offline-slice PR leaves the final-slice tasks open and does not close the issue. Missing evidence and unresolved requirements remain visible.
