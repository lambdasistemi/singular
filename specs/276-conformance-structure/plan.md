# Bounded implementation plan

The operator explicitly requires simple GLM slices with one small extraction per commit. One final audit, no checkpoint audits. One GLM-5.3/max coder, no additional seats.

1. Move only AssetEntry and its two JSON instances into Conformance.Evidence.Asset, retaining the Conformance.Receipt re-export. At most 40 lines of moved declarations; no caller edits.
2. Expose the Conformance library Haddock derivation in a separate build commit.
3. Integrate that generated reference with existing site generation, provenance, link checks and navigation in a separate commit. This is required residual work, not another production extraction.
4. Complete contributor architecture and speech in a separate documentation commit.

Base live book receipts precede coder edits. Head comparison follows the committed final candidate. CI runs its own rows; local runs cover only base/head comparison. Shared local budget: 25 expensive invocations and 200 cheap invocations, derived from per-invocation receipts.

Preserve conformance/app/Conformance/Run/Live.hs byte for byte, every Lean source and every pending neighbour lane. Rebase onto freshly fetched main before final push. No release or deployment.
