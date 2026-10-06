-- | Bind the registration theorem to the shared model comparison.
module Conformance.Lean.Registration
    ( InsertActive
    , modelComparison
    , insertActiveRow
    ) where

import Conformance.Story.Binding (mkBoundObligation)
import Conformance.Story.Live (LiveI, compareWithModel, observe)
import Conformance.Story.Specification
    ( LeanCheck
    , Theorem
    , bindCheck
    , bindTheorem
    )

-- | The registration declaration, distinct from every other theorem marker.
data InsertActive

modelComparison
    :: LeanCheck (LiveI reg wal step obs cmp) InsertActive step
modelComparison = bindCheck insertActiveRow $ \step -> do
    observation <- observe step
    _ <- compareWithModel step observation
    pure ()

insertActiveRow :: Theorem InsertActive
insertActiveRow =
    bindTheorem $
        mkBoundObligation
            "Singular.Statements.insert_active_transaction_row"
            "3c8d7b9bd9092b29d2bbb58ebbca15b008dc9b9396899d9d67d55ea66e1f6070"
            "265c595edd72eab10f3b08a36cb010ad407cf48b"
