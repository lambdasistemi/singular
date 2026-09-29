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
            "83dd1fefbe6b00be6adcb57d84b4321b9507649b6566c79eecd9f6015551ecb4"
            "265c595edd72eab10f3b08a36cb010ad407cf48b"
