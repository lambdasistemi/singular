{- | Early rejection (#320): a folder rejects, before its owner's retraction deadline,
a request that cannot be folded. The model admits the rejection with bound lifecycle
mismatch evidence; each owes the owner the deposit back.
-}
module Conformance.Edge.EarlyReject (story, requests) where

import Conformance.Story.Live
    ( Context (..)
    , Edge (..)
    , EdgeRequest (..)
    , Placement (..)
    , Story
    , Tamper (..)
    , compareWithModel
    , observe
    , rejectWithin
    , submit
    , tamperRejectWithin
    )

-- | Two insertion requests booked together, before either is rejected.
requests :: wal -> (EdgeRequest wal, EdgeRequest wal)
requests owner =
    ( EdgeRequest InsertActive "early-processing" owner
    , EdgeRequest InsertActive "early-retraction" owner
    )

{- | Each key is registered Active in this run, then a second request for the same key
is rejected while it can still be folded (first key) or while its owner can still
retract it (second key). In each window a reject refunding the owner one lovelace
short and one refunding another key are refused by both for the refund reason and leave
the request pending; the untampered reject of the same request, with lifecycle mismatch
evidence, is accepted by both as their control.
-}
story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry owner) = do
    let (first, second) = requests owner
    submit registry first >>= compared
    submit registry second >>= compared
    tamperRejectWithin ShortByOne InProcessingWindow registry first
        >>= compared
    tamperRejectWithin OtherAddress InProcessingWindow registry first
        >>= compared
    rejectWithin InProcessingWindow registry first >>= compared
    tamperRejectWithin ShortByOne InRetractionWindow registry second
        >>= compared
    tamperRejectWithin OtherAddress InRetractionWindow registry second
        >>= compared
    rejectWithin InRetractionWindow registry second >>= compared
  where
    compared step = do
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
