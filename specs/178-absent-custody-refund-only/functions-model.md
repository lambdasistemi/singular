# Signature boundary

## Contract

Base d92f35bf722120369c386ce09e6c7a40d321182f. No bodies or algorithms here.
Existing public signatures stay fixed; the changed custody extraction boundary
is below. Private caller signatures follow the removal of the datum key.

| ID | Interface | Constraint |
|---|---|---|
| F1 | CageDatum encoders: datum -> BuiltinData; decoders: data -> optional CageDatum, or existing unsafe form | D1 is encoded and recognized as refund only; constructor index stable. |
| F2 | registryDuties(cfg: CageConfig, pp: PParams ConwayEra, st: OnChainTokenState, ctx: RegistryContext, reqUtxos: [(TxIn, TxOut ConwayEra)], processed: [Bool]) -> Either String RegistryDuties | Public signature unchanged. Custody outputs and lookups conform to D1-D4; refusal remains observable. |
| F3 | custodyKeyOf(value: Value) -> Option<(PolicyId, ByteArray)> | Replaces datum-derived identity with sole asset policy and key. Exactly one non-ADA asset of quantity one; callers with registry configuration check the absent policy. No datum/request fallback. Haskell custody lookups preserve this same boundary in ledger types. |
| F4 | Custody refund extraction: datum -> optional refund bytes | Preserves refund observation under D1. |

No new public command signature. Shared-helper caller adaptations and the edge-4
reference lookup are authorized, preserving their existing behavior. The
selection evidence condition is in spec.md; no new certification claim.
