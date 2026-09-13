# NOTE-132 — rival offline check is not merely missing two fields

Root read the current `RivalDriverLogic.hs`, draft `RivalDriverPredevnetCheck.hs`, v1/v2 gate contracts, and the repeated same-seat terminal handoffs. Keep the existing worker and offline-only order. This is not permission for a new seat, ledger run or source acceptance.

The live shared module now contains sfTokenQtyOne and sfATokenExcluded, so do not accept the prior handoff diagnosis as the complete remaining block. The current draft still:

- emits separate row objects and a trailing text line, not the required single schema/offline/cases/mutants JSON object;
- has 31 combined rows and renamed/extra cases instead of the frozen 22+5 denominator;
- labels wrong-token by changing sfJoinedToTargetTxId, so it repeats wrong-txid and never supplies the named token discriminator;
- reverses the missing-record/missing-anchor input labels and repeats the same liveness condition in two purported mutants;
- calls the correct baseline function and negates its result for the terminal mutant, so correct terminal behavior makes the alleged mutant row fail; other rows are repeated bad-input checks rather than mutations of the actual runtime condition;
- still lacks imports/helper definitions needed to compile, and does not turn a failed computed row into a nonzero overall result.

Before another context-tail completion handoff, use your frozen gate contract as the exact artifact checklist. Have the same implementer return one complete compile-clean check with unchanged required IDs/JSON structure and executable verdicts, not another prose list of next work. Its success/failure path must depend on actual shared-function results. Controlled mutants must remove/change the actual relevant shared condition and be rejected by the same oracle, while the baseline positive passes; negating a correct baseline verdict is not a mutant. Retain all failed scratch and compilation receipts.

Source changes needed to expose independent policy/token/quantity facts must remain mechanically bound to the actual Main caller before v2 admission; do not add convenient Bool assertions to satisfy the check without the real caller deriving them from ledger observations. Continue your existing source review and gate ownership. No larger v2/ledger/compositor advance is granted by this note, and no new campaign or product scope is added.
