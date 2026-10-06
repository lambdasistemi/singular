{-# LANGUAGE GADTs #-}

{- |
Module      : Conformance.Run.Live
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Live
    ( StepOutcome (..)
    , LiveStep (..)
    , LiveState (..)
    , runLive
    , runLiveNamed
    , newLiveState
    , tamperedRefunds
    , mintOnFirstKey
    , submitEdge
    , storyReferences
    , storyWitness
    , storyModelRequest
    , observeStep
    , observeAcceptedStep
    , classifyLeaves
    , observeCustody
    , walletHoldingsOf
    , heldObservation
    , observePaid
    , observeSigner
    , observeStepMint
    , observedStepTx
    , askModel
    , compareStep
    , tamperDifferences
    , reportedDifferences
    , differingPaths
    , renderStepPath
    , differenceJson
    , renderDifferences
    , WalletIdentity (..)
    , PolicyIdentity (..)
    , KeyIdentity (..)
    , DatumIdentity (..)
    , LiveIdentities (..)
    , newLiveIdentities
    , allocateIdentity
    , observeIdentity
    , prepareRegistrationIdentities
    , observePins
    , abstractConfig
    , bumpEvaluationField
    , bumpObservedMint
    , hexT
    , cg21PolicyBytes
    , readRegistryState
    , storyProofs
    , storyDelivery
    , storyApprovalOn
    , cg21RequestFacts
    ) where

import Conformance.FoldFixture qualified as FoldFixture
import Conformance.Run.Book
import Conformance.Run.Cage
import Conformance.Run.Control
import Conformance.Run.Environment
import Conformance.Run.Fold
import Conformance.Run.Observe
import Conformance.Run.Submit
import Conformance.Run.Units
import Conformance.Run.Wallet
import Singular.Registry.Evidence qualified as Cage

import Conformance.Compare.Perturbation qualified as Perturbation
import Conformance.Compare.Registration qualified as Compare
import Conformance.Lean.Oracle qualified as LeanOracle
import Conformance.NodeRejection (boundedNodeReason)
import Conformance.Observe.Payments qualified as Payments
import Conformance.PurposeUnits
    ( PurposeMeasurements
    , PurposeUnits
    , budgetRefusalPurposes
    , missingPurposeBudgets
    )
import Conformance.Receipt
    ( AssetEntry (..)
    , maxLiveStepReasonChars
    , stepReplay
    )
import Conformance.Story.Binding qualified as Binding
import Conformance.Story.Identity qualified as Identity
import Conformance.Story.Live qualified as Live
import Conformance.Story.Specification qualified as Specification
import Control.Concurrent (threadDelay)
import Control.Exception
    ( ErrorCall (..)
    , SomeException
    , displayException
    , throwIO
    , try
    )
import Control.Monad (forM, forM_, replicateM, unless, void, when)
import Control.Monad.Operational qualified as Operational
import Data.Aeson
    ( Value (..)
    , eitherDecodeFileStrict
    , encode
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List (nub, sort, sortOn, stripPrefix)
import Data.Map.Strict qualified as Map
import Data.Maybe
    ( catMaybes
    , fromMaybe
    , isJust
    , isNothing
    , listToMaybe
    )
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import Data.Word (Word8)
import Lens.Micro ((%~), (&), (.~), (^.))
import System.Environment (lookupEnv)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , serialiseAddr
    )

import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Api.PParams
    ( ppMaxBlockExUnitsL
    , ppMaxTxExUnitsL
    )
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , collateralInputsTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , datumTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits
    ( Redeemers (..)
    , rdmrsTxWitsL
    , scriptTxWitsL
    )
import Cardano.Ledger.BaseTypes (SlotNo (..), StrictMaybe (SJust))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (KeyHash, hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (KeyHash (..), extractHash)
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.Plutus.Data
    ( Data (..)
    , binaryDataToData
    , hashBinaryData
    )
import Cardano.Ledger.TxIn (TxIn (..), txInToText)
import Cardano.Node.Client.E2E.Setup (Ed25519DSIGN, SignKeyDSIGN)
import Cardano.Tx.Balance (BalanceResult (..), balanceTx)
import Cardano.Tx.Ledger (ConwayTx)

import PlutusTx (fromBuiltinData)
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger
    ( AssetName (..)
    , Coin (..)
    , ConwayEra
    , ExUnits (..)
    , PolicyID (..)
    , Root (..)
    , TokenId (..)
    , TxOut
    )
import Singular.Registry.LedgerProvider (SubmitResult (..))
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.Pure (mkPureTrie)
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , addrWitnessKeyHash
    , approvalDestination
    , approvalName
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , computeRefund
    , currentPosixMs
    , destinationDatumHash
    , emptyRoot
    , extractCageDatum
    , leafAbsent
    , leafActive
    , leafTerminal
    , mkInlineDatum
    , mkRequestScript
    , placeholderExUnits
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptHashBytes
    , spendingIndex
    , toLedgerData
    , toPlcData
    , trySlots
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , Edge
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef (..)
    , ProofStep (..)
    , RequestAction (Update)
    , RequestDestination
    , UpdateRedeemer (Modify, Retract)
    , edgeDeleteAbsent
    , edgeInsertAbsent
    , edgeUpdateActive
    , edgeWitnessTerminal
    )
import Singular.Registry.Types qualified as Types

import Conformance.Mirror
    ( emit
    , failWith
    , hex
    , require
    , txIdHex
    )
import Conformance.Replay
    ( ReasonComparison (..)
    , stepComparison
    )
import Conformance.Run.Replay
    ( ReplayIndex (..)
    , purposesOf
    , recordComparison
    , replayEvidenceOf
    )
import Conformance.Run.Retraction (declareRetraction)
import Conformance.Run.Step
    ( StepOutcome (..)
    , StepRejection (..)
    , judgedTransaction
    , refusedOutcome
    )

{- | Keep step diagnostics on one bounded line while retaining the full reason
in memory for the receipt writer's tighter bound.
-}
maxStepLineReasonChars :: Int
maxStepLineReasonChars = 4000

data LiveStep = LiveStep
    { lsCage :: RowCage
    , lsRequest :: Live.EdgeRequest Addr
    , lsExit :: Live.Exit
    , lsTamper :: Maybe Live.Tamper
    , lsRequestIn :: Maybe TxIn
    -- ^ the output reference the booked request sat at
    , lsRequestOut :: Maybe (TxOut ConwayEra)
    , lsModelRequest :: Value
    , lsRetraction :: Maybe Value
    {- ^ what the model's admission reads of a retraction or a fold, from the
    transaction as built
    -}
    , lsRequestLovelace :: Integer
    , lsAfter :: Maybe OnChainTokenState
    , lsWitness :: Maybe (TxIn, TxOut ConwayEra)
    , lsCustody :: Maybe (TxIn, TxOut ConwayEra)
    , lsStateUtxo :: Maybe (TxIn, TxOut ConwayEra)
    {- ^ the state input the accepted step spent, retained so observation can
    read what the ledger physically held; @Nothing@ where no step spent one
    -}
    , lsSpent :: [Integer]
    -- ^ the state tokens each input of the submitted transaction held
    , lsOutcome :: StepOutcome
    }

data LiveState = LiveState
    { liveIds :: LiveIdentities
    , livePendingComparisons :: IORef Int
    , liveStarts :: IORef (Map.Map String OnChainTokenState)
    , liveTraces :: IORef (Map.Map String [Value])
    , liveRegistryKeys :: IORef (Map.Map String [ByteString])
    , liveRegistryWallets :: IORef (Map.Map String [Addr])
    , liveRegistryIds :: IORef (Map.Map String Integer)
    , livePendingRequests
        :: IORef
            (Map.Map (String, String, Int, ByteString) (TxIn, TxOut ConwayEra))
    , liveRow :: String
    -- ^ the row the story runs for, naming its placement lines
    , liveSigners :: [(Addr, SignKeyDSIGN Ed25519DSIGN)]
    -- ^ the wallets a booked request may name as its owner, with their keys
    }

-- | Interpret shared story instructions against the running node and builders.
runLive
    :: Env -> Live.Story RowCage Addr LiveStep Value Value res -> IO res
runLive env = runLiveNamed env "" [] []

-- | The interpreter's state for one row, before it acts on any registry.
newLiveState
    :: String -> [(Addr, SignKeyDSIGN Ed25519DSIGN)] -> IO LiveState
newLiveState row signers =
    LiveState
        <$> newLiveIdentities
        <*> newIORef 0
        <*> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef Map.empty
        <*> pure row
        <*> pure signers

{- | Run a row's story. Its cohort is booked before the first instruction, each
request retained under its registry, key, edge and wallet: timing stories need
both requests pending before the first window opens, while ordinary stories
book as they act. Each placed reject is logged under the row, with its validity
interval and the window it lies in. A booked request may name as its owner only
a wallet given here, with the key that signs its booking.
-}
runLiveNamed
    :: Env
    -> String
    -> [(RowCage, Live.EdgeRequest Addr)]
    -> [(Addr, SignKeyDSIGN Ed25519DSIGN)]
    -> Live.Story RowCage Addr LiveStep Value Value res
    -> IO res
runLiveNamed env row prepared signers program = do
    state <- newLiveState row signers
    forM_ prepared $ \(cage, request) -> do
        tid <- cageTid cage
        named <- bookStoryRequest env state cage request Nothing
        let pendingKey =
                ( show tid
                , Live.requestKey request
                , fromEnum (Live.requestEdge request)
                , serialiseAddr (Live.requestWallet request)
                )
        modifyIORef' (livePendingRequests state) (Map.insert pendingKey named)
    result <- go state program
    remaining <- readIORef (livePendingComparisons state)
    require
        "live story submitted a request without comparing it"
        (remaining == 0)
    pure result
  where
    go
        :: LiveState
        -> Live.Story RowCage Addr LiveStep Value Value res
        -> IO res
    go state body = case Operational.view body of
        Operational.Return result -> pure result
        Specification.Action instruction Operational.:>>= next ->
            interpret state instruction >>= go state . next
        Specification.Theorem declaration body' Operational.:>>= next -> do
            let binding = Specification.theoremBinding declaration
            manifest <- Binding.loadManifest >>= either failWith pure
            require
                "live theorem binding is missing or stale"
                (Binding.resolveBinding manifest binding)
            emit "theorem" (Binding.boName binding)
            runClauses state binding (Specification.clauses body')
                >>= go state . next
    runClauses
        :: LiveState
        -> Binding.Binding
        -> Operational.Program
            ( Specification.Clause
                thm
                (Live.LiveI RowCage Addr LiveStep Value Value)
            )
            res
        -> IO res
    runClauses state binding body = case Operational.view body of
        Operational.Return result -> pure result
        Specification.Clause title check actions Operational.:>>= next -> do
            require
                "clause check names a different declaration than its enclosing theorem"
                ( binding
                    == Specification.theoremBinding (Specification.checkTheorem check)
                )
            emit "clause" title
            observation <- go state actions
            _ <- go state (Specification.checkAction check observation)
            runClauses state binding (next observation)
    interpret
        :: LiveState
        -> Live.LiveI RowCage Addr LiveStep Value Value obs
        -> IO obs
    interpret state instruction = case instruction of
        Live.Submit exit registry request -> do
            requirePlaced exit
            step <- submitEdge env state registry exit Nothing Nothing request
            modifyIORef' (livePendingComparisons state) (+ 1)
            pure step
        Live.Tamper alteration exit registry request -> do
            requirePlaced exit
            step <-
                submitEdge env state registry exit (Just alteration) Nothing request
            modifyIORef' (livePendingComparisons state) (+ 1)
            pure step
        Live.RejectWithin placement alteration registry request -> do
            step <-
                submitEdge
                    env
                    state
                    registry
                    Live.Reject
                    alteration
                    (Just placement)
                    request
            modifyIORef' (livePendingComparisons state) (+ 1)
            pure step
        Live.FoldBatch alteration registry requests ->
            submitBatch
                env
                state
                registry
                Live.Fold
                Nothing
                (Left <$> alteration)
                [(request, Nothing) | request <- requests]
        Live.RejectBatchWithin placement alteration registry requests ->
            submitBatch
                env
                state
                registry
                Live.Reject
                (Just placement)
                (Right <$> alteration)
                requests
        Live.Observe step -> observeStep env state step
        Live.Compare step observation -> do
            result <- compareStep env state step observation
            modifyIORef' (livePendingComparisons state) (subtract 1)
            remaining <- readIORef (livePendingComparisons state)
            require
                "live story compared more requests than it submitted"
                (remaining >= 0)
            pure result
    -- Story validation refuses an unplaced reject; reaching here is a setup
    -- failure, never a step outcome.
    requirePlaced exit =
        when (exit == Live.Reject) $
            failWith "setup: a reject reached the interpreter without a placement"

{- | The same booking path for a prepared cohort, a single story action and a
batch. A request with a booking is booked by its owner, signing with the key the
row gave for that wallet, and holds its deposit beside the tip; any other is
booked by the runner's own wallet with the default deposit.
-}
bookStoryRequest
    :: Env
    -> LiveState
    -> RowCage
    -> Live.EdgeRequest Addr
    -> Maybe (Live.Booking Addr)
    -> IO (TxIn, TxOut ConwayEra)
bookStoryRequest env state cage request booking = do
    let key = TE.encodeUtf8 (T.pack (Live.requestKey request))
        edge = fromIntegral (fromEnum (Live.requestEdge request))
        cfg = rcCfg cage
    tid <- cageTid cage
    refs <- storyReferences env cage key edge
    (owner, signer, deposit) <- case booking of
        Nothing -> pure (genesisAddr, genesisSignKey, cgDeposit)
        Just (Live.Booking owner deposit) -> case lookup owner (liveSigners state) of
            Just signer -> pure (owner, signer, deposit)
            Nothing ->
                failWith
                    "setup: a booked request names an owner the row gave no key for"
    -- The datum the request carries is named while booking, by its hash, so a
    -- delivery carrying it is later looked up rather than invented.
    forM_ (snd (storyDestination request)) $ \carried ->
        void
            ( allocateIdentity
                (liveDatums (liveIds state))
                (DatumIdentity (destinationDatumHash (Just carried)))
            )
    bookEdge
        env
        cfg
        tid
        owner
        signer
        key
        edge
        (storyDestination request)
        refs
        (defaultTipCoin cfg + deposit)

{- | Name the owner a booking names as a wallet of the registry, while booking:
its identity is allocated and its outputs are read as the registry's.
-}
noteOwner :: LiveState -> String -> Addr -> IO ()
noteOwner state registry owner = do
    _ <-
        allocateIdentity
            (liveWallets (liveIds state))
            (WalletIdentity (serialiseAddr owner))
    modifyIORef'
        (liveRegistryWallets state)
        ( Map.alter
            ( \known ->
                Just
                    ( case known of
                        Just wallets | owner `elem` wallets -> wallets
                        Just wallets -> owner : wallets
                        Nothing -> [owner]
                    )
            )
            registry
        )

{- | The destination the edge books, carrying no datum: the live stories book
no request carrying one.
-}
storyDestination :: Live.EdgeRequest Addr -> RequestDestination
storyDestination request = case Live.requestEdge request of
    Live.UpdateTerminal -> (BS.empty, Nothing)
    Live.DeleteActive -> (BS.empty, Nothing)
    _ -> (serialiseAddr (Live.requestWallet request), Nothing)

{- | One story instruction books a request, or takes the request retained for
it: one booked with its cohort, or one left pending by a refused exit, so the
control spends the same request. All later work keeps its outref, so a refused
request left at the script cannot leak into a fold. The request then leaves by
the instruction's exit: folded by its own edge, rejected in the window its
placement names, or retracted by its owner.
-}
submitEdge
    :: Env
    -> LiveState
    -> RowCage
    -> Live.Exit
    -> Maybe Live.Tamper
    -> Maybe Live.Placement
    -> Live.EdgeRequest Addr
    -> IO LiveStep
submitEdge env state cage exit alteration placement request = do
    let key = TE.encodeUtf8 (T.pack (Live.requestKey request))
        cfg = rcCfg cage
        edge = fromIntegral (fromEnum (Live.requestEdge request))
        wallet = Live.requestWallet request
        ids = liveIds state
    (tid, before) <- enterRegistry env state cage
    let registry = show tid
    noteRequest state cage registry request
    refs <- storyReferences env cage key edge
    let pendingKey =
            ( registry
            , Live.requestKey request
            , fromEnum (Live.requestEdge request)
            , serialiseAddr wallet
            )
    retained <-
        Map.lookup pendingKey <$> readIORef (livePendingRequests state)
    booking <- case (exit, retained) of
        (_, Just named) -> pure (Right named)
        _ -> try @ErrorCall (bookStoryRequest env state cage request Nothing)
    case booking of
        Left failure -> case stripPrefix
            ( "conformance: bookEdge refused (edge "
                <> show edge
                <> ", key "
                <> show key
                <> "): "
            )
            (displayException failure) of
            Just nodeReason -> do
                let (_, _, codes) = envCodes env
                    decided =
                        RegistryEdges.bookingApproval
                            codes
                            edge
                            key
                            (addrKeyHashBytes genesisAddr)
                            (approvalDestination (storyDestination request))
                modelRequest <-
                    storyModelRequest
                        ids
                        cfg
                        exit
                        request
                        cgDeposit
                        (stateMaxFee before)
                        Nothing
                        (Left decided)
                pure
                    ( LiveStep
                        cage
                        request
                        exit
                        alteration
                        Nothing
                        Nothing
                        modelRequest
                        Nothing
                        0
                        Nothing
                        Nothing
                        Nothing
                        Nothing
                        []
                        (StepUnsupported Nothing (T.pack nodeReason) Nothing)
                    )
            Nothing -> throwIO failure
        Right named@(reqIn, reqOut) -> do
            when (alteration `elem` map Just [Live.Unsigned, Live.BeforePhase2]) $
                modifyIORef' (livePendingRequests state) (Map.insert pendingKey named)
            let Coin bond = reqOut ^. coinTxOutL
                deposit = bond - stateMaxFee before
            require
                "booked request holds less than the on-chain processing tip"
                (deposit >= 0)
            -- The output reference the request sits at is named while acting;
            -- a retraction's return is bound to it.
            reference <-
                allocateIdentity
                    (liveReferences ids)
                    (ReferenceIdentity (txInReference reqIn))
            modelRequest <-
                storyModelRequest
                    ids
                    cfg
                    exit
                    request
                    deposit
                    (stateMaxFee before)
                    (Just reference)
                    (Right reqOut)
            bindBookedApproval ids cfg reqOut modelRequest
            -- A payment tamper sends what it moves to a wallet other than the
            -- request's, whose identity is allocated here, while acting.
            elsewhere <- case alteration of
                Just payment | payment `elem` [Live.OtherAddress, Live.ShortByOne] -> do
                    other <-
                        if wallet == genesisAddr
                            then snd <$> secondWallet env
                            else pure genesisAddr
                    _ <-
                        allocateIdentity
                            (liveWallets ids)
                            (WalletIdentity (serialiseAddr other))
                    modifyIORef'
                        (liveRegistryWallets state)
                        ( Map.adjust
                            (\known -> if other `elem` known then known else other : known)
                            registry
                        )
                    pure (Just other)
                _ -> pure Nothing
            ownerKey <- requestOwnerKey reqOut
            let facts =
                    Payments.ExitFacts
                        exit
                        (Live.requestEdge request)
                        ownerKey
                        Nothing
                        (Just (txInReference reqIn))
                editsOf transaction = either (failWith . (("tamper: " <> show alteration <> ": ") <>)) pure $
                    case alteration of
                        Just Live.Unsigned | exit == Live.Retract -> Right []
                        Just Live.Unsigned -> Left "only a retraction can omit its owner's signature"
                        Just timing
                            | timing `elem` [Live.BeforePhase2, Live.AfterPhase2] ->
                                if exit == Live.Retract
                                    then Right []
                                    else Left "only a retraction has a phase-2 validity interval"
                        _ ->
                            maybe
                                (Right [])
                                ( \t ->
                                    Payments.tamperEdits
                                        t
                                        facts
                                        (map snd (foldOutputsOf cfg transaction))
                                )
                                alteration
            -- The exit's transaction, assembled with the given per-purpose units
            -- (none: the builder's own) and tampered; its collateral; and the
            -- active witness a fold spends.
            (build, collateral, witness) <- case exit of
                Live.Retract ->
                    retractionBuilder env ids cage tid named elsewhere alteration editsOf
                _ ->
                    foldingBuilder
                        env
                        cage
                        tid
                        exit
                        alteration
                        placement
                        request
                        named
                        before
                        elsewhere
                        editsOf
            (unsigned, measurements, declaredPairs) <- declareUnits env build
            -- A placed reject must lie inside the window its step names before
            -- it is submitted; the placement is logged with the interval.
            forM_ placement $ \placed ->
                checkPlacement env (liveRow state) placed reqOut before unsigned
            let allInputs = Set.toList (unsigned ^. bodyTxL . inputsTxBodyL)
            pending <- pendingRequests env cage
            require
                "generic step spent another pending request"
                (filter (`elem` map fst pending) allInputs == [reqIn])
            let wanted = Set.insert collateral (unsigned ^. bodyTxL . inputsTxBodyL)
            visible <-
                fmap
                    (Map.fromList . concat)
                    ( mapM
                        (\a -> Cage.withLatest (envProv env) (`Cage.outputsAt` a))
                        [ genesisAddr
                        , wallet
                        , requestAddrFromCfg cfg tid (network cfg)
                        , cageAddrFromCfg cfg (network cfg)
                        ]
                    )
            emit
                "step-inputs"
                ( "request="
                    <> T.unpack (txInToText reqIn)
                    <> " collateral="
                    <> T.unpack (txInToText collateral)
                    <> " inputs="
                    <> show (map txInToText allInputs)
                    <> " visible="
                    <> show (map txInToText (Map.keys visible))
                )
            require
                "generic fold has an input missing from the chain snapshot"
                (all (`Map.member` visible) (Set.toList wanted))
            let signedWitnessed = signTx genesisSignKey unsigned
                signed = signedTx signedWitnessed
                submittedBudgets = transactionPurposeUnits signed
                -- What each spent input holds of the state policy, which every
                -- registry's state token is minted under.
                statePolicy = cg21PolicyBytes (cagePolicyIdFromCfg cfg)
                spent =
                    [ maybe
                        0
                        ( sum
                            . Map.elems
                            . Map.findWithDefault Map.empty statePolicy
                            . outAssets
                        )
                        (Map.lookup input visible)
                    | input <- allInputs
                    ]
                -- The state input the step spends, as the chain held it before
                -- submission: the one spent output holding a state token. None,
                -- or more than one, retains nothing, and observation refuses.
                retainedState =
                    case [ (input, out)
                         | (input, held) <- zip allInputs spent
                         , held > 0
                         , Just out <- [Map.lookup input visible]
                         ] of
                        [one] -> Just one
                        _ -> Nothing
            require
                "assembled fold changed its per-purpose declarations"
                (submittedBudgets == declaredPairs)
            emit
                "step-units"
                ( "measured="
                    <> compactJson (purposeMeasurementsJson measurements)
                    <> " declared="
                    <> compactJson (purposeDeclarationsJson measurements submittedBudgets)
                )
            result <- submitTxResilient (envSubmit env) signedWitnessed
            -- What the model's admission reads of a retraction or a fold is read
            -- off the transaction as built, after it has been submitted.
            retraction <- case exit of
                Live.Retract -> Just <$> retractionWitness env state cage reqOut signed
                Live.Fold -> Just <$> foldWitnessOf env signed
                Live.Reject -> pure Nothing
            case result of
                SubmitAccepted _ -> do
                    modifyIORef' (livePendingRequests state) (Map.delete pendingKey)
                    case alteration of
                        Just payment
                            | payment /= Live.ExtraSigner ->
                                failWith
                                    ( Live.tamperName payment
                                        <> " FINDING: chain accepted tampered "
                                        <> Live.exitName exit (Live.requestEdge request)
                                        <> " for "
                                        <> Live.requestKey request
                                        <> " ("
                                        <> txIdHex signed
                                        <> ")"
                                    )
                        _ -> pure ()
                    confirmTx env signed
                    -- Only a fold moves the trie; a reject and a retraction leave it.
                    when (exit == Live.Fold) $ rowCommit env cage key edge
                    after <- readRegistryState env cage
                    (mem, cpu) <-
                        either
                            (failWith . T.unpack)
                            pure
                            (aggregatePurposeUnits measurements)
                    writeIORef (rcUnits cage) (mem, cpu)
                    modifyIORef'
                        (envLiveMeasurements env)
                        (<> [(mem, cpu, txSizeBytes signed)])
                    pure
                        ( LiveStep
                            cage
                            request
                            exit
                            alteration
                            (Just reqIn)
                            (Just reqOut)
                            modelRequest
                            retraction
                            bond
                            (Just after)
                            witness
                            (custodyOf refs)
                            retainedState
                            spent
                            (StepAccepted signed (mem, cpu, txSizeBytes signed))
                        )
                SubmitRefused reason -> do
                    let explanation = T.unpack reason
                        -- A retraction is judged by the request script, every other
                        -- exit by the state script.
                        marker =
                            if exit == Live.Retract
                                then requestMarkerOf cfg tid
                                else stateMarkerOf cfg
                        diagnostic =
                            StepRejection
                                { srText = T.pack explanation
                                , srMeasured = measurements
                                , srDeclared = declaredPairs
                                , srBudgetExceeded =
                                    budgetRefusalPurposes
                                        (transactionPurposeHashes signed visible)
                                        (T.pack explanation)
                                }
                    pure
                        ( LiveStep
                            cage
                            request
                            exit
                            alteration
                            (Just reqIn)
                            (Just reqOut)
                            modelRequest
                            retraction
                            bond
                            Nothing
                            witness
                            (custodyOf refs)
                            Nothing
                            spent
                            (refusedOutcome marker signed diagnostic)
                        )
                unavailable -> failWith ("submission unavailable: " <> show unavailable)
  where
    -- A fold spends the custody its edge consumes; a reject and a retraction
    -- consume none.
    custodyOf refs = if exit == Live.Fold then listToMaybe refs else Nothing

{- | One batch instruction: book every request — or take the one a refused batch
left pending under the same registry, key, edge and wallet — take them all by
one exit in one transaction — folded, each on its own edge, or rejected in the
window the placement names — submit it, and ask the model the matching batch
question through the transport. A request whose booking names an owner and a
deposit is booked by that owner holding that deposit; any other is booked by
the runner's own wallet with the default deposit. The requests are spent, and
asked, in the transaction's input order, which is the order the registry folds
them in. Each folded request claims what an honest folder claims for it, the
delta of its own edge, which the model reads off its own table rather than off
the transaction built. A refund tamper changes the refunds a reject batch pays
before its units are declared, so the tampered transaction is the one
evaluated. The record says what the chain did, what the model answered and
whether their outcomes agree; comparing the batch's observations is left to the
row that submits it. An accepted batch is measured, as an accepted step is, and
an accepted reject batch must leave the registry's root as it was.
-}
submitBatch
    :: Env
    -> LiveState
    -> RowCage
    -> Live.Exit
    -> Maybe Live.Placement
    -> Maybe (Either Live.BatchTamper Live.RefundTamper)
    -> [(Live.EdgeRequest Addr, Maybe (Live.Booking Addr))]
    -> IO Value
submitBatch env state cage exit placement alteration requests = do
    let cfg = rcCfg cage
        ids = liveIds state
    (tid, before) <- enterRegistry env state cage
    let registry = show tid
        pendingKeyOf request =
            ( registry
            , Live.requestKey request
            , fromEnum (Live.requestEdge request)
            , serialiseAddr (Live.requestWallet request)
            )
    mapM_ (noteRequest state cage registry . fst) requests
    -- The owner a booking names is a wallet of this registry, named while
    -- booking.
    mapM_
        (noteOwner state registry . Live.bookingOwner)
        [booking | (_, Just booking) <- requests]
    named <- forM requests $ \(request, booking) -> do
        retained <-
            Map.lookup (pendingKeyOf request)
                <$> readIORef (livePendingRequests state)
        utxo <-
            maybe (bookStoryRequest env state cage request booking) pure retained
        pure (request, maybe genesisAddr Live.bookingOwner booking, utxo)
    let sorted = sortOn (\(_, _, (reqIn, _)) -> reqIn) named
        booked = [(request, utxo) | (request, _, utxo) <- sorted]
        owners = [owner | (_, owner, _) <- sorted]
    modelRequests <- forM (zip booked owners) $ \((request, (reqIn, reqOut)), owner) -> do
        let Coin bond = reqOut ^. coinTxOutL
            deposit = bond - stateMaxFee before
        require
            "booked request holds less than the on-chain processing tip"
            (deposit >= 0)
        reference <-
            allocateIdentity
                (liveReferences ids)
                (ReferenceIdentity (txInReference reqIn))
        modelRequest <-
            storyModelRequestBy
                owner
                ids
                cfg
                exit
                request
                deposit
                (stateMaxFee before)
                (Just reference)
                (Right reqOut)
        bindBookedApproval ids cfg reqOut modelRequest
        pure modelRequest
    witnesses <-
        if exit == Live.Fold
            then
                catMaybes
                    <$> mapM
                        ( \(request, _) ->
                            storyWitness
                                env
                                cfg
                                (TE.encodeUtf8 (T.pack (Live.requestKey request)))
                                (Live.requestWallet request)
                        )
                        booked
            else pure []
    (actions, root, lower, reach) <- case exit of
        Live.Reject -> do
            placed <-
                maybe
                    ( failWith
                        "setup: a batch reject reached the builder without a placement"
                    )
                    pure
                    placement
            -- Every request's window: the batch is placed where all of them are.
            let windows =
                    [ Live.placementWindow
                        placed
                        (snd (requestDatumOf out))
                        (stateProcessTime before)
                        (stateRetractTime before)
                    | (_, (_, out)) <- booked
                    ]
                opens = maximum (0 : map fst windows)
                closes = case [c | (_, Just c) <- windows] of
                    [] -> Nothing
                    cs -> Just (minimum cs)
            lower <-
                if null windows
                    then pure Nothing
                    else do
                        sleepUntil (opens + 500)
                        Just
                            <$> Cage.withLatest
                                (envProv env)
                                (\v -> trySlots v [opens + 400, opens + 200, opens + 100])
            pure
                ( map (const Types.Rejected) booked
                , Root (unOnChainRoot (stateRoot before))
                , lower
                , \now ->
                    map
                        (maybe id (\c -> min (c - 1_000)) closes . (now +))
                        [30_000, 20_000, 15_000, 8_000]
                )
        Live.Fold -> do
            (proofs, root) <- storyProofs env cage tid (map snd booked)
            pure
                ( map Update proofs
                , root
                , Nothing
                , \now -> [now + 8_000, now + 7_500, now + 7_000]
                )
        Live.Retract -> failWith "setup: a batch takes no retraction"
    (refunds, besides) <- case alteration of
        Just (Right refundTamper)
            | exit /= Live.Reject ->
                failWith "setup: a refund tamper reached a batch that is not a reject"
            | otherwise ->
                either failWith pure $
                    tamperedRefunds
                        refundTamper
                        [ let Coin bond = out ^. coinTxOutL in bond - stateMaxFee before
                        | (_, (_, out)) <- booked
                        ]
                        owners
        _ -> pure ([], [])
    stateUtxo <- cageStateUtxo env cage
    (pot, funder) <- collateralPotWithChange env
    let spec =
            (rowSpec cage tid stateUtxo (map snd booked) actions root (ExUnits 0 0))
                { fsCollateral = Just pot
                , fsSigners = Just []
                , fsHolderUtxos = witnesses
                , fsFunder = Just funder
                , fsLower = lower
                , fsRefunds = refunds
                , fsExtraOutputs = besides
                }
        build units = do
            now <- currentPosixMs
            upper <- Cage.withLatest (envProv env) (`trySlots` reach now)
            assembleFoldWithFee
                env
                spec{fsPurposeUnits = units, fsUpper = Just upper}
    (unsigned, measurements, declaredPairs) <- declareUnits env build
    forM_ placement $ \placed ->
        forM_ booked $ \(_, (_, reqOut)) ->
            checkPlacement env (liveRow state) placed reqOut before unsigned
    let tampered = case alteration of
            Just (Left Live.MintOnFirstKey) -> case booked of
                (first, _) : _ ->
                    mintOnFirstKey
                        (pinnedPolicies cfg)
                        (TE.encodeUtf8 (T.pack (Live.requestKey first)))
                        [TE.encodeUtf8 (T.pack (Live.requestKey r)) | (r, _) <- booked]
                        unsigned
                [] -> unsigned
            _ -> unsigned
        signedWitnessed = signTx genesisSignKey tampered
        signed = signedTx signedWitnessed
        -- An honest folder claims, for each request, the delta of its own edge;
        -- the model reads that claim off its own table ("canonical"), never off
        -- the transaction the builder made, so a builder minting otherwise is
        -- refused by the chain while the model accepts the lawful batch. A
        -- tampered batch claims what its transaction mints at each key, read
        -- off the transaction as submitted.
        claimOf request = case alteration of
            Just (Left _) -> toJSON (claimedAt cfg signed (Live.requestKey request))
            _ -> String "canonical"
        asked =
            [ case (exit, modelRequest) of
                (Live.Fold, Object fields) ->
                    Object (KM.insert "claimed" (claimOf request) fields)
                (Live.Fold, other) -> other
                _ -> object ["exit" .= String "reject", "request" .= modelRequest]
            | ((request, _), modelRequest) <- zip booked modelRequests
            ]
    result <- submitTxResilient (envSubmit env) signedWitnessed
    measured <- case result of
        SubmitAccepted _ -> do
            confirmTx env signed
            forM_ booked $ \(request, _) ->
                modifyIORef'
                    (livePendingRequests state)
                    (Map.delete (pendingKeyOf request))
            -- Only a fold moves the trie; a reject leaves it.
            if exit == Live.Fold
                then forM_ booked $ \(request, _) ->
                    rowCommit
                        env
                        cage
                        (TE.encodeUtf8 (T.pack (Live.requestKey request)))
                        (fromIntegral (fromEnum (Live.requestEdge request)))
                else do
                    after <- readRegistryState env cage
                    require
                        "an accepted reject batch moved the registry's root"
                        (stateRoot after == stateRoot before)
            (mem, cpu) <-
                either
                    (failWith . T.unpack)
                    pure
                    (aggregatePurposeUnits measurements)
            let size = txSizeBytes signed
            modifyIORef' (envLiveMeasurements env) (<> [(mem, cpu, size)])
            pure (Just (mem, cpu, size))
        SubmitRefused _ -> do
            -- A refused batch leaves its requests pending; a later batch naming
            -- them spends the same ones.
            forM_ booked $ \(request, utxo) ->
                modifyIORef'
                    (livePendingRequests state)
                    (Map.insert (pendingKeyOf request) utxo)
            pure Nothing
        unavailable -> failWith ("submission unavailable: " <> show unavailable)
    batchRecord
        env
        state
        cage
        exit
        alteration
        (map snd booked)
        asked
        signed
        result
        measured
        (measurements, declaredPairs)

{- | The refunds a refund tamper pays, in the transaction's input order, from
what each request is owed and who owns it, and the outputs it adds beside them:
the change takes what a shortfall withholds unless the tamper puts it at the
first owner's key.
-}
tamperedRefunds
    :: Live.RefundTamper
    -> [Integer]
    -> [Addr]
    -> Either String ([Integer], [TxOut ConwayEra])
tamperedRefunds alteration owed owners = case (alteration, owed, owners) of
    (Live.CrossedRefunds, first : rest@(_ : _), _) -> Right (rest <> [first], [])
    (Live.CrossedRefunds, _, _) -> Left "crossed refunds need two requests to cross"
    (Live.ShortFirstRefund lovelace, first : rest, _) ->
        Right (first - lovelace : rest, [])
    (Live.SplitFirstRefund lovelace, first : rest, owner : _) ->
        Right
            ( first - lovelace : rest
            , [mkBasicTxOut owner (MaryValue (Coin 2_000_000) mempty)]
            )
    _ -> Left "a tampered refund needs a request to refund"

{- | Ask the model the batch a submitted transaction took, and compare. The
question is the model's matching batch question from where the registry's
compared trace leaves it; a reject batch also carries the outputs through which
the chain settles what the batch owes its owners, so the model's verdict is the
law's, then @settle@'s. When both refuse, the reason the traced replay of the
refused transaction admitted for the state script, which judges every batch,
meets the model's: written to the rejection's index entry first, then, when it
differs, failing the row naming both. The record says what the chain did, what
the model answered and whether they agree, and is added to the row's records.
-}
batchRecord
    :: Env
    -> LiveState
    -> RowCage
    -> Live.Exit
    -> Maybe (Either Live.BatchTamper Live.RefundTamper)
    -> [(TxIn, TxOut ConwayEra)]
    -> [Value]
    -> ConwayTx
    -> SubmitResult
    -> Maybe (Integer, Integer, Integer)
    -> (PurposeMeasurements, PurposeUnits)
    -> IO Value
batchRecord env state cage exit alteration booked asked signed result units (measured, declared) = do
    let cfg = rcCfg cage
        ids = liveIds state
        txid = T.pack (txIdHex signed)
    tid <- cageTid cage
    let registry = show tid
        stateMarker = stateMarkerOf cfg
        attributed hashes =
            [ name :: T.Text
            | (name, marker) <-
                [ ("state", stateMarker)
                , ("request", requestMarkerOf cfg tid)
                ]
            , T.pack marker `elem` hashes
            ]
    chainSide <- case result of
        SubmitAccepted _ -> pure (Right ())
        SubmitRefused reason ->
            pure . Left $
                refusedOutcome
                    stateMarker
                    signed
                    StepRejection
                        { srText = reason
                        , srMeasured = measured
                        , srDeclared = declared
                        , srBudgetExceeded = []
                        }
        unavailable -> failWith ("submission unavailable: " <> show unavailable)
    -- A reject batch is judged on the outputs crediting each owner it owes.
    judged <- case exit of
        Live.Reject -> do
            wallets <-
                maybe (failWith "registry has no allocated wallets") pure
                    . Map.lookup registry
                    =<< readIORef (liveRegistryWallets state)
            owners <- nub <$> mapM (requestOwnerKey . snd) booked
            Just . concat
                <$> mapM
                    ( \owner -> do
                        address <- ownerIdentity ids wallets owner
                        pure
                            [ object
                                [ "role" .= ("owner" :: T.Text)
                                , "address" .= address
                                , "lovelace" .= Payments.outputLovelace out
                                , "datum" .= Payments.outputDatum out
                                , "reference" .= (Nothing :: Maybe Integer)
                                ]
                            | (_, out) <- foldOutputsOf cfg signed
                            , Payments.creditsOwner owner out
                            ]
                    )
                    owners
        _ -> pure Nothing
    (_, startValue, setup) <- modelStart state cage
    foldWitness <-
        if exit == Live.Fold then Just <$> foldWitnessOf env signed else pure Nothing
    let batchName = if exit == Live.Fold then "foldBatch" else "rejectBatch" :: T.Text
        question =
            object $
                [ "question" .= batchName
                , "id" .= String "live-batch"
                , "theorem" .= String "Singular.Driver.runSurface"
                , "statementSha256" .= String "4242624938955313763"
                , "start" .= startValue
                , "setup" .= setup
                , "requests" .= asked
                ]
                    <> ["outputs" .= outputs | Just outputs <- [judged]]
                    <> ["foldWitness" .= w | Just w <- [foldWitness]]
    evaluator <- requireEnv "CONFORMANCE_MODEL_EVALUATOR"
    row <-
        LeanOracle.expectedObservation evaluator [] question
            >>= either failWith pure
    (modelOutcome, modelReason) <-
        either
            failWith
            pure
            (LeanOracle.modelVerdict row (row <$ judged))
    -- Both refuse: the reason the replay admitted for the state script meets
    -- Lean's, recorded on the rejection's entry before anything acts on it.
    reasonCheck <- case (chainSide, modelOutcome, modelReason) of
        (Left (StepRefused{}), String "refused", String lean) -> do
            control <-
                lookupEnv "CONFORMANCE_REASON_CONTROL"
                    >>= traverse (either failWith pure . parseReasonControl)
            rowName <- readIORef (riRow (envReplay env))
            compared <- length <$> readIORef (envLiveRecords env)
            let lean' = controlledReason control rowName compared lean
            purposes <- purposesOf (envReplay env) txid
            let comparison = stepComparison (T.pack stateMarker) lean' purposes
            recordComparison (envReplay env) txid lean' comparison
            pure (Just (lean', comparison))
        _ -> pure Nothing
    evidence <- case chainSide of
        Left (StepRefused{}) -> replayEvidenceOf (envReplay env) txid
        _ -> pure []
    let chainReason = case reasonCheck of
            Just (lean, Agrees) -> Just lean
            _ -> Nothing
        (chainOutcome, chain) = case chainSide of
            Right () ->
                ( String "accepted"
                , object $
                    ["outcome" .= String "accepted", "txid" .= txid]
                        <> ["measured" .= measuredJsonOf m | Just m <- [units]]
                )
            Left (StepRefused _ hashes rejection) ->
                ( String "refused"
                , object
                    [ "outcome" .= String "refused"
                    , "txid" .= txid
                    , "refusal"
                        .= stepReplay
                            evidence
                            ( withScripts
                                (attributed hashes)
                                (rejectionJson chainReason hashes rejection)
                            )
                    ]
                )
            Left other ->
                ( String "unsupported"
                , object
                    [ "outcome" .= String "unsupported"
                    , "txid" .= txid
                    , "reason" .= case other of
                        StepUnsupported _ why _ ->
                            boundedNodeReason maxLiveStepReasonChars why
                        _ -> "the refusal names no registry script"
                    ]
                )
        comparison
            | Just (_, Differs{}) <- reasonCheck = "disagrees"
            | modelOutcome == chainOutcome = "agrees"
            | otherwise = "disagrees" :: T.Text
    -- A batch the chain folded moves the registry the next question starts from.
    when (exit == Live.Fold && chainOutcome == String "accepted") $
        modifyIORef'
            (liveTraces state)
            (Map.insertWith (flip (<>)) registry asked)
    registryId <-
        maybe (failWith "batch registry was not allocated") pure
            . Map.lookup registry
            =<< readIORef (liveRegistryIds state)
    let record =
            object $
                [ "registry" .= registryId
                , "batch" .= batchName
                , "tamper" .= fmap tamperOf alteration
                , "requests" .= asked
                , "model" .= object ["outcome" .= modelOutcome, "reason" .= modelReason]
                , "chain" .= chain
                , "comparison" .= comparison
                , "compared" .= ["outcome" :: T.Text]
                ]
                    <> ["outputs" .= outputs | Just outputs <- [judged]]
                    <> [ "shortfall" .= lovelace
                       | Just (Right changed) <- [alteration]
                       , Just lovelace <- [Live.refundShortfall changed]
                       ]
    modifyIORef' (envLiveRecords env) (<> [record])
    emit
        "batch"
        ( T.unpack batchName
            <> " tamper="
            <> maybe "none" tamperOf alteration
            <> " model="
            <> show modelOutcome
            <> " modelReason="
            <> show modelReason
            <> " chain="
            <> show chainOutcome
            <> " txid="
            <> T.unpack txid
        )
    case reasonCheck of
        Just
            (_, Differs{chainReason = chainSideReason, leanReason = leanSide}) ->
                failWith
                    ( "model and chain refuse for different reasons for "
                        <> T.unpack batchName
                        <> " of "
                        <> show (length booked)
                        <> " requests: chain="
                        <> T.unpack chainSideReason
                        <> " lean="
                        <> T.unpack leanSide
                    )
        _ -> pure ()
    pure record
  where
    tamperOf = either Live.batchTamperName Live.refundTamperName

{- | The units and size of an accepted transaction, as a record carries them:
the measurement row reads the worst of them across the folds it names.
-}
measuredJsonOf :: (Integer, Integer, Integer) -> Value
measuredJsonOf (mem, cpu, size) = object ["mem" .= mem, "cpu" .= cpu, "size" .= size]

{- | What a transaction mints at a key under the registry's three pinned token
policies, by kind, read off the transaction as submitted.
-}
claimedAt :: CageConfig -> ConwayTx -> String -> [Value]
claimedAt cfg signed key =
    [ object ["kind" .= kind, "quantity" .= quantity]
    | (pin, kind) <-
        [ (cfgActivePolicy cfg, "active" :: T.Text)
        , (cfgAbsentPolicy cfg, "absent")
        , (cfgTerminalPolicy cfg, "terminal")
        ]
    , (policy, names) <- Map.toList minted
    , cg21PolicyBytes policy == SBS.fromShort pin
    , (AssetName name, quantity) <- Map.toList names
    , SBS.fromShort name == TE.encodeUtf8 (T.pack key)
    , quantity /= 0
    ]
  where
    MultiAsset minted = signed ^. bodyTxL . mintTxBodyL

-- | The registry's three pinned token policies, as raw script hash bytes.
pinnedPolicies :: CageConfig -> [ByteString]
pinnedPolicies cfg =
    map
        SBS.fromShort
        [cfgActivePolicy cfg, cfgAbsentPolicy cfg, cfgTerminalPolicy cfg]

{- | The 'Live.MintOnFirstKey' tamper: under the given policies, every quantity
the transaction mints, and every quantity its outputs carry, at one of the batch's
keys moves to the first key — the same quantity of each kind, at the wrong keys.
Nothing else of the transaction changes.
-}
mintOnFirstKey
    :: [ByteString] -> ByteString -> [ByteString] -> ConwayTx -> ConwayTx
mintOnFirstKey policies first keys tx =
    tx
        & bodyTxL . mintTxBodyL %~ moved
        & bodyTxL . outputsTxBodyL %~ fmap (valueTxOutL %~ movedValue)
  where
    movedValue (MaryValue coin assets) = MaryValue coin (moved assets)
    moved (MultiAsset byPolicy) = MultiAsset (Map.mapWithKey movePolicy byPolicy)
    movePolicy policy names
        | cg21PolicyBytes policy `elem` policies =
            let atKeys =
                    sum
                        [ q
                        | (AssetName n, q) <- Map.toList names
                        , SBS.fromShort n `elem` keys
                        ]
                others =
                    Map.filterWithKey
                        (\(AssetName n) _ -> SBS.fromShort n `notElem` keys)
                        names
            in  if atKeys == 0
                    then names
                    else Map.insert (AssetName (SBS.toShort first)) atKeys others
        | otherwise = names

{- | Enter the registry a story acts on: allocate its identity the first time,
and require it freshly booted then, so every model question starts from the
empty registry the chain held. Returns its present chain state.
-}
enterRegistry
    :: Env -> LiveState -> RowCage -> IO (TokenId, OnChainTokenState)
enterRegistry env state cage = do
    tid <- cageTid cage
    let registry = show tid
    -- Acting on a registry establishes its pinned policies, so a question
    -- about it can name them even when no request has yet.
    mapM_
        ( allocateIdentity (livePolicies (liveIds state))
            . PolicyIdentity
            . SBS.fromShort
        )
        (registryPins (rcCfg cage))
    knownRegistries <- readIORef (liveRegistryIds state)
    when (Map.notMember registry knownRegistries) $
        modifyIORef'
            (liveRegistryIds state)
            (Map.insert registry (fromIntegral (Map.size knownRegistries) + 1))
    before <- readRegistryState env cage
    starts <- readIORef (liveStarts state)
    case Map.lookup registry starts of
        Nothing -> do
            require
                "generic story requires a freshly booted empty registry"
                (unOnChainRoot (stateRoot before) == emptyRoot)
            modifyIORef' (liveStarts state) (Map.insert registry before)
        Just _ -> pure ()
    pure (tid, before)

{- | Note a request a story acts on: the identities it is named by, and its key
and wallet under its registry.
-}
noteRequest
    :: LiveState -> RowCage -> String -> Live.EdgeRequest Addr -> IO ()
noteRequest state cage registry request = do
    let key = TE.encodeUtf8 (T.pack (Live.requestKey request))
        wallet = Live.requestWallet request
    prepareRegistrationIdentities (liveIds state) cage key wallet
    modifyIORef'
        (liveRegistryKeys state)
        ( Map.alter
            ( \known ->
                Just
                    ( case known of
                        Nothing -> [key]
                        Just keys
                            | key `elem` keys -> keys
                            | otherwise -> key : keys
                    )
            )
            registry
        )
    modifyIORef'
        (liveRegistryWallets state)
        ( Map.alter
            ( \known ->
                Just
                    ( foldr
                        ( \address addresses ->
                            if address `elem` addresses then addresses else address : addresses
                        )
                        (fromMaybe [] known)
                        [wallet, genesisAddr]
                    )
            )
            registry
        )

{- | Measure a transaction's script purposes on the node and declare each its
own units, then assemble it again with them. Evaluation can consume the entire
short validity interval on a busy node, so the declared shape is assembled
immediately before submission; its fresh upper bound cannot age during
measurement.
-}
declareUnits
    :: Env
    -> (Map.Map T.Text ExUnits -> IO ConwayTx)
    -> IO (ConwayTx, PurposeMeasurements, PurposeUnits)
declareUnits env build = do
    pp <- Cage.withLatest (envProv env) Cage.parameters
    let maxUnits = pp ^. ppMaxTxExUnitsL
        blockUnits = pp ^. ppMaxBlockExUnitsL
    template <- build Map.empty
    let purposes = redeemerPurposeNames template
    require "honest fold has no redeemer purposes" (not (null purposes))
    probePairs <-
        either
            (failWith . T.unpack)
            pure
            (protocolProbePurposeUnits maxUnits blockUnits purposes)
    trial <- build (Map.map exUnits probePairs)
    measurements <- measurePurposeUnits env trial
    require
        "node evaluation did not return every redeemer purpose"
        (sort (Map.keys measurements) == sort (redeemerPurposeNames trial))
    declaredPairs <-
        either
            (failWith . T.unpack)
            pure
            (declaredPurposeUnits maxUnits blockUnits measurements)
    require
        "measured script purpose has no purpose-specific declaration"
        ( null
            ( missingPurposeBudgets
                (successfulPurposeUnits measurements)
                declaredPairs
            )
        )
    unsigned <- build (Map.map exUnits declaredPairs)
    pure (unsigned, measurements, declaredPairs)
  where
    exUnits (mem, cpu) = ExUnits (fromIntegral mem) (fromIntegral cpu)

{- | A fold or a reject of the booked request, through the harness's own fold
assembly: a fold carries the request's proof, a reject the @Rejected@ action
in the window its placement names, the root unchanged. The model requires no
signer; the extra-signer tamper adds the key this process already signs every
fold with, so the ledger has its witness and judges the signer alone.
-}
foldingBuilder
    :: Env
    -> RowCage
    -> TokenId
    -> Live.Exit
    -> Maybe Live.Tamper
    -> Maybe Live.Placement
    -> Live.EdgeRequest Addr
    -> (TxIn, TxOut ConwayEra)
    -> OnChainTokenState
    -> Maybe Addr
    -> (ConwayTx -> IO [Payments.OutputEdit])
    -> IO
        ( Map.Map T.Text ExUnits -> IO ConwayTx
        , TxIn
        , Maybe (TxIn, TxOut ConwayEra)
        )
foldingBuilder env cage tid exit alteration placement request named before elsewhere editsOf = do
    let cfg = rcCfg cage
        key = TE.encodeUtf8 (T.pack (Live.requestKey request))
    witness <-
        if exit == Live.Fold
            then storyWitness env cfg key (Live.requestWallet request)
            else pure Nothing
    (actions, root, lower, reach) <- case exit of
        Live.Reject -> do
            placed <-
                maybe
                    (failWith "setup: a reject reached the builder without a placement")
                    pure
                    placement
            let (_, submittedAt) = requestDatumOf (snd named)
                (opens, closes) =
                    Live.placementWindow
                        placed
                        submittedAt
                        (stateProcessTime before)
                        (stateRetractTime before)
            -- A window that has not opened is waited for; the lower bound falls
            -- inside it. The upper bound is set when the transaction is built,
            -- far enough ahead to outlast building and submitting it, and never
            -- past a window that closes; the whole interval is checked against
            -- the window before it is submitted.
            sleepUntil (opens + 500)
            lower <-
                Cage.withLatest (envProv env) $ \v ->
                    trySlots v [opens + 400, opens + 200, opens + 100]
            pure
                ( [Types.Rejected]
                , Root (unOnChainRoot (stateRoot before))
                , Just lower
                , \now ->
                    map
                        (maybe id (\c -> min (c - 1_000)) closes . (now +))
                        [30_000, 20_000, 15_000, 8_000]
                )
        _ -> do
            (proofs, root) <- storyProofs env cage tid [named]
            pure
                ( map Update proofs
                , root
                , Nothing
                , \now -> [now + 8_000, now + 7_500, now + 7_000]
                )
    stateUtxo <- cageStateUtxo env cage
    (pot, funder) <- collateralPotWithChange env
    let initialUnits = ExUnits 0 0
        initialSpec =
            (rowSpec cage tid stateUtxo [named] actions root initialUnits)
                { fsCollateral = Just pot
                , fsSigners =
                    Just
                        [ addrWitnessKeyHash (addrKeyHashBytes genesisAddr)
                        | alteration == Just Live.ExtraSigner
                        ]
                , fsHolderUtxos = maybe [] pure witness
                , fsFunder = Just funder
                , fsLower = lower
                , fsOmitUnfundedBurn =
                    exit == Live.Fold
                        && Live.requestEdge request == Live.UpdateTerminal
                        && isNothing witness
                }
    fixtureUnits <-
        FoldFixture.prepare
            (envFoldFixture env)
            (envProv env)
            (\budget -> assembleFoldWithFee env initialSpec{fsUnits = budget})
            (submitTxResilient (envSubmit env) . signTx genesisSignKey)
            initialUnits
    let spec = initialSpec{fsUnits = fixtureUnits}
        build units = do
            now <- currentPosixMs
            upper <-
                Cage.withLatest
                    (envProv env)
                    (`trySlots` reach now)
            transaction <-
                assembleFoldWithFee
                    env
                    spec{fsPurposeUnits = units, fsUpper = Just upper}
            edits <- editsOf transaction
            either
                (failWith . (("tamper: " <> show alteration <> ": ") <>))
                pure
                (editOutputs elsewhere Nothing transaction edits)
    pure (build, pot, witness)

{- | A retraction of the booked request by its owner, assembled before its
scripts are evaluated: the request is spent alone, its
return bound to it by an inline datum, the owner signing. A tamper edits that
transaction; spending the registry's state beside the request moves the state
from a reference input to an input, continued unchanged, with the state
validator resolved through the cage's reference output. The tampered shape is
then declared its own units and fee, the change absorbing the difference, and
collateralised by a dedicated pot.
-}
retractionBuilder
    :: Env
    -> LiveIdentities
    -> RowCage
    -> TokenId
    -> (TxIn, TxOut ConwayEra)
    -> Maybe Addr
    -> Maybe Live.Tamper
    -> (ConwayTx -> IO [Payments.OutputEdit])
    -> IO
        ( Map.Map T.Text ExUnits -> IO ConwayTx
        , TxIn
        , Maybe (TxIn, TxOut ConwayEra)
        )
retractionBuilder env ids cage tid (reqIn, reqOut) elsewhere alteration editsOf = do
    let cfg = rcCfg cage
        prov = envProv env
        (_, submittedAt) = requestDatumOf reqOut
    before <- readRegistryState env cage
    let phase2Start = submittedAt + stateProcessTime before
        phase2End = phase2Start + stateRetractTime before
    case alteration of
        Just Live.BeforePhase2 -> pure ()
        Just Live.AfterPhase2 -> do
            sleepUntil (phase2End + 500)
            -- The earlier accepted control returned its approval in the fee
            -- payer's change. Separate those tokens from the ADA funding
            -- before carving the next collateral pot.
            consolidateFunding env
        _ -> sleepUntil (phase2Start + 500)
    pot <- collateralPot env
    honest <- buildRetraction env cage tid (reqIn, reqOut) before
    owner <- requestOwnerKey reqOut
    -- The other request a rebound return names is the collateral pot's own
    -- output reference, named here while acting.
    other <-
        if alteration == Just Live.OtherReference
            then
                Just pot
                    <$ allocateIdentity
                        (liveReferences ids)
                        (ReferenceIdentity (txInReference pot))
            else pure Nothing
    stateUtxo <- cageStateUtxo env cage
    pp <- Cage.withLatest prov Cage.parameters
    let stateScripts =
            [ u
            | u@(_, out) <- rcRefs cage
            , SJust script <- [out ^. referenceScriptTxOutL]
            , hashScript script == cfgScriptHash cfg
            ]
        build units = do
            -- Refresh the outside-window interval immediately before each
            -- evaluation/submission. Both bounds are finite and include now.
            timed <- case alteration of
                Just Live.BeforePhase2 -> do
                    now <- currentPosixMs
                    require
                        "before-phase-2 request missed its processing window"
                        (now < phase2Start)
                    lower <- Cage.withLatest prov (`Services.floorSlot` submittedAt)
                    upper <- Cage.withLatest prov (`Services.floorSlot` phase2Start)
                    pure
                        ( honest
                            & bodyTxL . vldtTxBodyL .~ ValidityInterval (SJust lower) (SJust upper)
                        )
                Just Live.AfterPhase2 -> do
                    lower <- Cage.withLatest prov (`Services.ceilingSlot` phase2End)
                    now <- currentPosixMs
                    upper <- Cage.withLatest prov (`Services.floorSlot` (now + 10_000))
                    pure
                        ( honest
                            & bodyTxL . vldtTxBodyL .~ ValidityInterval (SJust lower) (SJust upper)
                        )
                _ -> pure honest
            edits <- editsOf timed
            edited <- either (failWith . (("tamper: " <> show alteration <> ": ") <>)) pure $ do
                outputsEdited <-
                    editOutputs
                        elsewhere
                        other
                        timed
                        (filter (/= Payments.SpendState) edits)
                if Payments.SpendState `elem` edits
                    then spendStateBeside stateUtxo stateScripts reqIn outputsEdited
                    else Right outputsEdited
            declared <-
                either
                    failWith
                    pure
                    ( declareRetraction
                        pp
                        units
                        pot
                        (sum (map (refScriptSize . snd) stateScripts))
                        genesisAddr
                        edited
                    )
            -- Removing the signer after declaring the fee changes no output:
            -- the original fee also covers the smaller unsigned transaction.
            pure $
                if alteration == Just Live.Unsigned
                    then
                        declared
                            & bodyTxL . reqSignerHashesTxBodyL
                                .~ Set.delete
                                    (addrWitnessKeyHash owner)
                                    (declared ^. bodyTxL . reqSignerHashesTxBodyL)
                    else declared
    require
        "the cage publishes no reference output carrying its state validator"
        (not (null stateScripts) || alteration /= Just Live.StateSpent)
    pure (build, pot, Nothing)

{- | Assemble the ordinary retraction before evaluation, so an inadmissible
request reaches the same node evaluation and submission as every other step.
-}
buildRetraction
    :: Env
    -> RowCage
    -> TokenId
    -> (TxIn, TxOut ConwayEra)
    -> OnChainTokenState
    -> IO ConwayTx
buildRetraction env cage tid named@(reqIn, reqOut) before = do
    let cfg = rcCfg cage
        prov = envProv env
        (_, submittedAt) = requestDatumOf reqOut
    state <- cageStateUtxo env cage
    wallet <- Cage.withLatest prov (`Cage.outputsAt` genesisAddr)
    funder <- case sortOn (negate . outCoin . snd) wallet of
        first : _ -> pure first
        [] -> failWith "retraction fee payer has no indexed outputs"
    owner <- requestOwnerKey reqOut
    pp <- Cage.withLatest prov Cage.parameters
    lower <-
        Cage.withLatest
            prov
            (`Services.ceilingSlot` (submittedAt + stateProcessTime before))
    SlotNo upper <-
        Cage.withLatest
            prov
            ( `Services.floorSlot`
                (submittedAt + stateProcessTime before + stateRetractTime before)
            )
    let inputs = Set.fromList [reqIn, fst funder]
        script = mkRequestScript cfg tid
        boundRefund =
            computeRefund pp (network cfg) 0 reqOut
                & datumTxOutL .~ mkInlineDatum (toPlcData (txInToRef reqIn))
        refund =
            boundRefund
                & coinTxOutL
                    .~ max (boundRefund ^. coinTxOutL) (getMinCoinTxOut pp boundRefund)
        redeemers =
            Redeemers
                ( Map.singleton
                    (ConwaySpending (AsIx (spendingIndex reqIn inputs)))
                    (toLedgerData (Retract (txInToRef (fst state))), placeholderExUnits)
                )
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton reqIn
                & referenceInputsTxBodyL .~ Set.singleton (fst state)
                & outputsTxBodyL .~ StrictSeq.singleton refund
                & collateralInputsTxBodyL .~ Set.singleton (fst funder)
                & reqSignerHashesTxBodyL .~ Set.singleton (addrWitnessKeyHash owner)
                & vldtTxBodyL
                    .~ ValidityInterval (SJust lower) (SJust (SlotNo (upper - 1)))
        transaction =
            mkBasicTx body
                & witsTxL . scriptTxWitsL .~ Map.singleton (hashScript script) script
                & witsTxL . rdmrsTxWitsL .~ redeemers
    either
        (failWith . show)
        (pure . balancedTx)
        (balanceTx pp [funder, named] [] genesisAddr transaction)

{- | Spend the registry's state beside a retraction: the state moves from the
reference inputs to the inputs and is continued unchanged ahead of every other
output, spent by an empty @Modify@ under the state validator resolved through
its reference output; the retraction keeps its own redeemer at its new index.
-}
spendStateBeside
    :: (TxIn, TxOut ConwayEra)
    -> [(TxIn, TxOut ConwayEra)]
    -> TxIn
    -> ConwayTx
    -> Either String ConwayTx
spendStateBeside (stateIn, stateOut) stateScripts reqIn transaction = do
    let inputs = Set.insert stateIn (transaction ^. bodyTxL . inputsTxBodyL)
        references =
            Set.union
                (Set.delete stateIn (transaction ^. bodyTxL . referenceInputsTxBodyL))
                (Set.fromList (map fst stateScripts))
        Redeemers purposes = transaction ^. witsTxL . rdmrsTxWitsL
    (retraction, units) <- case Map.elems purposes of
        [only] -> Right only
        _ -> Left "a retraction carries one redeemer"
    let redeemers =
            Redeemers
                ( Map.fromList
                    [
                        ( ConwaySpending (AsIx (spendingIndex reqIn inputs))
                        , (retraction, units)
                        )
                    ,
                        ( ConwaySpending (AsIx (spendingIndex stateIn inputs))
                        , (toLedgerData (Modify []), units)
                        )
                    ]
                )
    pure
        ( transaction
            & bodyTxL . inputsTxBodyL .~ inputs
            & bodyTxL . referenceInputsTxBodyL .~ references
            & bodyTxL . outputsTxBodyL
                .~ StrictSeq.fromList
                    (stateOut : toList (transaction ^. bodyTxL . outputsTxBodyL))
            & witsTxL . rdmrsTxWitsL .~ redeemers
        )

{- | What the model's admission reads of a retraction, from the retraction as
built: the @submitted_at@ of the request's own datum; the transaction's validity
bounds, each bounding slot at the POSIX time it starts, as the ledger hands them
to the request script (the lower one included, the upper one excluded); and its
required signers, each the wallet identity whose payment key it is. Nothing is
read back from an observation.
-}
retractionWitness
    :: Env -> LiveState -> RowCage -> TxOut ConwayEra -> ConwayTx -> IO Value
retractionWitness env state cage requestOut transaction = do
    tid <- cageTid cage
    wallets <-
        maybe (failWith "registry has no allocated wallets") pure
            . Map.lookup (show tid)
            =<< readIORef (liveRegistryWallets state)
    signatories <-
        mapM
            (observeSigner (liveIds state) wallets)
            (toList (transaction ^. bodyTxL . reqSignerHashesTxBodyL))
    (validFrom, validTo) <- case transaction ^. bodyTxL . vldtTxBodyL of
        ValidityInterval (SJust lower) (SJust upper) ->
            (,)
                <$> slotStartMs (envProv env) lower
                <*> slotStartMs (envProv env) upper
        _ -> failWith "a retraction is built without both validity bounds"
    let (_, submittedAt) = requestDatumOf requestOut
    pure
        ( object
            [ "submittedAt" .= submittedAt
            , "validFrom" .= validFrom
            , "validTo" .= validTo
            , "signatories" .= signatories
            ]
        )

{- | What the model's fold admission reads of a fold beyond its requests: the
fold transaction's validity upper bound, excluded, as the POSIX time its slot
begins. Each request's submission time is the request's own.
-}
foldWitnessOf :: Env -> ConwayTx -> IO Value
foldWitnessOf env transaction = case transaction ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust upper) -> do
        validTo <- slotStartMs (envProv env) upper
        pure (object ["validTo" .= validTo])
    _ -> failWith "a fold is built without a validity upper bound"

{- | The key a question names the admission witness under: a retraction's
@, a fold's @.
-}
admissionKey :: Live.Exit -> Key.Key
admissionKey exit = case exit of
    Live.Fold -> "foldWitness"
    _ -> "witness"

{- | The POSIX slot-start time from one acquired view's validated finite
material, through the fixed common conversion.
-}
slotStartMs
    :: (Cage.Network, Cage.LedgerProvider Cage.NoWitness IO)
    -> SlotNo
    -> IO Integer
slotStartMs prov slot = Cage.withLatest prov (`Services.slotStart` slot)

{- | Refuse to submit a placed reject whose validity interval does not lie in the
window its placement names: a setup failure of the run, never a step outcome.
Otherwise log the placement under its row with the interval, in POSIX
milliseconds, the window, and the transaction.
-}
checkPlacement
    :: Env
    -> String
    -> Live.Placement
    -> TxOut ConwayEra
    -> OnChainTokenState
    -> ConwayTx
    -> IO ()
checkPlacement env row placed requestOut before transaction = do
    (validFrom, validTo) <- case transaction ^. bodyTxL . vldtTxBodyL of
        ValidityInterval (SJust lower) (SJust upper) ->
            (,)
                <$> slotStartMs (envProv env) lower
                <*> slotStartMs (envProv env) upper
        _ ->
            failWith
                "setup: a placed reject is built without both validity bounds"
    let (_, submittedAt) = requestDatumOf requestOut
        (opens, closes) =
            Live.placementWindow
                placed
                submittedAt
                (stateProcessTime before)
                (stateRetractTime before)
        interval = "validity=[" <> show validFrom <> "," <> show validTo <> ")"
        window = "window=[" <> show opens <> "," <> maybe "" show closes <> ")"
    unless (opens <= validFrom && maybe True (validTo <=) closes) $
        failWith
            ( "setup: a reject "
                <> Live.placementName placed
                <> " is built outside its window: "
                <> interval
                <> " "
                <> window
            )
    emit
        "placement"
        ( row
            <> " reject "
            <> Live.placementName placed
            <> " "
            <> interval
            <> " "
            <> window
            <> " tx="
            <> txIdHex transaction
        )

-- | Wait for a phase boundary.
sleepUntil :: Integer -> IO ()
sleepUntil targetMs = do
    now <- currentPosixMs
    let remaining = targetMs - now
    when (remaining > 0) $ do
        emit "wait" (show remaining <> " ms to the next phase boundary")
        threadDelay (fromIntegral remaining * 1000)

-- | The certificate's destination is not an inferred post-state identity.
storyReferences
    :: Env -> RowCage -> ByteString -> Edge -> IO [(TxIn, TxOut ConwayEra)]
storyReferences env cage key edge
    | edge `notElem` [edgeUpdateActive, edgeDeleteAbsent] = pure []
    | otherwise = do
        let cfg = rcCfg cage
            absentPolicy = scriptHashBytes (policyID (policyIdFromPin (cfgAbsentPolicy cfg)))
        utxos <-
            Cage.withLatest
                (envProv env)
                (`Cage.outputsAt` cageAddrFromCfg cfg (network cfg))
        case [ u
             | u@(_, out) <- utxos
             , outAssets out == Map.singleton absentPolicy (Map.singleton key 1)
             , Just (AbsentCustody _) <- [extractCageDatum out]
             ] of
            [u] -> pure [u]
            _ -> failWith ("no single observed custody UTxO for " <> show key)

storyWitness
    :: Env
    -> CageConfig
    -> ByteString
    -> Addr
    -> IO (Maybe (TxIn, TxOut ConwayEra))
storyWitness env cfg key wallet = do
    utxos <- Cage.withLatest (envProv env) (`Cage.outputsAt` wallet)
    let policy = SBS.fromShort (cfgActivePolicy cfg)
        candidates =
            [ u
            | u@(_, out) <- utxos
            , (Map.lookup policy (outAssets out) >>= Map.lookup key) == Just 1
            ]
    case candidates of
        [] -> pure Nothing
        [u] -> pure (Just u)
        _ -> failWith ("more than one active witness input for " <> show key)

{- | Apply a tamper's edits to a transaction's outputs: a readdressed output
goes to @elsewhere@ with its value unchanged, a relovelaced output keeps its
address and assets, and a rebound output presents @other@'s output reference as
its inline datum.
-}
editOutputs
    :: Maybe Addr
    -> Maybe TxIn
    -> ConwayTx
    -> [Payments.OutputEdit]
    -> Either String ConwayTx
editOutputs elsewhere other transaction edits = do
    outputs <-
        foldl
            (\acc edit -> acc >>= apply edit)
            (Right (toList (transaction ^. bodyTxL . outputsTxBodyL)))
            edits
    pure
        (transaction & bodyTxL . outputsTxBodyL .~ StrictSeq.fromList outputs)
  where
    apply (Payments.Readdress i) outputs = case elsewhere of
        Just address -> Right (adjust i (addrTxOutL .~ address) outputs)
        Nothing -> Left "a tamper readdresses an output with no other address"
    apply (Payments.Relovelace i lovelace) outputs = Right (adjust i (coinTxOutL .~ Coin lovelace) outputs)
    apply (Payments.Rebind i) outputs = case other of
        Just reference ->
            Right
                ( adjust
                    i
                    (datumTxOutL .~ mkInlineDatum (toPlcData (txInToRef reference)))
                    outputs
                )
        Nothing -> Left "a tamper rebinds an output with no other output reference"
    apply Payments.SpendState _ = Left "spending the state beside a request edits no output"
    adjust i f outputs =
        [ if j == i then f out else out | (j, out) <- zip [0 :: Int ..] outputs
        ]

{- | The request as the model reads it: its edge, key, owner, destination and
approval as identities, its deposit, and its tip, what it holds beyond the
deposit (on chain the processing tip, `held − deposit`). A retraction also names
the output reference the request sits at, the one its return is bound to; no
other exit reads it.
-}
storyModelRequest
    :: LiveIdentities
    -> CageConfig
    -> Live.Exit
    -> Live.EdgeRequest Addr
    -> Integer
    -> Integer
    -> Maybe Integer
    -> Either (Maybe RegistryEdges.BookingApproval) (TxOut ConwayEra)
    -> IO Value
storyModelRequest = storyModelRequestBy genesisAddr

-- | 'storyModelRequest' for a request booked by the given wallet, its owner.
storyModelRequestBy
    :: Addr
    -> LiveIdentities
    -> CageConfig
    -> Live.Exit
    -> Live.EdgeRequest Addr
    -> Integer
    -> Integer
    -> Maybe Integer
    -> Either (Maybe RegistryEdges.BookingApproval) (TxOut ConwayEra)
    -> IO Value
storyModelRequestBy booker ids cfg exit request deposit tip reference requestOut = do
    let wallet = Live.requestWallet request
        key = TE.encodeUtf8 (T.pack (Live.requestKey request))
    modelKey <- observeIdentity (liveKeys ids) (KeyIdentity key)
    owner <-
        observeIdentity
            (liveWallets ids)
            (WalletIdentity (serialiseAddr booker))
    destination <-
        observeIdentity
            (liveWallets ids)
            (WalletIdentity (serialiseAddr wallet))
    (application, _, _, _) <- observePins ids cfg
    let (refundAddress, output) = case Live.requestEdge request of
            Live.InsertAbsent -> (destination, 0)
            Live.DeleteAbsent -> (destination, 0)
            Live.InsertActive -> (0, destination)
            Live.UpdateActive -> (0, destination)
            Live.WitnessTerminal -> (0, destination)
            _ -> (0, 0)
    -- The described approval is what the booked request UTxO carries. A
    -- refused booking left no request UTxO to read; there the description
    -- states the approval the booking decision put in the refused
    -- transaction.
    let canonical = maybe Null (const (String "canonical"))
    approval <- case requestOut of
        Left decided -> pure (canonical decided)
        Right out -> canonical . snd <$> storyApprovalOn cfg out
    -- When the request was submitted, read off its own datum, which a fold's
    -- admission reads. A refused booking left no request UTxO, and nothing folds it.
    submittedAt <- case requestOut of
        Left _ -> pure 0
        Right out -> case extractCageDatum out of
            Just (RequestDatum booked) -> pure (requestSubmittedAt booked)
            _ -> failWith "booked request output carries no request datum"
    -- The datum the request carries for its delivered output: read off the
    -- booked request's own datum, or, for a refused booking that left no
    -- request UTxO, the destination the booking decision named. The datum is
    -- the identity allocated for it, by its hash, while booking.
    let requestDatum carried = case carried of
            Nothing -> pure Null
            Just _ ->
                toJSON
                    <$> observeIdentity
                        (liveDatums ids)
                        (DatumIdentity (destinationDatumHash carried))
    datum <- case requestOut of
        Left _ -> requestDatum (snd (storyDestination request))
        Right out -> case extractCageDatum out of
            Just (RequestDatum booked) -> requestDatum (snd (requestDestination booked))
            _ -> failWith "booked request output carries no request datum"
    pure $
        object $
            [ "edge" .= Live.edgeName (Live.requestEdge request)
            , "key" .= modelKey
            , "owner" .= owner
            , "refundAddress" .= refundAddress
            , "deposit" .= deposit
            , "output" .= output
            , "applicationPolicy" .= application
            , "approval" .= approval
            , "tip" .= tip
            , "datum" .= datum
            , "submittedAt" .= submittedAt
            ]
                <> [ "reference" .= bound | exit == Live.Retract, Just bound <- [reference]
                   ]

{- | Observation only looks up identities allocated while acting. The
concrete trie root is checked before its leaves are translated.
-}
observeStep :: Env -> LiveState -> LiveStep -> IO Value
observeStep env state step = case lsOutcome step of
    StepAccepted transaction _ -> do
        control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
        when (control == Just "unknown-identity") $
            void
                ( observeIdentity
                    (liveWallets (liveIds state))
                    (WalletIdentity (BS.replicate 28 0xAB))
                )
        observeAcceptedStep env state step transaction
    _ -> pure Null

observeAcceptedStep
    :: Env -> LiveState -> LiveStep -> ConwayTx -> IO Value
observeAcceptedStep env state step transaction = do
    let cage = lsCage step
        cfg = rcCfg cage
        requestedKey = TE.encodeUtf8 (T.pack (Live.requestKey (lsRequest step)))
    after <-
        maybe
            (failWith "accepted step has no chain state")
            pure
            (lsAfter step)
    tid <- cageTid cage
    let registry = show tid
    keys <-
        maybe (failWith "registry has no allocated keys") pure
            . Map.lookup registry
            =<< readIORef (liveRegistryKeys state)
    wallets <-
        maybe (failWith "registry has no allocated wallets") pure
            . Map.lookup registry
            =<< readIORef (liveRegistryWallets state)
    (committed, membership) <- withTrie (envTm env) tid $ \trie -> do
        root <- CageTrie.getRoot trie
        values <- mapM (CageTrie.lookup trie) keys
        pure (root, zip keys (map isJust values))
    require
        "chain root differs from committed trie before observation"
        (unOnChainRoot (stateRoot after) == unRoot committed)
    -- This trie backend's `lookup` reports membership but returns the key's
    -- digest, not the stored leaf. Recover the leaves by rebuilding every
    -- possible assignment over the keys it says are present and matching the
    -- resulting concrete commitment against the chain-read root.
    classified <-
        classifyLeaves membership (unOnChainRoot (stateRoot after))
    translated <- mapM translateLeaf classified
    let root =
            Compare.rootOf
                [(identifier, ordinal) | (identifier, ordinal, _) <- translated]
        trie =
            [ object ["key" .= identifier, "leaf" .= leaf]
            | (identifier, _, leaf) <- translated
            ]
    requestedId <-
        observeIdentity (liveKeys ids) (KeyIdentity requestedKey)
    let leaf =
            fromMaybe
                Null
                ( lookup
                    requestedId
                    [(identifier, name) | (identifier, _, name) <- translated]
                )
    (application, active, absent, terminal) <- observePins ids cfg
    let config = abstractConfig after application active absent terminal root
        activeBytes = SBS.fromShort (cfgActivePolicy cfg)
        terminalBytes = SBS.fromShort (cfgTerminalPolicy cfg)
    holdings <-
        concat
            <$> mapM
                ( walletHoldings
                    ids
                    keys
                    [("active", activeBytes), ("terminal", terminalBytes)]
                )
                wallets
    cageOutputs <-
        Cage.withLatest
            (envProv env)
            (`Cage.outputsAt` cageAddrFromCfg cfg (network cfg))
    custody <-
        mapM
            (observeCustody ids cfg)
            [ out
            | (_, out) <- cageOutputs
            , Map.member (SBS.fromShort (cfgAbsentPolicy cfg)) (outAssets out)
            , Just (AbsentCustody _) <- [extractCageDatum out]
            ]
    let MultiAsset minted = transaction ^. bodyTxL . mintTxBodyL
    mint <-
        mapM
            ( \(policy, name, quantity) -> observeStepMint ids cfg policy name quantity
            )
            [ (cg21PolicyBytes policy, SBS.fromShort name, quantity)
            | (policy, names) <- Map.toList minted
            , (AssetName name, quantity) <- Map.toList names
            ]
    let orderedMint = sortOn mintKindOrder mint
    requestOut <-
        maybe
            (failWith "accepted step has no booked request output")
            pure
            (lsRequestOut step)
    payments <- observePaid ids wallets cfg step transaction requestOut
    let paid = map snd payments
    -- Only a fold delivers: a reject and a retraction deliver nothing, whatever
    -- edge their request named.
    destination <-
        case deliveredPolicy cfg (lsExit step) (Live.requestEdge (lsRequest step)) of
            Just policy -> observedDelivery policy requestedKey wallets
            Nothing -> pure 0
    let owner =
            object
                [ "config" .= config
                , "custody" .= custody
                , "held" .= holdings
                , "trie" .= trie
                ]
    (_, requestName) <- storyApprovalOn cfg requestOut
    -- The recomputation binds the approval the request carries; with none
    -- there is nothing to bind and the check is not made.
    case requestName of
        Nothing -> pure ()
        Just approval -> do
            (_, recomputed) <- cg21RequestFacts requestOut
            require
                "request approval disagrees with its chain-read datum"
                (approval == recomputed)
    ownerId <-
        observeIdentity
            (liveWallets ids)
            (WalletIdentity (serialiseAddr genesisAddr))
    commitment <-
        maybe (failWith "request commitment cannot be derived") pure $
            Compare.approvalAssetName
                (T.pack (Live.edgeName (Live.requestEdge (lsRequest step))))
                requestedId
                ownerId
                destination
    tx <-
        observedStepTx
            env
            ids
            wallets
            step
            transaction
            config
            orderedMint
            destination
            commitment
            custody
            paid
            requestOut
            tid
            (map fst payments)
    pure $
        object
            [ "config" .= config
            , "custody" .= custody
            , "held" .= map heldObservation holdings
            , "leaf" .= leaf
            , "mint" .= orderedMint
            , "paid" .= paid
            , "root" .= root
            , "state" .= owner
            , "tx" .= tx
            ]
  where
    ids = liveIds state
    mintKindOrder (Object fields) = case KM.lookup "kind" fields of
        Just (String "absent") -> (0 :: Int)
        Just (String "active") -> 1
        Just (String "terminal") -> 2
        _ -> 3
    mintKindOrder _ = 3
    observedDelivery policy key wallets = do
        (addressBytes, delivered) <- storyDelivery policy key transaction
        let expectedAsset = AssetEntry (hexT (cg21PolicyBytes policy)) (hexT key) 1
        require
            "accepted edge did not deliver one named token"
            (delivered == [expectedAsset])
        deliveredWallet <- case [ wallet
                                | wallet <- wallets
                                , hexT (serialiseAddr wallet) == addressBytes
                                ] of
            [wallet] -> pure wallet
            _ -> failWith "delivered token address was not allocated by an action"
        observeIdentity
            (liveWallets ids)
            (WalletIdentity (serialiseAddr deliveredWallet))
    translateLeaf (key, value) = do
        identifier <- observeIdentity (liveKeys ids) (KeyIdentity key)
        (ordinal, name) <-
            if value == leafAbsent
                then pure (0, String "absent")
                else
                    if value == leafActive
                        then pure (1, String "active")
                        else
                            if value == leafTerminal
                                then pure (2, String "terminal")
                                else failWith ("unrecognized trie leaf for " <> show key)
        pure (identifier, ordinal, name)
    -- A wallet holds the active and terminal witnesses the folds routed to
    -- it; the absent witness stays in the cage's custody.
    walletHoldings identities keys kinds wallet =
        Cage.withLatest (envProv env) (`Cage.outputsAt` wallet)
            >>= walletHoldingsOf identities keys kinds wallet

{- | The holdings one wallet's outputs carry, one entry per token unit of each
registry key under each witness policy: its key, kind, the wallet's identity,
and the datum the very output carrying it holds ('observedDatumValue'). The
state reports the datum; the `held` census drops it ('heldObservation').
-}
walletHoldingsOf
    :: LiveIdentities
    -> [ByteString]
    -> [(T.Text, ByteString)]
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> IO [Value]
walletHoldingsOf identities keys kinds wallet utxos = do
    addressId <-
        observeIdentity
            (liveWallets identities)
            (WalletIdentity (serialiseAddr wallet))
    concat
        <$> mapM
            ( \key -> do
                keyId <- observeIdentity (liveKeys identities) (KeyIdentity key)
                sequence
                    [ ( \datum ->
                            object
                                [ "key" .= keyId
                                , "kind" .= String kind
                                , "output" .= addressId
                                , "datum" .= datum
                                ]
                      )
                        <$> observedDatumValue identities out
                    | (kind, policyBytes) <- kinds
                    , (_, out) <- utxos
                    , Just names <- [Map.lookup policyBytes (outAssets out)]
                    , Just q <- [Map.lookup key names]
                    , _ <- [1 .. q]
                    ]
            )
            keys

{- | One holding as the `held` census reports it: key, kind and output. Its datum
belongs to the complete state, as the model's own projection has it.
-}
heldObservation :: Value -> Value
heldObservation holding = case holding of
    Object fields -> Object (KM.delete "datum" fields)
    _ -> holding

classifyLeaves
    :: [(ByteString, Bool)] -> ByteString -> IO [(ByteString, ByteString)]
classifyLeaves membership observedRoot = do
    let present = [key | (key, True) <- membership]
        assignments =
            replicateM
                (length present)
                [leafAbsent, leafActive, leafTerminal]
    candidates <-
        mapM
            ( \values -> do
                trie <- mkPureTrie
                mapM_
                    (uncurry (CageTrie.insert trie))
                    (zip present values)
                root <- CageTrie.getRoot trie
                pure (zip present values, unRoot root)
            )
            assignments
    case [leaves | (leaves, root) <- candidates, root == observedRoot] of
        [leaves] -> pure leaves
        matches ->
            failWith
                ( "concrete root identifies "
                    <> show (length matches)
                    <> " leaf assignments over this registry's allocated keys"
                )

observeCustody
    :: LiveIdentities -> CageConfig -> TxOut ConwayEra -> IO Value
observeCustody ids cfg out = do
    refund <- case extractCageDatum out of
        Just (AbsentCustody address) -> pure address
        _ -> failWith "custody output has no Absent custody datum"
    let policy = SBS.fromShort (cfgAbsentPolicy cfg)
    (key, quantity) <- case Map.toList (outAssets out) of
        [(actualPolicy, names)] | actualPolicy == policy -> case Map.toList names of
            [(name, count)] -> pure (name, count)
            _ -> failWith "custody output does not hold one named asset"
        _ ->
            failWith
                "custody output has assets outside this registry's Absent pin"
    require
        "custody output does not hold exactly one Absent token"
        (quantity == 1)
    keyId <- observeIdentity (liveKeys ids) (KeyIdentity key)
    refundId <- observeIdentity (liveWallets ids) (WalletIdentity refund)
    let Coin amount = out ^. coinTxOutL
    pure
        ( object
            ["key" .= keyId, "refundAddress" .= refundId, "value" .= amount]
        )

{- | The form a ledger output presents its datum in, read off the ledger's own
datum constructor: carried inline, presented by hash, or not presented.
-}
datumForm :: TxOut ConwayEra -> T.Text
datumForm out = case out ^. datumTxOutL of
    NoDatum -> "none"
    DatumHash _ -> "hashed"
    Datum _ -> "inline"

{- | The datum an output carries, as the model's datum value, read off the ledger's
own datum constructor: the identity allocated while acting for the datum a booked
request carries, looked up by its hash, so a datum no booked request carries is
refused rather than given one. An output carrying no datum, or presenting one by
hash, carries no value; its form is reported beside it.
-}
observedDatumValue :: LiveIdentities -> TxOut ConwayEra -> IO Value
observedDatumValue ids out = case out ^. datumTxOutL of
    Datum inline -> do
        known <- readIORef (liveDatums ids)
        either
            (const (failWith "an output carries a datum no booked request carries"))
            (pure . toJSON)
            ( Identity.observe
                (DatumIdentity (hashToBytes (extractHash (hashBinaryData inline))))
                known
            )
    _ -> pure Null

{- | The policy of the token an exit delivers to the request's destination:
only a fold delivers, and only these edges hand the requester a token. Every
other exit delivers nothing and has no destination output.
-}
deliveredPolicy
    :: CageConfig -> Live.Exit -> Live.Edge -> Maybe PolicyID
deliveredPolicy cfg exit edge = case (exit, edge) of
    (Live.Fold, Live.InsertActive) -> Just (policyIdFromPin (cfgActivePolicy cfg))
    (Live.Fold, Live.UpdateActive) -> Just (policyIdFromPin (cfgActivePolicy cfg))
    (Live.Fold, Live.WitnessTerminal) ->
        Just (policyIdFromPin (cfgTerminalPolicy cfg))
    _ -> Nothing

-- | The transaction's outputs holding the token named @key@ under @policy@.
carriersOf :: PolicyID -> ByteString -> ConwayTx -> [TxOut ConwayEra]
carriersOf policy key tx =
    [o | o <- toList (tx ^. bodyTxL . outputsTxBodyL), holds o]
  where
    holds o =
        or
            [ SBS.fromShort an == key
            | (p, names) <- Map.toList (rawAssets o)
            , p == policy
            , (AssetName an, _) <- Map.toList names
            ]

{- | The fold's outputs, each beside the reading settlement makes of it: its
address, payment key, lovelace, whether it carries a token this fold
delivers (a positive active or terminal mint), its datum form, the
approvals it holds and whether it is an absent custody at the cage, and the output reference its inline datum presents, if it presents one.
-}
foldOutputsOf
    :: CageConfig -> ConwayTx -> [(TxOut ConwayEra, Payments.FoldOutput)]
foldOutputsOf cfg transaction =
    [ ( out
      , Payments.FoldOutput
            { Payments.outputAddress = serialiseAddr (out ^. addrTxOutL)
            , Payments.outputKey = addrKeyHashBytes (out ^. addrTxOutL)
            , Payments.outputLovelace = let Coin c = out ^. coinTxOutL in c
            , Payments.outputCarrier = carries out
            , Payments.outputDatum = datumForm out
            , Payments.outputApprovals =
                [ hexT name
                | (name, quantity) <-
                    Map.toList
                        ( Map.findWithDefault
                            Map.empty
                            (SBS.fromShort (cfgApplicationPolicy cfg))
                            (outAssets out)
                        )
                , quantity /= 0
                ]
            , Payments.outputCustody =
                out ^. addrTxOutL == cageAddrFromCfg cfg (network cfg)
                    && case extractCageDatum out of
                        Just (AbsentCustody _) -> True
                        _ -> False
            , Payments.outputReference = case out ^. datumTxOutL of
                Datum inline ->
                    let Data plutus = binaryDataToData inline
                    in  onChainReference <$> fromBuiltinData (BuiltinData plutus)
                _ -> Nothing
            }
      )
    | out <- toList (transaction ^. bodyTxL . outputsTxBodyL)
    ]
  where
    MultiAsset minted = transaction ^. bodyTxL . mintTxBodyL
    delivered =
        [ (cg21PolicyBytes policy, SBS.fromShort name)
        | (policy, names) <- Map.toList minted
        , cg21PolicyBytes policy
            `elem` [ SBS.fromShort (cfgActivePolicy cfg)
                   , SBS.fromShort (cfgTerminalPolicy cfg)
                   ]
        , (AssetName name, quantity) <- Map.toList names
        , quantity > 0
        ]
    carries out =
        or
            [ Map.findWithDefault
                0
                name
                (Map.findWithDefault Map.empty policy (outAssets out))
                /= 0
            | (policy, name) <- delivered
            ]

{- | The payments of an accepted fold, read off its transaction by
'Payments.foldPayments', each beside its translation to the identities
allocated while acting. A spent custody is read from its own input, which
the fold must have spent; the owner is the key the booked request's datum
names.
-}
observePaid
    :: LiveIdentities
    -> [Addr]
    -> CageConfig
    -> LiveStep
    -> ConwayTx
    -> TxOut ConwayEra
    -> IO [(Payments.Payment, Value)]
observePaid ids wallets cfg step transaction requestOut = do
    let edge = Live.requestEdge (lsRequest step)
        outputs = foldOutputsOf cfg transaction
    refund <- case (edge, lsCustody step) of
        (e, Just (source, custodyOut)) | e `elem` [Live.UpdateActive, Live.DeleteAbsent] -> do
            require
                "custody refund did not spend its source"
                (source `Set.member` (transaction ^. bodyTxL . inputsTxBodyL))
            case extractCageDatum custodyOut of
                Just (AbsentCustody address) -> pure (Just address)
                _ -> failWith "paid custody source has no Absent datum"
        _ -> pure Nothing
    owner <- requestOwnerKey requestOut
    payments <-
        either failWith pure $
            Payments.foldPayments
                ( Payments.ExitFacts
                    (lsExit step)
                    edge
                    owner
                    refund
                    (txInReference <$> lsRequestIn step)
                )
                (map snd outputs)
    mapM (\payment -> (,) payment <$> translate payment) payments
  where
    translate (Payments.Payment payee value) = do
        address <- case payee of
            Payments.Custody -> pure 0
            Payments.Destination address ->
                observeIdentity (liveWallets ids) (WalletIdentity address)
            Payments.Refund address ->
                observeIdentity (liveWallets ids) (WalletIdentity address)
            Payments.Owner key -> ownerIdentity ids wallets key
        pure (object ["address" .= address, "value" .= value])

{- | The outputs of a submitted exit's transaction that pay what it owes for its
request, in the model's vocabulary, for the driver to judge: each output
'Payments.owedOutputs' reads as paying it, with the role the model gives that
payee, the identity of its address, its lovelace and datum form as the ledger
holds them, and the identity of the output reference its inline datum presents. A retraction
offers every output crediting the owner's key, bound or not, so which of them
is bound to the request is the driver's judgement. A carrier's address is
looked up among the identities allocated while acting, the cage is the model's
cage address, an owner's key names the one registry wallet it pays to, an
output reference is one named while acting. Nothing else of an output is read.
-}
settlementOutputs
    :: LiveIdentities
    -> [Addr]
    -> CageConfig
    -> LiveStep
    -> ConwayTx
    -> IO [Value]
settlementOutputs ids wallets cfg step transaction = do
    requestOut <-
        maybe
            (failWith "judged step has no booked request")
            pure
            (lsRequestOut step)
    owner <- requestOwnerKey requestOut
    let facts =
            Payments.ExitFacts
                (lsExit step)
                (Live.requestEdge (lsRequest step))
                owner
                Nothing
                (txInReference <$> lsRequestIn step)
        outputs = map snd (foldOutputsOf cfg transaction)
        judged = case lsExit step of
            Live.Retract -> [out | out <- outputs, Payments.creditsOwner owner out]
            _ -> map (outputs !!) (Payments.owedOutputs facts outputs)
    mapM (settlementOutput (Payments.owedPayee facts) owner) judged
  where
    settlementOutput payee owner out = do
        (role, address) <- case payee of
            Payments.OwedCarrier ->
                (,) ("destination" :: T.Text)
                    <$> observeIdentity
                        (liveWallets ids)
                        (WalletIdentity (Payments.outputAddress out))
            Payments.OwedCustody -> pure ("cage", 0)
            Payments.OwedOwner -> (,) "owner" <$> ownerIdentity ids wallets owner
            Payments.OwedBound -> (,) "owner" <$> ownerIdentity ids wallets owner
        reference <-
            traverse
                (observeIdentity (liveReferences ids) . ReferenceIdentity)
                (Payments.outputReference out)
        pure
            ( object
                [ "role" .= role
                , "address" .= address
                , "lovelace" .= Payments.outputLovelace out
                , "datum" .= Payments.outputDatum out
                , "reference" .= reference
                ]
            )

-- | The payment key the booked request's datum names as its owner.
requestOwnerKey :: TxOut ConwayEra -> IO ByteString
requestOwnerKey requestOut = case extractCageDatum requestOut of
    Just (RequestDatum rq) -> let BuiltinByteString key = requestOwner rq in pure key
    _ -> failWith "accepted fold's request carries no request datum"

-- | An owner's identity: the one registry wallet whose payment key it is.
ownerIdentity :: LiveIdentities -> [Addr] -> ByteString -> IO Integer
ownerIdentity ids wallets key = case [w | w <- wallets, addrKeyHashBytes w == key] of
    [wallet] ->
        observeIdentity
            (liveWallets ids)
            (WalletIdentity (serialiseAddr wallet))
    _ ->
        failWith
            ( "request owner "
                <> hex key
                <> " is not the key of one wallet of this registry"
            )

{- | The owner outputs of an accepted fold, one per owner payment, read off the
ledger outputs the chain credits to the owner's key by
'Payments.readOwner' and put in the model's vocabulary by
'Payments.ownerOutputObservation', whose returned approval is looked up in
the approvals the run bound while booking. Their registry tokens and the registry
state token they hold are read here, and none may carry a registry state or
custody datum. An owner no output credits has no owner output: the
transaction then differs from the model's in length.
-}
observeOwnerOutputs
    :: LiveIdentities
    -> [Addr]
    -> CageConfig
    -> TokenId
    -> LiveStep
    -> ConwayTx
    -> [Payments.Payment]
    -> IO [Value]
observeOwnerOutputs ids wallets cfg tid step transaction payments =
    concat
        <$> mapM
            ownerOutput
            [key | Payments.Payment (Payments.Owner key) _ <- payments]
  where
    outputs = foldOutputsOf cfg transaction
    -- A retraction returns the request through the one output bound to it;
    -- every other exit credits the owner every output at its key.
    bound = case lsExit step of
        Live.Retract -> txInReference <$> lsRequestIn step
        _ -> Nothing
    credits key folded =
        Payments.creditsOwner key folded
            && maybe
                True
                (\reference -> Payments.outputReference folded == Just reference)
                bound
    ownerOutput key = do
        read' <- either failWith pure $ case bound of
            Just reference -> Payments.readBound key reference (map snd outputs)
            Nothing -> Payments.readOwner key (map snd outputs)
        case read' of
            Nothing -> pure []
            Just reading -> do
                let credited = [out | (out, folded) <- outputs, credits key folded]
                -- The reference each credited output presents, as its datum reads.
                reference <- case nub
                    [ r
                    | (_, folded) <- outputs
                    , credits key folded
                    , Just r <- [Payments.outputReference folded]
                    ] of
                    [] -> pure Nothing
                    [presented] ->
                        Just
                            <$> observeIdentity (liveReferences ids) (ReferenceIdentity presented)
                    _ ->
                        failWith
                            "the outputs crediting the owner present several output references"
                address <- ownerIdentity ids wallets key
                require
                    "an output crediting the owner carries a registry state or custody datum"
                    (all (isNothing . extractCageDatum) credited)
                let tokenPins =
                        [ SBS.fromShort (cfgActivePolicy cfg)
                        , SBS.fromShort (cfgAbsentPolicy cfg)
                        , SBS.fromShort (cfgTerminalPolicy cfg)
                        ]
                assets <-
                    mapM
                        ( \(policy, name, quantity) -> observeStepMint ids cfg policy name quantity
                        )
                        [ (policy, name, quantity)
                        | out <- credited
                        , (policy, names) <- Map.toList (outAssets out)
                        , policy `elem` tokenPins
                        , (name, quantity) <- Map.toList names
                        ]
                let statePolicy = cg21PolicyBytes (cagePolicyIdFromCfg cfg)
                    stateName = SBS.fromShort (assetNameBytes (unTokenId tid))
                    stateTokens =
                        sum
                            [ Map.findWithDefault
                                0
                                stateName
                                (Map.findWithDefault Map.empty statePolicy (outAssets out))
                            | out <- credited
                            ]
                approvals <- readIORef (liveApprovals ids)
                let approvalOf name = Identity.observe (ApprovalIdentity name) approvals
                either failWith (pure . pure) $
                    Payments.ownerOutputObservation
                        address
                        approvalOf
                        assets
                        stateTokens
                        reference
                        reading

{- | A required signer of the submitted transaction, in the model's vocabulary:
the identity of the registry wallet whose payment key it is. A key no wallet
of this registry pays to is refused, never given a fresh identity.
-}
observeSigner
    :: LiveIdentities -> [Addr] -> KeyHash Guard -> IO Integer
observeSigner ids wallets (KeyHash signer) =
    case [ wallet
         | wallet <- wallets
         , addrKeyHashBytes wallet == hashToBytes signer
         ] of
        [wallet] ->
            observeIdentity
                (liveWallets ids)
                (WalletIdentity (serialiseAddr wallet))
        [] ->
            failWith
                ( "required signer "
                    <> hex (hashToBytes signer)
                    <> " is no wallet of this registry"
                )
        _ ->
            failWith
                ( "required signer "
                    <> hex (hashToBytes signer)
                    <> " is the payment key of more than one wallet"
                )

observeStepMint
    :: LiveIdentities
    -> CageConfig
    -> ByteString
    -> ByteString
    -> Integer
    -> IO Value
observeStepMint ids cfg policy key quantity = do
    kind <- case [ name
                 | (pin, name) <-
                    [ (cfgActivePolicy cfg, "active")
                    , (cfgAbsentPolicy cfg, "absent")
                    , (cfgTerminalPolicy cfg, "terminal")
                    ]
                 , SBS.fromShort pin == policy
                 ] of
        [name] -> pure (name :: T.Text)
        _ -> failWith "mint names a policy outside the registry's witness pins"
    policyId <- observeIdentity (livePolicies ids) (PolicyIdentity policy)
    keyId <- observeIdentity (liveKeys ids) (KeyIdentity key)
    pure
        ( object
            [ "kind" .= kind
            , "key" .= keyId
            , "policy" .= policyId
            , "assetName" .= keyId
            , "quantity" .= quantity
            ]
        )

observedStepTx
    :: Env
    -> LiveIdentities
    -> [Addr]
    -> LiveStep
    -> ConwayTx
    -> Value
    -> [Value]
    -> Integer
    -> Integer
    -> [Value]
    -> [Value]
    -> TxOut ConwayEra
    -> TokenId
    -> [Payments.Payment]
    -> IO Value
observedStepTx
    _env
    ids
    wallets
    step
    transaction
    config
    mint
    destination
    commitment
    custody
    paid
    requestOut
    tid
    payments = do
        let cfg = rcCfg (lsCage step)
            edge = Live.requestEdge (lsRequest step)
            requestKeyBytes = TE.encodeUtf8 (T.pack (Live.requestKey (lsRequest step)))
            actualInputs = transaction ^. bodyTxL . inputsTxBodyL
            outputValues = toList (transaction ^. bodyTxL . outputsTxBodyL)
            stateOutputs =
                [ out
                | out <- outputValues
                , Just (StateDatum _) <- [extractCageDatum out]
                ]
        -- A retraction spends no state, so it continues none.
        when (lsExit step /= Live.Retract) $
            require
                "accepted fold has no unique chain state output"
                (length stateOutputs == 1)
        let witnessInput what (source, spentOutput) = do
                require
                    (what <> " did not spend its observed active witness")
                    (source `Set.member` actualInputs)
                asset <-
                    observeStepMint
                        ids
                        cfg
                        (SBS.fromShort (cfgActivePolicy cfg))
                        requestKeyBytes
                        1
                value <- observedDatumValue ids spentOutput
                pure
                    [ object
                        [ "role" .= String "witness"
                        , "datum" .= String (datumForm spentOutput)
                        , "stateToken" .= (0 :: Integer)
                        , "approvalQuantity" .= (0 :: Integer)
                        , "lovelace" .= (0 :: Integer)
                        , "assets" .= [asset]
                        , "datumValue" .= value
                        ]
                    ]
        -- A fold alone spends a witness or a custody, or locks one: a reject and a
        -- retraction touch neither, whatever edge their request named.
        let folded = lsExit step == Live.Fold
        witnessInputs <-
            if not folded
                then pure []
                else case (edge, lsWitness step) of
                    (Live.UpdateTerminal, Just held) -> witnessInput "retirement" held
                    (Live.UpdateTerminal, Nothing) -> failWith "retirement has no observed active witness"
                    (Live.DeleteActive, Just held) -> witnessInput "deletion" held
                    (Live.DeleteActive, Nothing) -> failWith "deletion has no observed active witness"
                    _ -> pure []
        custodyInputs <-
            if not folded
                then pure []
                else case (edge, lsCustody step) of
                    (Live.UpdateActive, Just held) -> custodyInput held
                    (Live.DeleteAbsent, Just held) -> custodyInput held
                    (Live.UpdateActive, Nothing) -> failWith "updateActive has no custody input"
                    (Live.DeleteAbsent, Nothing) -> failWith "deleteAbsent has no custody input"
                    _ -> pure []
        let positive =
                [ asset
                | asset@(Object fields) <- mint
                , KM.lookup "kind" fields
                    `elem` [Just (String "active"), Just (String "terminal")]
                , case KM.lookup "quantity" fields of
                    Just (Number q) -> q > 0
                    _ -> False
                ]
            newCustody =
                [ out
                | out <- outputValues
                , Just (AbsentCustody _) <- [extractCageDatum out]
                ]
        cageOutputs <-
            if not folded
                then pure []
                else case edge of
                    Live.InsertAbsent -> case newCustody of
                        [out] -> do
                            entry <- observeCustody ids cfg out
                            require
                                "new custody was not observed at the cage"
                                (entry `elem` custody)
                            keyId <- storyField "key" entry
                            refundId <- storyField "refundAddress" entry
                            value <- storyField "value" entry
                            asset <-
                                observeStepMint
                                    ids
                                    cfg
                                    (SBS.fromShort (cfgAbsentPolicy cfg))
                                    requestKeyBytes
                                    1
                            require
                                "new custody is for a different key"
                                ( keyId
                                    == fromMaybe
                                        Null
                                        ( case lsModelRequest step of
                                            Object fields -> KM.lookup "key" fields
                                            _ -> Nothing
                                        )
                                )
                            pure
                                [ object
                                    [ "role" .= String "cage"
                                    , "datum" .= String (datumForm out)
                                    , "address" .= (0 :: Integer)
                                    , "stateToken" .= (0 :: Integer)
                                    , "inlineConfig" .= Null
                                    , "commitment" .= Null
                                    , "assets" .= [asset]
                                    , "custodyDatum" .= [refundId]
                                    , "lovelace" .= value
                                    , "reference" .= Null
                                    , "datumValue" .= Null
                                    ]
                                ]
                        _ -> failWith "insertAbsent did not create one Absent custody output"
                    _ -> pure []
        (requestQuantity, _) <- storyApprovalOn cfg requestOut
        let requestInput =
                object
                    [ "role" .= String "request"
                    , "datum" .= String (datumForm requestOut)
                    , "stateToken" .= (0 :: Integer)
                    , "approvalQuantity" .= requestQuantity
                    , "lovelace" .= lsRequestLovelace step
                    , "assets" .= ([] :: [Value])
                    , "datumValue" .= Null
                    ]
            stateInput form =
                object
                    [ "role" .= String "state"
                    , "datum" .= String form
                    , "stateToken" .= (1 :: Integer)
                    , "approvalQuantity" .= (0 :: Integer)
                    , "lovelace" .= (0 :: Integer)
                    , "assets" .= ([] :: [Value])
                    , "datumValue" .= Null
                    ]
            -- The one continued state output a fold or reject has, as required
            -- above; a retraction continues none.
            stateOutputRows =
                [ object
                    [ "role" .= String "state"
                    , "datum" .= String (datumForm out)
                    , "address" .= Null
                    , "stateToken" .= (1 :: Integer)
                    , "inlineConfig" .= config
                    , "commitment" .= Null
                    , "assets" .= ([] :: [Value])
                    , "custodyDatum" .= Null
                    , "lovelace" .= (0 :: Integer)
                    , "reference" .= Null
                    , "datumValue" .= Null
                    ]
                | out <- stateOutputs
                ]
            destinationOutput carrier carried =
                object
                    [ "role" .= String "destination"
                    , "datum" .= String (datumForm carrier)
                    , "address" .= destination
                    , "stateToken" .= (0 :: Integer)
                    , "inlineConfig" .= Null
                    , "commitment" .= commitment
                    , "assets" .= positive
                    , "custodyDatum" .= Null
                    , "lovelace"
                        .= sum
                            [value | Payments.Payment (Payments.Destination _) value <- payments]
                    , "reference" .= Null
                    , "datumValue" .= carried
                    ]
        -- Every exit spends the request it booked; its form is the booked output's.
        case lsRequestIn step of
            Just source ->
                require
                    "the booked request input was not spent by the accepted step"
                    (source `Set.member` actualInputs)
            Nothing -> failWith "accepted step retained no booked request input"
        -- A fold and a reject spend the state the step retained from the chain
        -- before submission; a retraction spends none.
        stateInputs <-
            if lsExit step == Live.Retract
                then pure []
                else case lsStateUtxo step of
                    Just (source, spentOutput) -> do
                        require
                            "the retained state input was not spent by the accepted step"
                            (source `Set.member` actualInputs)
                        pure [stateInput (datumForm spentOutput)]
                    Nothing ->
                        failWith "accepted step retained no unique spent state input"
        -- Only a fold that delivers a token has a destination: the one output
        -- carrying it. A fold delivering nothing reports no destination output.
        destinationOutputs <-
            case deliveredPolicy cfg (lsExit step) edge of
                Nothing -> pure []
                Just policy -> case carriersOf policy requestKeyBytes transaction of
                    [carrier] ->
                        (\carried -> [destinationOutput carrier carried])
                            <$> observedDatumValue ids carrier
                    carriers ->
                        failWith
                            ( "the fold has "
                                <> show (length carriers)
                                <> " destination outputs carrying its delivered token, want one"
                            )
        signers <-
            mapM
                (observeSigner ids wallets)
                (toList (transaction ^. bodyTxL . reqSignerHashesTxBodyL))
        ownerOutputs <-
            observeOwnerOutputs ids wallets cfg tid step transaction payments
        -- A reject spends and continues the state beside the request and refunds
        -- the owner; a retraction spends the request alone and returns it.
        let (inputs, outputs) = case lsExit step of
                Live.Fold ->
                    ( stateInputs <> (requestInput : custodyInputs <> witnessInputs)
                    , stateOutputRows <> destinationOutputs <> cageOutputs <> ownerOutputs
                    )
                Live.Reject ->
                    (stateInputs <> [requestInput], stateOutputRows <> ownerOutputs)
                Live.Retract -> ([requestInput], ownerOutputs)
        pure
            ( object
                [ "inputs" .= inputs
                , "outputs" .= outputs
                , "mint" .= mint
                , "signers" .= sort signers
                , "refunds" .= paid
                ]
            )
      where
        custodyInput (source, spentOutput) = do
            require
                "absent custody was not spent by the accepted fold"
                (source `Set.member` (transaction ^. bodyTxL . inputsTxBodyL))
            let cfg = rcCfg (lsCage step)
                key = TE.encodeUtf8 (T.pack (Live.requestKey (lsRequest step)))
            asset <-
                observeStepMint ids cfg (SBS.fromShort (cfgAbsentPolicy cfg)) key 1
            pure
                [ object
                    [ "role" .= String "cage"
                    , "datum" .= String (datumForm spentOutput)
                    , "stateToken" .= (0 :: Integer)
                    , "approvalQuantity" .= (0 :: Integer)
                    , "lovelace" .= (0 :: Integer)
                    , "assets" .= [asset]
                    , "datumValue" .= Null
                    ]
                ]

{- | Ask the same driver for every exit. Setup is only the earlier accepted,
compared folds of this registry; a tamper never joins it, nor a reject or a
retraction, which the model says leave the registry as it was. Given the
submitted transaction's inputs and outputs, the driver also judges whether it
spends what the exit may and pays what the exit owes. A retraction is asked
under the witness read off it as built, so the model admits it first.
-}
askModel
    :: Env -> LiveState -> LiveStep -> Maybe ([Value], [Value]) -> IO Value
askModel _env state step judged = do
    (start, startValue, setup) <- modelStart state (lsCage step)
    let question =
            object $
                [ "id" .= String "live-edge"
                , "theorem" .= String "Singular.Driver.runSurface"
                , "statementSha256" .= String "4242624938955313763"
                , "start" .= startValue
                , "setup" .= setup
                , "exit"
                    .= Live.exitName (lsExit step) (Live.requestEdge (lsRequest step))
                , "request" .= lsModelRequest step
                , "lovelace" .= lsRequestLovelace step
                ]
                    <> [admissionKey (lsExit step) .= witness | Just witness <- [lsRetraction step]]
                    <> concat
                        [ ["inputs" .= inputs, "outputs" .= outputs]
                        | Just (inputs, outputs) <- [judged]
                        ]
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    let asked = case control of
            Just "wrong-fee" -> bumpEvaluationField "maxFee" question
            Just "wrong-timing" -> bumpEvaluationField "processTime" question
            Just "inside-phase-2" | lsTamper step `elem` map Just [Live.BeforePhase2, Live.AfterPhase2] ->
                case (question, lsRetraction step) of
                    (Object fields, Just (Object witness))
                        | Just (Number submitted) <- KM.lookup "submittedAt" witness ->
                            let lower = submitted + fromInteger (stateProcessTime start)
                                upper = lower + fromInteger (stateRetractTime start)
                            in  Object
                                    ( KM.insert
                                        "witness"
                                        ( Object
                                            ( KM.insert
                                                "validFrom"
                                                (Number lower)
                                                (KM.insert "validTo" (Number upper) witness)
                                            )
                                        )
                                        fields
                                    )
                    _ -> question
            Just "signed-owner" | lsTamper step == Just Live.Unsigned ->
                case (question, lsModelRequest step) of
                    (Object fields, Object request)
                        | Just owner <- KM.lookup "owner" request
                        , Just (Object witness) <- KM.lookup "witness" fields ->
                            Object
                                ( KM.insert
                                    "witness"
                                    (Object (KM.insert "signatories" (toJSON [owner]) witness))
                                    fields
                                )
                    _ -> question
            _ -> question
    evaluator <- requireEnv "CONFORMANCE_MODEL_EVALUATOR"
    LeanOracle.expectedObservation evaluator [] asked
        >>= either failWith pure

{- | Where every model question about a registry starts: the empty registry the
chain held when the story first acted on it, under its pins, and the setup trace
of the folds since compared or submitted in a batch the chain accepted.
-}
modelStart
    :: LiveState -> RowCage -> IO (OnChainTokenState, Value, [Value])
modelStart state cage = do
    tid <- cageTid cage
    let registry = show tid
    start <-
        maybe (failWith "model question has no chain-read start") pure
            . Map.lookup registry
            =<< readIORef (liveStarts state)
    setup <-
        Map.findWithDefault [] registry <$> readIORef (liveTraces state)
    (application, active, absent, terminal) <-
        observePins (liveIds state) (rcCfg cage)
    pure
        ( start
        , object
            [ "config"
                .= abstractConfig
                    start
                    application
                    active
                    absent
                    terminal
                    (Compare.rootOf [])
            , "trie" .= ([] :: [Value])
            , "custody" .= ([] :: [Value])
            , "held" .= ([] :: [Value])
            ]
        , setup
        )

compareStep :: Env -> LiveState -> LiveStep -> Value -> IO Value
compareStep env state step observation = do
    row <- askModel env state step Nothing
    stepTid <- cageTid (lsCage step)
    -- Which of the registry's scripts a refusal names, read off the hashes the
    -- node reported against each script's applied hash.
    let stepCfg = rcCfg (lsCage step)
        attributed hashes =
            [ name :: T.Text
            | (name, marker) <-
                [ ("state", stateMarkerOf stepCfg)
                , ("request", requestMarkerOf stepCfg stepTid)
                ]
            , T.pack marker `elem` hashes
            ]
    lawOutcome <- storyField "outcome" row
    -- The law accepting is not the model accepting the transaction: the
    -- driver then judges the submitted outputs against what the exit owes.
    judged <-
        traverse judge (judgedTransaction lawOutcome (lsOutcome step))
    (modelOutcome, modelReason) <-
        either failWith pure (LeanOracle.modelVerdict row judged)
    -- A refused step the model refuses for a reason: the chain-side reason the
    -- replay admitted for the script the step is judged by meets Lean's. The
    -- comparison is written to the rejection's index entry before anything
    -- acts on it, so a failing row keeps it.
    reasonCheck <- case (lsOutcome step, modelOutcome, modelReason) of
        (StepRefused transaction _ _, String "refused", String lean) -> do
            control <-
                lookupEnv "CONFORMANCE_REASON_CONTROL"
                    >>= traverse (either failWith pure . parseReasonControl)
            rowName <- readIORef (riRow (envReplay env))
            compared <- length <$> readIORef (envLiveRecords env)
            let asked = controlledReason control rowName compared lean
                txid = T.pack (txIdHex transaction)
                judgedBy =
                    if lsExit step == Live.Retract
                        then requestMarkerOf stepCfg stepTid
                        else stateMarkerOf stepCfg
            purposes <- purposesOf (envReplay env) txid
            let comparison = stepComparison (T.pack judgedBy) asked purposes
            recordComparison (envReplay env) txid asked comparison
            pure (Just (asked, comparison))
        _ -> pure Nothing
    -- The replay of each failing purpose of a refused step's transaction, as
    -- the receipt carries it.
    evidence <- case lsOutcome step of
        StepRefused transaction _ _ ->
            replayEvidenceOf (envReplay env) (T.pack (txIdHex transaction))
        _ -> pure []
    let model = object ["outcome" .= modelOutcome, "reason" .= modelReason]
        -- The chain-side reason a receipt carries: only one that agrees.
        chainReason = case reasonCheck of
            Just (lean, Agrees) -> Just lean
            _ -> Nothing
        (chainOutcome, chain) = case lsOutcome step of
            StepAccepted transaction units ->
                ( String "accepted"
                , object
                    [ "outcome" .= String "accepted"
                    , "txid" .= txIdHex transaction
                    , "measured" .= measuredJsonOf units
                    ]
                )
            StepRefused transaction hashes rejection ->
                ( String "refused"
                , object
                    [ "outcome" .= String "refused"
                    , "txid" .= txIdHex transaction
                    , "refusal"
                        .= stepReplay
                            evidence
                            ( withScripts
                                (attributed hashes)
                                (rejectionJson chainReason hashes rejection)
                            )
                    ]
                )
            StepUnsupported _ reason diagnostic ->
                ( String "unsupported"
                , object
                    [ "outcome" .= String "unsupported"
                    , "reason" .= boundedNodeReason maxLiveStepReasonChars reason
                    , "refusal" .= fmap (rejectionJson Nothing []) diagnostic
                    ]
                )
    declared <- do
        corpusPath <- requireEnv "CONFORMANCE_DRIVER_CORPUS"
        corpus <- eitherDecodeFileStrict corpusPath >>= either failWith pure
        either failWith pure (Compare.declaredSurface corpus)
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    let presented = case control of
            Just "wrong-delivery" | chainOutcome == String "accepted" -> bumpObservedMint observation
            _ -> observation
    (comparison, compared, unobserved, perturbation, differing) <- case (lsTamper step, modelOutcome, chainOutcome) of
        _
            | StepRefused _ _ rejection <- lsOutcome step
            , not (null (srBudgetExceeded rejection)) ->
                pure ("disagrees", [], [], Null, [])
        (_, String "unsupported", _) -> pure ("unsupported" :: T.Text, [], [], Null, [])
        (_, _, String "unsupported") -> pure ("unsupported", [], [], Null, [])
        -- Both refuse. The outcome agrees; the reasons then meet: a chain-side
        -- reason the traced replay admitted that differs from Lean's fails the
        -- step, while an unobserved one leaves it agreeing on the outcome and
        -- uncompared on the reason (the index names the cause).
        (_, String "refused", String "refused")
            | Just (_, Differs{}) <- reasonCheck ->
                pure ("disagrees", [], [], Null, [])
            | otherwise -> pure ("agrees", [], [], Null, [])
        -- The ledger accepts the extra signer. The same comparison every
        -- untampered step gets must then report exactly the difference the
        -- tamper made: that detection is the tamper's agreement. Reporting
        -- none, or another, is a disagreement.
        (Just Live.ExtraSigner, String "accepted", String "accepted") -> do
            expected <- storyField "observations" row
            let differing = case Compare.compareRegistration declared expected presented of
                    Right _ -> []
                    Left differences -> reportedDifferences differences
            pure
                ( if not (null differing)
                    && differing == tamperDifferences Live.ExtraSigner
                    then "agrees"
                    else "disagrees"
                , []
                , []
                , Null
                , differing
                )
        (Just _, _, _) -> pure ("disagrees", [], [], Null, [])
        (Nothing, String "accepted", String "accepted") -> do
            expected <- storyField "observations" row
            agreement <-
                either
                    (failWith . renderDifferences)
                    pure
                    (Compare.compareRegistration declared expected presented)
            (refused, byObservation, exempt) <-
                either
                    failWith
                    pure
                    (Perturbation.checkPerturbations declared expected observation)
            pure
                ( "agrees"
                , Compare.agreementCompared agreement
                , Compare.agreementUnobserved agreement
                , object
                    [ "refused" .= refused
                    , "byObservation" .= byObservation
                    , "exempt" .= exempt
                    ]
                , []
                )
        _ -> pure ("disagrees", [], [], Null, [])
    tid <- cageTid (lsCage step)
    let registry = show tid
    registryId <-
        maybe (failWith "step registry was not allocated") pure
            . Map.lookup registry
            =<< readIORef (liveRegistryIds state)
    let record =
            object $
                [ "registry" .= registryId
                , "edge" .= Live.edgeName (Live.requestEdge (lsRequest step))
                , "exit" .= exitNamed
                , "request" .= lsModelRequest step
                , "tamper" .= fmap Live.tamperName (lsTamper step)
                , "model" .= model
                , "chain" .= chain
                , "comparison" .= comparison
                , "compared" .= compared
                , "unobserved" .= unobserved
                , "perturbation" .= perturbation
                , "differences" .= map differenceJson differing
                ]
                    <> [admissionKey (lsExit step) .= witness | Just witness <- [lsRetraction step]]
                    <> [ "requestScript" .= requestMarkerOf stepCfg stepTid
                       | lsExit step == Live.Retract
                       , lsTamper step
                            `elem` map Just [Live.Unsigned, Live.BeforePhase2, Live.AfterPhase2]
                            || Live.requestEdge (lsRequest step)
                                `notElem` [Live.InsertAbsent, Live.InsertActive, Live.WitnessTerminal]
                       ]
    modifyIORef' (envLiveRecords env) (<> [record])
    let chainDetail = case lsOutcome step of
            StepAccepted transaction _ -> " txid=" <> txIdHex transaction
            StepRefused transaction hashes rejection ->
                " txid="
                    <> txIdHex transaction
                    <> " trace="
                    <> show chainReason
                    <> " scriptHashes="
                    <> show hashes
                    <> rejectionDetail rejection
            StepUnsupported _ reason diagnostic ->
                " reason="
                    <> T.unpack (oneLine maxStepLineReasonChars reason)
                    <> maybe "" rejectionDetail diagnostic
    emit
        "step"
        ( exitNamed
            <> " key="
            <> show (Live.requestKey (lsRequest step))
            <> " tamper="
            <> maybe "none" Live.tamperName (lsTamper step)
            <> " model="
            <> show modelOutcome
            <> " modelReason="
            <> show modelReason
            <> " chain="
            <> show chainOutcome
            <> chainDetail
            <> " comparison="
            <> T.unpack comparison
            <> concatMap
                ( \(name, path) -> " differs=" <> T.unpack name <> ":" <> renderStepPath path
                )
                differing
        )
    case comparison of
        -- Every fold the ledger accepted moved the chain as the model's request
        -- does, a tampered one included, so later questions start from it. A
        -- reject or a retraction the ledger accepted left the registry as it was.
        "agrees" ->
            when (chainOutcome == String "accepted" && lsExit step == Live.Fold) $
                modifyIORef'
                    (liveTraces state)
                    (Map.insertWith (flip (<>)) registry [lsModelRequest step])
        "unsupported" -> case lsOutcome step of
            StepUnsupported _ reason _ ->
                emit
                    "gap"
                    ( exitNamed
                        <> " for "
                        <> Live.requestKey (lsRequest step)
                        <> ": "
                        <> T.unpack (oneLine maxStepLineReasonChars reason)
                    )
            _ -> failWith "unsupported comparison lacks an observed reason"
        _ -> case reasonCheck of
            Just (_, Differs{chainReason = chainSide, leanReason = leanSide}) ->
                failWith
                    ( "model and chain refuse for different reasons for "
                        <> exitNamed
                        <> " at "
                        <> Live.requestKey (lsRequest step)
                        <> ": chain="
                        <> T.unpack chainSide
                        <> " lean="
                        <> T.unpack leanSide
                    )
            _ ->
                failWith
                    ( "model and chain disagree for "
                        <> exitNamed
                        <> " at "
                        <> Live.requestKey (lsRequest step)
                        <> ": model="
                        <> show modelOutcome
                        <> " chain="
                        <> show chainOutcome
                    )
    pure record
  where
    exitNamed = Live.exitName (lsExit step) (Live.requestEdge (lsRequest step))
    judge transaction = do
        let ids = liveIds state
        tid <- cageTid (lsCage step)
        wallets <-
            maybe (failWith "registry has no allocated wallets") pure
                . Map.lookup (show tid)
                =<< readIORef (liveRegistryWallets state)
        outputs <-
            settlementOutputs ids wallets (rcCfg (lsCage step)) step transaction
        -- Each input as the judgement reads it: the state tokens it held.
        let inputs = [object ["stateToken" .= held] | held <- lsSpent step]
        askModel env state step (Just (inputs, outputs))

{- | The differences a tamper the ledger accepts must make, and no other: the
observation and the path inside it.
-}
tamperDifferences :: Live.Tamper -> [(T.Text, [Perturbation.Step])]
tamperDifferences alteration = case alteration of
    Live.ExtraSigner -> [("tx", [Perturbation.Field "signers"])]
    Live.OtherAddress -> []
    Live.ShortByOne -> []
    Live.OtherReference -> []
    Live.StateSpent -> []
    Live.Unsigned -> []
    Live.BeforePhase2 -> []
    Live.AfterPhase2 -> []

{- | Every path at which a reported difference's two sides differ, down to a
leaf or to an array whose length differs. A below-floor lovelace difference
is part of the transaction disagreement and remains visible here.
-}
reportedDifferences
    :: [Compare.Difference] -> [(T.Text, [Perturbation.Step])]
reportedDifferences = Perturbation.reportedDifferences

differingPaths :: Value -> Value -> [[Perturbation.Step]]
differingPaths = Perturbation.differingPaths

renderStepPath :: [Perturbation.Step] -> String
renderStepPath = concatMap render
  where
    render (Perturbation.Field name) = "." <> T.unpack name
    render (Perturbation.Index index) = "[" <> show index <> "]"

differenceJson :: (T.Text, [Perturbation.Step]) -> Value
differenceJson (name, path) =
    object
        [ "observation" .= name
        , "path" .= T.pack (drop 1 (renderStepPath path))
        ]

-- | A refusal record beside the names of the registry scripts its hashes are.
withScripts :: [T.Text] -> Value -> Value
withScripts scripts (Object fields) = Object (KM.insert "scripts" (toJSON scripts) fields)
withScripts _ value = value

rejectionJson :: Maybe T.Text -> [T.Text] -> StepRejection -> Value
rejectionJson trace hashes rejection =
    object
        [ "trace" .= trace
        , "hashes" .= hashes
        , "kind"
            .= if null (srBudgetExceeded rejection)
                then ("validator" :: T.Text)
                else "budget"
        , "rejection" .= srText rejection
        , "budgetPurposes" .= srBudgetExceeded rejection
        , "overDeclaredPurposes"
            .= exceedsDeclaredUnits (srMeasured rejection) (srDeclared rejection)
        , "declared"
            .= purposeDeclarationsJson (srMeasured rejection) (srDeclared rejection)
        , "measured" .= purposeMeasurementsJson (srMeasured rejection)
        ]

rejectionDetail :: StepRejection -> String
rejectionDetail rejection =
    " refusalKind="
        <> (if null (srBudgetExceeded rejection) then "validator" else "budget")
        <> " budgetPurposes="
        <> show (srBudgetExceeded rejection)
        <> " overDeclaredPurposes="
        <> show
            (exceedsDeclaredUnits (srMeasured rejection) (srDeclared rejection))
        <> " nodeRejection="
        <> T.unpack (oneLine maxStepLineReasonChars (srText rejection))
        <> " declared="
        <> compactJson
            (purposeDeclarationsJson (srMeasured rejection) (srDeclared rejection))
        <> " measured="
        <> compactJson (purposeMeasurementsJson (srMeasured rejection))

purposeMeasurementsJson :: PurposeMeasurements -> Value
purposeMeasurementsJson = Object . KM.fromList . map toPair . Map.toList
  where
    toPair (purpose, measured) = (Key.fromText purpose, measuredJson measured)

purposeDeclarationsJson
    :: PurposeMeasurements -> PurposeUnits -> Value
purposeDeclarationsJson measured = Object . KM.fromList . map toPair . Map.toList
  where
    toPair (purpose, (mem, cpu)) =
        ( Key.fromText purpose
        , object
            [ "mem" .= mem
            , "cpu" .= cpu
            , "source" .= case Map.lookup purpose measured of
                Just (Left _) -> ("probe-allowance" :: T.Text)
                _ -> "twice-measured"
            ]
        )

transactionPurposeUnits :: ConwayTx -> PurposeUnits
transactionPurposeUnits tx = case tx ^. witsTxL . rdmrsTxWitsL of
    Redeemers purposes ->
        Map.fromList
            [ (T.pack (show purpose), (fromIntegral mem, fromIntegral cpu))
            | (purpose, (_, ExUnits mem cpu)) <- Map.toList purposes
            ]

transactionPurposeHashes
    :: ConwayTx -> Map.Map TxIn (TxOut ConwayEra) -> Map.Map T.Text T.Text
transactionPurposeHashes tx visible = Map.fromList (spending <> minting)
  where
    spending =
        [ ( T.pack
                (show (ConwaySpending (AsIx ix) :: ConwayPlutusPurpose AsIx ConwayEra))
          , T.pack (hex (scriptHashBytes hash))
          )
        | (ix, input) <-
            zip [0 ..] (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL))
        , Just out <- [Map.lookup input visible]
        , Addr _ (ScriptHashObj hash) _ <- [out ^. addrTxOutL]
        ]
    MultiAsset policies = tx ^. bodyTxL . mintTxBodyL
    minting =
        [ ( T.pack
                (show (ConwayMinting (AsIx ix) :: ConwayPlutusPurpose AsIx ConwayEra))
          , T.pack (hex (scriptHashBytes (policyID policy)))
          )
        | (ix, policy) <- zip [0 ..] (Map.keys policies)
        ]

measuredJson :: Either T.Text (Integer, Integer) -> Value
measuredJson (Left reason) = object ["error" .= boundedNodeReason maxLiveStepReasonChars reason]
measuredJson (Right (mem, cpu)) = object ["mem" .= mem, "cpu" .= cpu]

oneLine :: Int -> T.Text -> T.Text
oneLine = boundedNodeReason

compactJson :: Value -> String
compactJson = T.unpack . TE.decodeUtf8 . BSL.toStrict . encode

renderDifferences :: [Compare.Difference] -> String
renderDifferences differences =
    unlines
        [ T.unpack (Compare.differenceObservation difference)
            <> " differs from Lean\nexpected: "
            <> jsonText (Compare.differenceExpected difference)
            <> "\nobserved: "
            <> jsonText (Compare.differenceObserved difference)
        | difference <- differences
        ]
  where
    jsonText = T.unpack . TE.decodeUtf8 . BSL.toStrict . encode

-- Mapping allocation is confined to context/actions. Observation is read-only.
newtype WalletIdentity = WalletIdentity ByteString
    deriving stock (Show, Eq, Ord)

newtype PolicyIdentity = PolicyIdentity ByteString
    deriving stock (Show, Eq, Ord)

newtype KeyIdentity = KeyIdentity ByteString
    deriving stock (Show, Eq, Ord)

-- | A booked approval's asset name, as the hex the chain carries.
newtype ApprovalIdentity = ApprovalIdentity T.Text
    deriving stock (Show, Eq, Ord)

{- | An output reference, as `txInReference` spells it: the one a request sits
at, or the other one a rebound return names.
-}
newtype ReferenceIdentity = ReferenceIdentity T.Text
    deriving stock (Show, Eq, Ord)

{- | A datum a booked request carries for its delivered output, by the BLAKE2b-256
hash of the datum as the chain serialises it: the model's datum value is the
identity allocated for it.
-}
newtype DatumIdentity = DatumIdentity ByteString
    deriving stock (Show, Eq, Ord)

{- | An output reference's spelling, whether read from a ledger input or from an
inline datum presenting it: the transaction id in hex, then the index.
-}
onChainReference :: OnChainTxOutRef -> T.Text
onChainReference (OnChainTxOutRef (BuiltinByteString txId) index) = hexT txId <> "#" <> T.pack (show index)

txInReference :: TxIn -> T.Text
txInReference = onChainReference . txInToRef

data LiveIdentities = LiveIdentities
    { liveWallets :: IORef (Identity.Identities WalletIdentity)
    , livePolicies :: IORef (Identity.Identities PolicyIdentity)
    , liveKeys :: IORef (Identity.Identities KeyIdentity)
    , liveApprovals :: IORef (Identity.Identities ApprovalIdentity)
    , liveReferences :: IORef (Identity.Identities ReferenceIdentity)
    , liveDatums :: IORef (Identity.Identities DatumIdentity)
    }

newLiveIdentities :: IO LiveIdentities
newLiveIdentities =
    LiveIdentities
        <$> newIORef Identity.empty
        <*> newIORef Identity.empty
        <*> newIORef Identity.empty
        <*> newIORef Identity.empty
        <*> newIORef Identity.empty
        <*> newIORef Identity.empty

allocateIdentity
    :: (Ord identity)
    => IORef (Identity.Identities identity) -> identity -> IO Integer
allocateIdentity state identity = do
    original <- readIORef state
    let (identifier, updated) = Identity.identify identity original
    writeIORef state updated
    pure identifier

observeIdentity
    :: (Ord identity)
    => IORef (Identity.Identities identity) -> identity -> IO Integer
observeIdentity state identity =
    readIORef state >>= either failWith pure . Identity.observe identity

prepareRegistrationIdentities
    :: LiveIdentities -> RowCage -> ByteString -> Addr -> IO ()
prepareRegistrationIdentities ids cage key recipient = do
    let cfg = rcCfg cage
    _ <-
        allocateIdentity
            (liveWallets ids)
            (WalletIdentity (serialiseAddr genesisAddr))
    _ <-
        allocateIdentity
            (liveWallets ids)
            (WalletIdentity (serialiseAddr recipient))
    _ <- allocateIdentity (liveKeys ids) (KeyIdentity key)
    mapM_
        (allocateIdentity (livePolicies ids) . PolicyIdentity . SBS.fromShort)
        (registryPins cfg)

-- | A registry's four pinned policies, in the order the model names them.
registryPins :: CageConfig -> [SBS.ShortByteString]
registryPins cfg =
    [ cfgApplicationPolicy cfg
    , cfgActivePolicy cfg
    , cfgAbsentPolicy cfg
    , cfgTerminalPolicy cfg
    ]

{- | Bind the approval a booked request carries to its model name, while
acting: the model names it by the request's edge, key, owner and
destination identities, as the destination commitment does. Observation
only looks these bindings up.
-}
bindBookedApproval
    :: LiveIdentities -> CageConfig -> TxOut ConwayEra -> Value -> IO ()
bindBookedApproval ids cfg requestOut modelRequest = do
    (_, booked) <- storyApprovalOn cfg requestOut
    case booked of
        Nothing -> pure ()
        Just name -> do
            let field key = case modelRequest of
                    Object fields -> KM.lookup key fields
                    _ -> Nothing
                number key = case field key of
                    Just (Number n) -> Just (truncate n)
                    _ -> Nothing
            modelName <- maybe (failWith "booked approval has no model name") pure $ do
                String edge <- field "edge"
                key <- number "key"
                owner <- number "owner"
                output <- number "output"
                let destination = if edge == "insertAbsent" then 0 else output
                Compare.approvalAssetName edge key owner destination
            approvals <- readIORef (liveApprovals ids)
            either
                failWith
                (writeIORef (liveApprovals ids))
                (Identity.bind (ApprovalIdentity name) modelName approvals)

observePins
    :: LiveIdentities
    -> CageConfig
    -> IO (Integer, Integer, Integer, Integer)
observePins ids cfg = do
    pins <-
        mapM
            (observeIdentity (livePolicies ids) . PolicyIdentity . SBS.fromShort)
            [ cfgApplicationPolicy cfg
            , cfgActivePolicy cfg
            , cfgAbsentPolicy cfg
            , cfgTerminalPolicy cfg
            ]
    case pins of
        [a, b, c, d] -> pure (a, b, c, d)
        _ -> failWith "registry context has an incomplete policy mapping"

-- | A registry configuration in the model's vocabulary, over an abstract root.
abstractConfig
    :: OnChainTokenState
    -> Integer
    -> Integer
    -> Integer
    -> Integer
    -> [Word8]
    -> Value
abstractConfig state application active absent terminal root =
    object
        [ "root" .= root
        , "maxFee" .= stateMaxFee state
        , "processTime" .= stateProcessTime state
        , "retractTime" .= stateRetractTime state
        , "applicationPolicy" .= application
        , "activePolicy" .= active
        , "absentPolicy" .= absent
        , "terminalPolicy" .= terminal
        ]

{- | What the chain shows, in the model's vocabulary.

Every value here is read off the registration that actually happened and
translated through bindings recorded while the run was constructed. The leaf is
classified by rebuilding the candidate tries against the real commitment, so it
is the chain's own answer rather than a label assumed from the request. The
abstract root is then recomputed from that translated trie, never compared with
the concrete authenticated-map hash.
-}

-- | Ask the model about a registry whose context differs from this one's.
bumpEvaluationField :: Text -> Value -> Value
bumpEvaluationField name value = case value of
    Object fields -> case KM.lookup "start" fields of
        Just (Object start) -> case KM.lookup "config" start of
            Just (Object config) -> case KM.lookup (Key.fromText name) config of
                Just (Number current) ->
                    let raised =
                            Object (KM.insert (Key.fromText name) (Number (current + 1)) config)
                    in  Object
                            (KM.insert "start" (Object (KM.insert "config" raised start)) fields)
                _ -> value
            _ -> value
        _ -> value
    _ -> value

-- | Present a delivered quantity the chain did not deliver.
bumpObservedMint :: Value -> Value
bumpObservedMint value = case value of
    Object fields -> case KM.lookup "mint" fields of
        Just (Array assets) -> case toList assets of
            Object asset : rest ->
                let raised = case KM.lookup "quantity" asset of
                        Just (Number quantity) ->
                            Object (KM.insert "quantity" (Number (quantity + 1)) asset)
                        _ -> Object asset
                in  Object
                        (KM.insert "mint" (Array (Vector.fromList (raised : rest))) fields)
            _ -> value
        _ -> value
    _ -> value

-- ---------------------------------------------------------
-- register-active-key helpers (#184)
-- ---------------------------------------------------------

-- | Hex, as the receipt records it.
hexT :: ByteString -> T.Text
hexT = T.pack . hex

-- | The raw 28 bytes a policy id is.
cg21PolicyBytes :: PolicyID -> ByteString
cg21PolicyBytes (PolicyID sh) = scriptHashBytes sh

-- | The cage's live eight-field state datum.
readRegistryState :: Env -> RowCage -> IO OnChainTokenState
readRegistryState env cage = do
    (_, out) <- cageStateUtxo env cage
    extractState out

{- | Assemble a fold of whatever is pending, WITHOUT evaluating it.

The library builder evaluates every fold against the node before it
returns one, so a fold the state script refuses never becomes a
transaction at all: `updateTokenWithDuties` raises the evaluation
failure and there is nothing to submit and nothing for the chain to
reject. The harness's own assembly builds the same shape and leaves the
verdict to the node — which is what a refusal on chain means.

This is the builder BOTH halves of the duplicate pair use, so the pair
differs in the key's occupancy and in nothing else.
-}
storyProofs
    :: Env
    -> RowCage
    -> TokenId
    -> [(TxIn, TxOut ConwayEra)]
    -> IO ([[ProofStep]], Root)
storyProofs env cage tid reqs = do
    attempt <- try @SomeException (speculativeApplyAll env cage tid reqs)
    case attempt of
        Right ok -> pure ok
        Left _ -> withSpeculativeTrie (envTm env) tid $ \trie -> do
            steps <-
                mapM
                    ( \(_, o) ->
                        fromMaybe []
                            <$> CageTrie.getProofSteps trie (fst (fst (requestDatumOf o)))
                    )
                    reqs
            root <- CageTrie.getRoot trie
            pure (steps, root)

{- | Fold through the harness's own assembly, submit, commit, and record
what the roots did — the accepting half of the duplicate pair.
-}

{- | Where the fold actually delivered, and what that output holds.

Read off the accepted transaction's own outputs rather than off the
address the harness queried: querying by address and then reporting that
address back would compare a value with itself.
-}
storyDelivery
    :: PolicyID -> ByteString -> ConwayTx -> IO (T.Text, [AssetEntry])
storyDelivery policy key tx =
    case carriersOf policy key tx of
        [o] ->
            pure
                ( hexT (serialiseAddr (o ^. addrTxOutL))
                , [ AssetEntry (hexT (cg21PolicyBytes policy)) (hexT key) q
                  | (p, names) <- Map.toList (rawAssets o)
                  , p == policy
                  , (AssetName an, q) <- Map.toList names
                  , SBS.fromShort an == key
                  ]
                )
        outs ->
            failWith
                ( "generic edge: the fold has "
                    <> show (length outs)
                    <> " outputs carrying the active token at this key, want one"
                )

{- | The approval the booked request UTxO carries, read off the chain as
FR-4 counts it: the total quantity under the application policy, paired
with the approval's name when exactly one name is carried at quantity 1.
Quantity 0 with no name is a request that carries no approval. Any other
shape — a second name, one name at a quantity other than 1, or any asset
under a foreign policy — fails the run naming the count found, rather
than being described as either shape.
-}
storyApprovalOn
    :: CageConfig -> TxOut ConwayEra -> IO (Integer, Maybe T.Text)
storyApprovalOn cfg out =
    let app = policyIdFromPin (cfgApplicationPolicy cfg)
        onApplication =
            [ (SBS.fromShort an, quantity)
            | (p, names) <- Map.toList (rawAssets out)
            , p == app
            , (AssetName an, quantity) <- Map.toList names
            ]
        foreignPolicies =
            [ p
            | (p, names) <- Map.toList (rawAssets out)
            , p /= app
            , not (Map.null names)
            ]
    in  case (onApplication, foreignPolicies) of
            ([(an, 1)], []) -> pure (1, Just (hexT an))
            ([], []) -> pure (0, Nothing)
            _ ->
                failWith
                    ( "generic edge: the request UTxO carries "
                        <> show (length onApplication)
                        <> " approval names totalling "
                        <> show (sum (map snd onApplication))
                        <> " under the application policy and "
                        <> show (length foreignPolicies)
                        <> " assets under foreign policies, want one name at quantity 1 or none"
                    )

{- | What the request's OWN datum says: the lovelace it carries, and the
approval name its edge, key, owner and destination pair hash to.

The recomputation is the destination binding. The approval's asset name
IS the hash of the scoping tuple the request names, so a fold delivering
somewhere the approval did not bind makes the recomputed name differ
from the one the chain shows on the request.
-}
cg21RequestFacts :: TxOut ConwayEra -> IO (Integer, T.Text)
cg21RequestFacts out = do
    rq <- case extractCageDatum out of
        Just (RequestDatum r) -> pure r
        _ -> failWith "generic edge: the request UTxO carries no request datum"
    -- #183: the request states its seven-admitted-edges row itself; there is nothing to
    -- derive. A tag outside the table names no approval binding, so a
    -- row that reads one would be reading a fact that does not exist.
    edgeIx <- do
        let e = requestEdge rq
        if e >= edgeInsertAbsent && e <= edgeWitnessTerminal
            then pure e
            else
                failWith "register-active-key: the request names no admissible edge"
    let BuiltinByteString owner = requestOwner rq
        Coin lovelace = out ^. coinTxOutL
    pure
        ( lovelace
        , hexT
            ( approvalName
                edgeIx
                (requestKey rq)
                owner
                (approvalDestination (requestDestination rq))
            )
        )
