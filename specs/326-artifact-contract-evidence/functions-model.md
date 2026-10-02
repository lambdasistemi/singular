# #326 functions model

Signatures are binding in shape; auxiliary names and placement within the modules model are the commit owner's.

- F1 `contractSuite :: AdapterHarness -> Spec` — the shared case list over one adapter (M1, D1). `AdapterHarness` carries the `Provider IO`, its evidence class and the chain controls the adapter supports.
- F2 Composition roots of R6 construct `Provider IO` and `SignedSubmitter` once and pass them down; no consumer function takes `NodeSession`, `NodeMode` or `Submitter` (M4).
- F3 `verify-release <tag>` (flake app) — exit 0 only when sums, archive members, separate-process journey and model revision agree (M5, R8).
- F4 Evidence page rendering takes `rows.json` and a receipts directory and produces the page; the check recomputes and compares (M6, R9).
