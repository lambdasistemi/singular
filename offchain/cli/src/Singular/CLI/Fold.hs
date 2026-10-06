{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Fold
Description : @singular registry fold@: the one routine that folds booked requests
License     : Apache-2.0

A booking leaves its request pending; the registry's fold is a command of
its own, run by whichever wallet folds, with its own key, funding,
journal lines and receipt. 'foldPending' is that fold and the only one:
@registry fold@ calls it on the requests found on the chain, and the
combined @insert --fold@ and @terminate --fold@ call it after the request
they have just booked, so no second fold path exists to drift from it.

One fold takes every pending request it can fold, whoever booked it, in the
ledger's input order ("Singular.CLI.FoldRules"), and names every one it
leaves with the reason. Everything it decides it decides from one view of
the chain, before anything is signed: which requests it takes, the edges,
whether each processing window still leaves time, the law over the batch
from the replayed tree, the envelope each insertion delivers (carried by its
request on the chain, so any wallet can fold it) or the live output each
termination releases, the replayed root after each request, the built
transaction over exactly those requests, what it pays each owner, and its
outlay. The built fold must spend the registry's state and exactly the
requests it takes; anything else is refused before it is signed.

The fold is judged against the funding the caller named, or else the
wallet's largest ada-only output, and against the allowance the caller
approved. Run alone, a fold that cannot be built or signed is a refusal
that submitted nothing; run after its own booking it stops partial, naming
the request that stays pending. A fold the node refuses because another
fold spent the registry's state output first is refused @stale-state@: its
journal is closed and a rerun folds whatever is still pending.
-}
module Singular.CLI.Fold
    ( -- * The command
      runFold

      -- * The one fold routine
    , FoldOrigin (..)
    , FoldSpec (..)
    , Folded (..)
    , FoldedRequest (..)
    , Delivery (..)
    , foldPending
    , foldedFields
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
import Control.Monad (forM, forM_, unless, when, (>=>))
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf, minimumBy, nub, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))
import PlutusTx.Builtins (fromBuiltin)

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeHash
    , envelopeToJson
    )
import Singular.Application.OpenDatum.Release (withApplication)
import Singular.CLI.Attached
import Singular.CLI.Command (FoldArgs (..))
import Singular.CLI.FoldRules
import Singular.CLI.Live
import Singular.CLI.Outlay
    ( foldOutlay
    , foldPastAllowance
    , outlayTotal
    )
import Singular.CLI.Plan (outlayReport, refuseOver)
import Singular.CLI.Receipt
    ( FoldTransition
    , OutcomeClass (..)
    , chainTransitions
    )
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
import Singular.CLI.Trace
    ( EdgeAction (..)
    , Scope (..)
    , What (EdgeStarted, RequestSeen, RootSeen)
    , report
    )
import Singular.CLI.Trace qualified as Trace
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Evidence qualified as Cage
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
    ( currentPosixMs
    , extractCageDatum
    , policyIdFromPin
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
deadlineOf v r st =
    deadlineAt
        v
        (requestDeadline (requestSubmittedAt r) (stateProcessTime st))

-- | A deadline time, with its slot when the view converts it.
deadlineAt :: Cage.Session Cage.NoWitness IO -> Integer -> IO Deadline
deadlineAt v ms = Deadline ms <$> slotAt v ms

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
    -- ^ A pending request the fold must take (@--request@)
    , fsFund :: Maybe TxIn
    -- ^ The wallet output to fund and collateralise from (@--fund-input@)
    , fsAllowance :: Maybe Integer
    -- ^ The approved outlay (@--max-outlay@)
    }

-- | What the fold left at the application for one request.
data Delivery
    = -- | The output now holding the key's active token, under its envelope
      Delivered TxIn Envelope
    | -- | The live output the fold released, and the deposit it paid back
      Released TxIn Integer

-- | One request a confirmed fold settled.
data FoldedRequest = FoldedRequest
    { frRequest :: TxIn
    , frKey :: ByteString
    , frEdge :: Edge
    , frOwner :: ByteString
    , frDeadline :: Deadline
    , frDelivery :: Delivery
    }

-- | A confirmed, committed and observed fold.
data Folded = Folded
    { fdFolded :: NonEmpty FoldedRequest
    -- ^ Every request it settled, in batch order
    , fdExcluded :: [Value]
    -- ^ Every pending request it left, with the reason
    , fdFolder :: ByteString
    -- ^ The payment key hash of the wallet that signed and funded the fold
    , fdTx :: ConwayTx
    , fdRootBefore :: ByteString
    , fdRoot :: ByteString
    , fdDeadline :: Deadline
    -- ^ The earliest deadline among the requests it settled
    , fdUpperSlot :: Maybe SlotNo
    -- ^ The fold's validity upper bound, from the built transaction
    , fdPostBuild :: Value
    -- ^ The post-build check's verdict and the values it compared
    , fdDecidedAt :: Integer
    -- ^ The host's UTC clock, in POSIX milliseconds, when the fold was decided
    , fdRemaining :: Integer
    -- ^ Milliseconds between the moment the fold was decided and that deadline
    }

-- | One request the fold's view decided to take, and what it needs.
data Step = Step
    { stSelected :: SelectedRequest
    , stDeadline :: Deadline
    , stEnvelope :: Maybe Envelope
    , stHolding :: Maybe ((TxIn, TxOut ConwayEra), Envelope)
    }

-- | What the fold's view decided before anything was signed.
data Plan = Plan
    { plSteps :: NonEmpty Step
    , plExcluded :: [Value]
    , plTransitions :: [FoldTransition]
    , plRootAfter :: ByteString
    , plDeadline :: Deadline
    , plUpper :: Maybe SlotNo
    , plDecidedAt :: Integer
    , plPostBuild :: Value
    , plRemaining :: Integer
    }

{- | @singular registry fold@: fold every foldable pending request, signed and
funded by this wallet, and journal it. Whoever booked each request, and
whatever wallet, the registry directory they share says what the fold needs.
-}
runFold :: Env -> FoldArgs -> IO Value
runFold env a =
    attached
        env
        (foldRegistry a)
        (foldBlueprint a)
        (foldWrite a)
        "fold"
        $ \at -> do
        folded <-
            foldPending
                at
                FoldSpec
                    { fsOrigin = Standalone
                    , fsRequest = foldRequest a
                    , fsFund = foldFund a
                    , fsAllowance = foldMaxOutlay a
                    }
        pure (receipt "fold" Success (foldedFields folded))

{- | A fold's receipt fields, in the order a reader meets them: the same shape
for one request or many, and for every command that folds.
-}
foldedFields :: Folded -> [(Text, Value)]
foldedFields f =
    [ ("fold", toJSON (txIdHex (fdTx f)))
    , ("folder", toJSON (hexT (fdFolder f)))
    , ("folded", toJSON (map foldedJson (toList (fdFolded f))))
    , ("excluded", toJSON (fdExcluded f))
    , ("rootBefore", toJSON (hexT (fdRootBefore f)))
    , ("root", toJSON (hexT (fdRoot f)))
    , ("foldDeadline", deadlineJson (fdDeadline f))
    , ("validUntilSlot", toJSON (unSlotNo <$> fdUpperSlot f))
    , ("postBuild", fdPostBuild f)
    , ("hostClockMs", toJSON (fdDecidedAt f))
    , ("remainingMs", toJSON (fdRemaining f))
    ]
  where
    foldedJson r =
        object $
            [ "request" .= txInText (frRequest r)
            , "key" .= hexT (frKey r)
            , "edge" .= edgeName (frEdge r)
            , "owner" .= hexT (frOwner r)
            , "deadline" .= deadlineJson (frDeadline r)
            ]
                <> case frDelivery r of
                    Delivered out envelope ->
                        [ "liveOutput" .= txInText out
                        , "envelope" .= envelopeToJson envelope
                        ]
                    Released out deposit ->
                        [ "released" .= txInText out
                        , "deposit" .= deposit
                        ]

{- | A pending request as the fold reads it from its output, under the
registry's application policy and processing time: its datum, its deadline,
and the model's verdict on the approval it carries.
-}
pendingOf :: PolicyID -> Integer -> TxOut ConwayEra -> PendingRequest
pendingOf policy processTime out = case extractCageDatum out of
    Just (RequestDatum r) ->
        let deadline = requestDeadline (requestSubmittedAt r) processTime
        in  maybe
                (PendingDecoded r deadline)
                (PendingUnapproved r deadline)
                (approvalVerdict r approvals)
    _ -> PendingUndecodable "the output carries no request datum"
  where
    approvals = case out ^. valueTxOutL of
        MaryValue _ (MultiAsset m) ->
            [ (SBS.fromShort name, q)
            | (AssetName name, q) <-
                Map.toList (Map.findWithDefault Map.empty policy m)
            ]

-- | What a receipt states of a request the fold leaves.
exclusionJson
    :: (TxIn -> Maybe Deadline) -> (TxIn, Exclusion) -> Value
exclusionJson deadlineFor (i, why) =
    object $
        [ "request" .= txInText i
        , "reason" .= renderExclusion why
        ]
            <> maybe [] (\d -> ["deadline" .= deadlineJson d]) (deadlineFor i)
            <> case why of
                WindowClosed left -> ["remainingMs" .= left]
                EdgeUnsupported e -> ["edge" .= e]
                Undecodable detail -> ["detail" .= detail]
                RefusedByLaw _ -> []

{- | Fold every foldable pending request with the application's context,
commit the batch speculatively, replay the new public root, and journal the
fold observed.

The requests, their edges, their windows, the law over the batch, each
preimage or holding, each root after and the built fold all come from the
fold's own view; any refusal there happens before anything is signed.
-}
foldPending :: Attached -> FoldSpec -> IO Folded
foldPending at FoldSpec{..} = do
    let s = savedOf at
        cfg = savedCfg s
        wc = atWrite at
        addr = walletAddr (wcWallet wc)
        named = case fsOrigin of
            Combined booking -> Just (TxIn (txIdTx booking) (TxIx 0))
            Standalone -> fsRequest
        applicationPolicy = policyIdFromPin (cfgApplicationPolicy cfg)
    rootBefore <- selectedTrieRoot (atTrie at)
    spentState <- newIORef Nothing
    attempt <-
        try $
            submitBuiltIn
                wc
                "fold"
                ["state", "requests"]
                ( \p ->
                    Expectation
                        Nothing
                        "fold"
                        Nothing
                        (Just rootBefore)
                        (Just (plRootAfter p))
                        (plTransitions p)
                )
                ( \building v -> do
                    pending <-
                        sortOn fst
                            <$> Cage.outputsAt v (requestAddrFromCfg cfg (savedToken s) Testnet)
                    let pendingIns = map fst pending
                        stop' = stop fsOrigin named
                    -- What the requests' own outputs decide needs no clock and
                    -- no state: a fold left with nothing by it, or a named request
                    -- it leaves, is refused before anything else is read.
                    let early =
                            [ (i, why)
                            | (i, o) <- pending
                            , Just why <- [requestExclusion (pendingOf applicationPolicy 0 o)]
                            ]
                        earlyRefusal refusal =
                            stop'
                                ClientRefusal
                                (renderFoldRefusal refusal)
                                [("excluded", toJSON (map (exclusionJson (const Nothing)) early))]
                    forM_ named $ \r ->
                        forM_ (lookup r early) $ \why ->
                            earlyRefusal (NamedNotIncluded r (Just why))
                    when (length early == length pending) $
                        earlyRefusal (NothingToFold early)
                    live <- attachLive v s
                    writeIORef spentState (Just (fst (liveState live)))
                    st <- case extractCageDatum (snd (liveState live)) of
                        Just (StateDatum st) -> pure st
                        _ ->
                            stop'
                                ClientRefusal
                                "the registry's state output carries no state datum"
                                []
                    freshRoot <- either (failWith ClientRefusal) pure (observedRoot live)
                    unless (freshRoot == rootBefore) $
                        failTrie
                            ( TS.StaleState
                                (savedIdentity s)
                                Nothing
                                (TS.StaleRoot (Root rootBefore) (Root freshRoot))
                            )
                    requireTrieSelection s live (atTrie at)
                    outs <- liveOutputs v s
                    let reads' =
                            [ (i, pendingOf applicationPolicy (stateProcessTime st) o)
                            | (i, o) <- pending
                            ]
                        keys = nub [requestKey r | (_, PendingDecoded r _) <- reads']
                        held =
                            Set.fromList
                                [k | k <- keys, Right _ <- [liveOutputFor s k outs]]
                    leaves <- withTrie (atTrie at) $ \snap ->
                        fmap Map.fromList . forM keys $ \k ->
                            TS.leafAt snap k
                                >>= either failTrie (pure . (k,))
                    now <- currentPosixMs
                    -- No custody census: every edge consuming a custody entry is
                    -- one this command does not fold, left before the law.
                    let selection = selectFold now foldMarginMs (leafLaw leaves held Set.empty) reads'
                    deadlines <-
                        Map.fromList
                            <$> sequence
                                [ (i,) <$> deadlineAt v d
                                | (i, PendingDecoded _ d) <- reads'
                                ]
                    let excluded =
                            map
                                (exclusionJson (`Map.lookup` deadlines))
                                (selExcluded selection)
                        refusalFields =
                            [ ("excluded", toJSON excluded)
                            , ("hostClockMs", toJSON now)
                            ]
                    chosen <-
                        either
                            ( \refusal ->
                                stop' ClientRefusal (renderFoldRefusal refusal) refusalFields
                            )
                            pure
                            (foldRequests named selection)
                    steps <- forM chosen $ \sel -> do
                        let req = srRequest sel
                            key = requestKey req
                            deadline =
                                Map.findWithDefault
                                    (Deadline (srDeadlineMs sel) Nothing)
                                    (srInput sel)
                                    deadlines
                        case srKind sel of
                            FoldInsertion -> do
                                e <-
                                    either
                                        (\why -> stop' ClientRefusal why [])
                                        pure
                                        (carriedEnvelope req)
                                pure (Step sel deadline (Just e) Nothing)
                            FoldTermination -> do
                                h <-
                                    either
                                        (\why -> stop' ClientRefusal why [])
                                        pure
                                        (liveOutputFor s key outs)
                                pure (Step sel deadline Nothing (Just h))
                    narrateSelection building steps
                    let moves = fmap (move . stSelected) steps
                    rootsAfter <- withTrie (atTrie at) $ \snap ->
                        forM (NE.toList (NE.inits1 moves)) $
                            TS.speculateEdges snap
                                >=> either
                                    ( \why ->
                                        stop'
                                            ClientRefusal
                                            ("TrieState " <> T.unpack (TS.trieFailureName why))
                                            (TS.trieFailureFields why)
                                    )
                                    (pure . unRoot . TS.walkRoot)
                    let rootAfter = last (rootBefore : rootsAfter)
                        transitions =
                            chainTransitions
                                (hexT rootBefore)
                                [ ( txInText (srInput (stSelected step))
                                  , hexT (requestKey (srRequest (stSelected step)))
                                  , requestEdge (srRequest (stSelected step))
                                  , expectOf step
                                  , hexT r
                                  )
                                | (step, r) <- zip (toList steps) rootsAfter
                                ]
                        earliest = minimumBy (comparing deadlineMs) (fmap stDeadline steps)
                        remaining = deadlineMs earliest - now
                    ctx0 <-
                        registryContextFor cfg (savedCodes s) v (liveRefs (atLive at))
                    ctx <-
                        either
                            (\why -> stop' ClientRefusal why [])
                            pure
                            ( withApplication
                                (applied s)
                                Nothing
                                (map fst (mapMaybe stHolding (toList steps)))
                                ctx0
                            )
                    funded <-
                        fundedView fsFund addr v
                            >>= either
                                ( \why ->
                                    stop' ClientRefusal ("the wallet cannot fund the fold: " <> why) []
                                )
                                pure
                    built <-
                        try
                            ( withTrie (atTrie at) $ \snap ->
                                updateTokenSelected
                                    cfg
                                    funded
                                    snap
                                    (savedToken s)
                                    addr
                                    ctx
                                    (fmap (srInput . stSelected) steps)
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
                    either
                        (\why -> stop' ClientRefusal (why <> "; the fold is not submitted") [])
                        pure
                        ( spendsSelection
                            (fst (liveState live))
                            (map (srInput . stSelected) (toList steps))
                            pendingIns
                            spent
                        )
                    case unpaidOwners (releasesOwed steps) (paidPerKey unsigned) of
                        [] -> pure ()
                        short ->
                            stop'
                                ClientRefusal
                                ( "the built fold pays "
                                    <> T.unpack
                                        ( T.intercalate
                                            "; "
                                            [ "owner 0x"
                                                <> hexT owner
                                                <> " "
                                                <> T.pack (show paid)
                                                <> " of the "
                                                <> T.pack (show owed)
                                                <> " lovelace its releases owe"
                                            | (owner, owed, paid) <- short
                                            ]
                                        )
                                    <> "; the fold is not submitted"
                                )
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
                    -- the selection's window rule above is only the fast refusal.
                    postNow <- currentPosixMs
                    let upperI = toInteger . unSlotNo <$> upper
                        deadlineSlotI = toInteger . unSlotNo <$> deadlineSlot earliest
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
                        ( unsigned
                        , Plan
                            { plSteps = steps
                            , plExcluded = excluded
                            , plTransitions = transitions
                            , plRootAfter = rootAfter
                            , plDeadline = earliest
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
                            }
                        )
                )
    (fold, plan) <- case attempt of
        Right done -> pure done
        Left failure@(CommandFailure LedgerRefusal why _) -> do
            -- The node refused the fold: when the state output it spends is no
            -- longer live, another fold took it first. Its journal is already
            -- closed (@rejected@); nothing of this fold is on the chain.
            stateIn <- readIORef spentState
            lost <- case stateIn of
                Nothing -> pure False
                Just i ->
                    readStep
                        (wcTracer wc)
                        (wcSource wc)
                        ["state"]
                        (wcCapabilities wc)
                        ( \v ->
                            (/= i) . fst . liveState <$> attachLive v s
                        )
            if lost
                then
                    failWithFields
                        StaleState
                        ( "another fold spent the registry's state output "
                            <> maybe "" (T.unpack . txInText) stateIn
                            <> " before this one was included, so the node refused it ("
                            <> why
                            <> "); nothing of this fold is on the chain and its journal is closed: run the fold again for what is still pending"
                        )
                        []
                else throwIO failure
        Left failure -> throwIO failure
    harnessHoldAt "SINGULAR_HARNESS_HOLD_BEFORE_COMMIT" Nothing
    local <- readingBack at "fold" fold ["state"] $ \v -> do
        afterFold <- attachLive v s
        context <- openTrie s
        requireTrieSelection s afterFold context
        root <- selectedTrieRoot context
        unless (root == plRootAfter plan) $
            failWith
                StaleState
                "after the fold the public lineage reaches another root"
        pure root
    after <- readingBack at "fold" fold ["key outputs"] (`liveOutputs` s)
    settled <- forM (plSteps plan) $ \step -> do
        let sel = stSelected step
            req = srRequest sel
            key = requestKey req
            owner = fromBuiltin (requestOwner req)
        (delivery, detail) <- case (srKind sel, stEnvelope step, stHolding step) of
            (FoldInsertion, Just envelope, _) -> do
                ((liveIn, _), seen) <-
                    either (failWith Partial) pure (liveOutputFor s key after)
                unless (seen == envelope) $
                    failWith
                        Partial
                        ( "the output delivered at key 0x"
                            <> T.unpack (hexT key)
                            <> " carries another envelope"
                        )
                unless (ctlController (envControl seen) == owner) $
                    failWith
                        Partial
                        ( "the output delivered at key 0x"
                            <> T.unpack (hexT key)
                            <> " is controlled by another key than its request's owner"
                        )
                pure
                    ( Delivered liveIn seen
                    , "key 0x"
                        <> hexT key
                        <> " live at "
                        <> txInText liveIn
                        <> " under its envelope"
                    )
            (FoldTermination, _, Just ((liveIn, _), envelope)) -> do
                when (any ((== liveIn) . fst) after) $
                    failWith
                        Partial
                        ( "the fold confirmed but the live output of key 0x"
                            <> T.unpack (hexT key)
                            <> " is still unspent"
                        )
                pure
                    ( Released liveIn (ctlDeposit (envControl envelope))
                    , "key 0x" <> hexT key <> " released at " <> txInText liveIn
                    )
            _ ->
                failWith
                    Partial
                    "the fold's plan carries neither an envelope nor a holding"
        pure
            ( FoldedRequest
                { frRequest = srInput sel
                , frKey = key
                , frEdge = requestEdge req
                , frOwner = owner
                , frDeadline = stDeadline step
                , frDelivery = delivery
                }
            , detail
            )
    harnessHoldAt "SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED" Nothing
    journalObserved
        wc
        "fold"
        fold
        ( T.intercalate "; " (map snd (toList settled))
            <> "; root 0x"
            <> hexT local
        )
    forM_ (toList settled) $ \(done, _) ->
        report
            (wcTracer wc)
            [ InRequest (txInText (frRequest done))
            , InEdge (Folding (edgeText (frEdge done)))
            ]
            ( Trace.Folded (edgeText (frEdge done)) (frKey done) $
                case frDelivery done of
                    Delivered out _ -> txInText out
                    Released out _ -> txInText out
            )
    report (wcTracer wc) [] (RootSeen (hexT rootBefore) (hexT local))
    pure
        Folded
            { fdFolded = fmap fst settled
            , fdExcluded = plExcluded plan
            , fdFolder = callerKey at
            , fdTx = fold
            , fdRootBefore = rootBefore
            , fdRoot = local
            , fdDeadline = plDeadline plan
            , fdUpperSlot = plUpper plan
            , fdPostBuild = plPostBuild plan
            , fdDecidedAt = plDecidedAt plan
            , fdRemaining = plRemaining plan
            }
  where
    move sel = (requestKey (srRequest sel), requestEdge (srRequest sel))
    narrateSelection building steps = do
        forM_ (toList steps) $ \step -> do
            let req = srRequest (stSelected step)
                request = txInText (srInput (stSelected step))
                edge = edgeText (requestEdge req)
                dl = stDeadline step
            found
                building
                [InRequest request]
                ( RequestSeen
                    request
                    edge
                    (requestKey req)
                    (Just (deadlineMs dl))
                    (unSlotNo <$> deadlineSlot dl)
                )
        let scopes =
                concatMap
                    ( \step ->
                        let req = srRequest (stSelected step)
                        in
                            [ InRequest (txInText (srInput (stSelected step)))
                            , InEdge (Folding (edgeText (requestEdge req)))
                            ]
                    )
                    (toList steps)
            opening =
                edgeText
                    ( requestEdge
                        (srRequest (stSelected (NE.head steps)))
                    )
        place building scopes (EdgeStarted (Folding opening))
    expectOf step = case (srKind (stSelected step), stEnvelope step) of
        (FoldInsertion, Just e) -> "active:" <> hexT (envelopeHash e)
        _ -> "terminal"

-- | What the fold's terminations release to each envelope's controller.
releasesOwed :: NonEmpty Step -> [(ByteString, Integer)]
releasesOwed steps =
    [ (ctlController c, ctlDeposit c)
    | Just (_, e) <- map stHolding (toList steps)
    , let c = envControl e
    ]

-- | The lovelace a body pays each payment key, summed over its outputs.
paidPerKey :: ConwayTx -> [(ByteString, Integer)]
paidPerKey tx =
    [ (hashToBytes kh, unCoin (out ^. coinTxOutL))
    | out <- toList (tx ^. bodyTxL . outputsTxBodyL)
    , Addr _ (KeyHashObj (KeyHash kh)) _ <- [out ^. addrTxOutL]
    ]

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
            <> " s of the earliest processing deadline it folds, so it could not be included in time"
    BoundBeyondDeadlineSlot u s ->
        "its validity upper bound, slot "
            <> show u
            <> ", is after the earliest deadline slot "
            <> show s
    BoundUnconvertible ->
        "its validity upper bound cannot be converted to a time by the view that built it, and the deadline has no slot to compare it with"
    BoundAfterDeadline t ->
        "its validity upper bound begins at "
            <> show t
            <> " ms, after the earliest processing deadline it folds"

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

-- | An edge as the receipt and the narration name it.
edgeText :: Edge -> Text
edgeText = T.pack . edgeName
