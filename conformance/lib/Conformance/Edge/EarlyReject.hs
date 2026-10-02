{- | Early rejection (#320): a folder rejects a pending request before its
owner's retraction deadline. The model gives a reject no admission, so a reject
is accepted in every window; each owes the owner the deposit back.
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
    , tamperRejectWithin
    )

-- | Two insertion requests booked together, before either is rejected.
requests :: wal -> (EdgeRequest wal, EdgeRequest wal)
requests owner =
    ( EdgeRequest InsertActive "early-processing" owner
    , EdgeRequest InsertActive "early-retraction" owner
    )

{- | The first request is rejected while it can still be folded, the second
while its owner can still retract it. In each window a reject refunding the
owner one lovelace short and one refunding another key are refused and leave
the request pending; the untampered reject of the same request is their
control.
-}
story :: Context reg wal -> Story reg wal step obs cmp ()
story (Context registry owner) = do
    let (first, second) = requests owner
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
