# Modules: who owns the rejection rule

## Responsibilities after the repair

| ID | Module | Responsibility after the repair | Depends on |
|---|---|---|---|
| M-01 | `onchain/validators/registry/fold.ak` | The per-request step owns a reject's refund duties and has no timing rule for a reject. It keeps the processing-window rule for an update. | `shared` (processing window only) |
| M-02 | `onchain/validators/request.ak` | `Contribute` owns the request purpose. It admits in the processing window, or when the state's own fold rejects this request, as the data model's D-02 defines. Retraction is untouched. | `shared`, the state redeemer in the same transaction |
| M-03 | `onchain/validators/shared.ak`, `cage.ak` | Window predicates for phase 1 and phase 2 only. The rejectability predicate and its wrapper are removed (swap rule: no dead guard). | — |
| M-04 | Aiken tests and properties (`cage.props.ak`, `cage_reject.tests.ak`, `cage_contribute.tests.ak`, `deposit_exits.tests.ak`, `cage_fixtures.ak`) | Restate the rule as the model states it, by both purposes. Keep every refund-floor, update-timing and retraction test. | M-01…M-03 |
| M-05 | Identity: `onchain/script-identity.json`, `witness.ak`, `open_datum.tests.ak`; `naming-onchain/{naming.ak, application.ak, fixtures.ak, script-identity.json}`; `offchain/test/.../EnvelopeSpec.hs` | Carry the regenerated hashes. Manifests change only through `just script-identity-regen`. A pin changes only to the value the regenerated manifest states. | the built blueprints |
| M-06 | `offchain/lib/Singular/Registry/TxBuilder/Reject.hs` | Build a reject of the registry's pending requests with no timing selection and no deadline-bound validity. The refund rule and state continuation are unchanged. | M-01, M-02 compiled |
| M-07 | `offchain/e2e-test/Singular/Registry/E2E/CageSpec.hs` | Prove M-06 on a devnet in the processing and retraction windows, beside the phase-3 case, with ledger readbacks. | M-06 |
| M-08 | Conformance story language: `conformance/lib/Conformance/Story/Live.hs` | A reject names the window it is placed in. The language renders it in book prose and rejects nothing it cannot render. | — |
| M-09 | Conformance interpreter: `conformance/app/Conformance/Run/Live.hs` | Realize a reject's placement. Refuse to submit when the built validity interval does not lie in the named window; that is a setup failure, never a step outcome. | M-08 |
| M-10 | Stories and rows: `conformance/lib/Conformance/Edge/Exit.hs` (CG23, placement after the windows), the new early-reject story `conformance/lib/Conformance/Edge/EarlyReject.hs` and its row CG24, `conformance/app/Conformance/Run/CgRows.hs` (CG09 now accepted and unmet by ruling, CG24's runner), `conformance/app/Conformance/Run.hs`, `conformance/app/Conformance/Run/Control.hs`, `conformance/app/Main.hs` (the book's chapters), `conformance/lib/Conformance/Rows.hs` (the row count), `conformance/lib/Conformance/Receipt.hs` (CG24's step completeness, no encoding change), `conformance/conformance.cabal` | Each row's runner owns its verdict from what the chain did. CG09 reports a held consumer conflict. | M-08, M-09 |
| M-11 | Publication: `.github/workflows/conformance.yml`, `docs/consumer-conformance.md`, `docs/onchain-validator-owners.md`, `conformance/lib/Conformance/Book.hs` prose and CG24's chapter, `conformance/rows.json` (CG23's two timing sentences, CG24 appended), `conformance/README.md` | State the current behaviour in product words. CG09's requirement text and every other consumer row are never edited. | M-10 |

## Dependency direction

Unchanged. The on-chain validators know nothing of the off-chain builder or the suite. The builder reads compiled scripts through the blueprint. The suite reads the blueprint and the model's driver. No new library edge is introduced. The request script newly reads the state redeemer of the same transaction, which it already locates to check `Modify`.

## Promotion

Nothing is promoted to a shared library. The window predicates stay in `shared.ak`.
