{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.FoldRules
Description : What decides whether, and which request, a fold may be built
License     : Apache-2.0

The decisions of @registry fold@ that need no node and no wallet: which
pending request a fold takes, which edges it folds, and whether the
request's processing window still leaves time to build one. The command
("Singular.CLI.Fold") reads the chain and asks these; the booking's
receipt ("Singular.CLI.Entry") states the same deadline from the same
function, so a requester and a folder never disagree about it.
-}
module Singular.CLI.FoldRules
    ( -- * The processing window
      libraryFallbackMs
    , foldMarginMs
    , requestDeadline
    , FoldWindow (..)
    , foldWindow
    , PostBuild (..)
    , PostBuildRefusal (..)
    , BoundBasis (..)
    , postBuildCheck
    , boundStartMs
    , boundStartTime
    , postBuildDecision
    , placedEdge

      -- * Which request
    , FoldTargetRefusal (..)
    , foldTarget
    , renderTargetRefusal

      -- * Which edge
    , FoldKind (..)
    , foldKind

      -- * Which funding
    , fundedView
    ) where

import Data.List (intercalate)
import Data.Text qualified as T

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.Types
    ( Edge
    , edgeInsertActive
    , edgeName
    , edgeUpdateTerminal
    )

{- | The widest validity bound the library gives a fold when it cannot place
the request's deadline in the node's horizon: it tries now plus 30, 5 and 2
seconds, in that order. A fold started more than this before the deadline is
bounded before the deadline either way.
-}
libraryFallbackMs :: Integer
libraryFallbackMs = 30_000

{- | How long a fold keeps clear of its request's processing deadline, judged on
the host's UTC clock at the decision: never less than 'libraryFallbackMs'.
A fold started within it of the deadline is not built, because the
transaction it would build could not be included before the deadline. In
milliseconds, so it means the same on a network of any slot length.
-}
foldMarginMs :: Integer
foldMarginMs = libraryFallbackMs

{- | A request's processing deadline, in POSIX milliseconds: its submission
time plus the processing time its registry's state records. A fold must
be included before it; the protocol bound the fold's validity interval
already ends at.
-}
requestDeadline
    :: Integer
    -- ^ The request's submission time
    -> Integer
    -- ^ The registry's processing time
    -> Integer
requestDeadline submittedAt processTime = submittedAt + processTime

-- | Whether a fold started now still has time before the deadline.
data FoldWindow
    = -- | Milliseconds left before the deadline, more than the margin
      FoldOpen Integer
    | {- | Milliseconds left before the deadline: the margin or fewer, none,
      or, when negative, how long ago it passed
      -}
      FoldClosed Integer
    deriving stock (Eq, Show)

{- | The window a fold has: the margin, now (the host's UTC clock), and the
deadline, all in POSIX milliseconds. It is judged in time, not in slots: a
node converts a time to a slot only inside its horizon, which on a
development network ends well before a request's deadline.
-}
foldWindow :: Integer -> Integer -> Integer -> FoldWindow
foldWindow margin now deadline
    | left > margin = FoldOpen left
    | otherwise = FoldClosed left
  where
    left = deadline - now

{- | What the built fold's validity upper bound is checked against.

The ledger's upper bound (@invalidHereafter@) is exclusive: a transaction is
included only at slots strictly below it, and the script reads the range's
endpoint as exclusive too — @interval.is_entirely_before@ requires @hi <=
point@ for an exclusive upper bound, with @point = submitted_at +
process_time@ (@onchain/validators/shared.ak@, @in_phase1@). A bound @U@
therefore admits the fold when the time at which slot @U@ begins is at or
before the deadline; when the view converts the deadline to its slot @S@
(floor), that is exactly @U <= S@, and the library's own bound is @S@
('computeUpperSlot' converts the deadline with the view's floor).
-}
data BoundBasis
    = -- | @invalidHereafter <= S@ for the deadline's slot @S@ (equality admitted)
      BoundByDeadlineSlot
    | -- | The bound's converted time is at or before the deadline time
      BoundByTime
    deriving stock (Eq, Show)

-- | Why a built fold is not signed.
data PostBuildRefusal
    = -- | The built fold carries no upper bound
      NoUpperBound
    | -- | The host clock after the build is within the margin of the deadline
      ClockWithinMargin
    | -- | The bound is after the deadline's slot (the bound, then the slot)
      BoundBeyondDeadlineSlot Integer Integer
    | -- | The deadline has no slot and the bound cannot be converted to a time
      BoundUnconvertible
    | -- | The deadline has no slot and the bound's time is after the deadline
      BoundAfterDeadline Integer
    deriving stock (Eq, Show)

-- | The verdict on a built fold, before it is signed.
data PostBuild
    = PostBuildAdmitted BoundBasis
    | PostBuildRefused PostBuildRefusal
    deriving stock (Eq, Show)

{- | Judge a built fold from its own body: the host clock after the build, the
deadline time, the deadline's slot when the view converts it, the body's
upper bound and, when the deadline has no slot, the time at which the bound's
slot begins as the same view converts it. Nothing is estimated: a bound that
cannot be compared is refused.
-}
postBuildCheck
    :: Integer
    -- ^ The host clock after the build, POSIX milliseconds
    -> Integer
    -- ^ The deadline, POSIX milliseconds
    -> Maybe Integer
    -- ^ The deadline's slot in the view, when it converts it
    -> Maybe Integer
    -- ^ The built fold's @invalidHereafter@
    -> Maybe Integer
    -- ^ The time that bound's slot begins, when the view converts it
    -> PostBuild
postBuildCheck now deadline deadlineSlot upper boundTime = case upper of
    Nothing -> PostBuildRefused NoUpperBound
    Just u
        | now + foldMarginMs >= deadline -> PostBuildRefused ClockWithinMargin
        | Just s <- deadlineSlot ->
            if u <= s
                then PostBuildAdmitted BoundByDeadlineSlot
                else PostBuildRefused (BoundBeyondDeadlineSlot u s)
        | otherwise -> case boundTime of
            Nothing -> PostBuildRefused BoundUnconvertible
            Just t
                | t <= deadline -> PostBuildAdmitted BoundByTime
                | otherwise -> PostBuildRefused (BoundAfterDeadline t)

{- | The time at which a slot begins, found by asking the view only what it
can answer: the earliest time in @(lo, hi]@ the view places at or after the
slot, when it places @lo@ before the slot and @hi@ at or after it; nothing
otherwise. Bisection over the view's own conversion, so no slot length or
system start is assumed.

The answer rests only on what the view said: a time is returned only when the
view placed it at or after the slot and placed the time before it before the
slot. A probe the view cannot place anywhere on the way ends the search with
nothing; it is never read as an ordering.
-}
boundStartMs
    :: (Monad m)
    => (Integer -> m (Maybe Integer))
    -- ^ The view's conversion of a time to a slot
    -> Integer
    -- ^ A time the view places before the slot
    -> Integer
    -- ^ A time the view places at or after the slot
    -> Integer
    -- ^ The slot
    -> m (Maybe Integer)
boundStartMs slotOf lo0 hi0 slot = do
    atLo <- slotOf lo0
    atHi <- slotOf hi0
    case (atLo, atHi) of
        (Just a, Just b)
            | a < slot && b >= slot && lo0 < hi0 -> go lo0 hi0
        _ -> pure Nothing
  where
    go lo hi
        | hi - lo <= 1 = pure (Just hi)
        | otherwise = do
            let mid = lo + (hi - lo) `div` 2
            placed <- slotOf mid
            case placed of
                Just m | m >= slot -> go lo mid
                Just _ -> go mid hi
                Nothing -> pure Nothing

-- | Why a fold has no request to take.
data FoldTargetRefusal
    = NothingPending
    | -- | The request the caller named is not pending
      NotPending TxIn
    | -- | Every pending request: a fold takes them all, and takes one
      SeveralPending [TxIn]
    deriving stock (Eq, Show)

{- | The one pending request a fold takes, or why there is none. The
production fold takes every request pending for the registry, so a fold
is built only while exactly one is pending, and a request the caller
named must be that one.
-}
foldTarget :: Maybe TxIn -> [TxIn] -> Either FoldTargetRefusal TxIn
foldTarget named pending = case (pending, named) of
    ([], _) -> Left NothingPending
    (_, Just r) | r `notElem` pending -> Left (NotPending r)
    ([one], _) -> Right one
    _ -> Left (SeveralPending pending)

-- | One line naming the refusal.
renderTargetRefusal :: FoldTargetRefusal -> String
renderTargetRefusal = \case
    NothingPending -> "nothing is pending: there is no request to fold"
    NotPending r ->
        "the request "
            <> txt r
            <> " is not pending: it was folded, retracted or never booked"
    SeveralPending rs ->
        "more than one request is pending ("
            <> intercalate ", " (map txt rs)
            <> "); the registry's fold takes every pending request, so it is built only while exactly one is pending"
  where
    txt = T.unpack . renderOutRef

-- | The edges @registry fold@ folds.
data FoldKind = FoldInsertion | FoldTermination
    deriving stock (Eq, Show)

-- | The kind a request's edge is, or why it is not one this command folds.
foldKind :: Edge -> Either String FoldKind
foldKind e
    | e == edgeInsertActive = Right FoldInsertion
    | e == edgeUpdateTerminal = Right FoldTermination
    | otherwise =
        Left
            ( "the request names edge "
                <> edgeName e
                <> ", which registry fold does not fold: it folds insertActive and updateTerminal"
            )

{- | A view in which the wallet's own address holds only the output the caller
named to fund the fold: the production fold funds and collateralises from
the largest ada-only output of the wallet it reads, and takes no funding
argument. The named output must be an ada-only output of that wallet. With
none named the view is the fold's own.
-}
fundedView
    :: Maybe TxIn
    -> Addr
    -> Cage.View IO
    -> IO (Either String (Cage.View IO))
fundedView Nothing _ v = pure (Right v)
fundedView chosen addr v = do
    wallet <- Cage.viewUTxOsAt v addr
    pure $ case selectFunding chosen wallet of
        Left why -> Left why
        Right one ->
            Right
                v
                    { Cage.viewUTxOsAt = \a ->
                        if a == addr then pure [one] else Cage.viewUTxOsAt v a
                    }

{- | The time at which a built fold's upper-bound slot begins, as the view
that built it converts times; nothing when it cannot place the bound.

The bound is the view's conversion of a time within 'libraryFallbackMs' of
the library's clock reading, which is no later than the host's clock @now@
here, so the bound's start lies within 'libraryFallbackMs' of @now@, and the
view placed that time, so it lies inside the view's horizon. The search for
the bound's start therefore uses only times the view places: its high end is
the latest time in that reach the view places ('placedEdge'), never a time
beyond its horizon, which it could only answer with nothing.
-}
boundStartTime
    :: (Monad m)
    => (Integer -> m (Maybe Integer))
    -- ^ The view's conversion of a time to a slot
    -> Integer
    -- ^ The host clock after the build, POSIX milliseconds
    -> Integer
    -- ^ The built fold's @invalidHereafter@
    -> m (Maybe Integer)
boundStartTime slotOf now u = firstJust attempts
  where
    attempts =
        [ placedEdge slotOf now (now + libraryFallbackMs)
            >>= maybe (pure Nothing) (\hi -> boundStartMs slotOf (now - before) hi u)
        | before <- [60_000, 10_000, 1_000]
        ]
    firstJust [] = pure Nothing
    firstJust (a : rest) =
        a >>= \found -> maybe (firstJust rest) (pure . Just) found

{- | The latest time in @[lo, hi]@ the view places in a slot, found by asking
only the view: @hi@ itself when it places it; otherwise, from a placed @lo@,
the edge of what it places, by bisection. Nothing when it places neither
@lo@ nor @hi@. A time is returned only if the view placed it.
-}
placedEdge
    :: (Monad m)
    => (Integer -> m (Maybe Integer))
    -> Integer
    -> Integer
    -> m (Maybe Integer)
placedEdge slotOf lo0 hi0 = do
    atHi <- slotOf hi0
    case atHi of
        Just _ -> pure (Just hi0)
        Nothing -> do
            atLo <- slotOf lo0
            case atLo of
                Nothing -> pure Nothing
                Just _ -> go lo0 hi0
  where
    -- lo is placed by the view, hi is not
    go lo hi
        | hi - lo <= 1 = pure (Just lo)
        | otherwise = do
            let mid = lo + (hi - lo) `div` 2
            placed <- slotOf mid
            case placed of
                Just _ -> go mid hi
                Nothing -> go lo mid

{- | The verdict on a built fold, from what the build left and what the view
and the clock say: the host clock after the build, the deadline time, the
deadline's slot when the view converts it, the built body's upper bound, and
the view's conversion of a time to a slot. When the deadline has no slot the
bound is placed in time first, by 'boundStartTime', and a bound the view
cannot place gives the verdict that refuses it. It returns the time the bound
begins at, when it was placed, beside the verdict. This is the one decision
the fold takes before signing; "Singular.CLI.Fold" refuses unsigned on a
refusal.
-}
postBuildDecision
    :: (Monad m)
    => (Integer -> m (Maybe Integer))
    -- ^ The view's conversion of a time to a slot
    -> Integer
    -- ^ The host clock after the build, POSIX milliseconds
    -> Integer
    -- ^ The deadline, POSIX milliseconds
    -> Maybe Integer
    -- ^ The deadline's slot in the view, when it converts it
    -> Maybe Integer
    -- ^ The built fold's @invalidHereafter@
    -> m (PostBuild, Maybe Integer)
postBuildDecision slotOf now deadline deadlineSlot upper = do
    boundTime <- case (deadlineSlot, upper) of
        (Nothing, Just u) -> boundStartTime slotOf now u
        _ -> pure Nothing
    pure
        (postBuildCheck now deadline deadlineSlot upper boundTime, boundTime)
