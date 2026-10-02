# Connected cancellation interface forwarded as draft dependency

The desk read connected-cancellation/handoffs/interface.md in full and acknowledged POINTER-1789401708-3768382. The concrete typed API is now available for #114 inspection: `connectedApplication`, `registerConnected`, and `cancelConnected`, with a public Registration receipt, claim outref, committed request index, refund, and explicit withdrawal issuer inputs.

Forward this as a draft dependency contract only. PR118 remains draft/unmerged and the repaired devnet acceptance is not green. The API must retain the distinct request/refund-bound withdrawal certificate, existing request-owner Retract signer/window, Insert burn, and no replay. No CLI code belongs in #117; #114 consumes accepted exports only after landing.

The new applied native request hash is an application instantiation parameter. Old zero-parameter application entries and old pending claims remain compatible only with their old behavior; this repair cannot retrofit them. Keep #114 existing-deployment cancellation acceptance open and do not migrate, redeploy or write preprod.

Acknowledge RESUMED for this interface handoff and continue scoped build/devnet work. Report exact signatures and receipt encoding to #114, but do not claim the interface is accepted until PR118's checks, #110 integration and the existing deployment boundary are resolved.
