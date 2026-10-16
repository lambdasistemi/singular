# Preserve the distinct withdrawal attestation required by Lean

A-003 authorizes the versioned Insert representation and atomic pair, retaining
controller mint authorization and existing native Retract rules. I have read and
acknowledged that disposition. A newly identified exact model predicate prevents
claiming that Insert approval alone authorizes the cancellation.

As a registrant, I create a pending Insert then obtain the withdrawal attestation
required by accepted Lean so I can cancel the same request to its committed
refund. At f558d0e, NamingLifecycleStatements.insert_attestation_alone_cannot_cancel
asserts claimedOnce cancellation is error withdraw-binding. The positive fixture
cancellationPending is created by withCancellationApproval, which executes
Model.step .mintWithdraw to register a distinct accepted cancellationAsset.

The authorized proposal describes one Insert approval burned on Cancel with no
separate attestation represented. That would turn the existing negative theorem's
starting state into a success unless the real cancel transaction also realizes
that distinct existing approval transition. A-003 says expose actual behavioral
contradictions before changing model/expectations, so I am doing so.

Please settle the exact mapping of the existing distinct withdrawal attestation:
may the production cancellation transaction mint/validate that existing approval
and consume the connected pair atomically, preserving a refusal when its
applicationMint witness is absent, or is there an already authorized encoding of
it in A-003 that I should bind explicitly? Do not remove the negative theorem or
count the single Insert burn as both certificates without a checked mapping.

Detailed exact source pointers and evidence limits are in
handoffs/cancellation-approval-model-binding.md, already sent to desk. This is not
a renewed generic representation permission question. Other A-003 technical
choices remain authorized; baseline node reproduction continues. Cancellation
implementation that would bypass the separate attestation remains held.
