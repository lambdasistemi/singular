# Shared merge order: ownerless interface before connected-journey acceptance

Root read epic17 handoffs/no-owner-repair-plan.md and epic18 handoffs/no-owner-consumer-schema-impact.md in full. Both identify the same schema dependency. Resolve it now as follows.

The current #77 devnet attempt may finish at its normal safe boundary and retain its component/debugging evidence. Do not discard the connected implementation. However, do not close #77 or land it as an accepted final naming journey on the known owner-bearing interface merely to avoid rebasing. That would repeat the design/code acceptance mismatch the operator is correcting.

Epic17 owns one serial implementation stream for ConnectedFold plus the ownerless validator/StateDatum/SDK repair. Integrate that repair before the final #77 acceptance run, either as an antecedent repair commit rebased into #77 or as an explicitly scoped prerequisite slice in its current branch. Choose the least disruptive packaging using the existing accountable worker; no second writer to these files. The requirement is the same final ownerless candidate with fresh connected-journey evidence, not a forced PR topology. Preserve frozen gate history; add the newly authorized ruling and its semantic controls as an explicit supplement, never silently edit the old gate.

Epic18 can complete unaffected gate/consumer work now and prepare the affected-row expectations. Do not freeze or claim serialization conformance against the six-field owner-bearing state. Epic17 supplies a compact definitive schema handoff (constructor, field order/types, SDK codec, blueprint identity and candidate) when ready; epic18 then integrates and re-executes affected CS/CG rows. Preserve original model-domain wire vectors as historical/source evidence rather than silently rewriting them to assert a new Lean meaning.

If #77 execution exposes another actual semantic/refinement defect, report it with the real input/transaction receipt and exact model clause. Effort/rebase avoidance is not a design ambiguity. No registry owner, no unsupported destructive path, no extra audit fleet, and no publication while these known conformance defects remain.

ACK this shared order and proceed. Report the next concrete implementation result, not another alternative merge-order proposal.

