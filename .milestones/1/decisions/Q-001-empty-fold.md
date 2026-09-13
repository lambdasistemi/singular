# Current status: narrow story approved; starvation concern recorded

Updated 2026-09-12T18:12:51.141Z. The stakeholder answered **yes** to rejecting empty processing attempts, then observed that a malicious SPO can feed and starve anyway. [The exact ruling and scope](../answers/A-001-empty-batch-refusal-and-starvation-limit.md) supersede the pending status below. Lean-first repair is authorized; starvation protection is not established.

---

# Historical question (preserved unchanged)

# Empty fold: one genuine M1 contract conflict

Created 2026-09-12T17:24:28.653Z. Asked through the asynchronous user question tool during this goal turn; NO answer has arrived.

As a cardano-keri integrator I want Singular's accepted transition contract and the consumer's required fold behavior to agree, so that consumer conformance is real.

Given a valid registry state, items=[], representative mint=[], actionNet=[], nativeSpend=true, and all other required transition conditions satisfied, Singular's accepted fold_iff and Model.step accept the fold as a no-op. The bound cardano-keri R8_empty_fold_refused requirement expects refusal. Source packet: ../epic-18/handoffs/decision-packet-2026-09-12.md revision2; original cross-model question ../epic-18/questions/Q-002-lean-authority-two-user-stories.md.

User decision requested: retain the permitted no-op and reconcile the consumer requirement, or require refusal and explicitly revise the Lean contract before implementation. Either route must reconcile both contracts before M1 completion. No response, timeout, default option or general completion instruction selects an answer.

This is a semantic decision, not permission to waive the row. Code-the-design requires an explicit operator ruling before changing a modeled transition/theorem. CG19 refund routing was separately reclassified as a concrete refinement obligation; CG12's concrete-to-model mapping and the canonical enforcing boundary still need evidence, not blanket user decisions or accepted divergence.

Independent #77 acceptance/repair, #80e execution coverage and #87b compiled refinement continue under their current contracts.
