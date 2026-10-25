# Tasks for creating a registry and registering a key on the proved design

Issue 742. Grouped by pull request and slice of [the plan](plan.md#pull-requests-and-slices). A task is checked only after
the ticket owner accepts its slice.

## Binding

- [x] lean-binding-rebound: the plan's Lean binding rebound to the aligned models landed on the epic branch, statement by statement.
- [x] gate-synthesized: the ticket owner's and the auditor's gate tables synthesized once and frozen with both input hashes.

## Pull request 1: state genesis

- [x] genesis-and-recognition: genesis, recognition from the supplied seed and state output integrity, each statement with a check seen to fail.
- [x] state-titles-declared: the new blueprint titles in the identity manifest and the declared-additions record; current hashes unmoved.

## Pull request 1: state registration fold

- [ ] registration-fold: approval consumed for exactly the change, key absent, one token into the committed address and datum with at least the deposit, nothing else under the state policy; each statement with a check seen to fail.

## Pull request 1: preimage vectors

- [x] preimage-vectors-shared: byte vectors for the state, active and registration-approval preimages, reproduced on-chain and off-chain, including a definite and an indefinite list and a byte string longer than 64 bytes.

## Pull request 2: approvals and configuration

- [ ] configuration-record: the configuration record at creation, immutable, read by reference.
- [ ] registration-approval: the approval mint committing its fields; the open burn.

## Pull request 2: pending registration

- [ ] three-phases: fold only before the deadline, refund-address reclaim of everything in the window, cleanup returning the deposit after it.
- [ ] fold-path-genuine-token: the fold path checks the genuine token reaches the new holding.

## Pull request 3: library create and fold

- [ ] genesis-builder: the genesis transaction against the new validator.
- [ ] registration-fold-builder: the registration fold transaction against the new validator, from chain data alone.
- [ ] scripts-published-once: publication of both reference scripts when no live copy exists, reuse otherwise, and the control that a reference script with another hash is not reused.

## Pull request 3: open-datum builders

- [ ] request-builders: configuration create, book, reclaim and cleanup.

## Pull request 3: commands and documentation

- [ ] six-commands: the commands of the plan with help snapshots and parser rows.
- [ ] recovery-kept: cancellation and uncertain submission keep the transaction identity; nothing is resubmitted.
- [ ] command-reference: the user documentation of the commands with its speech.

## Pull request 4: devnet journey and refusals

- [ ] journey-job: the hosted job `no-pin-registration-journey` runs create, book, fold, reclaim and cleanup through the packaged commands.
- [ ] fold-by-a-second-wallet: the journey's fold is built and signed by a wallet other than the booker's, from chain data only.
- [ ] refusals-on-devnet: the hosted job `no-pin-registration-refusals` shows the five refusals of the specification, each with its control.
- [ ] creation-measured: transactions and locked ADA for a first and a later registry, as a receipt; the later one publishes no script.

## Pull request 4: conformance old versus new

- [ ] old-versus-new-statement: folded, reclaimed and cleaned-up journeys, old against new, in requirement language, with the decided difference.
