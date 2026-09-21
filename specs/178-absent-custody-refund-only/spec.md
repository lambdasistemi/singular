# Absent custody carries refund only

Model/base: d92f35bf722120369c386ce09e6c7a40d321182f, PR 208 merged.
Correction citations reverified against this base. Constitution 1.0.0 applies.

## Story

As a registry integrator, I want an absent token's custody output to carry only
the refund address in its datum, so that token identity has one source: the
output's sole asset. The existing library and validator must agree on that wire.

## Authority

PR 208 candidate inspected: cf8f0d44880a5f774af1dc493302aec1aa2c595e.
`Singular.Statements.insert_absent_transaction_row`,
`Singular.custodyKey`, `Singular.txCageOutputs`, and `Singular.txOf` govern.
Statement digest: cbe444a5bddadef89cba2f1459a597a010531e396a90be4a798fdccc5633fb46.
Accepted model revision is the merge commit above. No Lean change is authorized.

## Requirements and invariants

| ID | Observable truth and refusal |
|---|---|
| INV-178-WIRE | Custody's inline datum contains refund only, retaining constructor index 2; actual encoders, decoders, validator schema and builder agree. The old two-field payload cannot masquerade as the corrected wire. |
| INV-178-ASSET | Identity comes from the complete discovered non-ADA asset set, corresponding to the model's assets list. Exactly one absent-policy asset of quantity one supplies its name as key. Zero assets, two assets, wrong policy or wrong quantity supply no custody identity. Datum and request supply no fallback. |
| INV-178-EFFECTS | The admitted insertion holds the requested refund and deposit at custody, mints the model's absent asset, and preserves the transaction row's root, configuration, ownership, approval and destination relationships. Existing custody-consuming helpers must read the corrected representation without changing another edge's contract. |
| INV-178-JUDGED | The executable conformance row is selected and its expected verdict/observations are asserted by CI. The unregistered-row control demonstrates the selection gap. Missing execution or observations cannot count as agreement. |
| INV-178-COPIES | Final PR enumerates discovered declarations, consumers, mirrors, derived artifacts and evidence records with file, line and disposition. The external naming mirror is explicitly recorded as excluded under the published contract. |
| INV-178-GATE | Full local root CI plus Conformance snapshot pass on the candidate; Registry and Conformance pass on the exact pushed head. Per-checkpoint approval and source-fence compliance are prerequisites for push. |

The first acceptance line requires executable singleton/zero/two-asset evidence
at the implementation boundary, including a check observed to fail for the
defect. Source search is discovery only. Quantification must not silently erase
assets from other policies or accept an empty population.

## Scope and limits

Two ordered slices; no runnable command. Owned production: onchain/,
offchain/lib/Singular/Registry/, offchain/test/, conformance/ rows and coverage,
Conformance workflow row registration, and docs for this edge.
Forbidden: naming-onchain/, simulator engine, another edge's arm,
offchain/insert-absent/, onchain-release/INSERT-ABSENT.md.
Minimal mechanical representation adaptations of existing consumers are
authorized by the parent's ruling of 2026-09-21T16:34Z: edgeReferences edge 4,
custodyInput/custodyKeyOf, and the AbsentCustody spending arm. Their edge
contracts do not change. For edge 4's reference selection, identify an existing
executing check and retain before/after passes plus a selection perturbation
that fails it. If none exercises it, state "no executing check covers this
selection" in the PR and name the uncovered consumer. Do not create a bespoke
check or claim deleteAbsent certification coverage.

S1 is wire and consumer adaptation. S2 is the new conformance row and its
registration, HELD until the parent reports the conformance DSL merge. No new
conformance test-tree changes in S1. S2 remains mandatory for ticket acceptance;
it may be deferred at the wall without undoing a separately verified S1.

Simulator transaction replay remains a named gap. Coverage-check INCOMPLETE
remains debt, not acceptance. No full-project conformance or release claim.
Code-the-design rung 1 for these invariants, preserving existing cross-layer
checks and adding the ticket's explicit conformance registration obligation.
Model ambiguity holds affected acceptance and travels upward as a concrete
user story with the conflicting revisions and clauses.
