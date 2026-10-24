# Tasks for creating a registry and registering a key on the proved design

Issue 742. One group per slice of [the plan](plan.md#slices). A task is checked only after the ticket owner accepts its
slice.

## Binding

- [ ] lean-binding-rebound: the plan's Lean binding rebound to the aligned models landed on the epic branch, statement by statement.
- [ ] gate-synthesized: the ticket owner's and the auditor's gate tables synthesized once and frozen with both input hashes.

## State genesis

- [ ] genesis-and-recognition: the Singular state validator's genesis, recognition from the supplied seed and state output integrity, each statement with a check seen to fail.
- [ ] state-titles-declared: the new blueprint titles in the identity manifest and the declared-additions record; current hashes unmoved.

## State registration fold

- [ ] registration-fold: approval consumed for exactly the change, key absent, one token into the committed address and datum with at least the deposit, nothing else under the state policy; each statement with a check seen to fail.

## Preimage vectors

- [ ] preimage-vectors-shared: byte vectors for the approval preimage and the state token name, reproduced on-chain and off-chain, including a definite and an indefinite list and a byte string longer than 64 bytes.

## Open-datum approvals and configuration

- [ ] configuration-record: the configuration record at creation, immutable, read by reference.
- [ ] registration-approval: the approval mint committing its fields; the open burn.

## Open-datum pending registration

- [ ] three-phases: fold only before the deadline, refund-address reclaim of everything in the window, cleanup returning the deposit after it.
- [ ] fold-path-genuine-token: the fold path checks the genuine token reaches the new holding.

## Library create and fold

- [ ] genesis-builder: the genesis transaction against the new validator.
- [ ] registration-fold-builder: the registration fold transaction against the new validator.

## Open-datum builders

- [ ] request-builders: configuration create, book, reclaim and cleanup.

## Commands and documentation

- [ ] six-commands: the commands of the plan with help snapshots and parser rows.
- [ ] recovery-kept: cancellation and uncertain submission keep the transaction identity; nothing is resubmitted.
- [ ] command-reference: the user documentation of the commands with its speech.

## Devnet journey and refusals

- [ ] journey-job: a new hosted job runs create, book, fold, reclaim and cleanup through the packaged commands.
- [ ] refusals-on-devnet: the five refusals of the specification, each seen on the development network.
- [ ] creation-measured: transactions and locked ADA for a first and a later registry, as a receipt.

## Conformance old versus new

- [ ] old-versus-new-statement: folded, reclaimed and cleaned-up journeys, old against new, in requirement language, with the decided difference.
