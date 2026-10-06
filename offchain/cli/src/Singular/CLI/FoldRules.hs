{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.FoldRules
Description : What decides whether, and which requests, a fold may be built
License     : Apache-2.0

The decisions of @registry fold@ that need no node and no wallet: which
pending requests a fold takes and why it leaves each other one, which edges
it folds, the envelope an insertion's request carries, whether each
request's processing window still leaves time to build one, what the model
says of the batch, and what the built fold must spend and pay. The command
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

      -- * Which requests
    , PendingRequest (..)
    , Exclusion (..)
    , SelectedRequest (..)
    , FoldSelection (..)
    , approvalVerdict
    , requestExclusion
    , selectFold
    , renderExclusion
    , leafLaw
    , FoldRefusal (..)
    , foldRequests
    , renderFoldRefusal
    , selectionDeadline
    , spendsSelection
    , unpaidOwners

      -- * Which edge
    , FoldKind (..)
    , foldKind
    , carriedEnvelope

      -- * Which funding
    , fundedView
    ) where

import Data.ByteString (ByteString)
import Data.List (intercalate, sortOn)
import Data.List.NonEmpty (NonEmpty (..), nonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import PlutusTx.Builtins (fromBuiltin)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.TxIn (TxIn)

import Singular.Application.OpenDatum.Envelope
    ( Envelope
    , envelopeFromData
    )

import Singular.Registry.TrieState (Leaf (..))

import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal (approvalDestination, approvalName)
import Singular.Registry.Types
    ( Edge
    , OnChainRequest (..)
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

-- | A request pending at the registry's request address, as a fold reads it.
data PendingRequest
    = -- | The decoded request and its processing deadline, POSIX milliseconds
      PendingDecoded OnChainRequest Integer
    | {- | The decoded request, its deadline, and the model's refusal of the
      approval its output carries ('approvalVerdict')
      -}
      PendingUnapproved OnChainRequest Integer Text
    | -- | Why its datum does not read as a request
      PendingUndecodable Text
    deriving stock (Eq, Show)

-- | Why a fold leaves a pending request out.
data Exclusion
    = {- | Its deadline is within the fold's margin or past: the milliseconds
      left, negative when it has passed
      -}
      WindowClosed Integer
    | -- | It names an edge @registry fold@ does not fold
      EdgeUnsupported Edge
    | -- | Its datum does not read as a request
      Undecodable Text
    | {- | The model refuses its step, for the model's reason: its approval, or
      the state the requests before it in the batch leave
      -}
      RefusedByLaw Text
    deriving stock (Eq, Show)

-- | A pending request a fold takes.
data SelectedRequest = SelectedRequest
    { srInput :: TxIn
    , srRequest :: OnChainRequest
    , srKind :: FoldKind
    , srDeadlineMs :: Integer
    }
    deriving stock (Eq, Show)

{- | What a fold takes and what it leaves: every pending request is in exactly
one of the two lists, each in the ledger's input order.
-}
data FoldSelection = FoldSelection
    { selIncluded :: [SelectedRequest]
    , selExcluded :: [(TxIn, Exclusion)]
    }
    deriving stock (Eq, Show)

{- | The model's refusal of the approval a request's output carries, from the
assets it holds under the registry's application policy: exactly one, at
quantity one, named 'approvalName' for this request's edge, key, owner and
destination. Anything else is @no-approval@; one named for another request is
@approval-mismatch@. The chain refuses the same outputs (@fold.ak@,
@admitted@), naming the second @approval-binding@.
-}
approvalVerdict
    :: OnChainRequest -> [(ByteString, Integer)] -> Maybe Text
approvalVerdict r = \case
    [(name, 1)]
        | name == bound -> Nothing
        | otherwise -> Just "approval-mismatch"
    _ -> Just "no-approval"
  where
    bound =
        approvalName
            (requestEdge r)
            (requestKey r)
            (fromBuiltin (requestOwner r))
            (approvalDestination (requestDestination r))

{- | The exclusion a pending request meets from its own output alone, before
any clock, state or law is read: @undecodable@ or @edge-unsupported@. A
request it names is left by 'selectFold' for that reason whatever else holds.
-}
requestExclusion :: PendingRequest -> Maybe Exclusion
requestExclusion = \case
    PendingUndecodable why -> Just (Undecodable why)
    PendingDecoded r _ -> edgeOf r
    PendingUnapproved r _ _ -> edgeOf r
  where
    edgeOf r =
        either
            (const (Just (EdgeUnsupported (requestEdge r))))
            (const Nothing)
            (foldKind (requestEdge r))

{- | The requests a fold takes, out of everything pending. In the ledger's
input order, each one is taken when it decodes, names an edge this command
folds, has more than the margin left before its deadline at @now@ (the
model's admission comes first), carries its approval, and the law accepts it
after the requests taken before it; otherwise it is left, for the first of
those it fails. Every pending request is in exactly one list.
-}
selectFold
    :: Integer
    -- ^ Now, the host's clock, POSIX milliseconds
    -> Integer
    -- ^ The margin a fold keeps clear of a deadline, milliseconds
    -> ([(ByteString, Edge)] -> Either Text ())
    -- ^ Whether the model accepts a batch, in order
    -> [(TxIn, PendingRequest)]
    -> FoldSelection
selectFold nowMs marginMs lawAdmits pending =
    go [] [] (sortOn fst pending)
  where
    go taken left [] = FoldSelection (reverse taken) (reverse left)
    go taken left ((i, p) : rest) = case judge (reverse taken) i p of
        Left why -> go taken ((i, why) : left) rest
        Right r -> go (r : taken) left rest
    judge taken i = \case
        PendingUndecodable why -> Left (Undecodable why)
        PendingDecoded r deadline -> admitted taken i r deadline Nothing
        PendingUnapproved r deadline why -> admitted taken i r deadline (Just why)
    admitted taken i r deadline unapproved = do
        kind <-
            either
                (const (Left (EdgeUnsupported (requestEdge r))))
                Right
                (foldKind (requestEdge r))
        case foldWindow marginMs nowMs deadline of
            FoldClosed left -> Left (WindowClosed left)
            FoldOpen _ -> Right ()
        maybe (Right ()) (Left . RefusedByLaw) unapproved
        either (Left . RefusedByLaw) Right $
            lawAdmits (map move taken <> [(requestKey r, requestEdge r)])
        Right (SelectedRequest i r kind deadline)
    move s = (requestKey (srRequest s), requestEdge (srRequest s))

{- | The exclusion's name, as a receipt states it: @window-closed@,
@edge-unsupported@, @undecodable@, or @refused-by-law@ and the model's reason.
-}
renderExclusion :: Exclusion -> Text
renderExclusion = \case
    WindowClosed _ -> "window-closed"
    EdgeUnsupported _ -> "edge-unsupported"
    Undecodable _ -> "undecodable"
    RefusedByLaw why -> "refused-by-law " <> why

{- | The model's verdict on a batch of the two edges @registry fold@ folds,
step by step, from the leaves the replayed tree holds before the fold and the
keys whose one active holding is live: @Singular.refusal@'s reasons for an
insertion to Active and for a termination. A key the batch inserts has no
live holding yet, so a termination of it in the same batch is
@token-missing@, although the model would admit it: the fold could not
source the burn.
-}
leafLaw
    :: Map ByteString Leaf
    -- ^ Each key's leaf before the fold; a key not here is unknown
    -> Set ByteString
    -- ^ The keys whose one active holding is live
    -> [(ByteString, Edge)]
    -> Either Text ()
leafLaw = go
  where
    go _ _ [] = Right ()
    go leaves holdings ((key, edge) : rest)
        | edge == edgeInsertActive = case before of
            Unknown -> go (Map.insert key Active leaves) holdings rest
            _ -> Left "key-exists"
        | edge == edgeUpdateTerminal = case before of
            Active
                | Set.member key holdings ->
                    go (Map.insert key Terminal leaves) (Set.delete key holdings) rest
                | otherwise -> Left "token-missing"
            Unknown -> Left "key-unknown"
            Absent -> Left "not-booked"
            Terminal -> Left "terminal-immutable"
        | otherwise = Left ("edge " <> edgeText <> " is not folded here")
      where
        before = Map.findWithDefault Unknown key leaves
        edgeText = T.pack (edgeName edge)

-- | Why a fold is not built over a selection.
data FoldRefusal
    = -- | Nothing pending is foldable: every exclusion, possibly none
      NothingToFold [(TxIn, Exclusion)]
    | -- | The named request is not among those folded, and why
      NamedNotIncluded TxIn (Maybe Exclusion)
    deriving stock (Eq, Show)

{- | The requests a fold builds over, in order, or why it builds none: nothing
foldable is pending, or a request the caller named is not among them.
-}
foldRequests
    :: Maybe TxIn
    -> FoldSelection
    -> Either FoldRefusal (NonEmpty SelectedRequest)
foldRequests named s = case nonEmpty (selIncluded s) of
    Nothing -> Left (NothingToFold (selExcluded s))
    Just taken -> case named of
        Just r
            | r `notElem` map srInput (selIncluded s) ->
                Left (NamedNotIncluded r (lookup r (selExcluded s)))
        _ -> Right taken

-- | One line naming the refusal.
renderFoldRefusal :: FoldRefusal -> String
renderFoldRefusal = \case
    NothingToFold [] -> "nothing-to-fold: nothing is pending, there is no request to fold"
    NothingToFold left ->
        "nothing-to-fold: every pending request is left out ("
            <> intercalate
                "; "
                [txt r <> " " <> T.unpack (renderExclusion why) | (r, why) <- left]
            <> "): no fold is built"
    NamedNotIncluded r Nothing ->
        "the request "
            <> txt r
            <> " is not pending: it was folded, retracted or never booked"
    NamedNotIncluded r (Just why) ->
        "the request "
            <> txt r
            <> " is not folded, "
            <> T.unpack (renderExclusion why)
            <> ": "
            <> detail why
            <> ": no fold is built"
  where
    txt = T.unpack . renderOutRef
    detail = \case
        WindowClosed left
            | left <= 0 ->
                "its processing deadline has passed, "
                    <> show (negate left `div` 1000)
                    <> " s ago"
            | otherwise ->
                "its processing deadline is only "
                    <> show (left `div` 1000)
                    <> " s ahead, within the "
                    <> show (foldMarginMs `div` 1000)
                    <> " s a fold needs to be included"
        EdgeUnsupported e ->
            "it names edge "
                <> edgeName e
                <> ", which registry fold does not fold"
        Undecodable why -> T.unpack why
        RefusedByLaw why -> "the model refuses its step, " <> T.unpack why

-- | The deadline that bounds a fold over the selected requests: the earliest.
selectionDeadline :: NonEmpty SelectedRequest -> Integer
selectionDeadline = minimum . fmap srDeadlineMs

{- | Whether a built fold spends the registry's state and exactly the selected
requests among those pending, beside whatever else funds it; otherwise why not.
-}
spendsSelection
    :: TxIn
    -- ^ The registry's state output
    -> [TxIn]
    -- ^ The selected requests
    -> [TxIn]
    -- ^ Every pending request
    -> [TxIn]
    -- ^ What the built fold spends
    -> Either String ()
spendsSelection state selected pending spent
    | state `notElem` spent =
        Left
            ( "the built fold does not spend the registry's state output "
                <> txt state
            )
    | spentRequests /= Set.fromList selected =
        Left
            ( "the built fold spends the requests ["
                <> intercalate ", " (map txt (Set.toList spentRequests))
                <> "], not exactly the selected ["
                <> intercalate ", " (map txt selected)
                <> "]"
            )
    | otherwise = Right ()
  where
    spentRequests = Set.fromList [i | i <- spent, i `elem` pending]
    txt = T.unpack . renderOutRef

{- | The owners a fold pays less than it owes them, with what it owes and pays:
what several requests owe one owner is summed, and so is what the fold's
outputs pay that owner.
-}
unpaidOwners
    :: [(ByteString, Integer)]
    -- ^ What is owed, per owner
    -> [(ByteString, Integer)]
    -- ^ What is paid, per owner
    -> [(ByteString, Integer, Integer)]
unpaidOwners owed paid =
    [ (owner, due, got)
    | (owner, due) <- Map.toList (Map.fromListWith (+) owed)
    , let got = Map.findWithDefault 0 owner (Map.fromListWith (+) paid)
    , got < due
    ]

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
    -> Cage.Session Cage.NoWitness IO
    -> IO (Either String (Cage.Session Cage.NoWitness IO))
fundedView Nothing _ v = pure (Right v)
fundedView chosen addr v = do
    wallet <- Cage.outputsAt v addr
    pure $ case selectFunding chosen wallet of
        Left why -> Left why
        Right one ->
            Right
                v
                    { Cage.outputs = \query ->
                        fmap (fmap (select query one)) (Cage.outputs v query)
                    }
  where
    select (Cage.AtAddress address) one fact
        | address == addr =
            fact{Cage.value = filter ((== fst one) . fst) (Cage.value fact)}
    select _ _ fact = fact

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

{- | The envelope an insertion's request carries for its delivered output
(#419), read off the request on the chain and never off a file, so any
wallet can fold the insertion.
-}
carriedEnvelope :: OnChainRequest -> Either String Envelope
carriedEnvelope req = case snd (requestDestination req) of
    Nothing ->
        Left
            "the insertion's request carries no envelope: its delivered output would hold none"
    Just datum ->
        either
            ( \why ->
                Left
                    ("the envelope the insertion's request carries cannot be read: " <> why)
            )
            Right
            (envelopeFromData datum)
