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
fold takes the pure selection over every pending request and settles its
first included request; several pending requests never refuse on count,
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

      -- * The one fold routine
    , FoldOrigin (..)
    , FoldSpec (..)
    , Folded (..)
    , Delivery (..)
    , foldPending
    , foldedFields
    , neutralTerminationRefusal
    , slotAt

      -- * The processing deadline
    , Deadline (..)
    , deadlineJson
    , deadlineOf
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.List (isPrefixOf, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
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
import Singular.CLI.ManagedState (resolveWalletDir)
import Singular.CLI.Outlay
    ( foldOutlay
    , foldPastAllowance
    , outlayTotal
    )
import Singular.CLI.Plan (outlayReport, refuseOver)
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
    ( Exclusion (..)
    , Leaf (..)
    , PendingRequest (..)
    , Reason (..)
    , Selection (..)
    , exclusionName
    , foldCapacity
    , selectFold
    )
import Singular.Registry.Ledger
    ( ConwayEra
    , Root (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TxBuilder.Edges (registryContextFor)
import Singular.Registry.TxBuilder.Internal
    ( addrFromBytes
    , currentPosixMs
    , extractCageDatum
    , requestAddrFromCfg
    )
import Singular.Registry.TxBuilder.Update (updateTokenSelected)
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , OnChainTokenState (..)
    , edgeName
    )
import Singular.Registry.Wallet (Wallet (..))

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

{- | The deadline of a request under a registry's processing time, with its
slot when the view converts the time.
-}
deadlineOf
    :: Cage.Session Cage.NoWitness IO
    -> OnChainRequest
    -> OnChainTokenState
    -> IO Deadline
deadlineOf v r st = do
    let ms = requestDeadline (requestSubmittedAt r) (stateProcessTime st)
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
    | -- | @insert --fold@ or @terminate --fold@: the booking it just confirmed
      Combined ConwayTx

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
      destination (neutral: decodes nothing)
      -}
      DeliveredDatum TxIn PLC.Data
    | -- | The live output the fold released, and the deposit it paid back
      Released TxIn Integer

-- | A confirmed, committed and observed fold.
data Folded = Folded
    { fdRequest :: TxIn
    , fdKey :: ByteString
    , fdEdge :: Edge
    , fdFolder :: ByteString
    -- ^ The payment key hash of the wallet that signed and funded the fold
    , fdTx :: ConwayTx
    , fdRoot :: ByteString
    , fdDelivery :: Delivery
    , fdDeadline :: Deadline
    , fdUpperSlot :: Maybe SlotNo
    -- ^ The fold's validity upper bound, from the built transaction
    , fdPostBuild :: Value
    -- ^ The post-build check's verdict and the values it compared
    , fdDecidedAt :: Integer
    -- ^ The host's UTC clock, in POSIX milliseconds, when the fold was decided
    , fdRemaining :: Integer
    -- ^ Milliseconds between the moment the fold was decided and the deadline
    , fdOwnerHex :: Text
    -- ^ The settled request's owner hex, as the selection carries it
    , fdExcluded :: [(TxIn, Exclusion)]
    -- ^ Every excluded pending request with its reason, in ledger order
    , fdCapacityBound :: Int
    -- ^ The capacity bound the selection used
    , fdCapacityProvenance :: Text
    -- ^ Why the bound is what it is
    }

-- | What the fold's view decided before anything was signed.
data Plan = Plan
    { plRequest :: TxIn
    , plKey :: ByteString
    , plEdge :: Edge
    , plKind :: FoldKind
    , plDatum :: Maybe PLC.Data
    -- ^ The datum an insertion delivers (the request's own, through the value)
    , plDestination :: Maybe (ByteString, Maybe PLC.Data)
    -- ^ Where the insertion delivers (the request's own destination)
    , plHolding :: Maybe ((TxIn, TxOut ConwayEra), DecodedHolding)
    -- ^ The holding a termination releases (through the value; absent on neutral)
    , plRootAfter :: ByteString
    , plDeadline :: Deadline
    , plUpper :: Maybe SlotNo
    , plDecidedAt :: Integer
    , plPostBuild :: Value
    , plRemaining :: Integer
    , plOwnerHex :: Text
    , plExcluded :: [(TxIn, Exclusion)]
    , plCapacityBound :: Int
    , plCapacityProvenance :: Text
    }

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
runFold app env a = do
    let ws = foldWrite a
    dir <-
        resolveWalletDir
            (foldStateDir a)
            (providerMagic (writeProvider ws))
            (accessToken (foldAccess a))
            (writeWalletKey ws)
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
                foldPending
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
            , keptDeadline = deadlineJson (fdDeadline f)
            , keptUpperSlot = toInteger . unSlotNo <$> fdUpperSlot f
            , keptPostBuild = fdPostBuild f
            , keptHostClockMs = fdDecidedAt f
            , keptRemainingMs = fdRemaining f
            }
        <> foldReceiptLists
            [settledEntry]
            (fdExcluded f)
            (fdCapacityBound f)
            (fdCapacityProvenance f)
  where
    settledEntry =
        SettledForReceipt
            (fdRequest f)
            (hexT (fdKey f))
            (T.pack (edgeName (fdEdge f)))
            (fdOwnerHex f)
            settlement
            (deadlineJson (fdDeadline f))
    settlement = case fdDelivery f of
        Delivered out holding ->
            object
                [ "liveOutput" .= txInText out
                , "envelope" .= dhDatumJson holding
                ]
        DeliveredDatum out datum ->
            object
                [ "liveOutput" .= txInText out
                , "datumHash" .= hexT (datumHash datum)
                , "datumCbor" .= hexT (datumCbor datum)
                ]
        Released out deposit ->
            object
                [ "released" .= txInText out
                , "deposit" .= deposit
                ]

{- | Fold the one pending request with the application's context, commit its
edge speculatively, replay the new public root, and journal the fold observed.

The request, its edge, the window, the envelope it carries or the holding, the root
after and the built fold all come from the fold's own view; any refusal
there happens before anything is signed. The speculative walk and the
journalled after-root are that one edge.
-}
foldPending :: Application -> Attached -> FoldSpec -> IO Folded
foldPending app at FoldSpec{..} = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
        addr = walletAddr (wcWallet wc)
        named = case fsOrigin of
            Combined booking -> Just (TxIn (txIdTx booking) (TxIx 0))
            Standalone -> fsRequest
    rootBefore <- selectedTrieRoot (atTrie at)
    (fold, plan) <-
        submitBuiltIn
            wc
            "fold"
            ["state", "requests"]
            ( \p ->
                let expectAfter = case plKind p of
                        FoldInsertion ->
                            "active:" <> maybe "" (hexT . datumHash) (plDatum p)
                        FoldTermination -> "terminal"
                in  FoldExpectation
                        ( chainTransitions
                            (hexT rootBefore)
                            ( ( txInText (plRequest p)
                              , hexT (plKey p)
                              , plEdge p
                              , expectAfter
                              , hexT (plRootAfter p)
                              )
                                :| []
                            )
                        )
            )
            ( \building v -> do
                pendingRaw <-
                    Cage.outputsAt v (requestAddrFromCfg cfg (savedToken s) Testnet)
                let pending = sortOn fst pendingRaw
                    pendingIns = map fst pending
                    stop' = stop fsOrigin named
                    decodedList =
                        [ (tx, out, decoded)
                        | (tx, out) <- pending
                        , let decoded = case extractCageDatum out of
                                Just (RequestDatum r) -> Right r
                                _ -> Left "undecodable" :: Either String OnChainRequest
                        ]
                case named of
                    Just r -> case lookup r pending of
                        Just out -> case extractCageDatum out of
                            Just (RequestDatum req) -> case foldKind (requestEdge req) of
                                Left why
                                    | refuseNamedEdgeEarly named pendingIns -> do
                                        found
                                            building
                                            [InRequest (txInText r)]
                                            ( RequestSeen
                                                (txInText r)
                                                (edgeText (requestEdge req))
                                                (requestKey req)
                                                Nothing
                                                Nothing
                                            )
                                        stop' ClientRefusal why []
                                    | otherwise ->
                                        -- another request is pending too: the
                                        -- selection's refusal names this
                                        -- request's cause and every other
                                        -- exclusion, so nothing is dropped
                                        pure ()
                                Right _ -> pure ()
                            _ -> pure ()
                        Nothing -> pure ()
                    Nothing -> pure ()
                live <- attachLive v s
                st <- case extractCageDatum (snd (liveState live)) of
                    Just (StateDatum st') -> pure st'
                    _ ->
                        stop'
                            ClientRefusal
                            "the registry's state output carries no state datum"
                            []
                let process = stateProcessTime st
                    pinned = cfgApplicationPolicy cfg
                    (pendings, pairing) = buildPendingRequests decodedList pinned app process
                outsApp <- liveOutputs app v s
                let keyBytesList =
                        [ either (const mempty) requestKey dec
                        | (_, _, dec) <- decodedList
                        ]
                    keyInts = assignKeyInts keyBytesList
                    keyMap = Map.fromList (zip keyBytesList keyInts)
                    activePolicy = cfgActivePolicy cfg
                    presentMap =
                        Map.fromList
                            [ (kb, holdsActiveToken activePolicy kb outsApp)
                            | kb <- Map.keys keyMap
                            ]
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
                        ( \kb -> case kb == mempty of
                            True -> pure (kb, LeafUnknown)
                            False -> do
                                got <- TS.leafAt snap kb
                                case got of
                                    Right TS.Unknown -> pure (kb, LeafUnknown)
                                    Right TS.Absent -> pure (kb, LeafAbsent)
                                    Right TS.Active -> pure (kb, LeafActive)
                                    Right TS.Terminal -> pure (kb, LeafTerminal)
                                    Left why -> failTrie why
                        )
                        (Map.keys keyMap)
                let leavesMap = Map.fromList leavesPairs
                    liveFacts = buildLiveFacts leavesMap presentMap keyMap
                nowSel <- currentPosixMs
                let selection = selectFold foldCapacity nowSel foldMarginMs liveFacts pendings
                    intToTx = [(r, tx) | (tx, r) <- pairing]
                    excludedTxs =
                        [ (tx, exc)
                        | (q, exc) <- selectionExcluded selection
                        , Just tx <- [lookup (prRef q) intToTx]
                        ]
                    isWindowClosed exc = exclusionName exc == "window-closed"
                    refuseWindowClosed tx = refuseWindowClosedWith tx []
                    refuseWindowClosedWith tx others = do
                        reqOutW <- case lookup tx pending of
                            Just o -> pure o
                            Nothing -> stop' ClientRefusal "the pending request vanished" []
                        reqW <- case extractCageDatum reqOutW of
                            Just (RequestDatum r) -> pure r
                            _ ->
                                stop' ClientRefusal "the pending request carries no request datum" []
                        deadlineW <- deadlineOf v reqW st
                        nowW <- currentPosixMs
                        case foldWindow foldMarginMs nowW (deadlineMs deadlineW) of
                            FoldOpen _ ->
                                stop'
                                    ClientRefusal
                                    ( renderFoldRequestsRefusal
                                        ( FoldNamedExcluded
                                            tx
                                            ( Exclusion
                                                ReasonWindowClosed
                                                "the processing window is not open beyond the fold margin"
                                            )
                                        )
                                    )
                                    []
                            FoldClosed left ->
                                let legacyMsg =
                                        "the request's processing deadline, "
                                            <> show (deadlineMs deadlineW)
                                            <> " ms"
                                            <> maybe
                                                ""
                                                ((" (slot " <>) . (<> ")") . show . unSlotNo)
                                                (deadlineSlot deadlineW)
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
                                in  stop'
                                        ClientRefusal
                                        (combineWindowClosedMessage legacyMsg others)
                                        [ ("foldDeadline", deadlineJson deadlineW)
                                        , ("hostClockMs", toJSON nowW)
                                        , ("remainingMs", toJSON left)
                                        ]
                settledNE <- case foldRequests named pairing selection of
                    Right ne -> pure ne
                    Left refusal -> case refusal of
                        FoldNothingPending ->
                            stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                        FoldNamedNotPending _ ->
                            stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                        FoldNamedExcluded tx exc -> case isWindowClosed exc of
                            True -> refuseWindowClosed tx
                            False -> stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                        FoldNothingToFold pairs -> case pairs of
                            [(tx, exc)] -> case isWindowClosed exc of
                                True -> refuseWindowClosed tx
                                False -> stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                            _ -> stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                        FoldInconsistentInput _ _ ->
                            stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                        FoldNamedNothingSettled tx mExc others -> case mExc of
                            Just exc -> case isWindowClosed exc of
                                True -> refuseWindowClosedWith tx others
                                False -> stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                            Nothing -> stop' ClientRefusal (renderFoldRequestsRefusal refusal) []
                let selectedTxs = case settledNE of
                        x :| xs -> x : xs
                    chosen = case settledNE of
                        c :| _ -> c
                    chosenRef = case lookup chosen pairing of
                        Just r -> r
                        Nothing -> -1
                    ownerHex = case [prOwner p | p <- pendings, prRef p == chosenRef] of
                        o : _ -> o
                        [] -> ""
                    boundUsed = selectionBound selection
                    provUsed = selectionProvenance selection
                reqOut <- case lookup chosen pending of
                    Just o -> pure o
                    Nothing -> stop' ClientRefusal "the pending request vanished" []
                req <- case extractCageDatum reqOut of
                    Just (RequestDatum r) -> pure r
                    _ ->
                        stop' ClientRefusal "the pending request carries no request datum" []
                let seen dl =
                        found
                            building
                            [InRequest (txInText chosen)]
                            ( RequestSeen
                                (txInText chosen)
                                (edgeText (requestEdge req))
                                (requestKey req)
                                (deadlineMs <$> dl)
                                (unSlotNo <$> (dl >>= deadlineSlot))
                            )
                    request = chosen
                kind <-
                    either
                        (\why -> seen Nothing >> stop' ClientRefusal why [])
                        pure
                        (foldKind (requestEdge req))
                deadline <- deadlineOf v req st
                seen (Just deadline)
                place
                    building
                    [ InRequest (txInText request)
                    , InEdge (Folding (edgeText (requestEdge req)))
                    ]
                    (EdgeStarted (Folding (edgeText (requestEdge req))))
                now <- currentPosixMs
                remaining <- case foldWindow foldMarginMs now (deadlineMs deadline) of
                    FoldOpen left -> pure left
                    FoldClosed left ->
                        stop'
                            ClientRefusal
                            ( "the request's processing deadline, "
                                <> show (deadlineMs deadline)
                                <> " ms"
                                <> maybe
                                    ""
                                    ((" (slot " <>) . (<> ")") . show . unSlotNo)
                                    (deadlineSlot deadline)
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
                            [ ("foldDeadline", deadlineJson deadline)
                            , ("hostClockMs", toJSON now)
                            , ("remainingMs", toJSON left)
                            ]
                let key = requestKey req
                    dest = requestDestination req
                (datum, holding) <- case kind of
                    FoldInsertion -> do
                        d <-
                            either
                                (\why -> seen Nothing >> stop' ClientRefusal why [])
                                pure
                                (checkCarriedDatum app req)
                        pure (Just d, Nothing)
                    FoldTermination -> do
                        outs <- liveOutputs app v s
                        h <-
                            either
                                (\why -> stop' ClientRefusal why [])
                                pure
                                (liveOutputFor app s key outs)
                        pure (Nothing, Just h)
                freshRoot <- either (failWith ClientRefusal) pure (observedRoot live)
                unless (freshRoot == rootBefore) $
                    failTrie
                        ( TS.StaleState
                            (savedIdentity s)
                            Nothing
                            (TS.StaleRoot (Root rootBefore) (Root freshRoot))
                        )
                viewTrie <- requireTrieSelection s live
                Root rootAfter <- withTrie viewTrie $ \snap -> do
                    walked <-
                        TS.speculateEdges snap ((key, requestEdge req) :| [])
                            >>= either
                                ( \why ->
                                    stop'
                                        ClientRefusal
                                        ("TrieState " <> T.unpack (TS.trieFailureName why))
                                        (TS.trieFailureFields why)
                                )
                                pure
                    pure (TS.walkRoot walked)
                ctx0 <-
                    registryContextFor cfg (savedCodes s) v (liveRefs (atLive at))
                ctx <- case appHolding app of
                    Just rules ->
                        either
                            (\why -> stop' ClientRefusal (T.unpack why) [])
                            pure
                            ( hrWithApplication
                                rules
                                (applied s)
                                Nothing
                                (maybe [] (pure . fst) holding)
                                ctx0
                            )
                    Nothing -> pure ctx0
                funded <-
                    fundedView fsFund addr v
                        >>= either
                            ( \why ->
                                stop' ClientRefusal ("the wallet cannot fund the fold: " <> why) []
                            )
                            pure
                built <-
                    try
                        ( withTrie viewTrie $ \snap ->
                            updateTokenSelected cfg funded snap (savedToken s) addr ctx settledNE
                        )
                unsigned <- case built of
                    Right tx -> pure tx
                    Left (e :: SomeException)
                        | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
                        | otherwise ->
                            stop'
                                ClientRefusal
                                ( "its fold could not be built, so nothing is folded: "
                                    <> briefly (show e)
                                )
                                []
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
                    Combined booking ->
                        forM_ (foldPastAllowance fsAllowance booking unsigned) $
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
                -- the up-front guard above is only the fast refusal.
                postNow <- currentPosixMs
                let upperI = toInteger . unSlotNo <$> upper
                    deadlineSlotI = toInteger . unSlotNo <$> deadlineSlot deadline
                (verdict, boundTime) <-
                    postBuildDecision
                        (fmap (fmap (toInteger . unSlotNo)) . slotAt v)
                        postNow
                        (deadlineMs deadline)
                        deadlineSlotI
                        upperI
                let postBuildFields =
                        [ ("foldDeadline", deadlineJson deadline)
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
                    ( unsigned
                    , Plan
                        { plRequest = request
                        , plKey = key
                        , plEdge = requestEdge req
                        , plKind = kind
                        , plDatum = datum
                        , plDestination = Just dest
                        , plHolding = holding
                        , plRootAfter = rootAfter
                        , plDeadline = deadline
                        , plUpper = upper
                        , plPostBuild =
                            object
                                [ "check" .= postBuildName verdict
                                , "hostClockMs" .= postNow
                                , "validUntilSlot" .= upperI
                                , "validUntilMs" .= boundTime
                                ]
                        , plDecidedAt = now
                        , plRemaining = remaining
                        , plOwnerHex = ownerHex
                        , plExcluded = excludedTxs
                        , plCapacityBound = boundUsed
                        , plCapacityProvenance = provUsed
                        }
                    )
            )
    let key = plKey plan
        edge = plEdge plan
    holdBeforeCommit
    local <- readingBack at "fold" fold ["state"] $ \v -> do
        afterFold <- attachLive v s
        afterFoldTrie <- requireTrieSelection s afterFold
        root <- selectedTrieRoot afterFoldTrie
        unless (root == plRootAfter plan) $
            failWith
                StaleState
                "after the fold the public lineage reaches another root"
        pure root
    (delivery, detail) <- case (plKind plan, plDatum plan, plHolding plan) of
        (FoldInsertion, Just datum, _) -> case appHolding app of
            Just _ -> do
                outs <-
                    readingBack at "fold" fold ["key outputs"] (\v -> liveOutputs app v s)
                ((liveIn, _), seen) <-
                    either (failWith Partial) pure (liveOutputFor app s key outs)
                unless (dhDatumData seen == datum) $
                    failWith Partial "the delivered output carries another envelope"
                pure
                    ( Delivered liveIn seen
                    , "key live at "
                        <> txInText liveIn
                        <> " under its envelope; root 0x"
                        <> hexT local
                    )
            Nothing -> do
                let destAddr = maybe "" fst (plDestination plan)
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
                liveIn <- case matching of
                    [(i, _)] -> pure i
                    [] ->
                        failWith Partial "the delivered output carries another datum"
                    _ ->
                        failWith
                            Partial
                            "more than one live output carries the delivered datum"
                pure
                    ( DeliveredDatum liveIn datum
                    , "key live at "
                        <> txInText liveIn
                        <> " under its datum; root 0x"
                        <> hexT local
                    )
        (FoldTermination, _, Just ((liveIn, _), holding)) -> do
            after <-
                readingBack at "fold" fold ["key outputs"] (\v -> liveOutputs app v s)
            when (any ((== liveIn) . fst) after) $
                failWith
                    Partial
                    "the fold confirmed but the live output is still unspent"
            pure
                ( Released liveIn (dhDeposit holding)
                , "live output "
                    <> txInText liveIn
                    <> " released; root 0x"
                    <> hexT local
                )
        _ ->
            failWith
                Partial
                "the fold's plan carries neither a datum nor a holding"
    holdBeforeObserved
    journalObserved wc "fold" fold detail
    report
        (wcTracer wc)
        [ InRequest (txInText (plRequest plan))
        , InEdge (Folding (edgeText edge))
        ]
        ( Trace.Folded (edgeText edge) key $ case delivery of
            Delivered out _ -> txInText out
            DeliveredDatum out _ -> txInText out
            Released out _ -> txInText out
        )
    report (wcTracer wc) [] (RootSeen (hexT rootBefore) (hexT local))
    pure
        Folded
            { fdRequest = plRequest plan
            , fdKey = key
            , fdEdge = edge
            , fdFolder = callerKey at
            , fdTx = confirmedTx fold
            , fdRoot = local
            , fdDelivery = delivery
            , fdDeadline = plDeadline plan
            , fdUpperSlot = plUpper plan
            , fdPostBuild = plPostBuild plan
            , fdDecidedAt = plDecidedAt plan
            , fdRemaining = plRemaining plan
            , fdOwnerHex = plOwnerHex plan
            , fdExcluded = plExcluded plan
            , fdCapacityBound = plCapacityBound plan
            , fdCapacityProvenance = plCapacityProvenance plan
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
        (Combined _, Just r, ClientRefusal) ->
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
