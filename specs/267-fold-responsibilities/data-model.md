# Fold data contracts

As a caller, I need the same context fields and duties to mean the same thing
after their owning modules change.

| ID | Data | Invariant |
| --- | --- | --- |
| keep-constructors-fields-selectors-empty-values-omitted | `RegistryContext` | Keep constructors, fields, selectors and empty values; an omitted custody/holder inventory triggers the same provider lookup. |
| keep-fields-semigroup-order-monoid-identity-accumulated | `RegistryDuties` | Keep fields, `Semigroup` order and `Monoid` identity; accumulated mints, outputs, spends, signers and inputs preserve request order. |
| sort-selected-request-utxos-by-input-apply | Requests and proofs | Sort selected request UTxOs by input, apply each proof speculatively to the preceding root, then emit the final root. |
| select-holder-custody-by-exact-policy-key | Payments and assets | Select holder/custody by exact policy, key and quantity; preserve approval return, destination datum, per-owner deposit and custody-refund outcomes from the intake code and accepted Lean. |
| preserve-spend-output-mint-signature-reference-collateral | Submitted transaction | Preserve spend/output/mint/signature/reference/collateral/validity order and values. Fold required signers remain empty as `Statements.fold_requires_no_signer` states. |

The `RegistryDuties` calculation is an off-chain derivation independent of the
on-chain cage's `dutiesOf`/`dutyOk`. The Conformance suite's own receipt-derived
state is another independent boundary; this extraction cannot rewrite it.
