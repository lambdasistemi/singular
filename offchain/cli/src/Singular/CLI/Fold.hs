{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Fold
Description : @singular registry fold@: the one routine that folds a booked request
License     : Apache-2.0

A booking leaves its request pending; the registry's fold is a command of
its own, run by whichever wallet folds, with its own key, funding,
journal lines and receipt. 'foldPending' is that fold and the only one:
@registry fold@ calls it on a request found on the chain, and the combined
@insert --fold@ and @terminate --fold@ call it on the request they have
just booked, so no second fold path exists to drift from it.

Everything the fold decides it decides from one view of the chain, before
anything is signed: which request it takes ("Singular.CLI.FoldRules"), its
edge, whether the request's processing window still leaves time, the
envelope an insertion delivers (carried by its request on the chain, so
any wallet can fold it) or the live output a termination releases, the
replayed root after the edge, the built transaction, and its outlay. The
fold takes the pure selection over every pending request and settles every
request that passes, up to the capacity bound; several pending requests never
refuse on count,
and a built fold that spends other than the selection is refused before
it is signed.

The fold is judged against the funding the caller named, or else the
wallet's largest ada-only output, and against the allowance the caller
approved. Run alone, a fold that cannot be built or signed is a refusal
that submitted nothing; run after its own booking it stops partial, naming
the request that stays pending.
-}
module Singular.CLI.Fold
    ( -- * The command
      runFold
    , runFoldBounded

      -- * The one fold routine
    , FoldOrigin (..)
    , FoldSpec (..)
    , Folded (..)
    , SettledEntry (..)
    , Plan (..)
    , PlanEntry (..)
    , Delivery (..)
    , foldPending
    , foldPendingBounded
    , foldedFields
    , settledEntryFor
    , foldDeadline
    , neutralTerminationRefusal
    , slotAt

      -- * The processing deadline
    , Deadline (..)
    , deadlineJson
    , registrationDeadline
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (foldM, forM_, unless)
import Data.Aeson (Value (Null), object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.Foldable (for_, toList)
import Data.List (isPrefixOf, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , outputsTxBodyL
    , treasuryDonationTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.BaseTypes
    ( StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import PlutusCore.Data qualified as PLC

import Singular.CLI.Attached
import Singular.CLI.Command
    ( Command (..)
    , FoldArgs (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    , neededRoles
    )
import Singular.CLI.FoldRules
import Singular.CLI.Harness (holdBeforeCommit, holdBeforeObserved)
import Singular.CLI.Live
import Singular.CLI.ManagedState (resolveSignerDir)
import Singular.CLI.Outlay
    ( Outlay
    , foldOutlay
    , foldPastAllowance
    , leftForFold
    , outlayTotal
    )
import Singular.CLI.Plan (outlayReport, refuseOver)
import Singular.CLI.Prepare
    ( PrepareRefusal (..)
    , preparationFields
    , prepareFunding
    )
import Singular.CLI.Receipt (OutcomeClass (..), chainTransitions)
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (EdgeStarted, RequestSeen, RootSeen)
    , report
    )
import Singular.CLI.Trace qualified as Trace
import Singular.Registry.Application
    ( Application (..)
    , DecodedHolding (..)
    , HoldingRules (..)
    , datumCbor
    , datumHash
    , txOutDatum
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.FoldSelection
    ( AppVerdict (..)
    , Exclusion
    , Leaf (..)
    , MemberKind (..)
    , TaggedRequest (..)
    , TaggedSelection (..)
    , foldCapacity
    , foldCapacityProvenance
    , selectTaggedFold
    )
import Singular.Registry.Ledger
    ( Coin (..)
    , Root (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TxBuilder.Edges (registryContextFor)
import Singular.Registry.TxBuilder.Internal
    ( BookedRequest (..)
    , addrFromBytes
    , bookedKey
    , bookedRequestOf
    , currentPosixMs
    , extractCageDatum
    , pendingByTag
    )
import Singular.Registry.TxBuilder.Prepare (Preparation (..))
import Singular.Registry.TxBuilder.Update (updateTokenSelected)
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRegistrationRequest (..)
    , OnChainTerminationRequest (..)
    , OnChainTokenState (..)
    , edgeInsertActive
    , edgeName
    , edgeUpdateTerminal
    , registrationRefundBytes
    )

-- ---------------------------------------------------------
-- The processing deadline
-- ---------------------------------------------------------

{- | A request's processing deadline: its time, and the slot it falls in when
the view that read it converts it.

The time is the protocol's and is the authority. A node converts a time to
a slot only inside its horizon, which on a development network ends well
before a request's deadline; then the slot is absent, with the reason, and
nothing is estimated in its place.
-}
data Deadline = Deadline
    { deadlineMs :: Integer
    -- ^ POSIX milliseconds: the request's submission plus the processing time
    , deadlineSlot :: Maybe SlotNo
    -- ^ The slot of that time, floor, when the view converts it
    }
    deriving stock (Eq, Show)

-- | The deadline as a receipt states it.
deadlineJson :: Deadline -> Value
deadlineJson d =
    object $
        [ "posixMs" .= deadlineMs d
        , "slot" .= (unSlotNo <$> deadlineSlot d)
        ]
            <> [ "slotUnavailable" .= ("beyond the node's conversion horizon" :: Text)
               | Nothing <- [deadlineSlot d]
               ]

{- | The deadline of a registration under a registry's processing time, with
its slot when the view converts the time. A termination has none: it has no
window.
-}
registrationDeadline
    :: Cage.Session Cage.NoWitness IO
    -> OnChainRegistrationRequest
    -> OnChainTokenState
    -> IO Deadline
registrationDeadline v r st = do
    let ms = requestDeadline (regSubmittedAt r) (stateProcessTime st)
    Deadline ms <$> slotAt v ms

slotAt
    :: Cage.Session Cage.NoWitness IO -> Integer -> IO (Maybe SlotNo)
slotAt v ms = do
    placed <- try (Services.floorSlot v ms)
    case placed of
        Right slot -> pure (Just slot)
        Left (e :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | otherwise -> pure Nothing

-- ---------------------------------------------------------
-- The fold
-- ---------------------------------------------------------

-- | How a fold came to run.
data FoldOrigin
    = -- | @registry fold@: nothing was booked by this command
      Standalone
    | {- | @insert --fold@ or @terminate --fold@: the booking it just confirmed
      and what that booking put out of the wallet, as it was measured: a
      termination's request holds the custody the key already had, which
      the wallet did not pay
      -}
      Combined ConwayTx Outlay

-- | What one fold is asked to do.
data FoldSpec = FoldSpec
    { fsOrigin :: FoldOrigin
    , fsRequest :: Maybe TxIn
    -- ^ The pending request the caller expects to fold (@--request@)
    , fsFund :: Maybe TxIn
    -- ^ The wallet output to fund and collateralise from (@--fund-input@)
    , fsAllowance :: Maybe Integer
    -- ^ The approved outlay (@--max-outlay@)
    }

-- | What the fold left at the application.
data Delivery
    = -- | The output now holding the key, as the value decodes it (open datum)
      Delivered TxIn DecodedHolding
    | {- | The output now holding the key's datum, at the request's own
      destination (neutral: decodes nothing); a registration that carried no
      datum delivers an output that holds none
      -}
      DeliveredDatum TxIn (Maybe PLC.Data)
    | {- | A termination: the request whose custody the fold took in and
      whose key it made terminal; no output holds the key any more
      -}
      Terminated TxIn
    deriving stock (Eq, Show)

{- | One settled request of a fold, in ledger order.

A fold of one carries a list of one; the fold over several requests of
the next run carries one entry per settled request, in order.
-}
data SettledEntry = SettledEntry
    { seRequest :: TxIn
    , seKey :: ByteString
    , seEdge :: Edge
    , seOwner :: Text
    , seKind :: FoldKind
    , seDelivery :: Delivery
    , seDeadline :: Maybe Deadline
    -- ^ A registration's deadline; a termination has none
    }
    deriving stock (Eq, Show)

-- | One planned request of a fold, in ledger order.
data PlanEntry = PlanEntry
    { peRequest :: TxIn
    , peKey :: ByteString
    , peEdge :: Edge
    , peKind :: FoldKind
    , peDatum :: Maybe PLC.Data
    -- ^ The datum an insertion delivers (the request's own, through the value)
    , peDestination :: Maybe (ByteString, Maybe PLC.Data)
    -- ^ Where the insertion delivers (the request's own destination)
    , peRootAfter :: ByteString
    , peDeadline :: Maybe Deadline
    , peOwnerHex :: Text
    }
    deriving stock (Eq, Show)

-- | One settled request gathered before the build, without its root after.
data Gathered = Gathered
    { gTx :: TxIn
    , gKind :: FoldKind
    , gDeadline :: Maybe Deadline
    , gKey :: ByteString
    , gDest :: Maybe (ByteString, Maybe PLC.Data)
    -- ^ Where a registration delivers; a termination delivers nothing
    , gDatum :: Maybe PLC.Data
    , gOwner :: Text
    }
    deriving stock (Eq, Show)

-- | A gathered request with its root after becomes one plan entry.
toPlanEntry :: Gathered -> ByteString -> PlanEntry
toPlanEntry g rootAfter =
    PlanEntry
        { peRequest = gTx g
        , peKey = gKey g
        , peEdge = edgeOfKind (gKind g)
        , peKind = gKind g
        , peDatum = gDatum g
        , peDestination = gDest g
        , peRootAfter = rootAfter
        , peDeadline = gDeadline g
        , peOwnerHex = gOwner g
        }

-- | A plan entry with its read-back delivery becomes one settled entry.
toSettled :: PlanEntry -> Delivery -> SettledEntry
toSettled entry delivery =
    SettledEntry
        { seRequest = peRequest entry
        , seKey = peKey entry
        , seEdge = peEdge entry
        , seOwner = peOwnerHex entry
        , seKind = peKind entry
        , seDelivery = delivery
        , seDeadline = peDeadline entry
        }

{- | A confirmed, committed and observed fold.

The result lists its settled requests; the fold-level facts stay single.
The fold's deadline is the earliest among the settled entries.
-}
data Folded = Folded
    { fdSettled :: NonEmpty SettledEntry
    , fdFolder :: ByteString
    -- ^ The payment key hash of the wallet that signed and funded the fold
    , fdTx :: ConwayTx
    , fdRoot :: ByteString
    , fdUpperSlot :: Maybe SlotNo
    -- ^ The fold's validity upper bound, from the built transaction
    , fdPostBuild :: Value
    -- ^ The post-build check's verdict and the values it compared
    , fdDecidedAt :: Integer
    -- ^ The host's UTC clock, in POSIX milliseconds, when the fold was decided
    , fdRemaining :: Maybe Integer
    -- ^ Milliseconds between the moment the fold was decided and the deadline; none when no registration is settled
    , fdExcluded :: [(TxIn, Exclusion)]
    -- ^ Every excluded pending request with its reason, in ledger order
    , fdCapacityBound :: Int
    -- ^ The capacity bound the selection used
    , fdCapacityProvenance :: Text
    -- ^ Why the bound is what it is
    , fdPreparation :: Maybe Preparation
    -- ^ The preparation transaction that funded the fold, if one was made
    , fdDonation :: Integer
    -- ^ What the built fold donates to the treasury, in lovelace
    }

-- | What the fold's view decided before anything was signed.
data Plan = Plan
    { plEntries :: NonEmpty PlanEntry
    , plUpper :: Maybe SlotNo
    , plDecidedAt :: Integer
    , plPostBuild :: Value
    , plRemaining :: Maybe Integer
    , plExcluded :: [(TxIn, Exclusion)]
    , plCapacityBound :: Int
    , plCapacityProvenance :: Text
    }

{- | The fold's deadline: the earliest among its settled registrations; a fold
of terminations alone has none.
-}
foldDeadline :: Folded -> Maybe Deadline
foldDeadline f = case [d | e <- toList (fdSettled f), Just d <- [seDeadline e]] of
    [] -> Nothing
    d : ds -> Just (foldr earliest d ds)
  where
    earliest a b
        | deadlineMs a <= deadlineMs b = a
        | otherwise = b

{- | The settled entry for a request reference, or nothing when the request
is not among the settled requests.
-}
settledEntryFor :: Folded -> TxIn -> Maybe SettledEntry
settledEntryFor f ref = case fdSettled f of
    e :| es -> go (e : es)
  where
    go [] = Nothing
    go (x : xs)
        | seRequest x == ref = Just x
        | otherwise = go xs

{- | Why a termination with no holding rules is refused, before anything is
built or signed: the registry's pinned application policy (hex), and the
value's executable when present, so the application's own executable folds it.
-}
neutralTerminationRefusal :: Application -> CageConfig -> String
neutralTerminationRefusal app cfg =
    let policyHex = hexT (SBS.fromShort (cfgApplicationPolicy cfg))
    in  case appExecutable app of
            Just exe ->
                "a termination must be folded by "
                    <> T.unpack exe
                    <> " (this registry pins application policy "
                    <> T.unpack policyHex
                    <> ")"
            Nothing ->
                "this registry pins application policy "
                    <> T.unpack policyHex
                    <> ": its termination must be folded by the application's own executable"

{- | @singular registry fold@: fold the one pending request, signed and funded
by this wallet, and journal it. Whoever booked the request, the fold journals
in this wallet's own managed partition.
-}
runFold :: Application -> Env -> FoldArgs -> IO Value
runFold = runFoldBounded foldCapacity

{- | 'runFold' with the capacity bound as an argument, so a command-run test
can fold two or three requests without a second production path. The packaged
dispatch uses 'runFold'; the bound travels only through tests.
-}
runFoldBounded :: Int -> Application -> Env -> FoldArgs -> IO Value
runFoldBounded bound app env a = do
    let ws = foldWrite a
    dir <-
        resolveSignerDir
            (foldStateDir a)
            (providerMagic (writeProvider ws))
            (accessToken (foldAccess a))
            (writeSigner ws)
    attached
        app
        env
        dir
        (foldBlueprint a)
        (foldAccess a)
        (neededRoles (Fold a))
        (foldWrite a)
        "fold"
        $ \at -> do
            folded <-
                foldPendingBounded
                    bound
                    app
                    at
                    FoldSpec
                        { fsOrigin = Standalone
                        , fsRequest = foldRequest a
                        , fsFund = foldFund a
                        , fsAllowance = foldMaxOutlay a
                        }
            pure (receipt "fold" Success (foldedFields folded))

{- | A fold's receipt fields, in the order a reader meets them.
The earlier single-request fields are gone; each settled request's facts
live in the @settled@ list. What stays at the top level are the facts of
the transaction: the folder, the fold, the root, the deadline, the validity
bound, the post-build verdict, the host clock and the time remaining, then
the three lists.
-}
foldedFields :: Folded -> [(Text, Value)]
foldedFields f =
    keptReceiptFields
        KeptReceipt
            { keptFolder = hexT (fdFolder f)
            , keptFold = txIdHex (fdTx f)
            , keptRoot = hexT (fdRoot f)
            , keptDeadline = maybe Null deadlineJson (foldDeadline f)
            , keptUpperSlot = toInteger . unSlotNo <$> fdUpperSlot f
            , keptPostBuild = fdPostBuild f
            , keptHostClockMs = fdDecidedAt f
            , keptRemainingMs = fdRemaining f
            }
        <> [("donation", toJSON (fdDonation f))]
        <> foldReceiptLists
            (map settledForReceipt settledList)
            (fdExcluded f)
            (fdCapacityBound f)
            (fdCapacityProvenance f)
        <> preparationFields (fdPreparation f)
  where
    settledList = case fdSettled f of
        e :| es -> e : es
    settledForReceipt entry =
        SettledForReceipt
            (seRequest entry)
            (hexT (seKey entry))
            (T.pack (edgeName (seEdge entry)))
            (seOwner entry)
            (settlement (seDelivery entry))
            (maybe Null deadlineJson (seDeadline entry))
    settlement = \case
        Delivered out holding ->
            object
                [ "liveOutput" .= txInText out
                , "envelope" .= dhDatumJson holding
                ]
        DeliveredDatum out datum ->
            object
                ( ("liveOutput" .= txInText out)
                    : maybe
                        []
                        ( \d ->
                            [ "datumHash" .= hexT (datumHash d)
                            , "datumCbor" .= hexT (datumCbor d)
                            ]
                        )
                        datum
                )
        Terminated request ->
            object
                [ "terminated" .= txInText request
                ]

{- | Fold the one pending request with the application's context, commit its
edge speculatively, replay the new public root, and journal the fold observed.

The request, its edge, the window, the envelope it carries or the holding, the root
after and the built fold all come from the fold's own view; any refusal
there happens before anything is signed. The speculative walk and the
journalled after-root are that one edge.
-}
foldPending :: Application -> Attached -> FoldSpec -> IO Folded
foldPending = foldPendingBounded foldCapacity

{- | 'foldPending' with the capacity bound as an argument, so a command-run
test can fold two or three requests without a second production path.
'Standalone' production folds use 'foldCapacity' (now 9); another bound is
used only by a test. The selection, the prefix walk, the application context,
the validity bound and the readback all cover every settled request.
-}
foldPendingBounded
    :: Int -> Application -> Attached -> FoldSpec -> IO Folded
foldPendingBounded bound app at FoldSpec{..} = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
        addr = wcCaller wc
        named = case fsOrigin of
            Combined booking _ -> Just (TxIn (txIdTx booking) (TxIx 0))
            Standalone -> fsRequest
    rootBefore <- selectedTrieRoot (atTrie at)
    (fold, (plan, preparation)) <-
        submitBuiltIn
            wc
            "fold"
            ["state", "requests"]
            ( \(p, _) -> case plEntries p of
                e :| es ->
                    let toTuple entry =
                            let expectAfter = case peKind entry of
                                    FoldInsertion ->
                                        "active:" <> maybe "" (hexT . datumHash) (peDatum entry)
                                    FoldTermination -> "terminal"
                            in  ( txInText (peRequest entry)
                                , hexT (peKey entry)
                                , peEdge entry
                                , expectAfter
                                , hexT (peRootAfter entry)
                                )
                    in  FoldExpectation
                            ( chainTransitions
                                (hexT rootBefore)
                                (toTuple e :| map toTuple es)
                            )
            )
            ( \building v -> do
                -- The pending requests are the outputs the request policy
                -- vouches for, found through the acquired session; nothing is
                -- discovered by reading the request address.
                pending <- pendingByTag cfg v (savedToken s)
                let bookedList =
                        [ (tx, req)
                        | (tx, out) <- pending
                        , Just req <- [bookedRequestOf cfg (savedToken s) out]
                        ]
                    bookedMap = Map.fromList bookedList
                    pendingIns = map fst bookedList
                    stop' = stop fsOrigin named
                -- A named request with no booking pending at all is refused
                -- before the registry's state is read: nothing else decides it.
                case named of
                    Just r
                        | null bookedList ->
                            stop'
                                ClientRefusal
                                (renderFoldRequestsRefusal (FoldNamedNothingSettled r Nothing []))
                                []
                    _ -> pure ()
                live <- attachLive v s
                st <- case extractCageDatum (snd (liveState live)) of
                    Just (StateDatum st') -> pure st'
                    _ ->
                        stop'
                            ClientRefusal
                            "the registry's state output carries no state datum"
                            []
                let process = stateProcessTime st
                    pairing = assignRefPairing pendingIns
                    keyBytesList = map (bookedKey . snd) bookedList
                    keyInts = assignKeyInts keyBytesList
                    keyMap = Map.fromList (zip keyBytesList keyInts)
                freshRootEarly <-
                    either (failWith ClientRefusal) pure (observedRoot live)
                unless (freshRootEarly == rootBefore) $
                    failTrie
                        ( TS.StaleState
                            (savedIdentity s)
                            Nothing
                            (TS.StaleRoot (Root rootBefore) (Root freshRootEarly))
                        )
                leavesTrie <- requireTrieSelection s live
                leavesPairs <- withTrie leavesTrie $ \snap ->
                    traverse
                        ( \kb -> do
                            got <- TS.leafAt snap kb
                            case got of
                                Right TS.Unknown -> pure (kb, LeafUnknown)
                                Right TS.Absent -> pure (kb, LeafAbsent)
                                Right TS.Active -> pure (kb, LeafActive)
                                Right TS.Terminal -> pure (kb, LeafTerminal)
                                Left why -> failTrie why
                        )
                        (Map.keys keyMap)
                let liveFacts = buildLiveFacts (Map.fromList leavesPairs) Map.empty keyMap
                    taggedRequests =
                        [ TaggedRequest
                            { tgRef = refOf tx
                            , tgKey = k
                            , tgKind = case req of
                                BookedRegistration _ -> MemberRegistration
                                BookedTermination _ -> MemberTermination
                            , tgSubmittedAt = case req of
                                BookedRegistration r -> regSubmittedAt r
                                BookedTermination _ -> 0
                            , tgCarried = case req of
                                BookedRegistration r -> case checkCarriedDatum app (regDatum r) of
                                    Left _ -> AppDatumUnreadable
                                    Right _ -> AppReady
                                BookedTermination _ -> AppReady
                            }
                        | ((tx, req), k) <- zip bookedList keyInts
                        ]
                    refOf tx = case lookup tx pairing of
                        Just r -> r
                        Nothing -> error "foldPendingBounded: a pending request has no reference"
                nowSel <- currentPosixMs
                let selection =
                        selectTaggedFold
                            bound
                            nowSel
                            foldMarginMs
                            process
                            liveFacts
                            taggedRequests
                    intToTx = [(r, tx) | (tx, r) <- pairing]
                    excludedTxs =
                        [ (tx, exc)
                        | (q, exc) <- taggedExcluded selection
                        , Just tx <- [lookup (tgRef q) intToTx]
                        ]
                settledNE <- case foldTaggedRequests named pairing selection of
                    Right ne -> pure ne
                    Left refusal -> do
                        -- A booking the selection refuses is named before the
                        -- refusal, with its key and its kind, as its receipt
                        -- names it.
                        for_ (refusedRequest refusal) $ \tx ->
                            for_ (Map.lookup tx bookedMap) $ \req ->
                                found
                                    building
                                    [InRequest (txInText tx)]
                                    ( RequestSeen
                                        (txInText tx)
                                        ( edgeText $ case req of
                                            BookedRegistration _ -> edgeInsertActive
                                            BookedTermination _ -> edgeUpdateTerminal
                                        )
                                        (bookedKey req)
                                        Nothing
                                        Nothing
                                    )
                        stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                let selectedTxs = case settledNE of
                        x :| xs -> x : xs
                    settledList = selectedTxs
                    boundUsed = taggedBound selection
                -- Per request, before the build: output, datum, edge kind,
                -- deadline, carried datum, one RequestSeen each.
                let gatherOneLocal tx = do
                        req <- case Map.lookup tx bookedMap of
                            Just r -> pure r
                            Nothing -> stop' ClientRefusal "the pending request vanished" []
                        case req of
                            BookedRegistration r -> do
                                let seen dl =
                                        found
                                            building
                                            [InRequest (txInText tx)]
                                            ( RequestSeen
                                                (txInText tx)
                                                (edgeText edgeInsertActive)
                                                (regKey r)
                                                (deadlineMs <$> dl)
                                                (unSlotNo <$> (dl >>= deadlineSlot))
                                            )
                                deadline <- registrationDeadline v r st
                                seen (Just deadline)
                                datum <-
                                    either
                                        (\why -> seen Nothing >> stop' ClientRefusal why [])
                                        pure
                                        (checkCarriedDatum app (regDatum r))
                                pure
                                    Gathered
                                        { gTx = tx
                                        , gKind = FoldInsertion
                                        , gDeadline = Just deadline
                                        , gKey = regKey r
                                        , gDest = Just (regDestination r, regDatum r)
                                        , gDatum = datum
                                        , gOwner = hexT (registrationRefundBytes r)
                                        }
                            BookedTermination t -> do
                                found
                                    building
                                    [InRequest (txInText tx)]
                                    ( RequestSeen
                                        (txInText tx)
                                        (edgeText edgeUpdateTerminal)
                                        (termKey t)
                                        Nothing
                                        Nothing
                                    )
                                pure
                                    Gathered
                                        { gTx = tx
                                        , gKind = FoldTermination
                                        , gDeadline = Nothing
                                        , gKey = termKey t
                                        , gDest = Nothing
                                        , gDatum = Nothing
                                        , gOwner = T.empty
                                        }
                perReq <- traverse gatherOneLocal settledList
                -- The window is a registration's: the earliest deadline among
                -- the registrations settled. A termination has none.
                let windowed = [(g, d) | g <- perReq, Just d <- [gDeadline g]]
                    earliestOf =
                        foldr1
                            (\a b -> if deadlineMs (snd a) <= deadlineMs (snd b) then a else b)
                    mEarliest = case windowed of
                        [] -> Nothing
                        w -> Just (earliestOf w)
                    placedFirst = case mEarliest of
                        Just (g, _) -> g
                        Nothing -> case perReq of
                            g : _ -> g
                            [] -> error "foldPendingBounded: no settled request"
                place
                    building
                    ( [InRequest (txInText (gTx r)) | r <- perReq]
                        <> [InEdge (Folding (edgeText (edgeOfKind (gKind r)))) | r <- perReq]
                    )
                    (EdgeStarted (Folding (edgeText (edgeOfKind (gKind placedFirst)))))
                now <- currentPosixMs
                remaining <- case mEarliest of
                    Nothing -> pure Nothing
                    Just (_, earliest) -> case foldWindow foldMarginMs now (deadlineMs earliest) of
                        FoldOpen left -> pure (Just left)
                        FoldClosed left ->
                            stop'
                                ClientRefusal
                                ( "the request's processing deadline, "
                                    <> show (deadlineMs earliest)
                                    <> " ms"
                                    <> maybe
                                        ""
                                        ((" (slot " <>) . (<> ")") . show . unSlotNo)
                                        (deadlineSlot earliest)
                                    <> ", "
                                    <> ( if left <= 0
                                            then "has passed"
                                            else
                                                "is only "
                                                    <> show (left `div` 1000)
                                                    <> " s ahead, within the "
                                                    <> show (foldMarginMs `div` 1000)
                                                    <> " s a fold needs to be included"
                                       )
                                    <> ": no fold is built"
                                )
                                [ ("foldDeadline", deadlineJson earliest)
                                , ("hostClockMs", toJSON now)
                                , ("remainingMs", toJSON left)
                                ]
                freshRoot <- either (failWith ClientRefusal) pure (observedRoot live)
                unless (freshRoot == rootBefore) $
                    failTrie
                        ( TS.StaleState
                            (savedIdentity s)
                            Nothing
                            (TS.StaleRoot (Root rootBefore) (Root freshRoot))
                        )
                viewTrie <- requireTrieSelection s live
                -- Roots between transitions: walk the trie once per prefix.
                rootsAfter <- withTrie viewTrie $ \snap ->
                    let walkOne prefix = do
                            walked <-
                                TS.speculateEdges snap prefix
                                    >>= either
                                        ( \why ->
                                            stop'
                                                ClientRefusal
                                                ("TrieState " <> T.unpack (TS.trieFailureName why))
                                                (TS.trieFailureFields why)
                                        )
                                        pure
                            case TS.walkRoot walked of
                                Root bytes -> pure bytes
                    in  traverse walkOne (prefixPairs perReq)
                ctx0 <-
                    registryContextFor cfg (savedCodes s) v (liveRefs (atLive at))
                ctx <- case appHolding app of
                    Just rules ->
                        either
                            (\why -> stop' ClientRefusal (T.unpack why) [])
                            pure
                            (hrWithApplication rules (applied s) Nothing ctx0)
                    Nothing -> pure ctx0
                (_fundIns, preparation, unsigned) <- do
                    prepared <-
                        prepareFunding
                            wc
                            "fold"
                            addr
                            fsFund
                            ( case fsOrigin of
                                Combined _ bookingSpent -> leftForFold fsAllowance bookingSpent
                                Standalone -> fsAllowance
                            )
                            foldOutlay
                            ( \funded ->
                                withTrie viewTrie $ \snap ->
                                    updateTokenSelected cfg funded snap (savedToken s) addr ctx settledNE
                            )
                            v
                    case prepared of
                        Left (ExplicitFundingRefusal why) ->
                            stop' ClientRefusal ("the wallet cannot fund the fold: " <> why) []
                        Left (OriginalFailure e) -> case fromException e of
                            Just (_ :: SomeAsyncException) -> throwIO e
                            _ ->
                                stop'
                                    ClientRefusal
                                    ( "its fold could not be built, so nothing is folded: "
                                        <> briefly (show e)
                                    )
                                    []
                        Left (PreparationShortfall text fields) ->
                            stop' ClientRefusal text fields
                        Left (AllowanceExceeded text fields) ->
                            stop' ClientRefusal text fields
                        Right triple -> pure triple
                let spent = Set.toList (unsigned ^. bodyTxL . inputsTxBodyL)
                    stateTx = fst (liveState live)
                case spendsSelection stateTx selectedTxs pendingIns spent of
                    Right _ -> pure ()
                    Left why ->
                        stop'
                            ConcurrentWriter
                            (renderSpendsRefusal why)
                            []
                case fsOrigin of
                    Combined _ bookingSpent ->
                        forM_ (foldPastAllowance fsAllowance bookingSpent unsigned) $
                            \(left, outlay) ->
                                stop'
                                    ClientRefusal
                                    ( "its fold costs "
                                        <> show (outlayTotal outlay)
                                        <> " lovelace under the fold's own parameters, past the "
                                        <> show left
                                        <> " the approved outlay leaves after the booking, so nothing is folded or signed"
                                    )
                                    [("outlay", outlayReport (Just left) outlay)]
                    Standalone -> refuseOver fsAllowance (foldOutlay unsigned)
                let upper = case unsigned ^. bodyTxL . vldtTxBodyL of
                        ValidityInterval _ (SJust u) -> Just u
                        _ -> Nothing
                -- The proof, from the built body before anything is signed:
                -- the up-front guard above is only the fast refusal. A fold of
                -- terminations alone has no window to prove.
                postNow <- currentPosixMs
                let upperI = toInteger . unSlotNo <$> upper
                postBuild <- case mEarliest of
                    Nothing ->
                        pure
                            ( object
                                [ "check"
                                    .= ("admitted: no registration is settled, so there is no window" :: Text)
                                , "hostClockMs" .= postNow
                                , "validUntilSlot" .= upperI
                                , "validUntilMs" .= (Nothing :: Maybe Integer)
                                ]
                            )
                    Just (_, earliest) -> do
                        let deadlineSlotI = toInteger . unSlotNo <$> deadlineSlot earliest
                        (verdict, boundTime) <-
                            postBuildDecision
                                (fmap (fmap (toInteger . unSlotNo)) . slotAt v)
                                postNow
                                (deadlineMs earliest)
                                deadlineSlotI
                                upperI
                        let postBuildFields =
                                [ ("foldDeadline", deadlineJson earliest)
                                , ("hostClockMs", toJSON postNow)
                                , ("validUntilSlot", toJSON upperI)
                                , ("validUntilMs", toJSON boundTime)
                                ]
                        case verdict of
                            PostBuildAdmitted _ -> pure ()
                            PostBuildRefused why ->
                                stop'
                                    ClientRefusal
                                    ( "the built fold is not signed: "
                                        <> renderPostBuildRefusal why
                                    )
                                    (postBuildFields <> [("postBuild", toJSON (postBuildName verdict))])
                        pure
                            ( object
                                [ "check" .= postBuildName verdict
                                , "hostClockMs" .= postNow
                                , "validUntilSlot" .= upperI
                                , "validUntilMs" .= boundTime
                                ]
                            )
                pure
                    ( unsigned
                    ,
                        ( Plan
                            { plEntries = case zipWith toPlanEntry perReq rootsAfter of
                                [] -> error "foldPendingBounded: no settled request"
                                (x : xs) -> x :| xs
                            , plUpper = upper
                            , plPostBuild = postBuild
                            , plDecidedAt = now
                            , plRemaining = remaining
                            , plExcluded = excludedTxs
                            , plCapacityBound = boundUsed
                            , plCapacityProvenance = foldCapacityProvenance
                            }
                        , preparation
                        )
                    )
            )
    let entries = case plEntries plan of
            e :| es -> e : es
        lastEntry = last entries
    holdBeforeCommit
    local <- readingBack at "fold" fold ["state"] $ \v -> do
        afterFold <- attachLive v s
        afterFoldTrie <- requireTrieSelection s afterFold
        root <- selectedTrieRoot afterFoldTrie
        unless (root == peRootAfter lastEntry) $
            failWith
                StaleState
                "after the fold the public lineage reaches another root"
        pure root
    (entryDeliveries, detail) <-
        readBackEntries app at s fold local entries
    holdBeforeObserved
    journalObserved wc "fold" fold detail
    forM_ entryDeliveries $ \(entry, delivery) ->
        report
            (wcTracer wc)
            [ InRequest (txInText (peRequest entry))
            , InEdge (Folding (edgeText (peEdge entry)))
            ]
            ( Trace.Folded (edgeText (peEdge entry)) (peKey entry) $ case delivery of
                Delivered out _ -> txInText out
                DeliveredDatum out _ -> txInText out
                Terminated request -> txInText request
            )
    reportSeen wc [] (RootSeen (hexT rootBefore) (hexT local))
    pure
        Folded
            { fdSettled = case [toSettled entry delivery | (entry, delivery) <- entryDeliveries] of
                [] -> error "foldPendingBounded: no settled entry"
                (x : xs) -> x :| xs
            , fdFolder = callerKey at
            , fdTx = confirmedTx fold
            , fdRoot = local
            , fdUpperSlot = plUpper plan
            , fdPostBuild = plPostBuild plan
            , fdDecidedAt = plDecidedAt plan
            , fdRemaining = plRemaining plan
            , fdExcluded = plExcluded plan
            , fdCapacityBound = plCapacityBound plan
            , fdCapacityProvenance = plCapacityProvenance plan
            , fdPreparation = preparation
            , fdDonation =
                let Coin d = confirmedTx fold ^. bodyTxL . treasuryDonationTxBodyL
                in  d
            }

-- | The verdict's short name, as a receipt states it.
postBuildName :: PostBuild -> Text
postBuildName = \case
    PostBuildAdmitted BoundByDeadlineSlot -> "admitted: bound at or before the deadline's slot"
    PostBuildAdmitted BoundByTime -> "admitted: bound's time at or before the deadline"
    PostBuildRefused _ -> "refused"

-- | One line naming why a built fold is not signed.
renderPostBuildRefusal :: PostBuildRefusal -> String
renderPostBuildRefusal = \case
    NoUpperBound -> "it carries no validity upper bound"
    ClockWithinMargin ->
        "the host clock after the build is within "
            <> show (foldMarginMs `div` 1000)
            <> " s of the request's processing deadline, so it could not be included in time"
    BoundBeyondDeadlineSlot u s ->
        "its validity upper bound, slot "
            <> show u
            <> ", is after the request's deadline slot "
            <> show s
    BoundUnconvertible ->
        "its validity upper bound cannot be converted to a time by the view that built it, and the deadline has no slot to compare it with"
    BoundAfterDeadline t ->
        "its validity upper bound begins at "
            <> show t
            <> " ms, after the request's processing deadline"

{- | The trie pairs per prefix of the selection: the first request, then the
first two, and so on. Each prefix walks from the fold's root before to the
root after its last request.
-}
prefixPairs :: [Gathered] -> [NonEmpty (ByteString, Edge)]
prefixPairs = go []
  where
    go _ [] = []
    go acc (r : rs) =
        let prefix = acc ++ [(gKey r, edgeOfKind (gKind r))]
        in  case prefix of
                [] -> go prefix rs
                (x : xs) -> (x :| xs) : go prefix rs

{- | One delivery readback per settled request, in ledger order. An insertion
under holding rules is found by key; a neutral insertion by destination and
datum hash, with distinct outputs for same-datum insertions (fewer matching
than such insertions is 'Partial'); a termination's release is checked per
entry. A fold of one keeps main's wording exactly, including the
"more than one..." refusal.
-}
readBackEntries
    :: Application
    -> Attached
    -> Saved
    -> ConfirmedSubmission
    -> ByteString
    -> [PlanEntry]
    -> IO ([(PlanEntry, Delivery)], Text)
readBackEntries app at s fold local entries = do
    let single = length entries == 1
    (revPairs, _) <- foldM (step single) ([], Set.empty) entries
    let pairs = reverse revPairs
        fragments = [fragment e d | (e, d) <- pairs]
        detail = T.intercalate "; " fragments <> "; root 0x" <> hexT local
    pure (pairs, detail)
  where
    fragment _ delivery = case delivery of
        Delivered out _ -> "key live at " <> txInText out <> " under its envelope"
        DeliveredDatum out datum ->
            "key live at "
                <> txInText out
                <> maybe " with no datum" (const " under its datum") datum
        Terminated request -> "key terminal, its custody taken in by " <> txInText request
    step isSingle (acc, used) entry = case (peKind entry, peDatum entry) of
        (FoldInsertion, Just datum) -> case appHolding app of
            Just _ -> do
                outs <-
                    readingBack at "fold" fold ["key outputs"] (\v -> liveOutputs app v s)
                ((liveIn, _), seen) <-
                    either
                        (failWith Partial)
                        pure
                        (liveOutputFor app s (peKey entry) outs)
                unless (dhDatumData seen == datum) $
                    failWith Partial "the delivered output carries another envelope"
                pure ((entry, Delivered liveIn seen) : acc, used)
            Nothing -> do
                let destAddr = maybe "" fst (peDestination entry)
                outs <- readingBack at "fold" fold ["key outputs"] $ \view ->
                    case addrFromBytes destAddr of
                        Nothing ->
                            failWith
                                Partial
                                "the insertion's request names an address this fold cannot decode"
                        Just destAt -> Cage.outputsAt view destAt
                let wanted = datumHash datum
                    matching =
                        [ u
                        | u@(_, o) <- outs
                        , Just (_, h) <- [txOutDatum o]
                        , h == wanted
                        ]
                liveIn <- case (isSingle, matching) of
                    (True, [(i, _)]) -> pure i
                    (True, []) -> failWith Partial "the delivered output carries another datum"
                    (True, _) ->
                        failWith
                            Partial
                            "more than one live output carries the delivered datum"
                    (False, _) ->
                        let unused = [i | (i, _) <- sortOn fst matching, i `Set.notMember` used]
                        in  case unused of
                                (i : _) -> pure i
                                [] -> failWith Partial "the delivered output carries another datum"
                let used' = Set.insert liveIn used
                pure ((entry, DeliveredDatum liveIn (Just datum)) : acc, used')
        (FoldInsertion, Nothing) -> do
            -- the registration carried no datum: nothing on the chain tells
            -- the delivered output from another at the destination but the
            -- fold's own transaction, so it is the first output of that
            -- transaction at the destination that holds no datum and that no
            -- earlier entry took
            let destAddr = maybe "" fst (peDestination entry)
                foldTx = confirmedTx fold
                made =
                    [ TxIn (txIdTx foldTx) (TxIx ix)
                    | (ix, out) <- zip [0 ..] (toList (foldTx ^. bodyTxL . outputsTxBodyL))
                    , serialiseAddr (out ^. addrTxOutL) == destAddr
                    , isNothing (txOutDatum out)
                    ]
            outs <- readingBack at "fold" fold ["key outputs"] $ \view ->
                case addrFromBytes destAddr of
                    Nothing ->
                        failWith
                            Partial
                            "the insertion's request names an address this fold cannot decode"
                    Just destAt -> Cage.outputsAt view destAt
            case [i | i <- made, i `Set.notMember` used, i `elem` map fst outs] of
                (liveIn : _) ->
                    pure
                        ( (entry, DeliveredDatum liveIn Nothing) : acc
                        , Set.insert liveIn used
                        )
                [] ->
                    failWith Partial "the delivered output is not live at the destination"
        (FoldTermination, _) -> do
            after <-
                readingBack at "fold" fold ["key outputs"] (\v -> liveOutputs app v s)
            -- the custody entered the request at the booking and the fold
            -- burned the key's tag: no output holds the key any more
            case liveOutputFor app s (peKey entry) after of
                Left _ -> pure ()
                Right ((liveIn, _), _) ->
                    failWith
                        Partial
                        ( "the fold confirmed but the key is still held at "
                            <> T.unpack (txInText liveIn)
                        )
            pure ((entry, Terminated (peRequest entry)) : acc, used)

{- | Stop before anything is signed. Run after its own booking, a fold that
cannot be built or signed leaves that booking's request pending, so the
command stops partial and names it; run alone it submitted nothing.
-}
stop
    :: FoldOrigin
    -> Maybe TxIn
    -> OutcomeClass
    -> String
    -> [(Text, Value)]
    -> IO a
stop origin request cls why fields =
    case (origin, request, cls) of
        (Combined _ _, Just r, ClientRefusal) ->
            failWithFields
                Partial
                ( "the booking is confirmed and its request "
                    <> T.unpack (txInText r)
                    <> " stays pending; "
                    <> why
                )
                (pending r <> fields)
        (_, Just r, _) -> failWithFields cls why (pending r <> fields)
        _ -> failWithFields cls why fields
  where
    pending r = [("pendingRequest", toJSON (txInText r))]

{- | A build failure's own words, without the script bytes and context a
Plutus failure carries after them.
-}
briefly :: String -> String
briefly = go
  where
    go s
        | "(PlutusWithContext" `isPrefixOf` s = "…"
        | otherwise = case s of
            [] -> []
            (c : rest) -> c : go rest

-- | An edge as the receipt names it.
edgeText :: Edge -> Text
edgeText = T.pack . edgeName

-- | The edge a kind of settled request books.
edgeOfKind :: FoldKind -> Edge
edgeOfKind = \case
    FoldInsertion -> edgeInsertActive
    FoldTermination -> edgeUpdateTerminal
