# Plan

One slice. Rung 0 of the design ladder: the `deleteActive` journey runs and agrees with Lean on a devnet receipt. Rung 1: the value-conservation check has been seen to fail on the unfixed builder.

Lean stays the authority. This ticket does not change a theorem.

## Order

1. RED. Execute the builder for an active key whose witness UTxO is in hand. The proof fails because the mint is `-1` and that UTxO is not an input.
2. Repair the builder so that input is spent and the burn remains. The same proof passes. Existing refusal controls still fail at their own boundary.
3. Flip only the `deleteActive` member of the sequence agreeing set from unsupported to agrees. Regenerate `conformance/BOOK.md` from a clean devnet run. Do not hand-edit the book.

`witnessTerminal` stays unsupported. `deleteAbsent` is not a step of this sequence.

## Shared files

#235 also regenerates `conformance/BOOK.md` and edits the sequence agreeing set, for `deleteAbsent` only. Whichever PR merges second rebases onto main and regenerates the book from its own run.

## Live boundary

Acceptance of the fold is a node submit on a devnet, not a builder-unit result. The unit proof binds the input and the mint. The receipt binds acceptance and the comparison.
