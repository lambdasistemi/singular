# A-001: bind `defaultFunSemanticsVariantC`. The E label was our commissioning defect.

You were right to refuse a silent substitution, and right that the pin implements only A/B/C. But
the conclusion is not "use C because the library lacks E" — **C is what the protocol mapping
actually specifies for this target.**

## The mapping, from primary sources

`IntersectMBO/plutus` at `e5bec6ae0caa8de4c2d33d518ce2cfd4bdc34cbf`:

- `plutus-ledger-api/src/PlutusLedgerApi/Common/ProtocolVersions.hs` — `vanRossemPV` is **11**. V3
  takes **C after Conway but before van Rossem**, and **E from van Rossem onward**.
- `PlutusLedgerApi/V3/EvaluationContext.hs` — `mkDynEvaluationContext` explicitly selects **C when
  `pv < vanRossemPV`**, E otherwise.

https://github.com/IntersectMBO/plutus/blob/e5bec6ae0caa8de4c2d33d518ce2cfd4bdc34cbf/plutus-ledger-api/src/PlutusLedgerApi/Common/ProtocolVersions.hs#L127

https://github.com/IntersectMBO/plutus/blob/e5bec6ae0caa8de4c2d33d518ce2cfd4bdc34cbf/plutus-ledger-api/src/PlutusLedgerApi/V3/EvaluationContext.hs#L45

Singular at `5bd7c79`: `offchain/e2e-test/genesis/shelley-genesis.json` configures **protocol 10.0**.
The register runner calls `genesisDir` then `withCardanoNode`; pinned cardano-node-clients
`38fc1917` defaults `genesisDir` to `e2e-test/genesis`, overridable by `E2E_GENESIS_DIR`.

**PV10 + V3 → `defaultFunSemanticsVariantC`.** Bind it explicitly.

## The defect was ours, not yours

The brief's blanket "V3 post-Conway → E" came from the skill's era table, which **omits the
intra-era van Rossem boundary**. That is a commissioning defect on my side. **Preserve your
original blocked report as evidence of it** — do not delete or soften it.

For this lane, this evidence-backed correction **overrides the era table** in the
`aiken-blaster-verification` skill. The skill's identity, discrimination and fail-closed
requirements all stand unchanged. Neither a skill table nor our frozen prose can override primary
implementation facts — which is exactly the principle your refusal applied.

No Lean invariant, hypothesis, refusal expectation, target behavior or debt category changes.
**No pin upgrade is needed** to satisfy an erroneous label.

## Conditions on every decisive run

- **Record and check the actual genesis override and queried protocol parameters** used by that
  run. Configuration provenance is verified; the live session's protocol version has **not** been
  independently queried — so query it, don't assume it.
- A **PV11-or-later** target requires E support. Mismatch, or an unsupported target, is
  **`COULD-NOT-EVALUATE`**.
- **Claim nothing about PV11, preprod, or universal era support from a PV10 run.** A bounded result
  carries its bound.
- Costs, supported builtins and evaluator limitations remain **separate** validation obligations —
  binding the variant does not discharge them.

## One thing to make explicit in `MAPPING.md`

Show **how the explicit CEK variant reaches any SMT claim** through the mapped execution function.
`#blaster` not taking a variant argument does **not** make its semantics unbound — it means the
binding happens in the function you map through, and a reader must be able to see where. No
convenience default, no model-only replacement.

## Resume

Continue on the existing seat: bind the variant as an explicit parameter, finish the lake dependency
build and imports, confirm `CardanoLedgerApiBlaster`, then the real I-1 and I-2 controls. Your
inventory finding stands and is valuable — **the build reports aiken `v1.1.21` while
`onchain/aiken.toml` prose says `v1.1.16`**. That is the documented-pin drift the skill warns about,
found in our own repository. Keep it bound in the identity record and report it as a finding.
