# Tasks for updating a holding and terminating its key on the proved design

Issue 743. Grouped by pull request and slice of [the plan](plan.md#pull-requests-and-slices). A task is checked only after
the ticket owner accepts its slice.

## Binding

- [x] gate-synthesized: the ticket owner's and the auditor's gate tables synthesized once and frozen with both input hashes.
- [x] removal-decisions-ruled: each removal decision of the plan ruled, and pull request 4's gate rows written.

## Pull request 1: Singular

- [x] termination-preimage-vectors: byte vectors for the termination approval preimage, reproduced on-chain and off-chain.
- [x] termination-fold: the termination change and mixed batches; each statement with a check seen to fail.
- [x] supply-and-history: the four history statements over generated accepted sequences, and the refused registration of a terminal key.

## Pull request 1: open datum

- [x] holding-update: the controller-signed update keeping control, tokens and deposit.
- [x] termination-booking: the approval mint, the request shape, the treasury donation equal to the deposit.
- [x] termination-request: spent only with its token and approval burned, by anyone; no stuck termination.

## Pull request 2: builders and commands

- [x] update-and-booking-builders: update and termination booking transactions.
- [x] termination-fold-builder: the shared fold builder over termination requests, from chain data alone.
- [x] commands-and-documentation: the commands with help snapshots, parser rows, recovery partitions and the command reference.

## Pull request 3: journey and conformance

- [x] devnet-journey-continuation: update, booking with the deposit at the treasury, the fold by a second wallet, the refused re-registration.
- [x] devnet-termination-refusals: the four refusals, each with its control.
- [x] conformance-old-versus-new: the update and termination journeys old against new, with the two decided differences.

## Pull request 4: the current line removed

- [ ] current-line-removal: the current line's validators, builders, commands, hosted jobs and Lean models removed as ruled.
- [ ] established-names: the new commands on the established names.
- [ ] documentation-follows: the user documentation describes only the new line.
