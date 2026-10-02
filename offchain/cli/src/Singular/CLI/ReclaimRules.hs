{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.ReclaimRules
Description : Whether the owner's pending request may be reclaimed
License     : Apache-2.0

Reuses the request-window reading that reject uses. Only the acquired
view's tip and deadline conversions decide admission. Opening needs a
converted processing deadline; an unconverted retract deadline remains open.
-}
module Singular.CLI.ReclaimRules
    ( ReclaimRefusal (..)
    , reclaimGate
    , renderReclaimRefusal
    , reclaimValidity
    , UpperLimit (..)
    ) where

import Singular.CLI.RejectRules (windowStatus)
import Singular.CLI.RequestWindow (Bounds (..))
import Singular.Registry.Types
    ( Edge
    , edgeInsertAbsent
    , edgeInsertActive
    , edgeName
    , edgeWitnessTerminal
    )

-- | Why no reclaim is built.
data ReclaimRefusal
    = NotPending
    | NotRetractable Edge
    | NotOwner
    | BeforeWindow Bounds Integer Integer
    | WindowClosed Bounds Integer Integer
    | WindowUnconverted Bounds (Maybe Integer) (Maybe Integer)
    deriving stock (Eq, Show)

{- | Decide from the caller and the named pending request: owner, edge,
bounds and their converted slots, followed by this view's tip slot.
-}
reclaimGate
    :: (Eq owner)
    => owner
    -> Maybe (owner, Edge, Bounds, Maybe Integer, Maybe Integer)
    -> Integer
    -> Either ReclaimRefusal Bounds
reclaimGate _ Nothing _ = Left NotPending
reclaimGate caller (Just (owner, edge, bounds, opens, closes)) tip
    | edge
        `notElem` [edgeInsertAbsent, edgeInsertActive, edgeWitnessTerminal] =
        Left (NotRetractable edge)
    | caller /= owner = Left NotOwner
    | Left end <- windowStatus tip closes =
        Left (WindowClosed bounds tip end)
    | Just start <- opens
    , tip < start =
        Left (BeforeWindow bounds tip start)
    | Just _ <- opens = Right bounds
    | otherwise = Left (WindowUnconverted bounds opens closes)

{- | Proof of the built upper bound: the deadline's slot, or the time at
which the bound's slot begins as converted by the acquired view.
-}
data UpperLimit
    = DeadlineSlot Integer
    | DeadlineTime Integer (Maybe Integer)
    deriving stock (Eq, Show)

{- | A finite, nonempty built interval inside the window. When the deadline
is unconverted, the built bound must still be placed in time by the view.
-}
reclaimValidity
    :: Integer -> UpperLimit -> Maybe Integer -> Maybe Integer -> Bool
reclaimValidity start limit (Just lo) (Just hi) =
    start <= lo && lo < hi && case limit of
        DeadlineSlot end -> hi <= end
        DeadlineTime end boundTime -> maybe False (<= end) boundTime
reclaimValidity _ _ _ _ = False

-- | A named refusal with the window's bounds when known.
renderReclaimRefusal :: ReclaimRefusal -> String
renderReclaimRefusal = \case
    NotPending -> "the named request is not pending in this registry"
    NotRetractable e ->
        "withdraw-insert-only: a pending "
            <> edgeName e
            <> " request cannot be reclaimed"
    NotOwner -> "retract-owner: this wallet is not the request's owner"
    BeforeWindow b tip start ->
        "the retract window opens at "
            <> show (processingEnds b)
            <> " ms (slot "
            <> show start
            <> "), and closes at "
            <> show (retractEnds b)
            <> " ms; this view's tip is slot "
            <> show tip
            <> ", before the window"
    WindowClosed b tip end ->
        "the retract window opened at "
            <> show (processingEnds b)
            <> " ms and closed at "
            <> show (retractEnds b)
            <> " ms (slot "
            <> show end
            <> "); this view's tip is slot "
            <> show tip
            <> "; registry reject clears expired pending requests"
    WindowUnconverted b _ _ ->
        "the retract window opens at "
            <> show (processingEnds b)
            <> " ms and closes at "
            <> show (retractEnds b)
            <> " ms; before the window: this view cannot convert the processing deadline to a slot, so its opening is not proved"
