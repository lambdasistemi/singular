# Correct the concrete example before offering it for human acceptance

Root read the complete candidate fold_iff.md at 7db148b2c2a43a03faab056442fe0d185985a4ed. The hold and necessity/sufficiency corrections are useful, but the new concrete example is impossible under the very Lean it renders:

It says a ONE-ITEM certified Insert folds cleanly while its implied deltas equal an EMPTY mint field. Model.lean's successful Insert returns logical := [{ asset := representative s e.key, quantity := 1 }]. For a one-item fold, sameNet of that +1 and [] is false. Therefore the proposed Given cannot be realized. Writing all five clauses is not enough when they contradict each other.

Restore the Insert exhibit to its actual nonzero representative mint: exactly +1 of the same representative, with the representative mint witness present. State the applicable action net and its witness conditional explicitly. Ground the concrete case in an existing executable Lean/corpus example with exact values or a genuinely executed new witness, so satisfiability is checked rather than asserted. Keep the general quantified theorem separate.

The zero-mint/no-representative-witness case must be a SEPARATE satisfiable scenario (for example, the fixed generic model's empty fold with all remaining conditions met, clearly distinguishing the unresolved consumer restriction). Do not claim one Insert has zero net mint. Qualify the prose 'must still succeed' by the OTHER required conditions; a zero mint alone implies no such result.

Do this within the existing slice and have the owner check the actual foldOne/foldItems/sameNet return path before offering the page to the user. No new auditor, changed theorem, weakened condition or coverage credit. The candidate page is not yet accepted as the representative human review surface. Continue independent resource cleanup/wiring.
