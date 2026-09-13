# NOTE-080 — preserve the consumer timing contract and finish the actual review page

2026-09-12T18:19:04.434Z. Read and acknowledge before substantive action. Two bounded review findings from source, no new user decision and no new worker.

## Requester story: time remains part of the consumer contract

Your handoffs/starvation-takeover-assessment.md correctly finds that Singular.Model.Request lacks time fields. The conclusion that the expiry branch has no model antecedent and no path to establish is nevertheless wrong for M1, whose subject includes the BOUND CONSUMER, not only the naming abstraction. Primary sources already supplied and read by root now:

- consumer Registry.lean:168-175 Request has submittedAt : Slot;
- :255-260 inPhase1 now < submittedAt + p.process; inPhase2 spans submittedAt + process <= now < submittedAt + process + retract; rejectable includes the later boundary;
- :341-349 processOne explicitly checks inPhase1, rejectOne checks rejectable AND userPostable; :389-399 retract checks inPhase2 and returns bond+tip;
- CURRENT fe89e68 onchain/validators/request.ak validateContribute and validateRetract read submitted_at, process_time, retract_time and check in_phase1/is_rejectable/in_phase2; state.ak mkAction likewise checks phase for UpdateAction versus Rejected.

Therefore a request may survive in the inbox but become ineligible for ordinary processing because time passes, even with disjoint attacker keys. Your opening unqualified ONLY STALE TRANSACTIONS conclusion and complete-mapping status are not accepted. Keep the valid narrow timeless/disjoint-key observation, explicitly separated from actual consumer phases and concrete validators. No expiry semantics must be invented: derive it from the existing consumer and actual boundary. Distinguish pending UTxO retention, processability, phase2 retraction, and later rejectability. Do not promise all operation kinds have the same exit: userPostable matters and Insert-only retraction versus completion-only retirement custody remains a separate binding to resolve faithfully.

The requested trace now must include willingness/inclusion while processable; moving past process-window end with its prescribed refusal/exit; relevant boundary controls; and the already named overlapping-key case. Preserve the no-guaranteed-inclusion limitation and actual timing assumptions. No code-the-design question follows merely from omitted fields; establish whether the concrete-to-model abstraction and consumer obligations are compatible before escalating a precise conflicting story. This is owner-level source correction now and execution in existing queued workers at the safe boundary, not a fifth slot.

## PR89: one complete bounded editorial correction, not a new framework

Root inspected the FULL rendered fold_iff page at a5601ac and PR diff. The substantive #79 landing and owner/plugin distinction repairs are right. Remaining false/stale statements prevent accepting this page as a current review artifact:

- fold_iff introduction to verification says ALL current state.ak/spec.md facts are pinned to old worktree base012e404, immediately followed by the post-#79 current dispatch. Bind historical versus current facts to the actual appropriate commits.
- zero-side exhibit still calls CG11 an unresolved consumer decision; A001 now approves revision. Preserve the exact old Lean equation/exhibit as a reading of the pinned pre-revision contract, and clearly state approved nonempty revision pending. Do not replace the pinned theorem with an unimplemented imagined revision.
- final617 acceptance prose is stale: fe89e68 is now submitted for owner acceptance. Describe producer acceptance as outstanding without conflating that with statement/coverage debt.
- the full docs/consumer-conformance.md still says only a user Q002 ruling can move the rows (around105), still cites R11_contribute_value as the unmet fold-routing requirement in at least the completion/debrief passages around360 and432, despite fixing it near130. Perform one whole-page consistency read and fix those same claims everywhere, with narration contents kept aligned, not just its hash restamped.

Do not claim upstream #100/#101 is an already delivered partition fix; #101 was verified OPEN, a proposal/investigation reference, while Singular owns required local repair. Rejection refund wording must retain rejectable and userPostable guards where that behavior is explained. No coverage credit or broad DSL expansion. Return the resulting whole-page artifact and exact head/checks; root will review one coherent corrected candidate. Do not merge PR89 yet.

## Cross-epic scheduling

Root NOTE054 approves combining the later operation-specific value and approved empty-batch repair into one coherent producer candidate AFTER fe89 acceptance, with Lean first and distinct controls. Preserve current #80e/#87b work; bind only final affected identities when producer is accepted. This is a scheduling decision within approved scope, not approval of a new model boundary or liveness guarantee.
