# Q-001: bind the pending Insert refund without inventing a token format

As a registrant, I want to cancel my actual pending Insert claim/request and recover its committed refund, so that cancellation cannot redirect value or leave a request that can later activate my name.

Accepted source and Lean: f558d0e8fc916eef494fffcef09cfe2ac5582b8e (fresh origin/main; #106). Original report: fc2ad9e5987b171ca33a430f5bbe170ab6423fd5. The relevant definitions remain present unchanged in the refreshed source inspected here.

`lean/Singular/NamingLifecycle.lean:223` requires an Insert request and exact equality with `request.proposal.refundAddress`, then calls generic `.withdraw` with the request-specific cancellation asset. It removes the claim and preserves records. `offchain/journey/register/Main.hs:1167` separately mints a claim with `insertApprovalName(control, commitment)` and the four-field NamingDatum; `submitRegistryRequest` at line 1045 separately queues spelling -> representative via `requestInsertImpl`. The claim/token stores neither the refund nor a request/registry identity. `naming-onchain/validators/application.ak:328` compares the sole approval name with the presented refund and then decodes that name as an address. The Insert token is instead a 32-byte hash.

Consequently, the current claim alone cannot authenticate the request's stored refund or its exact association with this claim. Merely adding an arbitrary request input/reference and reading its refund would introduce an unproved association. Merely allowing the claim controller to choose the refund would change the existing committed-refund promise. Generic retraction alone leaves the naming claim alive. Prior WithdrawApproval contexts remain only component controls. Real devnet reproduction is being prepared; no ledger outcome claimed yet.

Decision requested from operator/model authority (through desk):

1. Retain the four-field naming datum and use the existing registry Insert proposal/refund commitment as the binding authority. Specify the exact claim/token-to-request binding, when that binding is established, and how cancellation consumes/disposes of the pending generic request under its existing lifecycle. This is the preferred direction because it preserves the existing Lean source of refund truth, but the current hash does not implement that binding.
2. Authorize a changed Insert approval commitment carrying the missing request/refund association, with the exact source-bound fields and authorization supplied in the ruling. This changes mint/fold/cancel representation and overlaps #110; do not infer a new hash preimage or constructor encoding from this question.
3. If the intended semantics instead require a different claim representation or additional approval step, specify that modeled transition and its authorization first; no fifth naming field or substitute WithdrawApproval fixture is chosen here.

Please also settle the connected cancellation disposition: does `.withdraw` map to consuming the exact generic request in the same transaction, or a prescribed sequence using the existing retract boundary? I will inspect and report the generic implementation boundary rather than assume immediate retraction is legal.

Shared-path coordination: #110/PR112 remains OPEN at d796fdabff43be7f74045f242754f6e9423aa58f. Overlap includes naming-onchain/validators/application.ak, application.tests.ak, script identities, offchain/naming/src/Naming/Register.hs, offchain/test/Naming/RegisterSpec.hs, offchain/journey/register/Main.hs and naming journey callers. #114's PR115 currently exposes its CLI contract; production cancellation API extraction will be coordinated through desk. No sibling files are being edited.

Held: affected representation/authorization implementation and acceptance. Continuing: issue/draft PR intake, source-bound probe in own runtime, isolated devnet failing reproduction and additive tests, interface handoff. No deposit choice, preprod write or deployment is requested. Owner %1194, worktree /code/singular-connected-cancellation, branch fix/connected-cancellation.
