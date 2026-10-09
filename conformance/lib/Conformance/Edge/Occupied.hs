{- | Registration on a key the registry already holds, beside its reached
registration control and an explicit refusal of the excluded update encoding.
-}
module Conformance.Edge.Occupied (story) where

import Conformance.Story.Live
    ( Context (Context)
    , Edge (..)
    , EdgeRequest (..)
    , Story
    , compareWithModel
    , observe
    , submit
    )

story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry holder) = do
    checked (EdgeRequest InsertActive "occupied" holder)
    checked (EdgeRequest InsertActive "occupied" holder)
    checked (EdgeRequest UpdateActive "occupied" holder)
  where
    checked request = do
        step <- submit registry request
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
