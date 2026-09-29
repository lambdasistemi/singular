# Model repairs: spent-output disappearance and payload equality

Two forward repairs of the open-datum application model, each approved by the operator on 29 September 2026 in the words quoted below. They correct the model and its statements. They change no transition, no valid application behaviour and no root registry source, and they grant no validator, builder, command, publication, signing or merge.

## A terminated output disappears from a consistent world

As a controller terminating an application output from a consistent starting world, I want that spent output to disappear while every recipient receives the full sum of their payment floors.

- **Operator approval, verbatim:** "Approve the consistency premise (recommended)".
- **Evidence:** the settlement diagnostic at commit a039182ab2e8bb2fbf98810f64d78e0ccbbd98e8 (`applications/open-datum/lean/SettlementDiagnostic.lean`) executes the law in a malformed world whose next output reference is 0 while a live output already sits at reference 0. There, the fold's fresh output recreates reference 0, so the spent output is not gone. The connected valid lifecycle behaves as intended. The raw run output has SHA-256 3b6a7f628b05298a9594bedf99956f7db0bb015cb0cee9a2aa1ec27a74f1756f. This is model execution evidence only.
- **What was wrong:** `fold_settles_additively` promised the disappearance over any world.
- **Ruling:** the disappearance requires `AppConsistent w`, never reachability.
  - `fold_settles_additively` keeps its name and stays unconditional: the selected rows are exactly those `selectRow` chose, every spent output was live, each release is the spent output's own protected deposit to its own controller, and every recipient receives at least the sum of its floors.
  - The new `fold_spent_disappears` states, from a consistent world, that no output an accepted fold spends is live afterwards.
  - No payment floor is weakened, and the transitions are unchanged.

## An updated payload replaces its output

As a controller updating a payload, I want the prior output to be replaced while all payload constructors and update behaviour remain available and unchanged.

- **Operator approval, verbatim:** "Approve the structural equality repair (recommended)".
- **Evidence:** at commit f4eda570acc8d11686d36c57ed90ddb00b257d61, `PlutusData` is a nested inductive type with a derived `BEq`. For a nested type, Lean 4.25.0 derives that equality as a `partial` function, which a proof cannot unfold. An update removes the replaced output with `List.erase`, so no proof could show the output was actually removed, and `update_preserves_consistent` could not be proved. This is a finding about what can be proved from the source, not an observed runtime counterexample: the compiled equality always compared the values structurally.
- **Ruling:** the opaque equality is replaced by a total structural one, `PlutusData.beq`.
  - It is proved to be exactly propositional equality (`PlutusData.beq_iff_eq`, `LawfulBEq`), with the same laws for the envelope, control, state asset and application output that contain it.
  - All five constructors, every value and every equality result stay as they were. So do the update and fold transitions, the payload encoding, the envelope hash and the JSON codecs.
  - No axiom, admission, data restriction, or removal by reference instead of by value is introduced.
  - A differential run compares the old compiled equality and the new one over a fixed table of 1681 pairs, covering every constructor, map keys and values, constructor tags and children, list length and order, negative integers and bytes. Both give the same results. The table is a finite runtime sample; the proved laws are the universal claim.

## What follows for the model and its consumers

- The statements number 33. Proof status is established only by captured `#print axioms` reports. The generated theorem ledger lists `fold_spent_disappears` among the statements; recording proof status in that ledger is separate, unfinished work.
- The corpus replays with every recorded outcome unchanged. Only the reached scenarios that release an output also cite `fold_spent_disappears`.
- Issue 304's destination-output question, the application validators, builders, command line, artifact and public-chain evidence remain open and are not affected by these rulings.
