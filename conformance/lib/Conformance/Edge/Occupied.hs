{- | Insertion on a key the registry already holds, expressed only as edge
requests and comparisons. The key is booked by an accepted @insertAbsent@
and made active by an accepted @updateActive@ in the same registry — the
state the shared session key is in when the occupied-key row follows the
update row — which is the refusal's connected control; the same
@insertAbsent@ on that key is then refused by both sides.
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
    checked (EdgeRequest InsertAbsent "occupied" holder)
    checked (EdgeRequest UpdateActive "occupied" holder)
    checked (EdgeRequest InsertAbsent "occupied" holder)
  where
    checked request = do
        step <- submit registry request
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
