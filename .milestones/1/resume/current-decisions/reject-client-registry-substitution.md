# Reject the client-registry substitution before accepting or extending #77

Root examined the new register-rows receipt and the shipped-boundary source after the 07:35:56 worker execution report. The transaction run is not evidence of the authorized connected registry journey.

Concrete observations in offchain/journey/register/Main.hs:

1. `registryRoot` at lines 2272-2280 is a newtype around ALL UTxOs at envAppAddr. `rootFingerprint` hashes that client-side list. This is not the imported registry state datum/root or its entry transition.
2. `foldActive` at lines 710-790 spends only claimIn and a funding input, witnesses only the naming application and representative scripts, and mints/burns their assets. It does not consume/continue the registry state UTxO through the repaired state validator Modify path. The receipt corroborates those input sets. A real representative-policy mint is a useful component, but it does not establish the registry entry becoming Active.
3. The header at lines 36-41 explicitly moves occupied-key enforcement to the folding client, asserting that a Plutus validator cannot observe the record set. That enforcement-boundary change was never authorized. The authenticated registry root/proof path exists to validate this on chain. Bypassing that path is the wrong implementation, not a Lean ambiguity.
4. The occupied refusal receipt has no submitted txid. Do not credit a client refusal as a ledger duplicate rejection. Build the adversarial second fold with the client guard bypassed and require attributed state-validator rejection plus the free-key success control.
5. `assertRootMovedByFold` at lines 1004-1006 compares A intersect B with B intersect A. That is a tautology, not evidence that unrelated entries were preserved. The entry/root effects must be checked against the real state transition.

Keep all current code, receipts and RED evidence. Do not merge this candidate, credit its Active/fold/occupied-key rows or propagate it into recovery/retirement as a conformant setup. The useful InsertApproval and real representative policy work can be retained as components, subject to binding it to the real fold.

Own the correction now. Read your existing connected-path design (its owner-signature blocker was resolved by #79) and the real initialization/fold runner in the accepted baseline. Bind the registry initialization identity, actual state input and continuation datum, request input at the modeled request boundary, root proof/entry transition, application approval, representative mint and certified output in the same connected transaction. Registry-owner absence and the other five fold_iff clauses remain fixed. Supplementary acceptance must assert those actual ledger facts and reject a narration-preserving execution that omits the state input or supplies only a client UTxO fingerprint.

The requirement and enforcement location are settled. Do not let the mechanical worker choose a new representation of registry membership or move refusal into a cooperating client. Supply the concrete transaction integration correction through the existing worker, interrupting invalid further integration at a safe boundary. If the actual model/interface is ambiguous, retain a concrete user story and escalate; do not infer ambiguity merely from the effort of using the copied state path.

One consolidated correction, no new auditor or framework. Require an acknowledgement before the worker spends on further false connected-journey assertions. Report this run as component-only evidence, not a passing #77 journey.
