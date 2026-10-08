{- | The fixed contract's participant story in the existing description language.
Execution requires a permanent registry and the bounded model evaluator.
-}
module Conformance.Edge.Permanent (story, description) where

import Conformance.Story.Live
    ( Context (..)
    , Edge (..)
    , EdgeRequest (..)
    , Story
    , compareWithModel
    , foldBatch
    , observe
    , renderLive
    , submit
    )

story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry participant) = do
    compared (EdgeRequest InsertActive "registered-key" participant)
    compared (EdgeRequest UpdateTerminal "registered-key" participant)
    mapM_
        (\edge -> compared (EdgeRequest edge "registered-key" participant))
        [ InsertAbsent
        , UpdateActive
        , DeleteAbsent
        , DeleteActive
        , WitnessTerminal
        ]
    _ <-
        foldBatch
            registry
            [ EdgeRequest InsertActive "another-key" participant
            , EdgeRequest WitnessTerminal "registered-key" participant
            ]
    pure ()
  where
    compared request = do
        step <- submit registry request
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()

-- | Render the same actions that an interpreter executes, with opaque handles.
description :: String
description = renderLive (story (Context "permanent registry" "participant"))
