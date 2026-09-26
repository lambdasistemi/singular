-- | Owner-signed retractions on either side of phase 2 and inside it.
module Conformance.Edge.RetractionWindow (story, requests) where

import Conformance.Story.Live
    ( Context (..), Edge (..), EdgeRequest (..), Exit (..), Story
    , Tamper (..), compareWithModel, observe, retract, tamperExit
    )

-- | Two requests booked together, before either is retracted.
requests :: wal -> (EdgeRequest wal, EdgeRequest wal)
requests owner =
    (EdgeRequest InsertActive "window-first" owner, EdgeRequest InsertActive "window-second" owner)

-- | The first request is refused before phase 2 then accepted inside it.
-- The second, booked with it by the same owner, is refused after its window.
story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry owner) = do
    let (first, second) = requests owner
    tamperExit BeforePhase2 Retract registry first >>= compared
    retract registry first >>= compared
    tamperExit AfterPhase2 Retract registry second >>= compared
  where
    compared step = do
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
