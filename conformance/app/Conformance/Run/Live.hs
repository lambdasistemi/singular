{-# LANGUAGE GADTs #-}
{- |
Module      : Conformance.Run.Live
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Live (StepOutcome (..), LiveStep (..), LiveState (..), runLive, submitEdge, storyReferences, storyWitness, containsStoryAsset, storyModelRequest, observeStep, observeAcceptedStep, classifyLeaves, observeCustody, observePaidCustody, observeSigner, observeStepMint, observedStepTx, askModel, compareStep, tamperDifferences, reportedDifferences, differingPaths, renderStepPath, differenceJson, renderDifferences, WalletIdentity (..), PolicyIdentity (..), KeyIdentity (..), LiveIdentities (..), newLiveIdentities, allocateIdentity, observeIdentity, prepareRegistrationIdentities, observePins, abstractConfig, bumpEvaluationField, bumpObservedMint, hexT, cg21PolicyBytes, readRegistryState, storyProofs, storyRefusalTag, storyDelivery, storyApprovalOn, cg21RequestFacts) where

import Conformance.Run.Control
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
import Conformance.Lean.Oracle qualified as LeanOracle
import Conformance.Story.Binding qualified as Binding
import Control.Exception (
    ErrorCall (..),
    SomeException,
    displayException,
    throwIO,
    try,
 )
import Control.Monad (when)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson (
    eitherDecodeFileStrict,
    Value (..),
    encode,
    object,
    (.=),
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, nub, sort, sortOn, stripPrefix)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import Data.Word (Word8)
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (%~), (.~), (^.))
import System.Environment (lookupEnv)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (
    Addr (..),
    serialiseAddr,
 )

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    addrTxOutL,
    coinTxOutL,
 )
import Cardano.Ledger.Core (KeyHash)
import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value (MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..), txInToText)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
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
    policyIdFromPin,
    currentPosixMs,
    extractCageDatum,
    requestAddrFromCfg,
    scriptHashBytes,
    trySlots,
 )
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
    ProofStep (..),
    RequestAction (Update),
 )
import Cardano.Node.Client.E2E.Setup (addKeyWitness)
import Cardano.Node.Client.Submitter (SubmitResult (..))
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Conformance.Mirror (
    emit,
    failWith,
    hex,
    require,
    txIdHex,
 )
import Conformance.Receipt (AssetEntry (..))
import Conformance.Refusal (
    matchRefusal,
    refusalScriptHashes,
 )

-- The live interpreter's handles contain values observed during this run.
-- They cannot be constructed by a story or supplied by a JSON fixture.
data StepOutcome
    = StepAccepted ConwayTx (Integer, Integer, Integer)
    | StepRefused ConwayTx (Maybe T.Text) [T.Text]
    | StepUnsupported T.Text


data LiveStep = LiveStep
    { lsCage :: RowCage
    , lsRequest :: Live.EdgeRequest Addr
    , lsTamper :: Maybe Live.Tamper
    , lsRequestOut :: Maybe (TxOut ConwayEra)
    , lsModelRequest :: Value
    , lsRequestLovelace :: Integer
    , lsAfter :: Maybe OnChainTokenState
    , lsWitness :: Maybe (TxIn, TxOut ConwayEra)
    , lsCustody :: Maybe (TxIn, TxOut ConwayEra)
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
        Live.Submit registry request -> do
            step <- submitEdge env state registry Nothing request
            modifyIORef' (livePendingComparisons state) (+ 1)
            pure step
        Live.Tamper alteration registry request -> do
            step <- submitEdge env state registry (Just alteration) request
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
-- outref, so a refused request left at the script cannot leak into a fold.
submitEdge :: Env -> LiveState -> RowCage -> Maybe Live.Tamper -> Live.EdgeRequest Addr -> IO LiveStep
submitEdge env state cage alteration request = do
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
                modelRequest <- storyModelRequest ids cfg request cgDeposit (Left decided)
                pure (LiveStep cage request alteration Nothing modelRequest 0 Nothing Nothing Nothing
                    (StepUnsupported (T.pack nodeReason)))
            Nothing -> throwIO failure
        Right named@(reqIn, reqOut) -> do
            let Coin bond = reqOut ^. coinTxOutL
                deposit = bond - stateMaxFee before
            require "booked request holds less than the on-chain processing tip" (deposit >= 0)
            modelRequest <- storyModelRequest ids cfg request deposit (Right reqOut)
            alternate <- case alteration of
                Nothing -> pure Nothing
                Just Live.RedirectDelivery -> Just <$> (if wallet == genesisAddr
                    then snd <$> secondWallet env else pure genesisAddr)
                Just Live.ExtraSigner -> pure Nothing
            witness <- storyWitness env cfg key wallet
            stateUtxo <- cageStateUtxo env cage
            (proofs, root) <- storyProofs env cage tid [named]
            units <- declaredSpec env cage
            (pot, funder) <- collateralPotWithChange env
            let spec = (rowSpec cage tid stateUtxo [named] (map Update proofs) root units)
                    { fsCollateral = Just pot
                    -- The model requires no signer. The extra-signer tamper adds
                    -- the key this process already signs every fold with, so the
                    -- ledger has its witness and judges the signer alone.
                    , fsSigners = Just [addrWitnessKeyHash (addrKeyHashBytes genesisAddr)
                        | alteration == Just Live.ExtraSigner]
                    , fsHolderUtxos = maybe [] pure witness, fsFunder = Just funder
                    , fsOmitUnfundedBurn = Live.requestEdge request == Live.UpdateTerminal
                        && isNothing witness }
            trial <- assembleFoldWithFee env spec
            measured <- try @SomeException (measureUnits env trial)
            -- Evaluation can consume the entire short validity interval on a busy
            -- node. Assemble the same one-request shape again immediately before
            -- submission; its fresh upper bound cannot age during measurement.
            now <- currentPosixMs
            upper <- trySlots (envProv env) [now + 8_000, now + 7_500, now + 7_000]
            unsigned <- assembleFoldWithFee env spec{fsUpper = Just upper}
            let allInputs = Set.toList (unsigned ^. bodyTxL . inputsTxBodyL)
            pending <- pendingRequests env cage
            require "generic step spent another pending request"
                (filter (`elem` map fst pending) allInputs == [reqIn])
            let wanted = Set.insert pot (unsigned ^. bodyTxL . inputsTxBodyL)
            visible <- fmap Map.fromList $ fmap concat $ mapM (Cage.queryUTxOs (envProv env))
                [genesisAddr, wallet, requestAddrFromCfg cfg tid (network cfg),
                 cageAddrFromCfg cfg (network cfg)]
            emit "step-inputs" ("request=" <> T.unpack (txInToText reqIn)
                <> " collateral=" <> T.unpack (txInToText pot)
                <> " funder=" <> T.unpack (txInToText (fst funder))
                <> " visible=" <> show (map txInToText (Map.keys visible)))
            require "generic fold has an input missing from the chain snapshot"
                (all (`Map.member` visible) (Set.toList wanted))
            let candidate = case alternate of
                    Nothing -> unsigned
                    Just redirectTo -> unsigned & bodyTxL . outputsTxBodyL %~ fmap
                        (\out -> if containsStoryAsset cfg key out
                            then out & addrTxOutL .~ redirectTo
                            else out)
                signed = addKeyWitness genesisSignKey candidate
            result <- submitTxResilient (envSubmit env) signed
            case result of
                Submitted _ -> do
                    case alteration of
                        Just Live.RedirectDelivery -> failWith
                            ("redirect-delivery FINDING: chain accepted tampered "
                                <> Live.edgeName (Live.requestEdge request)
                                <> " for " <> Live.requestKey request <> " (" <> txIdHex signed <> ")")
                        Just Live.ExtraSigner -> pure ()
                        Nothing -> pure ()
                    awaitTx signed
                    rowCommit env cage key edge
                    after <- readRegistryState env cage
                    (mem, cpu) <- either (failWith . displayException) pure measured
                    modifyIORef' (envLiveMeasurements env) (<> [(mem, cpu, txSizeBytes signed)])
                    pure (LiveStep cage request alteration (Just reqOut) modelRequest bond
                        (Just after) witness (listToMaybe refs)
                        (StepAccepted signed (mem, cpu, txSizeBytes signed)))
                Rejected reason -> do
                    let explanation = T.unpack (TE.decodeUtf8Lenient reason)
                        marker = stateMarkerOf cfg
                    pure (LiveStep cage request alteration (Just reqOut) modelRequest bond Nothing witness
                        (listToMaybe refs)
                        (case matchRefusal marker explanation of
                            Right () -> StepRefused signed (storyRefusalTag explanation)
                                (map T.pack (refusalScriptHashes explanation))
                            Left _ -> StepUnsupported (T.pack ("unattributed node rejection: " <> explanation))))


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


containsStoryAsset :: CageConfig -> ByteString -> TxOut ConwayEra -> Bool
containsStoryAsset cfg key out =
    any (\policy -> maybe False (Map.member key) (Map.lookup policy (outAssets out)))
        (map SBS.fromShort [cfgActivePolicy cfg, cfgAbsentPolicy cfg, cfgTerminalPolicy cfg])


storyModelRequest :: LiveIdentities -> CageConfig -> Live.EdgeRequest Addr -> Integer
    -> Either (Maybe RegistryEdges.BookingApproval) (TxOut ConwayEra) -> IO Value
storyModelRequest ids cfg request deposit requestOut = do
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
    pure $ object
        [ "edge" .= Live.edgeName (Live.requestEdge request)
        , "key" .= modelKey, "owner" .= owner
        , "refundAddress" .= refundAddress, "deposit" .= deposit
        , "output" .= output, "applicationPolicy" .= application
        , "approval" .= approval
        ]


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
    paid <- case (Live.requestEdge (lsRequest step), lsCustody step) of
        (Live.UpdateActive, Just source) -> observePaidCustody ids transaction source
        (Live.DeleteAbsent, Just source) -> observePaidCustody ids transaction source
        (Live.UpdateActive, Nothing) -> failWith "updateActive has no observed custody source"
        (Live.DeleteAbsent, Nothing) -> failWith "deleteAbsent has no observed custody source"
        _ -> pure []
    destination <- case Live.requestEdge (lsRequest step) of
        Live.InsertActive -> observedDelivery activePolicy requestedKey wallets
        Live.UpdateActive -> observedDelivery activePolicy requestedKey wallets
        Live.WitnessTerminal -> observedDelivery
            (policyIdFromPin (cfgTerminalPolicy cfg)) requestedKey wallets
        _ -> pure 0
    let owner = object
            [ "config" .= config, "custody" .= custody
            , "held" .= holdings, "trie" .= trie ]
    requestOut <- maybe (failWith "accepted step has no booked request output") pure (lsRequestOut step)
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
        commitment custody paid requestOut
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


-- | Refunds are observed from the custody input and the accepted transaction.
-- The address and value must occur together in one actual ada-only output.
observePaidCustody :: LiveIdentities -> ConwayTx -> (TxIn, TxOut ConwayEra) -> IO [Value]
observePaidCustody ids transaction (source, custodyOut) = do
    require "custody refund did not spend its source"
        (source `Set.member` (transaction ^. bodyTxL . inputsTxBodyL))
    refund <- case extractCageDatum custodyOut of
        Just (AbsentCustody address) -> pure address
        _ -> failWith "paid custody source has no Absent datum"
    let Coin amount = custodyOut ^. coinTxOutL
        matching = [out | out <- toList (transaction ^. bodyTxL . outputsTxBodyL)
            , serialiseAddr (out ^. addrTxOutL) == refund
            , out ^. coinTxOutL == Coin amount
            , Map.null (outAssets out)]
    require "custody refund has no matching chain output" (length matching == 1)
    recipient <- observeIdentity (liveWallets ids) (WalletIdentity refund)
    pure [object ["address" .= recipient, "value" .= amount]]


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
    -> Integer -> Integer -> [Value] -> [Value] -> TxOut ConwayEra -> IO Value
observedStepTx _env ids wallets step transaction config mint destination commitment custody paid requestOut = do
    let cfg = rcCfg (lsCage step)
        edge = Live.requestEdge (lsRequest step)
        requestKeyBytes = TE.encodeUtf8 (T.pack (Live.requestKey (lsRequest step)))
        actualInputs = transaction ^. bodyTxL . inputsTxBodyL
        outputValues = toList (transaction ^. bodyTxL . outputsTxBodyL)
        stateOutputs = [out | out <- outputValues,
            Just (StateDatum _) <- [extractCageDatum out]]
    require "accepted fold has no unique chain state output" (length stateOutputs == 1)
    let witnessInput what source = do
            require (what <> " did not spend its observed active witness")
                (source `Set.member` actualInputs)
            asset <- observeStepMint ids cfg (SBS.fromShort (cfgActivePolicy cfg))
                requestKeyBytes 1
            pure [object ["role" .= String "witness", "datum" .= String "inline",
                "stateToken" .= (0 :: Integer), "approvalQuantity" .= (0 :: Integer),
                "lovelace" .= (0 :: Integer), "assets" .= [asset]]]
    witnessInputs <- case (edge, lsWitness step) of
        (Live.UpdateTerminal, Just (source, _)) -> witnessInput "retirement" source
        (Live.UpdateTerminal, Nothing) -> failWith "retirement has no observed active witness"
        (Live.DeleteActive, Just (source, _)) -> witnessInput "deletion" source
        (Live.DeleteActive, Nothing) -> failWith "deletion has no observed active witness"
        _ -> pure []
    custodyInputs <- case (edge, lsCustody step) of
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
    cageOutputs <- case edge of
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
                    "lovelace" .= value]]
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
            "lovelace" .= (0 :: Integer)]
        destinationOutput = object ["role" .= String "destination", "datum" .= String "inline",
            "address" .= destination, "stateToken" .= (0 :: Integer),
            "inlineConfig" .= Null, "commitment" .= commitment,
            "assets" .= positive, "custodyDatum" .= Null,
            "lovelace" .= (0 :: Integer)]
    signers <- mapM (observeSigner ids wallets)
        (toList (transaction ^. bodyTxL . reqSignerHashesTxBodyL))
    pure (object ["inputs" .= (stateInput : requestInput : custodyInputs <> witnessInputs),
        "outputs" .= (stateOutput : destinationOutput : cageOutputs),
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


-- | Ask the same driver for every edge. Setup is only the earlier accepted,
-- compared requests of this registry; a tamper never joins it.
askModel :: Env -> LiveState -> LiveStep -> IO Value
askModel _env state step = do
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
        question = object
            [ "id" .= String "live-edge"
            , "theorem" .= String "Singular.Driver.runSurface"
            , "statementSha256" .= String "17057847551091892576"
            , "start" .= startValue, "setup" .= setup
            , "request" .= lsModelRequest step
            , "lovelace" .= lsRequestLovelace step ]
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    let asked = case control of
            Just "wrong-fee" -> bumpEvaluationField "maxFee" question
            Just "wrong-timing" -> bumpEvaluationField "processTime" question
            _ -> question
    evaluator <- requireEnv "CONFORMANCE_MODEL_EVALUATOR"
    LeanOracle.expectedObservation evaluator [] asked >>= either failWith pure


compareStep :: Env -> LiveState -> LiveStep -> Value -> IO Value
compareStep env state step observation = do
    row <- askModel env state step
    modelOutcome <- storyField "outcome" row
    modelReason <- storyField "reason" row
    let model = object ["outcome" .= modelOutcome, "reason" .= modelReason]
        (chainOutcome, chain) = case lsOutcome step of
            StepAccepted transaction _ ->
                (String "accepted", object ["outcome" .= String "accepted", "txid" .= txIdHex transaction])
            StepRefused transaction trace hashes ->
                (String "refused", object
                    [ "outcome" .= String "refused", "txid" .= txIdHex transaction
                    , "refusal" .= object ["trace" .= trace, "hashes" .= hashes] ])
            StepUnsupported reason ->
                (String "unsupported", object ["outcome" .= String "unsupported", "reason" .= reason])
    declared <- do
        corpusPath <- requireEnv "CONFORMANCE_DRIVER_CORPUS"
        corpus <- eitherDecodeFileStrict corpusPath >>= either failWith pure
        either failWith pure (Compare.declaredSurface corpus)
    control <- lookupEnv "CONFORMANCE_STORY_CONTROL"
    let presented = case control of
            Just "wrong-delivery" | chainOutcome == String "accepted" -> bumpObservedMint observation
            _ -> observation
    (comparison, compared, unobserved, perturbation, differing) <- case (lsTamper step, modelOutcome, chainOutcome) of
        (_, String "unsupported", _) -> pure ("unsupported" :: T.Text, [], [], Null, [])
        (_, _, String "unsupported") -> pure ("unsupported", [], [], Null, [])
        (Just Live.RedirectDelivery, String "accepted", String "refused") ->
            pure ("agrees", [], [], Null, [])
        -- The ledger accepts the extra signer. The same comparison every
        -- untampered step gets must then report exactly the difference the
        -- tamper made: that detection is the tamper's agreement, as the
        -- ledger's refusal is the redirected delivery's. Reporting none, or
        -- another, is a disagreement.
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
        (Nothing, expectedClass, actualClass)
            | expectedClass == actualClass -> pure ("agrees", [], [], Null, [])
            | otherwise -> pure ("disagrees", [], [], Null, [])
    tid <- cageTid (lsCage step)
    let registry = show tid
    registryId <- maybe (failWith "step registry was not allocated") pure
        . Map.lookup registry =<< readIORef (liveRegistryIds state)
    let record = object
            [ "registry" .= registryId
            , "edge" .= Live.edgeName (Live.requestEdge (lsRequest step))
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
            StepRefused transaction trace hashes ->
                " txid=" <> txIdHex transaction <> " trace=" <> show trace
                    <> " scriptHashes=" <> show hashes
            StepUnsupported reason -> " reason=" <> T.unpack reason
    emit "step" (Live.edgeName (Live.requestEdge (lsRequest step))
        <> " key=" <> show (Live.requestKey (lsRequest step))
        <> " tamper=" <> maybe "none" Live.tamperName (lsTamper step)
        <> " model=" <> show modelOutcome <> " modelReason=" <> show modelReason
        <> " chain=" <> show chainOutcome <> chainDetail
        <> " comparison=" <> T.unpack comparison
        <> concatMap (\(name, path) -> " differs=" <> T.unpack name <> ":" <> renderStepPath path) differing)
    case comparison of
        -- Every fold the ledger accepted moved the chain as the model's request
        -- does, a tampered one included, so later questions start from it.
        "agrees" -> when (chainOutcome == String "accepted") $
            modifyIORef' (liveTraces state)
                (Map.insertWith (\new old -> old <> new) registry [lsModelRequest step])
        "unsupported" -> case lsOutcome step of
            StepUnsupported reason -> emit "gap" (Live.edgeName (Live.requestEdge (lsRequest step))
                <> " for " <> Live.requestKey (lsRequest step) <> ": " <> T.unpack reason)
            _ -> failWith "unsupported comparison lacks an observed reason"
        _ -> failWith ("model and chain disagree for " <> Live.edgeName (Live.requestEdge (lsRequest step))
            <> " at " <> Live.requestKey (lsRequest step)
            <> ": model=" <> show modelOutcome <> " chain=" <> show chainOutcome)
    pure record


-- | The differences a tamper the ledger accepts must make, and no other: the
-- observation and the path inside it.
tamperDifferences :: Live.Tamper -> [(T.Text, [Perturbation.Step])]
tamperDifferences alteration = case alteration of
    Live.ExtraSigner -> [("tx", [Perturbation.Field "signers"])]
    Live.RedirectDelivery -> []


-- | Every path at which a reported difference's two sides differ, down to a
-- leaf or to an array whose length differs. Output minimum ada is left out:
-- the comparison already removes it and it never counts as a difference.
reportedDifferences :: [Compare.Difference] -> [(T.Text, [Perturbation.Step])]
reportedDifferences differences =
    [ (name, path)
    | difference <- differences
    , let name = Compare.differenceObservation difference
    , path <- differingPaths (Compare.differenceExpected difference)
        (Compare.differenceObserved difference)
    , not (Perturbation.isOutputMinimumAda name path)
    ]


differingPaths :: Value -> Value -> [[Perturbation.Step]]
differingPaths left right
    | left == right = []
    | otherwise = case (left, right) of
        (Object l, Object r) ->
            [ Perturbation.Field (Key.toText name) : rest
            | name <- nub (KM.keys l <> KM.keys r)
            , rest <- case (KM.lookup name l, KM.lookup name r) of
                (Just a, Just b) -> differingPaths a b
                _ -> [[]]
            ]
        (Array l, Array r)
            | length l == length r ->
                [ Perturbation.Index index : rest
                | (index, a, b) <- zip3 [0 ..] (toList l) (toList r)
                , rest <- differingPaths a b
                ]
        _ -> [[]]


renderStepPath :: [Perturbation.Step] -> String
renderStepPath = concatMap render
  where
    render (Perturbation.Field name) = "." <> T.unpack name
    render (Perturbation.Index index) = "[" <> show index <> "]"


differenceJson :: (T.Text, [Perturbation.Step]) -> Value
differenceJson (name, path) =
    object ["observation" .= name, "path" .= T.pack (drop 1 (renderStepPath path))]


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


data LiveIdentities = LiveIdentities
    { liveWallets :: IORef (Identity.Identities WalletIdentity)
    , livePolicies :: IORef (Identity.Identities PolicyIdentity)
    , liveKeys :: IORef (Identity.Identities KeyIdentity)
    }


newLiveIdentities :: IO LiveIdentities
newLiveIdentities = LiveIdentities <$> newIORef Identity.empty <*> newIORef Identity.empty <*> newIORef Identity.empty


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
storyRefusalTag :: String -> Maybe T.Text
storyRefusalTag text =
    case [n | n <- ["key-exists", "not-booked", "key-unknown"], n `isInfixOf` text] of
        (n : _) -> Just (T.pack n)
        [] -> Nothing


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
