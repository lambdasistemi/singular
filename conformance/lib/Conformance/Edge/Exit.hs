-- | A request that is never folded: a folder rejects it once it may no longer be
-- folded, or its owner retracts it. Each owes the owner the deposit back, and a
-- retraction the tip too, through an output bound to the request it retracts.
module Conformance.Edge.Exit (story) where

import Conformance.Story.Live
    ( Context (Context), Edge (..), EdgeRequest (..), Exit (..), Story
    , Tamper (..), compareWithModel, observe, reject, retract, tamperExit
    )

{- | Reject in one registry, retract in another: the rejection registry's
requests become rejectable moments after they are booked, the retraction
registry's stay retractable long enough to be retracted. Each tampered exit is
refused and leaves its request pending; the untampered one is its control.
Only an insertion is retracted: the chain admits no other retraction until
#239 states which requests are retractable.
-}
story :: Context reg wal -> Context reg wal -> Story reg wal step obs cmp ()
story (Context rejection holder) (Context retraction _) = do
    let rejected = EdgeRequest InsertActive "rejected" holder
    tamperExit ShortByOne Reject rejection rejected >>= compared
    tamperExit OtherAddress Reject rejection rejected >>= compared
    reject rejection rejected >>= compared
    let retracted = EdgeRequest InsertActive "retracted" holder
    tamperExit ShortByOne Retract retraction retracted >>= compared
    tamperExit OtherAddress Retract retraction retracted >>= compared
    tamperExit OtherReference Retract retraction retracted >>= compared
    tamperExit StateSpent Retract retraction retracted >>= compared
    retract retraction retracted >>= compared
  where
    compared step = do
        observation <- observe step
        _ <- compareWithModel step observation
        pure ()
