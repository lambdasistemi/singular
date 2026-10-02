{- | A request that is never folded: a folder rejects it after its owner's
retraction window has closed, or its owner retracts it. Each owes the owner the
deposit back, and a retraction the tip too, through an output bound to the
request it retracts.
-}
module Conformance.Edge.Exit (story) where

import Conformance.Story.Live
    ( Context (Context)
    , Edge (..)
    , EdgeRequest (..)
    , Exit (..)
    , Placement (..)
    , Story
    , Tamper (..)
    , compareWithModel
    , observe
    , rejectWithin
    , retract
    , tamperExit
    , tamperRejectWithin
    )

{- | Reject in one registry, retract in another: the rejection registry's
rejects are placed after their owner's retraction window, which closes a
second after it opens; the retraction registry's requests stay retractable long
enough to be retracted. Rejects inside the windows are the early rejection
story's. Each tampered exit is refused and leaves its request pending; the
untampered one is its control. An update request cannot be retracted, and an
insertion cannot be retracted without its owner's signature; the owner-signed
insertion is their control.
-}
story
    :: Context reg wal -> Context reg wal -> Story reg wal step obs cmp ()
story (Context rejection holder) (Context retraction _) = do
    let rejected = EdgeRequest InsertActive "rejected" holder
    tamperRejectWithin ShortByOne AfterTheWindows rejection rejected
        >>= compared
    tamperRejectWithin OtherAddress AfterTheWindows rejection rejected
        >>= compared
    rejectWithin AfterTheWindows rejection rejected >>= compared
    let retracted = EdgeRequest InsertActive "retracted" holder
    tamperExit ShortByOne Retract retraction retracted >>= compared
    tamperExit OtherAddress Retract retraction retracted >>= compared
    tamperExit OtherReference Retract retraction retracted >>= compared
    tamperExit StateSpent Retract retraction retracted >>= compared
    retract
        retraction
        (EdgeRequest UpdateTerminal "pending-update" holder)
        >>= compared
    tamperExit Unsigned Retract retraction retracted >>= compared
    retract retraction retracted >>= compared
  where
    compared step = do
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
