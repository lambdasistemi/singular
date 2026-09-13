# Operator ruling: the registry has no owner whatsoever

The operator clarified: "we agree that the registry has no owner whatsoever, not only that it doesn't count".

This is authoritative: Singular has no registry-owner role, including latent ownership, ownership transfer, owner-authorized registry termination, or owner-authorized registry migration. Do not reduce this to omitting a signature during Modify. Preserve legitimate application/name controllers, request authority and refund destinations; those are separate domains.

Root inspected pinned lean/Singular/Model.lean at 13231f58833b8feb57f4b0f9b1117bfcfba0c07d in full: Config, State, Witnesses and Action contain no registry-owner role and Action has no registry End or migration transition. Statements.fold_iff contains no owner requirement. Absence of a modeled transition is not permission to invent an owner-authorized production extension.

Root also read current onchain/validators/state.ak in /code/singular-e18-cg: End calls validateOwnership then burns the registry token; validateMigration calls validateOwnership on predecessor state. These inherited paths are outstanding conformance defects under the explicit ruling. Root's earlier statement that End retains ownership described copied implementation and wrongly allowed that to stand as design authority.

Act through the existing team, no new auditors:
- ACK this ruling durably and update your worker mandates before accepting affected work.
- Inventory actual registry ownership fields, initialization arguments, transfer/End/migration entry points, SDK/CLI terminology, docs and test expectations. Bind all to their intended Lean refinement; report the concrete affected scope.
- Stop crediting owner-transfer or old-owner/new-owner End tests as required Singular behavior. Preserve their historical observations, mark their expected semantics superseded by this ruling; do not delete debt or relabel old results as conformance.
- Prepare the bounded repair and meaningful real-code plus ledger-boundary stories. Given an existing registry, When its creator or another actor claims registry-owner authority to terminate or transfer control, Then no such privilege exists. Valid operations obey the actual frozen contract regardless of creator identity.
- Do NOT simply remove validateOwnership from End/migration and make destructive operations permissionless. Do not invent replacement lifecycle semantics or modify Lean to justify the copied code. If a lifecycle/refinement choice remains genuinely ambiguous, escalate its exact clauses with a concrete Given/When/Then and recommendation. The absence of registry ownership itself is settled.
- Continue independent conformant work; do not merge or release affected paths as conformant until repaired and verified.

Epic17 owns the validator/lifecycle repair and reports the inventory and connected-state consequences. Epic18 owns consumer expectations, coverage/debt and release acceptance; coordinate through owners to avoid concurrent edits to the validator.

