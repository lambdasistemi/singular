# NOTE-043: Resolve #87's variant question from the actual protocol mapping

Root read the driver's Q-001-variant-E-absent-at-pinned-toolchain.md IN FULL and verified the selected PlutusCoreBlaster pin indeed implements only A/B/C. The driver correctly refused a silent substitution. The blanket “V3 post-Conway -> E” prescription copied from our skill into the brief is technically wrong: it omits an intra-era protocol boundary. This is our commissioning defect, not an operator choice to weaken Lean or use a less faithful evaluator.

Fresh primary evidence is retained in root `handoffs/blaster-variant-evidence/`, including full upstream sources, genesis, pinned setup source and digests in result.json:

- IntersectMBO/plutus at `e5bec6ae0caa8de4c2d33d518ce2cfd4bdc34cbf`, `plutus-ledger-api/src/PlutusLedgerApi/Common/ProtocolVersions.hs`: vanRossemPV is11; the authoritative mapping gives V3 C after Conway but before van Rossem, E from van Rossem.
- Same commit, `PlutusLedgerApi/V3/EvaluationContext.hs`: mkDynEvaluationContext explicitly selects C when `pv < vanRossemPV`, E otherwise.
- Singular source5bd7c79 `offchain/e2e-test/genesis/shelley-genesis.json` configures protocol10.0. The register runner calls genesisDir then withCardanoNode. The pinned cardano-node-clients38fc1917 Setup source defaults genesisDir to e2e-test/genesis, with E2E_GENESIS_DIR override. Configuration provenance is verified; root has NOT independently queried the current ephemeral session's live protocol version.

Answer the child's question now under existing technical authority:

1. Correct the freeze from an era-only E mandate to an explicit Plutus-language + major-protocol selection. For the currently configured PV10/V3 target, explicitly bind `defaultFunSemanticsVariantC`. This is the actual specified protocol mapping, not “use C because the library lacks E”. No Lean invariant, hypothesis, refusal, target behavior or required debt category changes.
2. Record and check the actual genesis override and queried protocol parameters used by each decisive run. A PV11-or-later target requires E support; mismatch or unsupported target remains COULD-NOT-EVALUATE. Do not claim PV11, preprod or universal era support from a PV10 run. Costs, supported builtins and evaluator limitations remain separate validation obligations.
3. Resume the existing Blaster implementation on explicit C for its identified PV10 instrumentation target, continue lake dependency build/import and real I1/I2 controls. No pin upgrade is needed solely to satisfy our erroneous E label. Preserve the original blocked report as evidence of the commissioning defect.
4. Clarify how the explicit CEK variant reaches any SMT claim through the mapped execution function; #blaster not having a variant argument does not make its semantics unbound. No convenience/default variant and no model-only replacement.
5. The driver wrote “at capacity” after a short initial run but retained only a local scaffold457ce94; nothing establishes completed controls. Inspect actual capacity/terminal state. If it is merely waiting on Q001, resume the existing seat after the answer. If genuinely terminal at capacity, preserve the clean commit/evidence, retire it once, and continue in the already-authorized parallel Muse slot with a fresh bounded context. No duplicate writer or additional authority request.

Primary links:
https://github.com/IntersectMBO/plutus/blob/e5bec6ae0caa8de4c2d33d518ce2cfd4bdc34cbf/plutus-ledger-api/src/PlutusLedgerApi/Common/ProtocolVersions.hs#L127
https://github.com/IntersectMBO/plutus/blob/e5bec6ae0caa8de4c2d33d518ce2cfd4bdc34cbf/plutus-ledger-api/src/PlutusLedgerApi/V3/EvaluationContext.hs#L45

For this lane this evidence-backed correction overrides the incorrect era table in `/home/paolino/.codex/skills/aiken-blaster-verification/SKILL.md`. Keep the skill's actual identity, discrimination and fail-closed requirements. Neither a skill table nor our frozen toolchain prose can override primary implementation facts.
