# Plan

One slice. Lean changes first. The corpus is regenerated from those statements. The sequence then submits `deleteAbsent` and the book is regenerated from that devnet receipt.

## Order

1. Add `trieErase`. Point both `applyEdge` deletion arms at it. Restate and prove the theorems in the spec table. Prove `trieGet (trieErase t k) k = .unknown` and that every `Reachable` state stores no `.unknown` leaf.
2. Regenerate `lean/driver-corpus.json` from `lean/DriverMain.lean`'s executable. `nix run --quiet .#model-check` is the check.
3. Add one `deleteAbsent` step to `conformance/lib/Conformance/Edge/Sequence.hs` for the key that sequence inserted as Absent, while that key is still Absent. Admit `deleteAbsent` to the agreeing outcomes in `expectedSequenceOutcome` (`conformance/app/Conformance/Run.hs`). Leave `deleteActive` and `witnessTerminal` unsupported.
4. Remove the typed disagreement paragraph in `conformance/lib/Conformance/Book.hs` and the same claim in `conformance/test/README.md`. Regenerate `conformance/BOOK.md` from the devnet book run. Do not type a replacement agreement sentence. Do not hand-merge the book.

## Constraints

- Justification is the design: a deleted key is a non-member. The chain receipt is the comparison, not the reason for the model change.
- `Reachable` (`lean/Singular/Model.lean`) is the reachability hypothesis. It is closed over successful `step`s, and `step` applies `applyEdge`.
- `#235` and `#236` both regenerate `conformance/BOOK.md`. The second to merge rebases onto main and regenerates. It does not hand-merge the book.
- The agreeing-outcome function is shared. This ticket changes `deleteAbsent` only.
- On this base, `.github/workflows/conformance.yml` has no sequence assertion. This ticket does not add one unless the parent names that workflow change. The devnet receipt is still required evidence for R7 and R8.

## Live boundary

The unnamed sequence runs on a local devnet through the existing book command. The receipt's comparison for the `deleteAbsent` step is the boundary result. A unit test of the story program is not that result.

## Baseline

`origin/main` at `7eba114` has green CI, Documentation release, and Conformance on the merge push. Those runs do not execute this deletion comparison: the sequence omits `deleteAbsent`, and the model check agrees the model with itself.
