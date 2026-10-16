# Exact cancellation approval precondition in accepted Lean

Additional source binding at f558d0e8fc916eef494fffcef09cfe2ac5582b8e:
`NamingLifecycleStatements.insert_attestation_alone_cannot_cancel` (line 43)
asserts `claimedOnce` cancellation fails with `withdraw-binding`.
`NamingLifecycle.withCancellationApproval` (line 452) executes the separate
`Model.step .mintWithdraw` transition; `cancellationPending` (line 462) adds that
distinct accepted withdrawal attestation while leaving the Insert attestation
separately present. The positive stored-refund theorem uses cancellationPending,
not claimedOnce. `Model.step .withdraw` requires recognized(cancellationAsset).

This sharpens the proposal's required model decision: permitting an Insert
approval alone to authorize cancellation would contradict that existing negative
statement, even after adding the missing refund/request commitment. The repair
must either represent the existing distinct withdrawal approval in the real
connected path or receive an explicit model change to remove that prerequisite.
The previous seven-field Insert-commitment proposal did not yet account for this
separate authorization predicate; do not approve it as a complete Lean refinement.

The physical application currently allows only one app-policy token in the claim
and one token name in the transaction's mint field. Its Cancel path consumes a
WithdrawApproval whose name is the refund; the real registration claim holds the
separate Insert hash. Therefore adding the modeled withdrawal attestation to that
real claim is not implemented by a generic retract or by the old LC01 fixture.
A real production bridge still needs the exact representation decision.

The devnet baseline attempts the existing Cancel over a real Insert claim plus
native Retract. Its refusal establishes the current route's limitation; it cannot
be called a contradiction of the insert-attestation-alone refusal theorem or
proof of a completed modeled approval sequence. The component mismatch remains
real, and the connected management story remains unimplemented.

Please carry this exact source-bound prerequisite into the pending operator/model
ruling alongside A-002's signer/authentication/stationary-claim questions. No
additional transition or new approval authority is implemented here.
