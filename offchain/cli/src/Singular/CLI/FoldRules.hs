{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.CLI.FoldRules
Description : What decides whether, and which request, a fold may be built
License     : Apache-2.0

The decisions of @registry fold@ that need no node and no wallet: which
pending request a fold takes, which edges it folds, the envelope an
insertion's request carries, and whether the request's processing window
still leaves time to build one. The command
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

      -- * Which requests take the selection (#518)
    , FoldRequestsRefusal (..)
    , foldRequests
    , renderFoldRequestsRefusal
    , refuseNamedEdgeEarly
    , SpendsRefusal (..)
    , spendsSelection
    , renderSpendsRefusal

      -- * Which edge
    , FoldKind (..)
    , foldKind
    , checkCarriedDatum

      -- * Selection inputs (#518, pure adapters)
    , requestEdgeKind
    , requestOwnerText
    , pendingDeadlineOf
    , approvalCheckOf
    , appVerdictOf
    , neutralAppExecutable
    , pendingRequestOf
    , assignKeyInts
    , assignRefPairing
    , buildPendingRequests
    , buildLiveFacts

      -- * Additive receipt lists (#518, pull request 1)
    , SettledForReceipt (..)
    , foldReceiptLists
    , EarlierDelivery (..)
    , EarlierReceipt (..)
    , earlierReceiptFields
    , combineReceiptFields
    , combineWindowClosedMessage
    , holdsActiveToken

      -- * Which funding
    , fundedView
    ) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import PlutusCore.Data qualified as PLC

import Singular.Registry.Application
    ( Application (..)
    , HoldingRules (..)
    )

import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.FoldSelection
    ( AppVerdict (..)
    , ApprovalCheck (..)
    , EdgeKind (..)
    , Exclusion (..)
    , Leaf (..)
    , LiveFacts
    , PendingRequest (..)
    , SelectedRequest (..)
    , Selection (..)
    , exclusionName
    , exclusionSource
    )
import Singular.Registry.Ledger (AssetName (..), ConwayEra)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.Registry.TxBuilder.Internal.Edges
    ( approvalDestination
    , approvalName
    )
import Singular.Registry.TxBuilder.Internal.Identity
    ( extractOwnerBytes
    , scriptHashBytes
    )
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

{- | The datum an insertion's request carries for its delivered output
(#419), read off the request on the chain and never off a file, so any
wallet can fold the insertion. Through the value: the open datum checks
it is an envelope; the neutral value takes the request's own datum
unchanged (decoding nothing).
-}
checkCarriedDatum
    :: Application -> OnChainRequest -> Either String PLC.Data
checkCarriedDatum app req = case appHolding app of
    Just rules -> case hrCheckCarried rules req of
        Left why -> Left (T.unpack why)
        Right datum -> Right datum
    Nothing -> case snd (requestDestination req) of
        Nothing ->
            Left
                "the insertion's request carries no datum: its delivered output would hold none"
        Just datum -> Right datum

-- ---------------------------------------------------------
-- Which requests take the selection (#518)
-- ---------------------------------------------------------

{- | Why a fold that takes the selection has no settled request, or why a
named request is not among them. The selection works in its own 'Int'
references; the caller passes the pairing of output references with those
in ledger input order, so every exclusion is named with the output
reference the command prints. 'FoldInconsistentInput' carries the listed
references without pairing and the paired outputs listed nowhere; it fires
before any other refusal except on fully consistent inputs.
-}
data FoldRequestsRefusal
    = FoldNothingPending
    | FoldNamedNotPending TxIn
    | FoldNamedExcluded TxIn Exclusion
    | FoldNothingToFold [(TxIn, Exclusion)]
    | FoldInconsistentInput [Int] [TxIn]
    | FoldNamedNothingSettled TxIn (Maybe Exclusion) [(TxIn, Exclusion)]
    deriving stock (Eq, Show)

{- | The settled requests a fold takes: the optional named expectation, the
pairing of output references with the selection's own references in ledger
input order, and the selection. A named request that is settled returns
exactly the settled list; a named request that is excluded or not pending
is refused with its reason; nothing settleable lists every exclusion. When
nothing settles and a request is named, the refusal states the named cause
and every other exclusion ('FoldNamedNothingSettled'); with nothing pending
it states both causes.

Final signature (the authorized addition to the functions model row, which
lists only the named request and the selection): the pairing is the second
argument, [(TxIn, Int)] in ledger input order.
-}
foldRequests
    :: Maybe TxIn
    -> [(TxIn, Int)]
    -> Selection
    -> Either FoldRequestsRefusal (NonEmpty TxIn)
foldRequests named pairing sel =
    let intToTx = [(r, tx) | (tx, r) <- pairing]
        lookupTx r = lookup r intToTx
        pairedInts = map snd pairing
        settledRefs = map selRef (selectionSettled sel)
        excludedRefs = map (prRef . fst) (selectionExcluded sel)
        listedRefs = settledRefs ++ excludedRefs
        missingPairing = [r | r <- listedRefs, r `notElem` pairedInts]
        extraPairingTxs = [tx | (tx, r) <- pairing, r `notElem` listedRefs]
    in  if not (null missingPairing) || not (null extraPairingTxs)
            then Left (FoldInconsistentInput missingPairing extraPairingTxs)
            else
                let settledTxs = [tx | ref <- settledRefs, Just tx <- [lookupTx ref]]
                    excludedTxs =
                        [ (tx, exc)
                        | (q, exc) <- selectionExcluded sel
                        , Just tx <- [lookupTx (prRef q)]
                        ]
                in  case settledTxs of
                        [] -> case (pairing, named) of
                            ([], Nothing) -> Left FoldNothingPending
                            ([], Just r) -> Left (FoldNamedNothingSettled r Nothing [])
                            (_, Nothing) -> Left (FoldNothingToFold excludedTxs)
                            (_, Just r)
                                | r `notElem` map fst pairing ->
                                    Left (FoldNamedNothingSettled r Nothing excludedTxs)
                                | otherwise -> case [exc | (tx, exc) <- excludedTxs, tx == r] of
                                    (exc : _) ->
                                        let others = [x | x@(tx, _) <- excludedTxs, tx /= r]
                                        in  if null others
                                                then Left (FoldNamedExcluded r exc)
                                                else
                                                    Left
                                                        ( FoldNamedNothingSettled
                                                            r
                                                            (Just exc)
                                                            others
                                                        )
                                    [] -> Left (FoldNamedNotPending r)
                        (x : xs) -> case named of
                            Nothing -> Right (x :| xs)
                            Just r
                                | r `notElem` map fst pairing -> Left (FoldNamedNotPending r)
                                | r `elem` (x : xs) -> Right (x :| xs)
                                | otherwise -> case [exc | (tx, exc) <- excludedTxs, tx == r] of
                                    (exc : _) -> Left (FoldNamedExcluded r exc)
                                    [] -> Left (FoldNamedNotPending r)

-- | One line naming the refusal, plus one line per exclusion.
renderFoldRequestsRefusal :: FoldRequestsRefusal -> String
renderFoldRequestsRefusal = \case
    FoldNothingPending -> "nothing is pending: there is no request to fold"
    FoldNamedNotPending r ->
        "the request "
            <> txt r
            <> " is not pending: it was folded, retracted or never booked"
    FoldNamedExcluded r exc ->
        "the request "
            <> txt r
            <> " is excluded: "
            <> T.unpack (exclusionName exc)
            <> " ("
            <> T.unpack (exclusionSource exc)
            <> "): "
            <> T.unpack (excDetail exc)
    FoldNothingToFold xs ->
        "nothing to fold: every pending request is excluded"
            <> concatMap
                ( \(r, exc) ->
                    "\n"
                        <> txt r
                        <> ": "
                        <> T.unpack (exclusionName exc)
                        <> " ("
                        <> T.unpack (exclusionSource exc)
                        <> "): "
                        <> T.unpack (excDetail exc)
                )
                xs
    FoldInconsistentInput missing extra -> case (missing, extra) of
        ([], []) ->
            "the fold selection does not match the pending outputs: no reference to name"
        (_, []) ->
            "the fold selection does not match the pending outputs: listed without pairing "
                <> intercalate ", " (map show missing)
        ([], _) ->
            "the fold selection does not match the pending outputs: paired without listing "
                <> intercalate ", " (map txt extra)
        (_, _) ->
            "the fold selection does not match the pending outputs: listed without pairing "
                <> intercalate ", " (map show missing)
                <> "; paired without listing "
                <> intercalate ", " (map txt extra)
    FoldNamedNothingSettled r mExc others ->
        let cause = case mExc of
                Just exc -> renderFoldRequestsRefusal (FoldNamedExcluded r exc)
                Nothing -> renderFoldRequestsRefusal (FoldNamedNotPending r)
        in  case (mExc, others) of
                (Just _, []) -> cause
                (_, []) -> cause <> "\n" <> renderFoldRequestsRefusal FoldNothingPending
                (_, _) ->
                    cause
                        <> "\n"
                        <> renderFoldRequestsRefusal (FoldNothingToFold others)
  where
    txt = T.unpack . renderOutRef

{- | Whether the fold refuses a named request's untakeable edge at once,
before the selection runs and before any other pending request is read:
only when that request is the only one pending, so the early refusal has no
other exclusion to name. Consulted only after the named request was found
pending and its edge was refused by 'foldKind'; every other case goes
through the selection and 'foldRequests', whose refusal names the named
request's cause and every other exclusion.
-}
refuseNamedEdgeEarly :: Maybe TxIn -> [TxIn] -> Bool
refuseNamedEdgeEarly (Just r) pendings = pendings == [r]
refuseNamedEdgeEarly Nothing _ = False

-- | Why a built fold does not spend exactly the selection.
data SpendsRefusal
    = SpendsMissingState TxIn
    | SpendsMissingSelected [TxIn]
    | SpendsExtraPending [TxIn]
    deriving stock (Eq, Show)

{- | Whether a built transaction spends the state output and exactly the
selected request outputs among those pending: the state output reference,
the selected references, the pending references and the spent references.
References that are not pending (funding and collateral) are free.
-}
spendsSelection
    :: TxIn
    -> [TxIn]
    -> [TxIn]
    -> [TxIn]
    -> Either SpendsRefusal ()
spendsSelection state selected pending spent
    | state `notElem` spent = Left (SpendsMissingState state)
    | not (null missingSel) = Left (SpendsMissingSelected missingSel)
    | not (null extra) = Left (SpendsExtraPending extra)
    | otherwise = Right ()
  where
    missingSel = [r | r <- selected, r `notElem` spent]
    others = [p | p <- pending, p `notElem` selected]
    extra = [p | p <- others, p `elem` spent]

-- | One line naming the offending references.
renderSpendsRefusal :: SpendsRefusal -> String
renderSpendsRefusal = \case
    SpendsMissingState s ->
        "the built fold does not spend the registry state output " <> txt s
    SpendsMissingSelected ms ->
        "the built fold does not spend the selected requests: "
            <> intercalate ", " (map txt ms)
    SpendsExtraPending es ->
        "the built fold spends pending requests it was not given: "
            <> intercalate ", " (map txt es)
  where
    txt = T.unpack . renderOutRef

-- ---------------------------------------------------------
-- Selection inputs (#518, pure adapters)
-- ---------------------------------------------------------

{- | The request's edge as the selection's edge kind: the two admitted
edges map to themselves, any other edge maps to other carrying the
model's own edge name.
-}
requestEdgeKind :: Edge -> EdgeKind
requestEdgeKind e
    | e == edgeInsertActive = EdgeInsertActive
    | e == edgeUpdateTerminal = EdgeUpdateTerminal
    | otherwise = EdgeOther (T.pack (edgeName e))

-- | The owner's raw bytes as hex text.
requestOwnerText :: ByteString -> T.Text
requestOwnerText bs = T.pack (BC.unpack (B16.encode bs))

{- | A request's processing deadline: its submission time plus the
registry's processing time (the same addition the booking receipt states).
-}
pendingDeadlineOf :: Integer -> Integer -> Integer
pendingDeadlineOf = requestDeadline

{- | The model's approval check over the output's assets: assets under
the pinned policy carrying the expected commitment are ok; assets under
the pinned policy without it are a tuple mismatch; assets only under
other policies are a policy mismatch; no non-ada asset at all is missing.
Takes the output's assets as (policy bytes, asset-name bytes), the pinned
policy, and the expected commitment (the builder's 'approvalName').
-}
approvalCheckOf
    :: [(SBS.ShortByteString, ByteString)]
    -> SBS.ShortByteString
    -> ByteString
    -> ApprovalCheck
approvalCheckOf assets pinned expected
    | any (\(p, n) -> p == pinned && n == expected) assets = ApprovalOk
    | any (\(p, _) -> p == pinned) assets = ApprovalTupleMismatch
    | not (null assets) = ApprovalPolicyMismatch
    | otherwise = ApprovalMissing

{- | The application step's verdict, through the application value only:
an insertion whose carried datum the value cannot read is unreadable; a
termination under a value with no holding rules is required carrying the
value's executable (the generic wording when it names none); otherwise
ready. Reuses 'checkCarriedDatum' for readability and 'appHolding' for
the holding-rules presence; 'neutralTerminationRefusal' in 'Fold' is
unreachable here ('Fold' imports this module), so the generic wording is
duplicated as 'neutralAppExecutable' (see the reliance record).
-}
appVerdictOf :: Application -> OnChainRequest -> AppVerdict
appVerdictOf app req
    | requestEdge req == edgeInsertActive = case checkCarriedDatum app req of
        Left _ -> AppDatumUnreadable
        Right _ -> AppReady
    | requestEdge req == edgeUpdateTerminal = case appHolding app of
        Just _ -> AppReady
        Nothing -> AppRequired (fromMaybe neutralAppExecutable (appExecutable app))
    | otherwise = AppReady

-- | The generic wording the neutral refusal uses when the value names no executable.
neutralAppExecutable :: T.Text
neutralAppExecutable = "the application's own executable"

-- | A pending output's non-ada assets as (policy bytes, asset-name bytes).
outputAssets :: TxOut ConwayEra -> [(SBS.ShortByteString, ByteString)]
outputAssets out =
    [ (SBS.toShort (scriptHashBytes policyHash), SBS.fromShort rawName)
    | (PolicyID policyHash, names) <- Map.toList assets
    , (AssetName rawName, _) <- Map.toList names
    ]
  where
    MaryValue _ (MultiAsset assets) = out ^. valueTxOutL

{- | One pending request's selection input: the decode verdict, the edge
kind, the owner (hex of the output's owner bytes, which match the datum
for a decodable output), the deadline, the model's approval check
(expected commitment via the builders' 'approvalName' over the request's
edge, key, owner and destination), and the given application verdict.
For an undecodable output the datum-derived fields are placeholders that
the selection never reaches (it refuses undecodable first).
-}
pendingRequestOf
    :: Int
    -> Int
    -> Either String OnChainRequest
    -> TxOut ConwayEra
    -> SBS.ShortByteString
    -> AppVerdict
    -> Integer
    -> PendingRequest
pendingRequestOf ref key decoded out pinned appVerdict process = case decoded of
    Left _ ->
        PendingRequest
            ref
            key
            T.empty
            (EdgeOther (T.pack "undecodable"))
            0
            False
            ApprovalMissing
            appVerdict
    Right req ->
        let ownerBytes = extractOwnerBytes out
            expected =
                approvalName
                    (requestEdge req)
                    (requestKey req)
                    ownerBytes
                    (approvalDestination (requestDestination req))
            assets = outputAssetsPinned out pinned
        in  PendingRequest
                ref
                key
                (requestOwnerText ownerBytes)
                (requestEdgeKind (requestEdge req))
                (pendingDeadlineOf (requestSubmittedAt req) process)
                True
                (approvalCheckOf assets pinned expected)
                appVerdict

{- | A pending output's assets relevant to approval: all non-ada assets as
(policy bytes, name bytes). Compared against the pinned policy by
'approvalCheckOf'.
-}
outputAssetsPinned
    :: TxOut ConwayEra
    -> SBS.ShortByteString
    -> [(SBS.ShortByteString, ByteString)]
outputAssetsPinned out _ = outputAssets out

{- | Integer keys sharing one number among requests on the same key bytes
and never among distinct keys, in first-appearance order starting at 1.
-}
assignKeyInts :: [ByteString] -> [Int]
assignKeyInts = go Map.empty 1
  where
    go _ _ [] = []
    go seen next (k : ks) = case Map.lookup k seen of
        Just i -> i : go seen next ks
        Nothing -> next : go (Map.insert k next seen) (next + 1) ks

-- | Distinct integer references in ledger input order, with the pairing.
assignRefPairing :: [TxIn] -> [(TxIn, Int)]
assignRefPairing txs = zip txs [1 ..]

{- | The whole pending list's selection inputs with consistent integers:
key bytes from decodable datums (empty for undecodable, which the
selection refuses before the key rule), references distinct in ledger
order, application verdicts assembled from the given application value
('AppReady' placeholder for undecodable), and the pairing 'foldRequests'
takes.
-}
buildPendingRequests
    :: [(TxIn, TxOut ConwayEra, Either String OnChainRequest)]
    -> SBS.ShortByteString
    -> Application
    -> Integer
    -> ([PendingRequest], [(TxIn, Int)])
buildPendingRequests inputs pinned app process =
    let txs = [tx | (tx, _, _) <- inputs]
        pairing = assignRefPairing txs
        refOf tx = case lookup tx pairing of
            Just r -> r
            Nothing -> error "buildPendingRequests: missing pairing"
        keyBytes =
            [either (const mempty) requestKey decoded | (_, _, decoded) <- inputs]
        keyInts = assignKeyInts keyBytes
        verdictOf = either (const AppReady) (appVerdictOf app)
        pendings =
            [ pendingRequestOf
                (refOf tx)
                k
                decoded
                out
                pinned
                (verdictOf decoded)
                process
            | ((tx, out, decoded), k) <- zip inputs keyInts
            ]
    in  (pendings, pairing)

{- | The selection's live facts keyed by the shared integers: the leaf
from the registry state (unknown when the state never mentions the key)
with whether a live output holds the key's active token.
-}
buildLiveFacts
    :: Map.Map ByteString Leaf
    -> Map.Map ByteString Bool
    -> Map.Map ByteString Int
    -> LiveFacts
buildLiveFacts leaves present keys =
    Map.fromList
        [ ( i
          ,
              ( Map.findWithDefault LeafUnknown k leaves
              , Map.findWithDefault False k present
              )
          )
        | (k, i) <- Map.toList keys
        ]

{- | Whether any live output at the application address holds the key's one
active token: an asset under the active-token policy named by the key bytes.
Pure over the outputs the routine already reads, so the selection's leaf
check sees the same holdings the fold would spend, for either application
value (the neutral value carries no holding rules, but its keys still hold
tokens at the application address).
-}
holdsActiveToken
    :: SBS.ShortByteString
    -- ^ The active-token policy bytes
    -> ByteString
    -- ^ The key bytes
    -> [(TxIn, TxOut ConwayEra)]
    -> Bool
holdsActiveToken _ key _ | key == mempty = False
holdsActiveToken active key outs =
    any (holds . snd) outs
  where
    holds out = any (\(p, n) -> p == active && n == key) (outputAssets out)

-- ---------------------------------------------------------
-- Additive receipt lists (#518, pull request 1)
-- ---------------------------------------------------------

{- | One settled request as the additive receipt lists it: the output
reference, the key and edge as the receipt names them, the owner hex,
the settlement object (the delivered output with its datum, or the
released holding with the deposit paid back) and the deadline object.
-}
data SettledForReceipt = SettledForReceipt
    { sfrRequest :: TxIn
    , sfrKeyHex :: T.Text
    , sfrEdge :: T.Text
    , sfrOwnerHex :: T.Text
    , sfrSettlement :: Value
    , sfrDeadline :: Value
    }
    deriving stock (Eq, Show)

{- | The three additive receipt fields beside the earlier top-level ones:
@settled@ (each settled request in ledger order), @excluded@ (each
excluded request with reason, source and detail, in ledger order) and
@capacity@ (the bound with its provenance text). Pure over simple data
so the receipt shape is tested without a ledger.
-}
foldReceiptLists
    :: [SettledForReceipt]
    -> [(TxIn, Exclusion)]
    -> Int
    -> T.Text
    -> [(T.Text, Value)]
foldReceiptLists settled excluded bound provenance =
    [ ("settled", toJSON (map settledJson settled))
    , ("excluded", toJSON (map excludedJson excluded))
    , ("capacity", object ["bound" .= bound, "provenance" .= provenance])
    ]
  where
    settledJson s =
        object
            [ "request" .= renderOutRef (sfrRequest s)
            , "key" .= sfrKeyHex s
            , "edge" .= sfrEdge s
            , "owner" .= sfrOwnerHex s
            , "settlement" .= sfrSettlement s
            , "deadline" .= sfrDeadline s
            ]
    excludedJson (tx, exc) =
        object
            [ "request" .= renderOutRef tx
            , "reason" .= exclusionName exc
            , "source" .= exclusionSource exc
            , "detail" .= excDetail exc
            ]

{- | The delivery of the earlier top-level receipt fields as simple
components: the delivered output with its envelope, the delivered datum
with its hash and cbor, or the released output with the deposit paid back.
-}
data EarlierDelivery
    = -- | The output now holding the key, with its envelope as the receipt states it
      EarlierDelivered T.Text Value
    | -- | The output now holding the key's datum, with the datum's hash and cbor
      EarlierDeliveredDatum T.Text T.Text T.Text
    | -- | The live output the fold released, and the deposit it paid back
      EarlierReleased T.Text Integer
    deriving stock (Eq, Show)

{- | The earlier top-level receipt fields as one record of simple
components, each already spelled as the receipt states it: the settled
request, key, edge, folder and fold transaction as text, the delivery, the
root after, the deadline object, the validity upper bound slot, the
post-build verdict, the host clock and the milliseconds remaining.
-}
data EarlierReceipt = EarlierReceipt
    { earRequest :: T.Text
    , earKey :: T.Text
    , earEdge :: T.Text
    , earFolder :: T.Text
    , earFold :: T.Text
    , earDelivery :: EarlierDelivery
    , earRoot :: T.Text
    , earDeadline :: Value
    , earUpperSlot :: Maybe Integer
    , earPostBuild :: Value
    , earHostClockMs :: Integer
    , earRemainingMs :: Integer
    }
    deriving stock (Eq, Show)

{- | The earlier top-level receipt fields in the order a reader meets them,
projected from simple components. The production 'foldedFields' in
"Singular.CLI.Fold" builds the record and calls this function, so rows over
it pin the production projection: every earlier pair unchanged and in
order, nothing added or removed, per delivery branch.
-}
earlierReceiptFields :: EarlierReceipt -> [(T.Text, Value)]
earlierReceiptFields r =
    [ ("request", toJSON (earRequest r))
    , ("key", toJSON (earKey r))
    , ("edge", toJSON (earEdge r))
    , ("folder", toJSON (earFolder r))
    , ("fold", toJSON (earFold r))
    ]
        <> deliveryFields (earDelivery r)
        <> [ ("root", toJSON (earRoot r))
           , ("foldDeadline", earDeadline r)
           , ("validUntilSlot", toJSON (earUpperSlot r))
           , ("postBuild", earPostBuild r)
           , ("hostClockMs", toJSON (earHostClockMs r))
           , ("remainingMs", toJSON (earRemainingMs r))
           ]
  where
    deliveryFields = \case
        EarlierDelivered live envelope ->
            [ ("liveOutput", toJSON live)
            , ("envelope", envelope)
            ]
        EarlierDeliveredDatum live dHash dCbor ->
            [ ("liveOutput", toJSON live)
            , ("datumHash", toJSON dHash)
            , ("datumCbor", toJSON dCbor)
            ]
        EarlierReleased out deposit ->
            [ ("released", toJSON out)
            , ("deposit", toJSON deposit)
            ]

{- | Combine the earlier top-level receipt fields with the three additions:
the earlier pairs survive unchanged and in order, the additions follow them,
nothing else added or removed. The production @foldedFields@ calls this, so
rows over realistic earlier projections pin the production path.
-}
combineReceiptFields
    :: [(T.Text, Value)]
    -> [(T.Text, Value)]
    -> [(T.Text, Value)]
combineReceiptFields earlier additions = earlier ++ additions

{- | Combine a legacy window-closed message with every other exclusion.
Sole cause returns the legacy message unchanged, so the Demo 1 readers of
the closed-window wording and timing fields stay untouched; with others,
the legacy wording stays first and every other exclusion is listed after
it in the same refusal, so no exclusion is lost.
-}
combineWindowClosedMessage :: String -> [(TxIn, Exclusion)] -> String
combineWindowClosedMessage legacy [] = legacy
combineWindowClosedMessage legacy others =
    legacy ++ "\n" ++ renderFoldRequestsRefusal (FoldNothingToFold others)
