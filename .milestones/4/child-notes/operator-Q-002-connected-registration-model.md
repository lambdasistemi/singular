# Operator model choice: atomic connected registration

Recommendation from #117: one registration transaction creates the naming claim and its exact pending Insert request and fixes the full refund address. Cancellation consumes that pair together during the existing request-owner retraction window. This replaces the current two-transaction registration representation. Existing pending claims do not gain this binding retroactively; no migration or deployment is authorized here.

Operator question: should registration create both the claim and request together in one transaction, fixing the refund address at that point?

Source: connected-cancellation/handoffs/refund-binding-proposal.md, read in full and acknowledged POINTER-1789399816-3342824. Lean at f558d0e models a claim/request identity and proposal.refundAddress but does not specify the wire binding or atomic registration. Repository AGENTS.md requires user escalation for underspecified modeled behavior. The operator's committed refund-address choice is preserved, not reopened.

Technical details remain subject to source-bound completion in connected-cancellation/answers/A-002-refund-binding-proposal-review.md: genuine native-request credential authentication, signer requirements versus mere funding, pending-claim movement and compatibility. Agreement on the product choice is not a blanket approval for the unfinished seven-field commitment or a new deployment parameter. A separate deposit-model lock-point question also remains pending; this question does not settle economics.

## Disposition after the source-bound refinement

WITHDRAWN as an unnecessary approval question, not answered by assumption. See connected-cancellation/answers/A-003-refinement-disposition.md. The constitution explicitly permits checked technical refinements and correction of clear code/model mismatches. Removing the proposed new request-owner creation signer preserves authorization; fixed native-request hash implements config.requestAddress; atomic pair/immutable refund implements the existing identity/refund association; Active-only maintenance/recovery implements namingRecord custody. No economic decision or existing-deployment migration is inferred. The separate deposit lock-point question remains open.
