# #323 modules model

Dependency direction: `offchain/cli` → `offchain/lib` → read interface (M1) ← adapters (M2, M3). Composition (M5) is the only module set that names a backend.

- M1 `Singular.Registry.Provider` (`offchain/node-internal`, existing, refactored): owns the read interface, the view and the chain point (D1–D3). Depends on ledger types only; names no backend, socket or mode.
- M2 node adapter (`offchain/node-internal`, new module, name the commit owner's): builds M1 from the pinned node-clients N2C provider through `withAcquired`. Owns acquire, origin refusal and lost-connection classification for node views. Used by DevNet and external node alike.
- M3 in-memory adapter (`offchain/node-internal` or `offchain/lib`, new module): builds M1 from a deterministic mutable chain value (D5), snapshotting at acquire. Library code, not test-only, so #326's contract suite reuses it.
- M4 transaction builders (`offchain/lib/Singular/Registry/TxBuilder/**`, `Singular.Application.OpenDatum.Update`, `Singular.Registry.Driver`, `Singular.Registry.Deployment.Attach`): consume a view, never a provider or a fresh parameter fetch.
- M5 composition (`offchain/cli` startup module(s) and node-internal session modules): resolves node configuration once, opens the node adapter and the signed-transaction submitter (D4), and injects them. The allowlist of the source check (I6) names exactly these modules plus fixture startup, each with a one-line reason.
- M6 CLI commands (`offchain/cli/src/Singular/CLI/{Entry,Create,Inspect,Live,Command,Session,Registry}.hs`): consume injected capabilities; each operation acquires one view.

Promotion: none upstream. The pinned node-clients already provides the acquire primitive; no upstream change is required.
