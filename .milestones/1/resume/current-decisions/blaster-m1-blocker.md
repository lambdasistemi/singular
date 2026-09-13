# M1 blocker: validate compiled Aiken invariants with Blaster

Authority: operator instruction, 2026-09-12: “add blaster level invariants validation on the aiken code as M1 blocker”. Effective immediately for M1 acceptance and the integrated M1 release. This is additional to the existing code-the-design acceptance layers; it grants no conformance credit by itself.

Accountable owner: epic #18 owner, for the compiled-invariant inventory, executable verification artifact and integration into #80's strict publication gate. Epic #17 supplies the exact repaired validator artifacts and handles implementation defects through its existing serial writer. The milestone owner reviews the gates and independently challenges their negative controls. Existing staffing applies: GLM/Muse for mechanical work, no additional auditors or automatic fleet expansion.

## User story

As a Singular integrator, I can trace each applicable accepted Lean invariant through its readable Given/When/Then story to validation of the exact compiled Aiken program in the release, so that an implementation or compilation divergence prevents M1 acceptance.

## Required acceptance

1. Use a versioned inventory of every M1 validator title and every applicable invariant/required clause, derived from the full accepted Lean inventory. Preserve exact hypotheses, quantifiers, both directions of equivalences, vocabulary and refinement mappings. Unclassified applicability and missing rows remain debt. An exclusion requires a design-based rationale and milestone review; tool limitations do not justify exclusion.
2. Import the actual production-built UPLC through the pinned Blaster/PlutusCoreBlaster toolchain. Bind source commit and clean tree, actual compiler and dependency versions, blueprint and compiled-byte digests, exact validator titles, Plutus version, applied parameters and script identities, plus the explicit BuiltinSemanticsVariant justified for the target ledger. Never silently select a first title or a default semantics variant.
3. Validate the invariant against that imported program. A handwritten Lean model, Aiken source test, arbitrary receipt, successful import or bounded example alone cannot establish a quantified compiled-code claim. Record the checked domain and disposition separately: KERNEL-PROVED, SMT-VALID (no proof term), TESTED or UNPROVED. Finite CEK executions are TESTED; retain any remaining quantified obligation as debt.
4. Every assertion records ESTABLISHED, REFUTED or COULD-NOT-EVALUATE, with reproducible command, bound inputs, raw result/trace and evidence digests. Missing identity, unsupported builtin, opaque error, timeout, solver unknown, skipped or unreachable assertion is COULD-NOT-EVALUATE and blocks acceptance. Distinguish tooling failure from validator rejection.
5. Exercise valid controls and adversarial cases from the frozen design. Demonstrate discrimination with relevant source mutations rebuilt through the production compiler, prove the mutated bytes reached the evaluator, retain the intended REFUTED result and restore/reverify the baseline. The milestone owner supplies/checks independent gate controls under the existing no-extra-auditor ruling.
6. Preserve the settled ownerless registry contract: there is no registry owner role or latent owner/stake authority. Unmodeled End, migration, Sweep and Burning routes cannot restore inherited destructive authority. Legitimate application/name controllers, request/refund requirements and ordinary funding witnesses remain governed by their own clauses. Do not invent a ban on a registry creator funding or signing. Changes or ambiguity in Lean must be escalated through a concrete user story, never rewritten to satisfy code or tooling.
7. Supply a repository-owned reproducible command and CI integration. Extend #80's strict completion/publication gate with a separate per-obligation compiled-invariant debt category. Missing, stale, fabricated, skipped, unknown or failing evidence must prevent M1 acceptance/publication; unrelated green tests cannot offset it. Test removal of an inventory row/artifact, stale bytes/parameters/variant, false evidence and bypass/removal of the publication guard.
8. Publish human-readable Lean/story/compiled-check correspondence and the exact artifact evidence. M1 closes only when all required compiled-invariant obligations are discharged and all existing acceptance categories also reach zero. A bounded result is reported with its limits, never promoted to universal equivalence.

## Delivery order and fences

Prepare the inventory and toolchain/runner alongside current repairs. Bind definitive execution to the repaired ownerless schema and subsequent accepted candidate; rerun affected checks whenever source, parameters, toolchain or semantics change. Start with ownerless authority and supported-fold obligations as the first executable slice, then cover the full applicable M1 inventory. That first slice is not the denominator.

Keep #77's existing frozen gate and retained evidence intact; this is a separately versioned new M1 obligation. Do not interrupt current builds, add a second validator writer, weaken Lean, adopt Scalus, modify upstream MPFS, create an indexer, deploy to preprod or silently change the release version line. Existing bounded-release authority remains bounded and cannot be presented as completed M1. Ordinary independent docs publication retains its existing policy.

Read and apply aiken-blaster-verification and code-the-design. Before implementation, the epic owner records the issue, affected inventory, toolchain availability, first executable slice, worker ownership and terminal conditions. A toolchain obstacle remains an explicit M1 blocker; it is not an automatic waiver or permission to substitute model-only evidence.

Current result: REQUIRED / NOT YET ESTABLISHED. No Blaster run or compiled-invariant discharge is claimed by this commission.


## Parallel implementation authorized — 2026-09-12

The operator authorizes a Blaster implementation driver alongside the ongoing lifecycle and conformance repairs. Epic18 commissions an additional Muse driver in an isolated worktree for the compiled-artifact extraction/import/execution slice, covering both onchain and naming-onchain. The epic owner freezes the Lean invariant/refinement mappings and owns acceptance. Shared coverage-schema, CI and publication changes integrate serially through #80. Existing workers continue; no additional auditor is commissioned. This supersedes the earlier wait-for-an-existing-worker-to-finish scheduling hold. Preparation and instrumentation can run against an explicitly identified snapshot now; final evidence must bind the accepted repaired artifacts and all required debt remains blocking.
