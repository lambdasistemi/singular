# Q-001: When does a registration deposit become locked?

Decision requested from the M4 desk, escalating to the operator if needed. NOTE-001 model-only scope applies; no issue or PR has been filed and no model or production behavior has been edited.

As a registrant whose queued name request is cancelled or loses to another claim, I want to know whether I have already locked the registration deposit, so that cancellation does not strand capital or create an unauthorized refund before Over.

## Live source evidence

Baseline: `fc2ad9e5987b171ca33a430f5bbe170ab6423fd5`, fetched origin/main, worktree `/code/singular-naming-deposit`, branch `feat/naming-deposit`.

- `lean/Singular/Naming.lean`: `namingQueue` accepts two pending claims for `alice`; `claimedTwice` contains request IDs 1 and 2. `namingFoldRequest claimedTwice 1` produces `activeOnce`; folding request 2 then refuses `occupied-key`. Approval/queueing does not register or reserve a name.
- `namingQueueAction` commits `Proposal.initial.value = demoValue` and `Proposal.refundAddress = demoRefundAddress` in the Insert. These are explicitly generic demo fixtures, not economics. The model has no separately represented pending cash balance.
- `lean/Singular/NamingLifecycle.lean`: `cancelNamingClaim` accepts only Insert cancellation to `request.proposal.refundAddress`; `cancellationRefund` explicitly fixes value to zero because economics were outside the previous ruling. Cancellation removes the pending claim and request. It does not set that claim's name to Over.
- `retirementRequest` currently sets refundAddress to 0; `beginRetirement` removes the naming record and moves custody to an Update request; `finishRetirement` folds that request to Over. A losing pending Insert never owns that lifecycle.
- `lean/Singular/Model.lean`: `foldOne` requires an absent entry for Insert and sets Active; Update sets Over. Its `Output.value` is abstract, with no minimum-UTxO or fee accounting.

These are inspected definitions and existing executable fixture traces, not a fresh execution receipt or a ledger claim.

## Competing readings

1. **Lock at successful registration (recommended):** queueing commits the eventual refund address and required deposit but does not yet lock the registration deposit. The successful Insert fold requires the configured amount and locks it. A losing/cancelled pending request has no registration deposit to release, preserving cancellation without an early-refund exception. Implement as a model distinction between a pending commitment and a funded successful registration; do not pretend generic demoValue is the deposit.
2. **Fund/lock at queueing:** a cancelled or losing request already holds the deposit. Returning it needs an explicit pre-registration cancellation exception to "only at Over"; retaining it strands a deposit without the registrant owning a path to Over. Please specify the intended treatment if this reading is chosen.

Please settle the lock point and treatment of cancelled/losing pending claims. This changes observable economics, so I will not choose it as an encoding detail.

Minimum-UTxO accounting does not need a second economic ruling for this model-only ticket: model the configured deposit separately from network-required ADA and state that fees/minimum-UTxO top-ups remain outside this abstract model. No economic default will be introduced.

## Unaffected work

Source inspection, isolated-worktree preparation, duplicate search, command mapping, issue proposal and interface handoff can proceed. Those records are being completed. Actual deposit transitions and a frozen issue acceptance depend on this answer. #104, #107 and naming-cli remain independent; no requests to sibling owners are needed.
