-- | Bind the registration theorem to the shared model comparison.
module Conformance.Lean.Registration (
    InsertActive, modelComparison, insertActiveRow,
) where

import Conformance.Story.Binding (mkBoundObligation)
import Conformance.Story.Specification (LeanCheck, Theorem, bindCheck, bindTheorem)
import Conformance.Story.Live (LiveI, compareWithModel, observe)

-- | The registration declaration, distinct from every other theorem marker.
data InsertActive

modelComparison :: LeanCheck (LiveI reg wal step obs cmp) InsertActive step
modelComparison = bindCheck insertActiveRow $ \step -> do
    observation <- observe step
    _ <- compareWithModel step observation
    pure ()

insertActiveRow :: Theorem InsertActive
insertActiveRow = bindTheorem $ mkBoundObligation
    "Singular.Statements.insert_active_transaction_row"
    "f1f50ac910b0ff0f5abb8d371bd82ce5007e8bfe861939c5972d62e8c85e8508"
    "265c595edd72eab10f3b08a36cb010ad407cf48b"
