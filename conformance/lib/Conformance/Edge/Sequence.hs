-- | An edge sequence that belongs to no named requirement chapter.
-- It exercises the same interpreter used by registration and retirement.
module Conformance.Edge.Sequence (story) where

import Conformance.Story.Live
    ( Context (Context), Edge (..), EdgeRequest (..), Story
    , compareWithModel, observe, submit
    )

story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry holder) = do
    checked (EdgeRequest InsertAbsent "sequence-active" holder)
    checked (EdgeRequest UpdateActive "sequence-active" holder)
    checked (EdgeRequest UpdateTerminal "sequence-active" holder)
    checked (EdgeRequest InsertActive "sequence-direct" holder)
    checked (EdgeRequest InsertAbsent "sequence-absent" holder)
    checked (EdgeRequest WitnessTerminal "sequence-active" holder)
    checked (EdgeRequest DeleteActive "sequence-direct" holder)
  where
    checked request = do
        step <- submit registry request
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
