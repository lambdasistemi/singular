# Publication and funding: modules model

Only changed responsibilities are listed. Binding and authority are in [plan.md](plan.md).
Fields and capabilities are in [data-model.md](data-model.md); signatures are in
[functions-model.md](functions-model.md) and [wallet-functions-model.md](wallet-functions-model.md).

## Closed capabilities

- `ledger-kernel` owns raw Session, query and history types in their defining modules.
- `local-services` exports abstract Session, opaque WalletOutputs and named Reads. Provider
  kernel capabilities stay internal; plain ledger types do not grant read capabilities.
- `koios-provider` depends on the kernel and HTTP client, exposing only abstract-session
  constructors. Returned candidates remain unverified and locally admitted where required.
- The main builder library depends on local-services without kernel/provider-internal access.
- `registry-history` exports reconstruction state and refusals, not raw history/transactions.
- `registry-harness`, above main/kernel, owns Driver diagnostics and Funding.checkFunding.
  Only harness/application consumers depend on it; provider/HTTP dependencies stay acyclic.
- The shipped executable has no kernel/harness/internal-provider read capability. Existing
  harnesses retain required diagnostics without extending the shipped wallet interface.
- The future registry-page component stays above main/history, as previously bound. This
  migration must not implement #503 or create a dependency cycle for it.

## Wallet and observation ownership

`Singular.Registry.WalletOutputs` alone owns the raw wallet collection, the single fundable
predicate, ordinary funding projection, chosen funding restriction, reserved seed, locally
matched carriers and candidates for a specifically required burn asset. StateToken re-exports
the one predicate rather than duplicating it. All ordinary selectors migrate together.

`Singular.Registry.Reads` owns named script/reference, exact-output visibility, address-wide
recovery/refund and inspect-report reads. Query restrictions apply to returned output content;
provider labels do not establish script credentials or script hashes.

## Publication and CLI

`Singular.Registry.StateToken` owns checked release-script derivation and the shared deferred
provider-first/wallet-fallback missing-role discovery. Existing findReferences adds the
missing-role refusal to that path; no parallel search is introduced.

`Singular.Registry.TxBuilder.Edges` owns the publication transaction with payer-controlled
minimum-ADA script outputs. Named protocol inputs remain separate from ordinary funding.
Existing builders/CLI consumers preserve their outcomes when acquiring opaque wallet views.

`Singular.CLI.References` owns publication preview, selected roles, receipt and recovery through
existing write composition. Command/help expose publish-references and explicit opt-in
restoration on existing dependent commands. No implicit publication or registry creation.

Conformance description, interpreter and renderer own the connected restoration/fold claims
and receipt-computed state. Every discovered instruction executes and renders; harness proofs
stay in an appendix. Demo/packaging/docs helpers change only for this delivery's runnable
command, independent actors and archive entry point. The new retirement and page commands
remain in #502/#503.
