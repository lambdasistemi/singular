# A-006 — implement the rejected-fold refinement candidate

This is a milestone-owner arbitration within the existing M1 outcome, not a new stakeholder ruling, epic or feature. E18 owns delivery through its existing worker. A001, A002 and the complete E17/E18 acceptance requirements remain binding.

Root read the restored R2 packet in full. The reviewed frozen file is `handoffs/r2-root-restored-revision-observed.md`, SHA-256 `ff648663fed46dc19dd0181a97b8018de8a5c78545c85fc407716aa7e870b719`, 26,124 bytes. Its sections 0–8 are present; the remaining quoted historical truncation marker in section 8 describes the old incident and is not a missing tail. This distinguishes the restored proposal from the genuinely truncated file in NOTE-127.

## Authorized next work

Implement and execute the per-item processed/rejected transition and its refinement candidate in the existing owned `blaster/abstract/` area, with its necessary owned evidence/check integration. This replaces another prose-only proposal round. Keep the accepted `lean/` model, production validators, consumer implementation and shared coverage schema unchanged during this candidate stage. There is no new worker, ticket, ledger campaign, release or final producer migration grant.

The candidate is a proposed conservative extension/refinement of the agreed behavior. It is not adopted merely because it builds. E18 returns the executable rules, exact domain, affected statement map, discriminating results and remaining proof/implementation obligations to root before any accepted shared model changes.

## Required behavior and relation

1. Processed items retain the existing `foldOne` effects and sequential order. Rejected items refer to the same present request id, remove that consumed request, contribute no logical update, and preserve the rejected entry. Keep ids consumed, request-id reuse forbidden, and all unaffected state components accounted for. An empty batch and missing/duplicate/unmatched items must not be made valid by the mapping. Legitimate nonempty all-rejected, mixed and zero-net batches remain required.

2. Timing and consumer permission must be explicit and correctly associated with each item/batch and the real context. Preserve both correspondence directions and actual post-state/result correspondence. Do not replace the required correspondence with two independent green endpoints, or reduce the backward direction to one unrelated existential example. State all remaining realizability, proof and concrete-context obligations honestly.

3. The packet's request-only `held = none` case can be an initial implementation slice, but is not full R2 closure. Required retirement cases must retain separately established custody and the pending name even when the concrete request is consumed/refunded. Do not permanently exclude legitimate held-custody cases, erase a held representative, restore the application record, free a naming key, or invent a signature requirement. Represent and check the request/custody association explicitly. If the original model cannot represent the surviving custody after request removal, make the smallest additional state/relationship explicit in the candidate and its invariant obligations; do not hide that extension in a ghost assertion. No new on-ledger rejection output, indexer or service is authorized.

4. Rejected-processing refund recipients come from the actual current request-owner/funding relation. The existing proposal's `refundAddress` describes the distinct committed withdrawal/cancellation obligation; do not assume the two recipients are equal without evidence. Preserve the actual per-owner input-minus-tip floors, visible fees/top-ups and conservation as separately bound observable obligations. Request identities must bind the recipient/value metadata used by the relation; caller-provided expected amounts are not evidence of allocation correctness.

5. The current E17 `consumer()` is the bounded producer/naming consumer. It does not replace the bound `14a64a4` cardano-keri consumer or E18's real `Plugin.registry` adapter/compositor. A generic refinement may name its consumer contract parametrically, but each claimed application instantiation must identify and verify its actual program and operation predicates. Keep naming current-context evidence, actual KERI registration evidence and final-tuple evidence distinct. The KERI outcome remains mandatory.

6. The packet's D4 must concern the actual separate naming custody layout, not require manufacturing the already-disproved assumption that the representative sits directly in the generic request output. Existing root controls establish no named-retirement escape and no final ledger result. Preserve them with their scope, and continue the actual connected custody/retirement/burn-policy obligations.

## Next reviewable result

Return the executable candidate and commands/results showing the real distinction between all-rejected and mixed effects, same-id request removal and no replay, supported processed behavior, timing/refund/consumer refusal controls, and separately retained custody for the required domain. Include at least one control that fails when rejected consumption is erased or its result is falsely mapped to successful processing. A pure `consume` illustration or another list of equations is not the next deliverable. Prove the conservative relationship and required lemmas where available; finite controls remain finite evidence and cannot discharge the full quantified #87 obligations.

The independently accepted register-checker repair and the C5 shared-context correction stay independently reviewable and must not be repeatedly rerun for an unchanged packet. No current result grants full invariant credit, epic acceptance or release. Stop the milestone only after both E17 and E18 are fully accepted under A005.
