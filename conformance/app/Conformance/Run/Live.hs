{-# LANGUAGE GADTs #-}
{- |
Module      : Conformance.Run.Live
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Live (StepOutcome (..), LiveStep (..), LiveState (..), runLive, submitEdge, storyReferences, storyWitness, storyModelRequest, observeStep, observeAcceptedStep, classifyLeaves, observeCustody, observePaid, observeSigner, observeStepMint, observedStepTx, askModel, compareStep, tamperDifferences, reportedDifferences, differingPaths, renderStepPath, differenceJson, renderDifferences, WalletIdentity (..), PolicyIdentity (..), KeyIdentity (..), LiveIdentities (..), newLiveIdentities, allocateIdentity, observeIdentity, prepareRegistrationIdentities, observePins, abstractConfig, bumpEvaluationField, bumpObservedMint, hexT, cg21PolicyBytes, readRegistryState, storyProofs, storyRefusalTag, storyDelivery, storyApprovalOn, cg21RequestFacts) where

import Conformance.Run.Control
import Conformance.FoldFixture qualified as FoldFixture
import Conformance.Run.Fold
import Conformance.Run.Book
import Conformance.Run.Units
import Conformance.Run.Cage
import Conformance.Run.Wallet
import Conformance.Run.Submit
import Conformance.Run.Environment
import Conformance.Run.Observe

import Control.Monad.Operational qualified as Operational
import Conformance.Story.Specification qualified as Specification
import Conformance.Story.Live qualified as Live
import Conformance.Story.Identity qualified as Identity
import Conformance.Compare.Registration qualified as Compare
import Conformance.Compare.Perturbation qualified as Perturbation
import Conformance.Observe.Payments qualified as Payments
import Conformance.Lean.Oracle qualified as LeanOracle
import Conformance.Story.Binding qualified as Binding
import Conformance.PurposeUnits (
    PurposeUnits,
    PurposeMeasurements,
    missingPurposeBudgets,
    budgetRefusalPurposes,
 )
import Conformance.Receipt (maxLiveStepReasonChars)
import Conformance.NodeRejection (boundedNodeReason)
import Control.Exception (
    ErrorCall (..),
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson (
    eitherDecodeFileStrict,
    Value (..),
    encode,
    object,
    toJSON,
    (.=),
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub, sort, sortOn, stripPrefix)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import Data.Word (Word8)
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import System.Environment (lookupEnv)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (
    Addr (..),
    serialiseAddr,
 )

import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Api.PParams (ppMaxBlockExUnitsL, ppMaxTxExUnitsL)
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
 )
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx.Out (
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.BaseTypes (StrictMaybe (SJust))
import Cardano.Ledger.Core (KeyHash, hashScript)
import Cardano.Ledger.Plutus.Data (Data (..), binaryDataToData)
import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..), txInToText)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ExUnits (..),
    ConwayEra,
    PolicyID (..),
    Root (..),
    TokenId (..),
    TxOut,
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.Pure (mkPureTrie)
import Singular.Registry.TxBuilder.Edges qualified as RegistryEdges
import Singular.Registry.TxBuilder.Internal (
    emptyRoot,
    leafAbsent,
    leafActive,
    leafTerminal,
    approvalName,
    policyIdFromPin,
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    policyIdFromPin,
    currentPosixMs,
    extractCageDatum,
    mkInlineDatum,
    requestAddrFromCfg,
    scriptHashBytes,
    spendingIndex,
    toLedgerData,
    toPlcData,
    trySlots,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Retract (retractRequestImpl)
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    edgeDeleteAbsent,
    edgeInsertAbsent,
    edgeUpdateActive,
    edgeWitnessTerminal,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),
    ProofStep (..),
    RequestAction (Update),
    UpdateRedeemer (Modify),
 )
import Singular.Registry.Types qualified as Types
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter (SubmitResult (..))
import PlutusTx (fromBuiltinData)
import PlutusTx.Builtins.Internal (BuiltinByteString (..), BuiltinData (..))

import Conformance.Mirror (
    emit,
    failWith,
    hex,
    require,
    txIdHex,
 )
import Conformance.Receipt (AssetEntry (..))
import Conformance.Run.Retraction (declareRetraction)
import Conformance.Run.Step (
    StepOutcome (..),
    StepRejection (..),
    judgedTransaction,
    refusedOutcome,
    storyRefusalTag,
 )

-- | Keep step diagnostics on one bounded line while retaining the full reason
-- in memory for the receipt writer's tighter bound.
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
    , lsRequestLovelace :: Integer
    , lsAfter :: Maybe OnChainTokenState
    , lsWitness :: Maybe (TxIn, TxOut ConwayEra)
    , lsCustody :: Maybe (TxIn, TxOut ConwayEra)
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
    }


-- | Interpret shared story instructions against the running node and builders.
runLive :: Env -> Live.Story RowCage Addr LiveStep Value Value res -> IO res
runLive env program = do
    identities <- newLiveIdentities
    pending <- newIORef 0
    starts <- newIORef Map.empty
    traces <- newIORef Map.empty
    keys <- newIORef Map.empty
    wallets <- newIORef Map.empty
    registryIds <- newIORef Map.empty
    result <- go (LiveState identities pending starts traces keys wallets registryIds) program
    remaining <- readIORef pending
    require "live story submitted a request without comparing it" (remaining == 0)
    pure result
  where
    go :: LiveState -> Live.Story RowCage Addr LiveStep Value Value res -> IO res
    go state body = case Operational.view body of
        Operational.Return result -> pure result
        Specification.Action instruction Operational.:>>= next ->
            interpret state instruction >>= go state . next
        Specification.Theorem declaration body' Operational.:>>= next -> do
            let binding = Specification.theoremBinding declaration
            manifest <- Binding.loadManifest >>= either failWith pure
            require "live theorem binding is missing or stale" (Binding.resolveBinding manifest binding)
            emit "theorem" (Binding.boName binding)
            runClauses state binding (Specification.clauses body') >>= go state . next
    runClauses :: LiveState -> Binding.Binding -> Operational.Program (Specification.Clause thm (Live.LiveI RowCage Addr LiveStep Value Value)) res -> IO res
    runClauses state binding body = case Operational.view body of
        Operational.Return result -> pure result
        Specification.Clause title check actions Operational.:>>= next -> do
            require "clause check names a different declaration than its enclosing theorem"
                (binding == Specification.theoremBinding (Specification.checkTheorem check))
            emit "clause" title
            observation <- go state actions
            _ <- go state (Specification.checkAction check observation)
            runClauses state binding (next observation)
    interpret :: LiveState -> Live.LiveI RowCage Addr LiveStep Value Value obs -> IO obs
    interpret state instruction = case instruction of
        Live.Submit exit registry request -> do
            step <- submitEdge env state registry exit Nothing request
            modifyIORef' (livePendingComparisons state) (+ 1)
            pure step
        Live.Tamper alteration exit registry request -> do
            step <- submitEdge env state registry exit (Just alteration) request
            modifyIORef' (livePendingComparisons state) (+ 1)
            pure step
        Live.Observe step -> observeStep env state step
        Live.Compare step observation -> do
            result <- compareStep env state step observation
            modifyIORef' (livePendingComparisons state) (subtract 1)
            remaining <- readIORef (livePendingComparisons state)
            require "live story compared more requests than it submitted" (remaining >= 0)
            pure result


-- | One story instruction books exactly one request. All later work keeps its
-- outref, so a refused request left at the script cannot leak into a fold. The
-- request then leaves by the instruction's exit: folded by its own edge,
-- rejected once it may no longer be folded, or retracted by its owner.
submitEdge :: Env -> LiveState -> RowCage -> Live.Exit -> Maybe Live.Tamper -> Live.EdgeRequest Addr -> IO LiveStep
submitEdge env state cage exit alteration request = do
    let key = TE.encodeUtf8 (T.pack (Live.requestKey request))
        cfg = rcCfg cage
        edge = fromIntegral (fromEnum (Live.requestEdge request))
        wallet = Live.requestWallet request
        ids = liveIds state
    tid <- cageTid cage
    let registry = show tid
    knownRegistries <- readIORef (liveRegistryIds state)
    when (Map.notMember registry knownRegistries) $
        modifyIORef' (liveRegistryIds state)
            (Map.insert registry (fromIntegral (Map.size knownRegistries) + 1))
    before <- readRegistryState env cage
    starts <- readIORef (liveStarts state)
    case Map.lookup registry starts of
        Nothing -> do
            require "generic story requires a freshly booted empty registry"
                (unOnChainRoot (stateRoot before) == emptyRoot)
            modifyIORef' (liveStarts state) (Map.insert registry before)
        Just _ -> pure ()
    prepareRegistrationIdentities ids cage key wallet
    modifyIORef' (liveRegistryKeys state)
        (Map.alter (\known -> Just (case known of
            Nothing -> [key]
            Just keys | key `elem` keys -> keys
                      | otherwise -> key : keys)) registry)
    modifyIORef' (liveRegistryWallets state)
        (Map.alter (\known -> Just (foldr (\address addresses ->
            if address `elem` addresses then addresses else address : addresses)
            (fromMaybe [] known) [wallet, genesisAddr])) registry)
    let destination = case Live.requestEdge request of
            Live.InsertAbsent -> (serialiseAddr wallet, BS.empty)
            Live.InsertActive -> (serialiseAddr wallet, BS.empty)
            Live.UpdateActive -> (serialiseAddr wallet, BS.empty)
            Live.DeleteAbsent -> (serialiseAddr wallet, BS.empty)
            Live.WitnessTerminal -> (serialiseAddr wallet, BS.empty)
            _ -> (BS.empty, BS.empty)
    refs <- storyReferences env cage key edge
    booking <- try @ErrorCall (bookEdge env cfg tid genesisAddr genesisSignKey key edge destination refs
        (defaultTipCoin cfg + cgDeposit))
    case booking of
        Left failure -> case stripPrefix
            ("conformance: bookEdge refused (edge " <> show edge <> ", key " <> show key <> "): ")
            (displayException failure) of
            Just nodeReason -> do
                let (_, _, codes) = envCodes env
                    decided = RegistryEdges.bookingApproval codes edge key
                        (addrKeyHashBytes genesisAddr) destination
                modelRequest <- storyModelRequest ids cfg exit request cgDeposit (stateMaxFee before)
                    Nothing (Left decided)
                pure (LiveStep cage request exit alteration Nothing Nothing modelRequest 0 Nothing Nothing
                    Nothing [] (StepUnsupported Nothing (T.pack nodeReason) Nothing))
            Nothing -> throwIO failure
        Right named@(reqIn, reqOut) -> do
            let Coin bond = reqOut ^. coinTxOutL
                deposit = bond - stateMaxFee before
            require "booked request holds less than the on-chain processing tip" (deposit >= 0)
            -- The output reference the request sits at is named while acting;
            -- a retraction's return is bound to it.
            reference <- allocateIdentity (liveReferences ids) (ReferenceIdentity (txInReference reqIn))
            modelRequest <- storyModelRequest ids cfg exit request deposit (stateMaxFee before)
                (Just reference) (Right reqOut)
            bindBookedApproval ids cfg reqOut modelRequest
            -- A payment tamper sends what it moves to a wallet other than the
            -- request's, whose identity is allocated here, while acting.
            elsewhere <- case alteration of
                Just payment | payment `elem` [Live.OtherAddress, Live.ShortByOne] -> do
                    other <- if wallet == genesisAddr then snd <$> secondWallet env else pure genesisAddr
                    _ <- allocateIdentity (liveWallets ids) (WalletIdentity (serialiseAddr other))
                    modifyIORef' (liveRegistryWallets state)
                        (Map.adjust (\known -> if other `elem` known then known else other : known) registry)
                    pure (Just other)
                _ -> pure Nothing
            ownerKey <- requestOwnerKey reqOut
            let facts = Payments.ExitFacts exit (Live.requestEdge request) ownerKey Nothing
                    (Just (txInReference reqIn))
                editsOf transaction = either (failWith . (("tamper: " <> show alteration <> ": ") <>)) pure
                    (maybe (Right []) (\t -> Payments.tamperEdits t facts
                        (map snd (foldOutputsOf cfg transaction))) alteration)
            -- The exit's transaction, assembled with the given per-purpose units
            -- (none: the builder's own) and tampered; its collateral; and the
            -- active witness a fold spends.
            (build, collateral, witness) <- case exit of
                Live.Retract -> retractionBuilder env ids cage tid named elsewhere alteration editsOf
                _ -> foldingBuilder env cage tid exit alteration request named before elsewhere editsOf
            pp <- Cage.queryProtocolParams (envProv env)
            let maxUnits = pp ^. ppMaxTxExUnitsL
                blockUnits = pp ^. ppMaxBlockExUnitsL
            template <- build Map.empty
            let purposes = redeemerPurposeNames template
            require "honest fold has no redeemer purposes" (not (null purposes))
            probePairs <- either (failWith . T.unpack) pure
                (protocolProbePurposeUnits maxUnits blockUnits purposes)
            let probePurposeUnits = Map.map
                    (\(mem, cpu) -> ExUnits (fromIntegral mem) (fromIntegral cpu))
                    probePairs
            trial <- build probePurposeUnits
            measurements <- measurePurposeUnits env trial
            require "node evaluation did not return every redeemer purpose"
                (sort (Map.keys measurements) == sort (redeemerPurposeNames trial))
            declaredPairs <- either (failWith . T.unpack) pure (declaredPurposeUnits maxUnits blockUnits measurements)
            let declared = Map.map
                    (\(mem, cpu) -> ExUnits (fromIntegral mem) (fromIntegral cpu))
                    declaredPairs
                missingDeclarations = missingPurposeBudgets
                    (successfulPurposeUnits measurements)
                    declaredPairs
            require "measured script purpose has no purpose-specific declaration"
                (null missingDeclarations)
            -- Evaluation can consume the entire short validity interval on a busy
            -- node. Assemble the same one-request shape again immediately before
            -- submission; its fresh upper bound cannot age during measurement.
            unsigned <- build declared
            let allInputs = Set.toList (unsigned ^. bodyTxL . inputsTxBodyL)
            pending <- pendingRequests env cage
            require "generic step spent another pending request"
                (filter (`elem` map fst pending) allInputs == [reqIn])
            let wanted = Set.insert collateral (unsigned ^. bodyTxL . inputsTxBodyL)
            visible <- fmap Map.fromList $ fmap concat $ mapM (Cage.queryUTxOs (envProv env))
                [genesisAddr, wallet, requestAddrFromCfg cfg tid (network cfg),
                 cageAddrFromCfg cfg (network cfg)]
            emit "step-inputs" ("request=" <> T.unpack (txInToText reqIn)
                <> " collateral=" <> T.unpack (txInToText collateral)
                <> " inputs=" <> show (map txInToText allInputs)
                <> " visible=" <> show (map txInToText (Map.keys visible)))
            require "generic fold has an input missing from the chain snapshot"
                (all (`Map.member` visible) (Set.toList wanted))
            let signed = addKeyWitness genesisSignKey unsigned
                submittedBudgets = transactionPurposeUnits signed
                -- What each spent input holds of the state policy, which every
                -- registry's state token is minted under.
                statePolicy = cg21PolicyBytes (cagePolicyIdFromCfg cfg)
                spent = [ maybe 0 (sum . Map.elems . Map.findWithDefault Map.empty statePolicy . outAssets)
                            (Map.lookup input visible)
                        | input <- allInputs ]
            require "assembled fold changed its per-purpose declarations"
                (submittedBudgets == declaredPairs)
            emit "step-units" ("measured=" <> compactJson (purposeMeasurementsJson measurements)
                <> " declared=" <> compactJson (purposeDeclarationsJson measurements submittedBudgets))
            result <- submitTxResilient (envSubmit env) signed
            case result of
                Submitted _ -> do
                    case alteration of
                        Just payment | payment /= Live.ExtraSigner -> failWith
                            (Live.tamperName payment <> " FINDING: chain accepted tampered "
                                <> Live.exitName exit (Live.requestEdge request)
                                <> " for " <> Live.requestKey request <> " (" <> txIdHex signed <> ")")
                        _ -> pure ()
                    awaitTx signed
                    -- Only a fold moves the trie; a reject and a retraction leave it.
                    when (exit == Live.Fold) $ rowCommit env cage key edge
                    after <- readRegistryState env cage
                    (mem, cpu) <- either (failWith . T.unpack) pure
                        (aggregatePurposeUnits measurements)
                    writeIORef (rcUnits cage) (mem, cpu)
                    modifyIORef' (envLiveMeasurements env) (<> [(mem, cpu, txSizeBytes signed)])
                    pure (LiveStep cage request exit alteration (Just reqIn) (Just reqOut) modelRequest bond
                        (Just after) witness (custodyOf refs) spent
                        (StepAccepted signed (mem, cpu, txSizeBytes signed)))
                Rejected reason -> do
                    let explanation = T.unpack (TE.decodeUtf8Lenient reason)
                        -- A retraction is judged by the request script, every other
                        -- exit by the state script.
                        marker = if exit == Live.Retract then requestMarkerOf cfg tid else stateMarkerOf cfg
                        diagnostic =
                            StepRejection
                                { srText = T.pack explanation
                                , srMeasured = measurements
                                , srDeclared = declaredPairs
                                , srBudgetExceeded = budgetRefusalPurposes
                                    (transactionPurposeHashes signed visible) (T.pack explanation)
                                }
                    pure (LiveStep cage request exit alteration (Just reqIn) (Just reqOut) modelRequest bond
                        Nothing witness (custodyOf refs) spent
                        (refusedOutcome marker signed diagnostic))
  where
    -- A fold spends the custody its edge consumes; a reject and a retraction
    -- consume none.
    custodyOf refs = if exit == Live.Fold then listToMaybe refs else Nothing


{- | A fold or a reject of the booked request, through the harness's own fold
assembly: a fold carries the request's proof, a reject the @Rejected@ action
once the request may no longer be folded, the root unchanged. The model
requires no signer; the extra-signer tamper adds the key this process already
signs every fold with, so the ledger has its witness and judges the signer alone.
-}
foldingBuilder :: Env -> RowCage -> TokenId -> Live.Exit -> Maybe Live.Tamper -> Live.EdgeRequest Addr
    -> (TxIn, TxOut ConwayEra) -> OnChainTokenState -> Maybe Addr
    -> (ConwayTx -> IO [Payments.OutputEdit])
    -> IO (Map.Map T.Text ExUnits -> IO ConwayTx, TxIn, Maybe (TxIn, TxOut ConwayEra))
foldingBuilder env cage tid exit alteration request named before elsewhere editsOf = do
    let cfg = rcCfg cage
        key = TE.encodeUtf8 (T.pack (Live.requestKey request))
    witness <- if exit == Live.Fold
        then storyWitness env cfg key (Live.requestWallet request)
        else pure Nothing
    (actions, root, lower) <- case exit of
        Live.Reject -> do
            let (_, submittedAt) = requestDatumOf (snd named)
                deadline = submittedAt + stateProcessTime before + stateRetractTime before
            sleepUntil (deadline + 500)
            -- The lower bound falls after the retract window closes, or the
            -- request script reads the fold as neither phase 1 nor rejectable.
            lower <- trySlots (envProv env) [deadline + 400, deadline + 200, deadline + 100]
            pure ([Types.Rejected], Root (unOnChainRoot (stateRoot before)), Just lower)
        _ -> do
            (proofs, root) <- storyProofs env cage tid [named]
            pure (map Update proofs, root, Nothing)
    stateUtxo <- cageStateUtxo env cage
    (pot, funder) <- collateralPotWithChange env
    let initialUnits = ExUnits 0 0
        initialSpec = (rowSpec cage tid stateUtxo [named] actions root initialUnits)
            { fsCollateral = Just pot
            , fsSigners = Just [addrWitnessKeyHash (addrKeyHashBytes genesisAddr)
                | alteration == Just Live.ExtraSigner]
            , fsHolderUtxos = maybe [] pure witness, fsFunder = Just funder
            , fsLower = lower
            , fsOmitUnfundedBurn = exit == Live.Fold
                && Live.requestEdge request == Live.UpdateTerminal && isNothing witness }
    fixtureUnits <- FoldFixture.prepare
        (envFoldFixture env) (envProv env)
        (\budget -> assembleFoldWithFee env initialSpec{fsUnits = budget})
        (submitTxResilient (envSubmit env) . addKeyWitness genesisSignKey)
        initialUnits
    let spec = initialSpec{fsUnits = fixtureUnits}
        build units = do
            now <- currentPosixMs
            upper <- trySlots (envProv env) [now + 8_000, now + 7_500, now + 7_000]
            transaction <- assembleFoldWithFee env spec{fsPurposeUnits = units, fsUpper = Just upper}
            edits <- editsOf transaction
            either (failWith . (("tamper: " <> show alteration <> ": ") <>)) pure
                (editOutputs elsewhere Nothing transaction edits)
    pure (build, pot, witness)


{- | A retraction of the booked request by its owner, through the offchain
builder once the request is retractable: the request is spent alone, its
return bound to it by an inline datum, the owner signing. A tamper edits that
transaction; spending the registry's state beside the request moves the state
from a reference input to an input, continued unchanged, with the state
validator resolved through the cage's reference output. The tampered shape is
then declared its own units and fee, the change absorbing the difference, and
collateralised by a dedicated pot.
-}
retractionBuilder :: Env -> LiveIdentities -> RowCage -> TokenId -> (TxIn, TxOut ConwayEra)
    -> Maybe Addr -> Maybe Live.Tamper -> (ConwayTx -> IO [Payments.OutputEdit])
    -> IO (Map.Map T.Text ExUnits -> IO ConwayTx, TxIn, Maybe (TxIn, TxOut ConwayEra))
retractionBuilder env ids cage tid (reqIn, reqOut) elsewhere alteration editsOf = do
    let cfg = rcCfg cage
        prov = envProv env
        (_, submittedAt) = requestDatumOf reqOut
    before <- readRegistryState env cage
    -- Phase 2 opens once the request's processing window has passed.
    sleepUntil (submittedAt + stateProcessTime before + 500)
    pot <- collateralPot env
    honest <- retractRequestImpl cfg prov tid reqIn genesisAddr
    -- The other request a rebound return names is the collateral pot's own
    -- output reference, named here while acting.
    other <- if alteration == Just Live.OtherReference
        then Just pot <$ allocateIdentity (liveReferences ids) (ReferenceIdentity (txInReference pot))
        else pure Nothing
    stateUtxo <- cageStateUtxo env cage
    pp <- Cage.queryProtocolParams prov
    let stateScripts = [ u | u@(_, out) <- rcRefs cage
                       , SJust script <- [out ^. referenceScriptTxOutL]
                       , hashScript script == cfgScriptHash cfg ]
        build units = do
            edits <- editsOf honest
            edited <- either (failWith . (("tamper: " <> show alteration <> ": ") <>)) pure $ do
                outputsEdited <- editOutputs elsewhere other honest (filter (/= Payments.SpendState) edits)
                if Payments.SpendState `elem` edits
                    then spendStateBeside stateUtxo stateScripts reqIn outputsEdited
                    else Right outputsEdited
            either failWith pure (declareRetraction pp units pot
                (sum (map (refScriptSize . snd) stateScripts)) genesisAddr edited)
    require "the cage publishes no reference output carrying its state validator"
        (not (null stateScripts) || alteration /= Just Live.StateSpent)
    pure (build, pot, Nothing)


{- | Spend the registry's state beside a retraction: the state moves from the
reference inputs to the inputs and is continued unchanged ahead of every other
output, spent by an empty @Modify@ under the state validator resolved through
its reference output; the retraction keeps its own redeemer at its new index.
-}
spendStateBeside :: (TxIn, TxOut ConwayEra) -> [(TxIn, TxOut ConwayEra)] -> TxIn -> ConwayTx
    -> Either String ConwayTx
spendStateBeside (stateIn, stateOut) stateScripts reqIn transaction = do
    let inputs = Set.insert stateIn (transaction ^. bodyTxL . inputsTxBodyL)
        references = Set.union (Set.delete stateIn (transaction ^. bodyTxL . referenceInputsTxBodyL))
            (Set.fromList (map fst stateScripts))
        Redeemers purposes = transaction ^. witsTxL . rdmrsTxWitsL
    (retraction, units) <- case Map.elems purposes of
        [only] -> Right only
        _ -> Left "a retraction carries one redeemer"
    let redeemers = Redeemers (Map.fromList
            [ (ConwaySpending (AsIx (spendingIndex reqIn inputs)), (retraction, units))
            , (ConwaySpending (AsIx (spendingIndex stateIn inputs)), (toLedgerData (Modify []), units)) ])
    pure (transaction
        & bodyTxL . inputsTxBodyL .~ inputs
        & bodyTxL . referenceInputsTxBodyL .~ references
        & bodyTxL . outputsTxBodyL .~ StrictSeq.fromList (stateOut : toList (transaction ^. bodyTxL . outputsTxBodyL))
        & witsTxL . rdmrsTxWitsL .~ redeemers)


-- | Wait for a phase boundary.
sleepUntil :: Integer -> IO ()
sleepUntil targetMs = do
    now <- currentPosixMs
    let remaining = targetMs - now
    when (remaining > 0) $ do
        emit "wait" (show remaining <> " ms to the next phase boundary")
        threadDelay (fromIntegral remaining * 1000)


-- | The certificate's destination is not an inferred post-state identity.
storyReferences :: Env -> RowCage -> ByteString -> Edge -> IO [(TxIn, TxOut ConwayEra)]
storyReferences env cage key edge
    | edge `notElem` [edgeUpdateActive, edgeDeleteAbsent] = pure []
    | otherwise = do
        let cfg = rcCfg cage
            absentPolicy = scriptHashBytes (policyID (policyIdFromPin (cfgAbsentPolicy cfg)))
        utxos <- Cage.queryUTxOs (envProv env) (cageAddrFromCfg cfg (network cfg))
        case [u | u@(_, out) <- utxos, Just (AbsentCustody _) <- [extractCageDatum out]
                , outAssets out == Map.singleton absentPolicy (Map.singleton key 1)] of
            [u] -> pure [u]
            _ -> failWith ("no single observed custody UTxO for " <> show key)


storyWitness :: Env -> CageConfig -> ByteString -> Addr -> IO (Maybe (TxIn, TxOut ConwayEra))
storyWitness env cfg key wallet = do
    utxos <- Cage.queryUTxOs (envProv env) wallet
    let policy = SBS.fromShort (cfgActivePolicy cfg)
        candidates = [u | u@(_, out) <- utxos
            , (Map.lookup policy (outAssets out) >>= Map.lookup key) == Just 1]
    case candidates of
        [] -> pure Nothing
        [u] -> pure (Just u)
        _ -> failWith ("more than one active witness input for " <> show key)


{- | Apply a tamper's edits to a transaction's outputs: a readdressed output
goes to @elsewhere@ with its value unchanged, a relovelaced output keeps its
address and assets, and a rebound output presents @other@'s output reference as
its inline datum.
-}
editOutputs :: Maybe Addr -> Maybe TxIn -> ConwayTx -> [Payments.OutputEdit] -> Either String ConwayTx
editOutputs elsewhere other transaction edits = do
    outputs <- foldl (\acc edit -> acc >>= apply edit)
        (Right (toList (transaction ^. bodyTxL . outputsTxBodyL))) edits
    pure (transaction & bodyTxL . outputsTxBodyL .~ StrictSeq.fromList outputs)
  where
    apply (Payments.Readdress i) outputs = case elsewhere of
        Just address -> Right (adjust i (addrTxOutL .~ address) outputs)
        Nothing -> Left "a tamper readdresses an output with no other address"
    apply (Payments.Relovelace i lovelace) outputs = Right (adjust i (coinTxOutL .~ Coin lovelace) outputs)
    apply (Payments.Rebind i) outputs = case other of
        Just reference -> Right (adjust i (datumTxOutL .~ mkInlineDatum (toPlcData (txInToRef reference))) outputs)
        Nothing -> Left "a tamper rebinds an output with no other output reference"
    apply Payments.SpendState _ = Left "spending the state beside a request edits no output"
    adjust i f outputs = [if j == i then f out else out | (j, out) <- zip [0 :: Int ..] outputs]

{- | The request as the model reads it: its edge, key, owner, destination and
approval as identities, its deposit, and its tip, what it holds beyond the
deposit (on chain the processing tip, `held − deposit`). A retraction also names
the output reference the request sits at, the one its return is bound to; no
other exit reads it.
-}
storyModelRequest :: LiveIdentities -> CageConfig -> Live.Exit -> Live.EdgeRequest Addr -> Integer
    -> Integer -> Maybe Integer -> Either (Maybe RegistryEdges.BookingApproval) (TxOut ConwayEra) -> IO Value
storyModelRequest ids cfg exit request deposit tip reference requestOut = do
    let wallet = Live.requestWallet request
        key = TE.encodeUtf8 (T.pack (Live.requestKey request))
    modelKey <- observeIdentity (liveKeys ids) (KeyIdentity key)
    owner <- observeIdentity (liveWallets ids) (WalletIdentity (serialiseAddr genesisAddr))
    destination <- observeIdentity (liveWallets ids) (WalletIdentity (serialiseAddr wallet))
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
    pure $ object $
        [ "edge" .= Live.edgeName (Live.requestEdge request)
        , "key" .= modelKey, "owner" .= owner
        , "refundAddress" .= refundAddress, "deposit" .= deposit
        , "output" .= output, "applicationPolicy" .= application
        , "approval" .= approval, "tip" .= tip
        ]
        <> [ "reference" .= bound | exit == Live.Retract, Just bound <- [reference] ]


-- | Observation only looks up identities allocated while acting. The
-- concrete trie root is checked before its leaves are translated.
observeStep :: Env -> LiveState -> LiveStep -> IO Value
observeStep env state step = case lsOutcome step of
    StepAccepted transaction _ -> do
        control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
        when (control == Just "unknown-identity") $
            () <$ observeIdentity (liveWallets (liveIds state))
                (WalletIdentity (BS.replicate 28 0xAB))
        observeAcceptedStep env state step transaction
    _ -> pure Null


observeAcceptedStep :: Env -> LiveState -> LiveStep -> ConwayTx -> IO Value
observeAcceptedStep env state step transaction = do
    let cage = lsCage step
        cfg = rcCfg cage
        requestedKey = TE.encodeUtf8 (T.pack (Live.requestKey (lsRequest step)))
    after <- maybe (failWith "accepted step has no chain state") pure (lsAfter step)
    tid <- cageTid cage
    let registry = show tid
    keys <- maybe (failWith "registry has no allocated keys") pure
        . Map.lookup registry =<< readIORef (liveRegistryKeys state)
    wallets <- maybe (failWith "registry has no allocated wallets") pure
        . Map.lookup registry =<< readIORef (liveRegistryWallets state)
    (committed, membership) <- withTrie (envTm env) tid $ \trie -> do
        root <- CageTrie.getRoot trie
        values <- mapM (CageTrie.lookup trie) keys
        pure (root, zip keys (map isJust values))
    require "chain root differs from committed trie before observation"
        (unOnChainRoot (stateRoot after) == unRoot committed)
    -- This trie backend's `lookup` reports membership but returns the key's
    -- digest, not the stored leaf. Recover the leaves by rebuilding every
    -- possible assignment over the keys it says are present and matching the
    -- resulting concrete commitment against the chain-read root.
    classified <- classifyLeaves membership (unOnChainRoot (stateRoot after))
    translated <- mapM translateLeaf classified
    let root = Compare.rootOf [(identifier, ordinal) | (identifier, ordinal, _) <- translated]
        trie = [object ["key" .= identifier, "leaf" .= leaf]
               | (identifier, _, leaf) <- translated]
    requestedId <- observeIdentity (liveKeys ids) (KeyIdentity requestedKey)
    let leaf = fromMaybe Null
            (lookup requestedId [(identifier, name) | (identifier, _, name) <- translated])
    (application, active, absent, terminal) <- observePins ids cfg
    let config = abstractConfig after application active absent terminal root
        activeBytes = SBS.fromShort (cfgActivePolicy cfg)
        terminalBytes = SBS.fromShort (cfgTerminalPolicy cfg)
        activePolicy = policyIdFromPin (cfgActivePolicy cfg)
    holdings <- fmap concat $ mapM
        (walletHoldings ids keys [("active", activeBytes), ("terminal", terminalBytes)])
        wallets
    cageOutputs <- Cage.queryUTxOs (envProv env) (cageAddrFromCfg cfg (network cfg))
    custody <- mapM (observeCustody ids cfg) [out
        | (_, out) <- cageOutputs, Just (AbsentCustody _) <- [extractCageDatum out]
        , Map.member (SBS.fromShort (cfgAbsentPolicy cfg)) (outAssets out)]
    let MultiAsset minted = transaction ^. bodyTxL . mintTxBodyL
    mint <- mapM (\(policy, name, quantity) -> observeStepMint ids cfg policy name quantity)
        [ (cg21PolicyBytes policy, SBS.fromShort name, quantity)
        | (policy, names) <- Map.toList minted
        , (AssetName name, quantity) <- Map.toList names ]
    let orderedMint = sortOn mintKindOrder mint
    requestOut <- maybe (failWith "accepted step has no booked request output") pure (lsRequestOut step)
    payments <- observePaid ids wallets cfg step transaction requestOut
    let paid = map snd payments
    -- Only a fold delivers: a reject and a retraction deliver nothing, whatever
    -- edge their request named.
    destination <- case (lsExit step, Live.requestEdge (lsRequest step)) of
        (Live.Fold, Live.InsertActive) -> observedDelivery activePolicy requestedKey wallets
        (Live.Fold, Live.UpdateActive) -> observedDelivery activePolicy requestedKey wallets
        (Live.Fold, Live.WitnessTerminal) -> observedDelivery
            (policyIdFromPin (cfgTerminalPolicy cfg)) requestedKey wallets
        _ -> pure 0
    let owner = object
            [ "config" .= config, "custody" .= custody
            , "held" .= holdings, "trie" .= trie ]
    (_, requestName) <- storyApprovalOn cfg requestOut
    -- The recomputation binds the approval the request carries; with none
    -- there is nothing to bind and the check is not made.
    case requestName of
        Nothing -> pure ()
        Just approval -> do
            (_, recomputed) <- cg21RequestFacts requestOut
            require "request approval disagrees with its chain-read datum" (approval == recomputed)
    ownerId <- observeIdentity (liveWallets ids)
        (WalletIdentity (serialiseAddr genesisAddr))
    commitment <- maybe (failWith "request commitment cannot be derived") pure $
        Compare.approvalAssetName (T.pack (Live.edgeName (Live.requestEdge (lsRequest step))))
            requestedId ownerId destination
    tx <- observedStepTx env ids wallets step transaction config orderedMint destination
        commitment custody paid requestOut tid (map fst payments)
    pure $ object
        [ "config" .= config, "custody" .= custody
        , "held" .= holdings, "leaf" .= leaf, "mint" .= orderedMint
        , "paid" .= paid, "root" .= root
        , "state" .= owner, "tx" .= tx ]
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
        require "accepted edge did not deliver one named token" (delivered == [expectedAsset])
        deliveredWallet <- case [wallet | wallet <- wallets,
                hexT (serialiseAddr wallet) == addressBytes] of
            [wallet] -> pure wallet
            _ -> failWith "delivered token address was not allocated by an action"
        observeIdentity (liveWallets ids) (WalletIdentity (serialiseAddr deliveredWallet))
    translateLeaf (key, value) = do
        identifier <- observeIdentity (liveKeys ids) (KeyIdentity key)
        (ordinal, name) <- if value == leafAbsent then pure (0, String "absent")
            else if value == leafActive then pure (1, String "active")
            else if value == leafTerminal then pure (2, String "terminal")
            else failWith ("unrecognized trie leaf for " <> show key)
        pure (identifier, ordinal, name)
    -- A wallet holds the active and terminal witnesses the folds routed to
    -- it; the absent witness stays in the cage's custody.
    walletHoldings identities keys kinds wallet = do
        utxos <- Cage.queryUTxOs (envProv env) wallet
        addressId <- observeIdentity (liveWallets identities) (WalletIdentity (serialiseAddr wallet))
        fmap concat $ mapM (\key -> do
            keyId <- observeIdentity (liveKeys identities) (KeyIdentity key)
            pure [ object ["key" .= keyId, "kind" .= String kind, "output" .= addressId]
                 | (kind, policyBytes) <- kinds
                 , _ <- [1 .. sum
                    [ q | (_, out) <- utxos
                        , Just names <- [Map.lookup policyBytes (outAssets out)]
                        , Just q <- [Map.lookup key names] ]]
                 ]) keys


classifyLeaves :: [(ByteString, Bool)] -> ByteString -> IO [(ByteString, ByteString)]
classifyLeaves membership observedRoot = do
    let present = [key | (key, True) <- membership]
        assignments = sequence (replicate (length present) [leafAbsent, leafActive, leafTerminal])
    candidates <- mapM (\values -> do
        trie <- mkPureTrie
        mapM_ (\(key, value) -> CageTrie.insert trie key value)
            (zip present values)
        root <- CageTrie.getRoot trie
        pure (zip present values, unRoot root)) assignments
    case [leaves | (leaves, root) <- candidates, root == observedRoot] of
        [leaves] -> pure leaves
        matches -> failWith ("concrete root identifies " <> show (length matches)
            <> " leaf assignments over this registry's allocated keys")


observeCustody :: LiveIdentities -> CageConfig -> TxOut ConwayEra -> IO Value
observeCustody ids cfg out = do
    refund <- case extractCageDatum out of
        Just (AbsentCustody address) -> pure address
        _ -> failWith "custody output has no Absent custody datum"
    let policy = SBS.fromShort (cfgAbsentPolicy cfg)
    (key, quantity) <- case Map.toList (outAssets out) of
        [(actualPolicy, names)] | actualPolicy == policy -> case Map.toList names of
            [(name, count)] -> pure (name, count)
            _ -> failWith "custody output does not hold one named asset"
        _ -> failWith "custody output has assets outside this registry's Absent pin"
    require "custody output does not hold exactly one Absent token" (quantity == 1)
    keyId <- observeIdentity (liveKeys ids) (KeyIdentity key)
    refundId <- observeIdentity (liveWallets ids) (WalletIdentity refund)
    let Coin amount = out ^. coinTxOutL
    pure (object ["key" .= keyId, "refundAddress" .= refundId, "value" .= amount])


-- | The fold's outputs, each beside the reading settlement makes of it: its
-- address, payment key, lovelace, whether it carries a token this fold
-- delivers (a positive active or terminal mint), its datum form, the
-- approvals it holds and whether it is an absent custody at the cage, and the output reference its inline datum presents, if it presents one.
foldOutputsOf :: CageConfig -> ConwayTx -> [(TxOut ConwayEra, Payments.FoldOutput)]
foldOutputsOf cfg transaction =
    [ (out, Payments.FoldOutput
        { Payments.outputAddress = serialiseAddr (out ^. addrTxOutL)
        , Payments.outputKey = addrKeyHashBytes (out ^. addrTxOutL)
        , Payments.outputLovelace = let Coin c = out ^. coinTxOutL in c
        , Payments.outputCarrier = carries out
        , Payments.outputDatum = case out ^. datumTxOutL of
            NoDatum -> "none"
            DatumHash _ -> "hashed"
            Datum _ -> "inline"
        , Payments.outputApprovals =
            [ hexT name
            | (name, quantity) <- Map.toList
                (Map.findWithDefault Map.empty (SBS.fromShort (cfgApplicationPolicy cfg)) (outAssets out))
            , quantity /= 0 ]
        , Payments.outputCustody = out ^. addrTxOutL == cageAddrFromCfg cfg (network cfg)
            && case extractCageDatum out of
                Just (AbsentCustody _) -> True
                _ -> False
        , Payments.outputReference = case out ^. datumTxOutL of
            Datum inline -> let Data plutus = binaryDataToData inline
                in onChainReference <$> fromBuiltinData (BuiltinData plutus)
            _ -> Nothing })
    | out <- toList (transaction ^. bodyTxL . outputsTxBodyL) ]
  where
    MultiAsset minted = transaction ^. bodyTxL . mintTxBodyL
    delivered =
        [ (cg21PolicyBytes policy, SBS.fromShort name)
        | (policy, names) <- Map.toList minted
        , cg21PolicyBytes policy `elem`
            [SBS.fromShort (cfgActivePolicy cfg), SBS.fromShort (cfgTerminalPolicy cfg)]
        , (AssetName name, quantity) <- Map.toList names, quantity > 0 ]
    carries out = or
        [ Map.findWithDefault 0 name (Map.findWithDefault Map.empty policy (outAssets out)) /= 0
        | (policy, name) <- delivered ]


-- | The payments of an accepted fold, read off its transaction by
-- 'Payments.foldPayments', each beside its translation to the identities
-- allocated while acting. A spent custody is read from its own input, which
-- the fold must have spent; the owner is the key the booked request's datum
-- names.
observePaid :: LiveIdentities -> [Addr] -> CageConfig -> LiveStep -> ConwayTx
    -> TxOut ConwayEra -> IO [(Payments.Payment, Value)]
observePaid ids wallets cfg step transaction requestOut = do
    let edge = Live.requestEdge (lsRequest step)
        outputs = foldOutputsOf cfg transaction
    refund <- case (edge, lsCustody step) of
        (e, Just (source, custodyOut)) | e `elem` [Live.UpdateActive, Live.DeleteAbsent] -> do
            require "custody refund did not spend its source"
                (source `Set.member` (transaction ^. bodyTxL . inputsTxBodyL))
            case extractCageDatum custodyOut of
                Just (AbsentCustody address) -> pure (Just address)
                _ -> failWith "paid custody source has no Absent datum"
        _ -> pure Nothing
    owner <- requestOwnerKey requestOut
    payments <- either failWith pure $ Payments.foldPayments
        (Payments.ExitFacts (lsExit step) edge owner refund (txInReference <$> lsRequestIn step))
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
settlementOutputs :: LiveIdentities -> [Addr] -> CageConfig -> LiveStep -> ConwayTx -> IO [Value]
settlementOutputs ids wallets cfg step transaction = do
    requestOut <- maybe (failWith "judged step has no booked request") pure (lsRequestOut step)
    owner <- requestOwnerKey requestOut
    let facts = Payments.ExitFacts (lsExit step) (Live.requestEdge (lsRequest step)) owner Nothing
            (txInReference <$> lsRequestIn step)
        outputs = map snd (foldOutputsOf cfg transaction)
        judged = case lsExit step of
            Live.Retract -> [out | out <- outputs, Payments.creditsOwner owner out]
            _ -> map (outputs !!) (Payments.owedOutputs facts outputs)
    mapM (settlementOutput (Payments.owedPayee facts) owner) judged
  where
    settlementOutput payee owner out = do
        (role, address) <- case payee of
            Payments.OwedCarrier -> (,) ("destination" :: T.Text)
                <$> observeIdentity (liveWallets ids) (WalletIdentity (Payments.outputAddress out))
            Payments.OwedCustody -> pure ("cage", 0)
            Payments.OwedOwner -> (,) "owner" <$> ownerIdentity ids wallets owner
            Payments.OwedBound -> (,) "owner" <$> ownerIdentity ids wallets owner
        reference <- traverse (observeIdentity (liveReferences ids) . ReferenceIdentity)
            (Payments.outputReference out)
        pure (object [ "role" .= role, "address" .= address
                     , "lovelace" .= Payments.outputLovelace out
                     , "datum" .= Payments.outputDatum out, "reference" .= reference ])


-- | The payment key the booked request's datum names as its owner.
requestOwnerKey :: TxOut ConwayEra -> IO ByteString
requestOwnerKey requestOut = case extractCageDatum requestOut of
    Just (RequestDatum rq) -> let BuiltinByteString key = requestOwner rq in pure key
    _ -> failWith "accepted fold's request carries no request datum"


-- | An owner's identity: the one registry wallet whose payment key it is.
ownerIdentity :: LiveIdentities -> [Addr] -> ByteString -> IO Integer
ownerIdentity ids wallets key = case [w | w <- wallets, addrKeyHashBytes w == key] of
    [wallet] -> observeIdentity (liveWallets ids) (WalletIdentity (serialiseAddr wallet))
    _ -> failWith ("request owner " <> hex key <> " is not the key of one wallet of this registry")


-- | The owner outputs of an accepted fold, one per owner payment, read off the
-- ledger outputs the chain credits to the owner's key by
-- 'Payments.readOwner' and put in the model's vocabulary by
-- 'Payments.ownerOutputObservation', whose returned approval is looked up in
-- the approvals the run bound while booking. Their registry tokens and the registry
-- state token they hold are read here, and none may carry a registry state or
-- custody datum. An owner no output credits has no owner output: the
-- transaction then differs from the model's in length.
observeOwnerOutputs :: LiveIdentities -> [Addr] -> CageConfig -> TokenId -> LiveStep -> ConwayTx
    -> [Payments.Payment] -> IO [Value]
observeOwnerOutputs ids wallets cfg tid step transaction payments =
    fmap concat $ mapM ownerOutput
        [ key | Payments.Payment (Payments.Owner key) _ <- payments ]
  where
    outputs = foldOutputsOf cfg transaction
    -- A retraction returns the request through the one output bound to it;
    -- every other exit credits the owner every output at its key.
    bound = case lsExit step of
        Live.Retract -> txInReference <$> lsRequestIn step
        _ -> Nothing
    credits key folded = Payments.creditsOwner key folded
        && maybe True (\reference -> Payments.outputReference folded == Just reference) bound
    ownerOutput key = do
      read' <- either failWith pure $ case bound of
          Just reference -> Payments.readBound key reference (map snd outputs)
          Nothing -> Payments.readOwner key (map snd outputs)
      case read' of
        Nothing -> pure []
        Just reading -> do
            let credited = [out | (out, folded) <- outputs, credits key folded]
            -- The reference each credited output presents, as its datum reads.
            reference <- case nub [r | (_, folded) <- outputs, credits key folded
                                     , Just r <- [Payments.outputReference folded]] of
                [] -> pure Nothing
                [presented] -> Just <$> observeIdentity (liveReferences ids) (ReferenceIdentity presented)
                _ -> failWith "the outputs crediting the owner present several output references"
            address <- ownerIdentity ids wallets key
            require "an output crediting the owner carries a registry state or custody datum"
                (all (isNothing . extractCageDatum) credited)
            let registryPins =
                    [ SBS.fromShort (cfgActivePolicy cfg), SBS.fromShort (cfgAbsentPolicy cfg)
                    , SBS.fromShort (cfgTerminalPolicy cfg) ]
            assets <- mapM (\(policy, name, quantity) -> observeStepMint ids cfg policy name quantity)
                [ (policy, name, quantity)
                | out <- credited
                , (policy, names) <- Map.toList (outAssets out), policy `elem` registryPins
                , (name, quantity) <- Map.toList names ]
            let statePolicy = cg21PolicyBytes (cagePolicyIdFromCfg cfg)
                stateName = SBS.fromShort (assetNameBytes (unTokenId tid))
                stateTokens = sum
                    [ Map.findWithDefault 0 stateName (Map.findWithDefault Map.empty statePolicy (outAssets out))
                    | out <- credited ]
            approvals <- readIORef (liveApprovals ids)
            let approvalOf name = Identity.observe (ApprovalIdentity name) approvals
            either failWith (pure . pure) $ Payments.ownerOutputObservation address approvalOf
                assets stateTokens reference reading


-- | A required signer of the submitted transaction, in the model's vocabulary:
-- the identity of the registry wallet whose payment key it is. A key no wallet
-- of this registry pays to is refused, never given a fresh identity.
observeSigner :: LiveIdentities -> [Addr] -> KeyHash Guard -> IO Integer
observeSigner ids wallets (KeyHash signer) =
    case [wallet | wallet <- wallets, addrKeyHashBytes wallet == hashToBytes signer] of
        [wallet] -> observeIdentity (liveWallets ids) (WalletIdentity (serialiseAddr wallet))
        [] -> failWith ("required signer " <> hex (hashToBytes signer) <> " is no wallet of this registry")
        _ -> failWith ("required signer " <> hex (hashToBytes signer) <> " is the payment key of more than one wallet")


observeStepMint :: LiveIdentities -> CageConfig -> ByteString -> ByteString -> Integer -> IO Value
observeStepMint ids cfg policy key quantity = do
    kind <- case [name | (pin, name) <-
            [(cfgActivePolicy cfg, "active"), (cfgAbsentPolicy cfg, "absent"),
             (cfgTerminalPolicy cfg, "terminal")], SBS.fromShort pin == policy] of
        [name] -> pure (name :: T.Text)
        _ -> failWith "mint names a policy outside the registry's witness pins"
    policyId <- observeIdentity (livePolicies ids) (PolicyIdentity policy)
    keyId <- observeIdentity (liveKeys ids) (KeyIdentity key)
    pure (object ["kind" .= kind, "key" .= keyId, "policy" .= policyId,
        "assetName" .= keyId, "quantity" .= quantity])


observedStepTx :: Env -> LiveIdentities -> [Addr] -> LiveStep -> ConwayTx -> Value -> [Value]
    -> Integer -> Integer -> [Value] -> [Value] -> TxOut ConwayEra -> TokenId
    -> [Payments.Payment] -> IO Value
observedStepTx _env ids wallets step transaction config mint destination commitment custody paid requestOut
        tid payments = do
    let cfg = rcCfg (lsCage step)
        edge = Live.requestEdge (lsRequest step)
        requestKeyBytes = TE.encodeUtf8 (T.pack (Live.requestKey (lsRequest step)))
        actualInputs = transaction ^. bodyTxL . inputsTxBodyL
        outputValues = toList (transaction ^. bodyTxL . outputsTxBodyL)
        stateOutputs = [out | out <- outputValues,
            Just (StateDatum _) <- [extractCageDatum out]]
    -- A retraction spends no state, so it continues none.
    when (lsExit step /= Live.Retract) $
        require "accepted fold has no unique chain state output" (length stateOutputs == 1)
    let witnessInput what source = do
            require (what <> " did not spend its observed active witness")
                (source `Set.member` actualInputs)
            asset <- observeStepMint ids cfg (SBS.fromShort (cfgActivePolicy cfg))
                requestKeyBytes 1
            pure [object ["role" .= String "witness", "datum" .= String "inline",
                "stateToken" .= (0 :: Integer), "approvalQuantity" .= (0 :: Integer),
                "lovelace" .= (0 :: Integer), "assets" .= [asset]]]
    -- A fold alone spends a witness or a custody, or locks one: a reject and a
    -- retraction touch neither, whatever edge their request named.
    let folded = lsExit step == Live.Fold
    witnessInputs <- if not folded then pure [] else case (edge, lsWitness step) of
        (Live.UpdateTerminal, Just (source, _)) -> witnessInput "retirement" source
        (Live.UpdateTerminal, Nothing) -> failWith "retirement has no observed active witness"
        (Live.DeleteActive, Just (source, _)) -> witnessInput "deletion" source
        (Live.DeleteActive, Nothing) -> failWith "deletion has no observed active witness"
        _ -> pure []
    custodyInputs <- if not folded then pure [] else case (edge, lsCustody step) of
        (Live.UpdateActive, Just (source, _)) -> custodyInput source
        (Live.DeleteAbsent, Just (source, _)) -> custodyInput source
        (Live.UpdateActive, Nothing) -> failWith "updateActive has no custody input"
        (Live.DeleteAbsent, Nothing) -> failWith "deleteAbsent has no custody input"
        _ -> pure []
    let positive = [asset | asset@(Object fields) <- mint,
            KM.lookup "kind" fields `elem` [Just (String "active"), Just (String "terminal")],
            case KM.lookup "quantity" fields of Just (Number q) -> q > 0; _ -> False]
        newCustody = [out | out <- outputValues,
            Just (AbsentCustody _) <- [extractCageDatum out]]
    cageOutputs <- if not folded then pure [] else case edge of
        Live.InsertAbsent -> case newCustody of
            [out] -> do
                entry <- observeCustody ids cfg out
                require "new custody was not observed at the cage" (entry `elem` custody)
                keyId <- storyField "key" entry
                refundId <- storyField "refundAddress" entry
                value <- storyField "value" entry
                asset <- observeStepMint ids cfg (SBS.fromShort (cfgAbsentPolicy cfg))
                    requestKeyBytes 1
                require "new custody is for a different key" (keyId ==
                    fromMaybe Null (case lsModelRequest step of
                        Object fields -> KM.lookup "key" fields
                        _ -> Nothing))
                pure [object ["role" .= String "cage", "datum" .= String "inline",
                    "address" .= (0 :: Integer), "stateToken" .= (0 :: Integer),
                    "inlineConfig" .= Null, "commitment" .= Null,
                    "assets" .= [asset], "custodyDatum" .= [refundId],
                    "lovelace" .= value, "reference" .= Null]]
            _ -> failWith "insertAbsent did not create one Absent custody output"
        _ -> pure []
    (requestQuantity, _) <- storyApprovalOn cfg requestOut
    let requestInput = object ["role" .= String "request", "datum" .= String "inline",
            "stateToken" .= (0 :: Integer), "approvalQuantity" .= requestQuantity,
            "lovelace" .= lsRequestLovelace step, "assets" .= ([] :: [Value])]
        stateInput = object ["role" .= String "state", "datum" .= String "inline",
            "stateToken" .= (1 :: Integer), "approvalQuantity" .= (0 :: Integer),
            "lovelace" .= (0 :: Integer), "assets" .= ([] :: [Value])]
        stateOutput = object ["role" .= String "state", "datum" .= String "inline",
            "address" .= Null, "stateToken" .= (1 :: Integer),
            "inlineConfig" .= config, "commitment" .= Null,
            "assets" .= ([] :: [Value]), "custodyDatum" .= Null,
            "lovelace" .= (0 :: Integer), "reference" .= Null]
        destinationOutput = object ["role" .= String "destination", "datum" .= String "inline",
            "address" .= destination, "stateToken" .= (0 :: Integer),
            "inlineConfig" .= Null, "commitment" .= commitment,
            "assets" .= positive, "custodyDatum" .= Null,
            "lovelace" .= sum [value | Payments.Payment (Payments.Destination _) value <- payments]
            , "reference" .= Null]
    signers <- mapM (observeSigner ids wallets)
        (toList (transaction ^. bodyTxL . reqSignerHashesTxBodyL))
    ownerOutputs <- observeOwnerOutputs ids wallets cfg tid step transaction payments
    -- A reject spends and continues the state beside the request and refunds
    -- the owner; a retraction spends the request alone and returns it.
    let (inputs, outputs) = case lsExit step of
            Live.Fold -> ( stateInput : requestInput : custodyInputs <> witnessInputs
                         , stateOutput : destinationOutput : cageOutputs <> ownerOutputs )
            Live.Reject -> ([stateInput, requestInput], stateOutput : ownerOutputs)
            Live.Retract -> ([requestInput], ownerOutputs)
    pure (object ["inputs" .= inputs,
        "outputs" .= outputs,
        "mint" .= mint, "signers" .= sort signers, "refunds" .= paid])
  where
    custodyInput source = do
        require "absent custody was not spent by the accepted fold"
            (source `Set.member` (transaction ^. bodyTxL . inputsTxBodyL))
        let cfg = rcCfg (lsCage step)
            key = TE.encodeUtf8 (T.pack (Live.requestKey (lsRequest step)))
        asset <- observeStepMint ids cfg (SBS.fromShort (cfgAbsentPolicy cfg)) key 1
        pure [object ["role" .= String "cage", "datum" .= String "inline",
            "stateToken" .= (0 :: Integer), "approvalQuantity" .= (0 :: Integer),
            "lovelace" .= (0 :: Integer), "assets" .= [asset]]]


-- | Ask the same driver for every exit. Setup is only the earlier accepted,
-- compared folds of this registry; a tamper never joins it, nor a reject or a
-- retraction, which the model says leave the registry as it was. Given the
-- submitted transaction's inputs and outputs, the driver also judges whether it
-- spends what the exit may and pays what the exit owes.
askModel :: Env -> LiveState -> LiveStep -> Maybe ([Value], [Value]) -> IO Value
askModel _env state step judged = do
    tid <- cageTid (lsCage step)
    let registry = show tid
        ids = liveIds state
    start <- maybe (failWith "model question has no chain-read start") pure
        . Map.lookup registry =<< readIORef (liveStarts state)
    setup <- pure . Map.findWithDefault [] registry =<< readIORef (liveTraces state)
    (application, active, absent, terminal) <- observePins ids (rcCfg (lsCage step))
    let startValue = object
            [ "config" .= abstractConfig start application active absent terminal (Compare.rootOf [])
            , "trie" .= ([] :: [Value]), "custody" .= ([] :: [Value])
            , "held" .= ([] :: [Value]) ]
        question = object $
            [ "id" .= String "live-edge"
            , "theorem" .= String "Singular.Driver.runSurface"
            , "statementSha256" .= String "13086894509481008378"
            , "start" .= startValue, "setup" .= setup
            , "exit" .= Live.exitName (lsExit step) (Live.requestEdge (lsRequest step))
            , "request" .= lsModelRequest step
            , "lovelace" .= lsRequestLovelace step ]
            <> concat [ ["inputs" .= inputs, "outputs" .= outputs] | Just (inputs, outputs) <- [judged] ]
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    let asked = case control of
            Just "wrong-fee" -> bumpEvaluationField "maxFee" question
            Just "wrong-timing" -> bumpEvaluationField "processTime" question
            _ -> question
    evaluator <- requireEnv "CONFORMANCE_MODEL_EVALUATOR"
    LeanOracle.expectedObservation evaluator [] asked >>= either failWith pure


compareStep :: Env -> LiveState -> LiveStep -> Value -> IO Value
compareStep env state step observation = do
    row <- askModel env state step Nothing
    stepTid <- cageTid (lsCage step)
    -- Which of the registry's scripts a refusal names, read off the hashes the
    -- node reported against each script's applied hash.
    let stepCfg = rcCfg (lsCage step)
        attributed hashes = [ name :: T.Text
                            | (name, marker) <- [("state", stateMarkerOf stepCfg), ("request", requestMarkerOf stepCfg stepTid)]
                            , T.pack marker `elem` hashes ]
    lawOutcome <- storyField "outcome" row
    -- The law accepting is not the model accepting the transaction: the
    -- driver then judges the submitted outputs against what the exit owes.
    judged <- traverse judge (judgedTransaction lawOutcome (lsOutcome step))
    (modelOutcome, modelReason) <- either failWith pure (LeanOracle.modelVerdict row judged)
    let model = object ["outcome" .= modelOutcome, "reason" .= modelReason]
        (chainOutcome, chain) = case lsOutcome step of
            StepAccepted transaction _ ->
                (String "accepted", object ["outcome" .= String "accepted", "txid" .= txIdHex transaction])
            StepRefused transaction trace hashes rejection ->
                (String "refused", object
                    [ "outcome" .= String "refused", "txid" .= txIdHex transaction
                    , "refusal" .= withScripts (attributed hashes) (rejectionJson trace hashes rejection) ])
            StepUnsupported _ reason diagnostic ->
                (String "unsupported", object
                    ["outcome" .= String "unsupported", "reason" .= boundedNodeReason maxLiveStepReasonChars reason
                    , "refusal" .= fmap (rejectionJson Nothing []) diagnostic])
    declared <- do
        corpusPath <- requireEnv "CONFORMANCE_DRIVER_CORPUS"
        corpus <- eitherDecodeFileStrict corpusPath >>= either failWith pure
        either failWith pure (Compare.declaredSurface corpus)
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    let presented = case control of
            Just "wrong-delivery" | chainOutcome == String "accepted" -> bumpObservedMint observation
            _ -> observation
    (comparison, compared, unobserved, perturbation, differing) <- case (lsTamper step, modelOutcome, chainOutcome) of
        _ | StepRefused _ _ _ rejection <- lsOutcome step
          , not (null (srBudgetExceeded rejection)) -> pure ("disagrees", [], [], Null, [])
        (_, String "unsupported", _) -> pure ("unsupported" :: T.Text, [], [], Null, [])
        (_, _, String "unsupported") -> pure ("unsupported", [], [], Null, [])
        -- Both refuse. A tampered payment is refused this way, by the ledger
        -- and by the model's judgement of the submitted outputs; the ledger's
        -- reason is not observed (validators compiled without traces), and
        -- the model's is recorded with the step.
        (_, String "refused", String "refused") ->
            pure ("agrees", [], [], Null, [])
        -- The ledger accepts the extra signer. The same comparison every
        -- untampered step gets must then report exactly the difference the
        -- tamper made: that detection is the tamper's agreement. Reporting
        -- none, or another, is a disagreement.
        (Just Live.ExtraSigner, String "accepted", String "accepted") -> do
            expected <- storyField "observations" row
            let differing = case Compare.compareRegistration declared expected presented of
                    Right _ -> []
                    Left differences -> reportedDifferences differences
            pure ( if not (null differing) && differing == tamperDifferences Live.ExtraSigner
                    then "agrees" else "disagrees"
                 , [], [], Null, differing )
        (Just _, _, _) -> pure ("disagrees", [], [], Null, [])
        (Nothing, String "accepted", String "accepted") -> do
            expected <- storyField "observations" row
            agreement <- either (failWith . renderDifferences) pure
                (Compare.compareRegistration declared expected presented)
            (refused, byObservation, exempt) <- either failWith pure
                (Perturbation.checkPerturbations declared expected observation)
            pure ("agrees", Compare.agreementCompared agreement,
                Compare.agreementUnobserved agreement,
                object ["refused" .= refused, "byObservation" .= byObservation, "exempt" .= exempt], [])
        _ -> pure ("disagrees", [], [], Null, [])
    tid <- cageTid (lsCage step)
    let registry = show tid
    registryId <- maybe (failWith "step registry was not allocated") pure
        . Map.lookup registry =<< readIORef (liveRegistryIds state)
    let record = object
            [ "registry" .= registryId
            , "edge" .= Live.edgeName (Live.requestEdge (lsRequest step))
            , "exit" .= exitNamed
            , "request" .= lsModelRequest step
            , "tamper" .= fmap Live.tamperName (lsTamper step)
            , "model" .= model, "chain" .= chain
            , "comparison" .= comparison
            , "compared" .= compared, "unobserved" .= unobserved
            , "perturbation" .= perturbation
            , "differences" .= map differenceJson differing ]
    modifyIORef' (envLiveRecords env) (<> [record])
    let chainDetail = case lsOutcome step of
            StepAccepted transaction _ -> " txid=" <> txIdHex transaction
            StepRefused transaction trace hashes rejection ->
                " txid=" <> txIdHex transaction <> " trace=" <> show trace
                    <> " scriptHashes=" <> show hashes
                    <> rejectionDetail rejection
            StepUnsupported _ reason diagnostic -> " reason=" <> T.unpack (oneLine maxStepLineReasonChars reason)
                <> maybe "" rejectionDetail diagnostic
    emit "step" (exitNamed
        <> " key=" <> show (Live.requestKey (lsRequest step))
        <> " tamper=" <> maybe "none" Live.tamperName (lsTamper step)
        <> " model=" <> show modelOutcome <> " modelReason=" <> show modelReason
        <> " chain=" <> show chainOutcome <> chainDetail
        <> " comparison=" <> T.unpack comparison
        <> concatMap (\(name, path) -> " differs=" <> T.unpack name <> ":" <> renderStepPath path) differing)
    case comparison of
        -- Every fold the ledger accepted moved the chain as the model's request
        -- does, a tampered one included, so later questions start from it. A
        -- reject or a retraction the ledger accepted left the registry as it was.
        "agrees" -> when (chainOutcome == String "accepted" && lsExit step == Live.Fold) $
            modifyIORef' (liveTraces state)
                (Map.insertWith (\new old -> old <> new) registry [lsModelRequest step])
        "unsupported" -> case lsOutcome step of
            StepUnsupported _ reason _ -> emit "gap" (exitNamed
                <> " for " <> Live.requestKey (lsRequest step) <> ": " <> T.unpack (oneLine maxStepLineReasonChars reason))
            _ -> failWith "unsupported comparison lacks an observed reason"
        _ -> failWith ("model and chain disagree for " <> exitNamed
            <> " at " <> Live.requestKey (lsRequest step)
            <> ": model=" <> show modelOutcome <> " chain=" <> show chainOutcome)
    pure record
  where
    exitNamed = Live.exitName (lsExit step) (Live.requestEdge (lsRequest step))
    judge transaction = do
        let ids = liveIds state
        tid <- cageTid (lsCage step)
        wallets <- maybe (failWith "registry has no allocated wallets") pure
            . Map.lookup (show tid) =<< readIORef (liveRegistryWallets state)
        outputs <- settlementOutputs ids wallets (rcCfg (lsCage step)) step transaction
        -- Each input as the judgement reads it: the state tokens it held.
        let inputs = [object ["stateToken" .= held] | held <- lsSpent step]
        askModel env state step (Just (inputs, outputs))


-- | The differences a tamper the ledger accepts must make, and no other: the
-- observation and the path inside it.
tamperDifferences :: Live.Tamper -> [(T.Text, [Perturbation.Step])]
tamperDifferences alteration = case alteration of
    Live.ExtraSigner -> [("tx", [Perturbation.Field "signers"])]
    Live.OtherAddress -> []
    Live.ShortByOne -> []
    Live.OtherReference -> []
    Live.StateSpent -> []


-- | Every path at which a reported difference's two sides differ, down to a
-- leaf or to an array whose length differs. A below-floor lovelace difference
-- is part of the transaction disagreement and remains visible here.
reportedDifferences :: [Compare.Difference] -> [(T.Text, [Perturbation.Step])]
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
    object ["observation" .= name, "path" .= T.pack (drop 1 (renderStepPath path))]


-- | A refusal record beside the names of the registry scripts its hashes are.
withScripts :: [T.Text] -> Value -> Value
withScripts scripts (Object fields) = Object (KM.insert "scripts" (toJSON scripts) fields)
withScripts _ value = value


rejectionJson :: Maybe T.Text -> [T.Text] -> StepRejection -> Value
rejectionJson trace hashes rejection = object
    [ "trace" .= trace
    , "hashes" .= hashes
    , "kind" .= if null (srBudgetExceeded rejection) then ("validator" :: T.Text) else "budget"
    , "rejection" .= srText rejection
    , "budgetPurposes" .= srBudgetExceeded rejection
    , "overDeclaredPurposes" .= exceedsDeclaredUnits (srMeasured rejection) (srDeclared rejection)
    , "declared" .= purposeDeclarationsJson (srMeasured rejection) (srDeclared rejection)
    , "measured" .= purposeMeasurementsJson (srMeasured rejection)
    ]

rejectionDetail :: StepRejection -> String
rejectionDetail rejection =
    " refusalKind=" <> (if null (srBudgetExceeded rejection) then "validator" else "budget")
        <> " budgetPurposes=" <> show (srBudgetExceeded rejection)
        <> " overDeclaredPurposes=" <> show (exceedsDeclaredUnits (srMeasured rejection) (srDeclared rejection))
        <> " nodeRejection=" <> T.unpack (oneLine maxStepLineReasonChars (srText rejection))
        <> " declared=" <> compactJson (purposeDeclarationsJson (srMeasured rejection) (srDeclared rejection))
        <> " measured=" <> compactJson (purposeMeasurementsJson (srMeasured rejection))

purposeMeasurementsJson :: PurposeMeasurements -> Value
purposeMeasurementsJson = Object . KM.fromList . map toPair . Map.toList
  where
    toPair (purpose, measured) = (Key.fromText purpose, measuredJson measured)

purposeDeclarationsJson :: PurposeMeasurements -> PurposeUnits -> Value
purposeDeclarationsJson measured = Object . KM.fromList . map toPair . Map.toList
  where
    toPair (purpose, (mem, cpu)) =
        (Key.fromText purpose, object
            [ "mem" .= mem, "cpu" .= cpu
            , "source" .= case Map.lookup purpose measured of
                Just (Left _) -> ("probe-allowance" :: T.Text)
                _ -> "twice-measured"
            ])

transactionPurposeUnits :: ConwayTx -> PurposeUnits
transactionPurposeUnits tx = case tx ^. witsTxL . rdmrsTxWitsL of
    Redeemers purposes -> Map.fromList
        [ (T.pack (show purpose), (fromIntegral mem, fromIntegral cpu))
        | (purpose, (_, ExUnits mem cpu)) <- Map.toList purposes ]

transactionPurposeHashes :: ConwayTx -> Map.Map TxIn (TxOut ConwayEra) -> Map.Map T.Text T.Text
transactionPurposeHashes tx visible = Map.fromList (spending <> minting)
  where
    spending =
        [ (T.pack (show (ConwaySpending (AsIx ix) :: ConwayPlutusPurpose AsIx ConwayEra)),
           T.pack (hex (scriptHashBytes hash)))
        | (ix, input) <- zip [0..] (Set.toAscList (tx ^. bodyTxL . inputsTxBodyL))
        , Just out <- [Map.lookup input visible]
        , Addr _ (ScriptHashObj hash) _ <- [out ^. addrTxOutL]
        ]
    MultiAsset policies = tx ^. bodyTxL . mintTxBodyL
    minting =
        [ (T.pack (show (ConwayMinting (AsIx ix) :: ConwayPlutusPurpose AsIx ConwayEra)),
           T.pack (hex (scriptHashBytes (policyID policy))))
        | (ix, policy) <- zip [0..] (Map.keys policies)
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
newtype WalletIdentity = WalletIdentity ByteString deriving stock (Show, Eq, Ord)


newtype PolicyIdentity = PolicyIdentity ByteString deriving stock (Show, Eq, Ord)


newtype KeyIdentity = KeyIdentity ByteString deriving stock (Show, Eq, Ord)


-- | A booked approval's asset name, as the hex the chain carries.
newtype ApprovalIdentity = ApprovalIdentity T.Text deriving stock (Show, Eq, Ord)


-- | An output reference, as `txInReference` spells it: the one a request sits
-- at, or the other one a rebound return names.
newtype ReferenceIdentity = ReferenceIdentity T.Text deriving stock (Show, Eq, Ord)


-- | An output reference's spelling, whether read from a ledger input or from an
-- inline datum presenting it: the transaction id in hex, then the index.
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
    }


newLiveIdentities :: IO LiveIdentities
newLiveIdentities = LiveIdentities <$> newIORef Identity.empty <*> newIORef Identity.empty
    <*> newIORef Identity.empty <*> newIORef Identity.empty <*> newIORef Identity.empty


allocateIdentity :: Ord identity => IORef (Identity.Identities identity) -> identity -> IO Integer
allocateIdentity state identity = do
    original <- readIORef state
    let (identifier, updated) = Identity.identify identity original
    writeIORef state updated
    pure identifier


observeIdentity :: Ord identity => IORef (Identity.Identities identity) -> identity -> IO Integer
observeIdentity state identity = readIORef state >>= either failWith pure . Identity.observe identity


prepareRegistrationIdentities :: LiveIdentities -> RowCage -> ByteString -> Addr -> IO ()
prepareRegistrationIdentities ids cage key recipient = do
    let cfg = rcCfg cage
    _ <- allocateIdentity (liveWallets ids) (WalletIdentity (serialiseAddr genesisAddr))
    _ <- allocateIdentity (liveWallets ids) (WalletIdentity (serialiseAddr recipient))
    _ <- allocateIdentity (liveKeys ids) (KeyIdentity key)
    mapM_ (allocateIdentity (livePolicies ids) . PolicyIdentity . SBS.fromShort)
        [cfgApplicationPolicy cfg, cfgActivePolicy cfg, cfgAbsentPolicy cfg, cfgTerminalPolicy cfg]


-- | Bind the approval a booked request carries to its model name, while
-- acting: the model names it by the request's edge, key, owner and
-- destination identities, as the destination commitment does. Observation
-- only looks these bindings up.
bindBookedApproval :: LiveIdentities -> CageConfig -> TxOut ConwayEra -> Value -> IO ()
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
            either failWith (writeIORef (liveApprovals ids))
                (Identity.bind (ApprovalIdentity name) modelName approvals)


observePins :: LiveIdentities -> CageConfig -> IO (Integer, Integer, Integer, Integer)
observePins ids cfg = do
    pins <-
        mapM
            (observeIdentity (livePolicies ids) . PolicyIdentity . SBS.fromShort)
            [cfgApplicationPolicy cfg, cfgActivePolicy cfg, cfgAbsentPolicy cfg, cfgTerminalPolicy cfg]
    case pins of
        [a, b, c, d] -> pure (a, b, c, d)
        _ -> failWith "registry context has an incomplete policy mapping"


-- | A registry configuration in the model's vocabulary, over an abstract root.
abstractConfig :: OnChainTokenState -> Integer -> Integer -> Integer -> Integer -> [Word8] -> Value
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
                    let raised = Object (KM.insert (Key.fromText name) (Number (current + 1)) config)
                     in Object (KM.insert "start" (Object (KM.insert "config" raised start)) fields)
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
                 in Object (KM.insert "mint" (Array (Vector.fromList (raised : rest))) fields)
            _ -> value
        _ -> value
    _ -> value


-- ---------------------------------------------------------
-- CG21 helpers (#184)
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
storyProofs ::
    Env ->
    RowCage ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ([[ProofStep]], Root)
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
storyDelivery ::
    PolicyID -> ByteString -> ConwayTx -> IO (T.Text, [AssetEntry])
storyDelivery policy key tx =
    case [o | o <- toList (tx ^. bodyTxL . outputsTxBodyL), holds o] of
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
  where
    holds o =
        or
            [ SBS.fromShort an == key
            | (p, names) <- Map.toList (rawAssets o)
            , p == policy
            , (AssetName an, _) <- Map.toList names
            ]


-- | The approval the booked request UTxO carries, read off the chain as
-- FR-4 counts it: the total quantity under the application policy, paired
-- with the approval's name when exactly one name is carried at quantity 1.
-- Quantity 0 with no name is a request that carries no approval. Any other
-- shape — a second name, one name at a quantity other than 1, or any asset
-- under a foreign policy — fails the run naming the count found, rather
-- than being described as either shape.
storyApprovalOn :: CageConfig -> TxOut ConwayEra -> IO (Integer, Maybe T.Text)
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
    in case (onApplication, foreignPolicies) of
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
    -- #183: the request states its C2 row itself; there is nothing to
    -- derive. A tag outside the table names no approval binding, so a
    -- row that reads one would be reading a fact that does not exist.
    edgeIx <- do
        let e = requestEdge rq
        if e >= edgeInsertAbsent && e <= edgeWitnessTerminal
            then pure e
            else failWith "CG21: the request names no admissible edge"
    let BuiltinByteString owner = requestOwner rq
        Coin lovelace = out ^. coinTxOutL
    pure
        ( lovelace
        , hexT (approvalName edgeIx (requestKey rq) owner (requestDestination rq))
        )
