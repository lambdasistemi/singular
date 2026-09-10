{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.MPFS.Cage.E2E.CageSpec
Description : E2E tests for the full cage protocol
License     : Apache-2.0
-}
module Cardano.MPFS.Cage.E2E.CageSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Lens.Micro ((&), (.~), (^.))
import System.Environment (lookupEnv)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldSatisfy,
 )

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    mkBasicTx,
    txIdTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    mintTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    coinTxOutL,
    mkBasicTxOut,
 )
import Cardano.Ledger.BaseTypes (
    Inject (..),
    Network (..),
    TxIx (..),
 )
import Cardano.Ledger.Mary.Value (
    MultiAsset (..),
 )
import Cardano.Ledger.TxIn (TxIn (..))

import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)

import Cardano.MPFS.Cage.Blueprint (
    applyPreviousPolicies,
    extractCompiledCode,
    loadBlueprint,
 )
import Cardano.MPFS.Cage.Config (
    CageConfig (..),
 )
import Cardano.MPFS.Cage.Ledger (
    Coin (..),
    ConwayEra,
    TokenId (..),
 )
import Cardano.MPFS.Cage.Provider qualified as Cage
import Cardano.MPFS.Cage.Trie (TrieManager (..))
import Cardano.MPFS.Cage.Trie.PureManager (
    mkPureTrieManager,
 )
import Cardano.MPFS.Cage.TxBuilder.Boot (
    bootTokenImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.End (
    endTokenImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    findStateUtxo,
    findUtxoByTxIn,
    requestAddrFromCfg,
    txInToRef,
 )
import Cardano.MPFS.Cage.TxBuilder.Reject (
    rejectRequestsImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.Request (
    requestInsertImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.Retract (
    retractRequestImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.Sweep (
    sweepUtxoImpl,
 )
import Cardano.MPFS.Cage.TxBuilder.Update (
    updateTokenImpl,
 )
import Cardano.MPFS.Cage.Types (OnChainTxOutRef)
import Cardano.Node.Client.E2E.Devnet (
    withCardanoNode,
 )
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
    genesisAddr,
    genesisDir,
    genesisSignKey,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (
    mkN2CProvider,
 )
import Cardano.Node.Client.N2C.Submitter (
    mkN2CSubmitter,
 )
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Tx.Balance (
    BalanceResult (balancedTx),
    balanceTx,
 )
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Ouroboros.Network.Magic (NetworkMagic (..))

-- | Uninhabited query context for registration programs.
data NoCtx a

{- | Full cage protocol E2E test spec.
Skips when @MPFS_BLUEPRINT@ is not set.
-}
spec :: Spec
spec = describe "Cage E2E" $ do
    mPath <-
        runIO $ lookupEnv "MPFS_BLUEPRINT"
    case mPath of
        Nothing ->
            it
                "skipped (MPFS_BLUEPRINT \
                \not set)"
                (pure () :: IO ())
        Just path -> do
            ebp <-
                runIO $ loadBlueprint path
            case ebp of
                Left err ->
                    it
                        ( "blueprint error: "
                            <> err
                        )
                        (expectationFailure err)
                Right bp ->
                    case ( extractCompiledCode
                            "state.state"
                            bp
                         , extractCompiledCode
                            "request.request"
                            bp
                         , extractCompiledCode
                            "staking.staking"
                            bp
                         ) of
                        (Just stateBytes, Just requestBytes, mStakingBytes) ->
                            cageFlowSpec stateBytes requestBytes mStakingBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure
                                    "state or request script not \
                                    \found in blueprint"

-- ---------------------------------------------------------
-- Test implementation
-- ---------------------------------------------------------

-- | Full cage E2E coverage.
cageFlowSpec ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Maybe SBS.ShortByteString ->
    Spec
cageFlowSpec stateBytes requestBytes mStakingBytes = do
    it "boots state and applies a request update"
        $ withBootedCage
            id
            stateBytes
            requestBytes
        $ \cfg prov submit tm tokenId -> do
            let requestAddr =
                    requestAddrFromCfg
                        cfg
                        tokenId
                        Testnet

            _ <-
                submitInsertRequest
                    cfg
                    prov
                    submit
                    tokenId
                    "hello"
                    "world"
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            unsignedUpdate <-
                updateTokenImpl
                    cfg
                    prov
                    tm
                    tokenId
                    genesisAddr
            _ <- submitWithGenesis submit unsignedUpdate

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

    it "retracts a phase-2 request"
        $ withBootedCage
            fastRetractCfg
            stateBytes
            requestBytes
        $ \cfg prov submit _tm tokenId -> do
            let requestAddr =
                    requestAddrFromCfg
                        cfg
                        tokenId
                        Testnet
            reqTxIn <-
                submitInsertRequest
                    cfg
                    prov
                    submit
                    tokenId
                    "bye"
                    "moon"
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            threadDelay 3_000_000

            unsignedRetract <-
                retractRequestImpl
                    cfg
                    prov
                    tokenId
                    reqTxIn
                    genesisAddr
            _ <- submitWithGenesis submit unsignedRetract

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

    it "rejects a phase-3 request"
        $ withBootedCage
            fastRejectCfg
            stateBytes
            requestBytes
        $ \cfg prov submit _tm tokenId -> do
            let requestAddr =
                    requestAddrFromCfg
                        cfg
                        tokenId
                        Testnet
            _ <-
                submitInsertRequest
                    cfg
                    prov
                    submit
                    tokenId
                    "stale"
                    "value"
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            threadDelay 3_000_000

            unsignedReject <-
                rejectRequestsImpl
                    cfg
                    prov
                    tokenId
                    genesisAddr
            _ <- submitWithGenesis submit unsignedReject

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

    it "ends a cage by burning the state token"
        $ withBootedCage
            id
            stateBytes
            requestBytes
        $ \cfg prov submit _tm tokenId -> do
            let stateAddr =
                    cageAddrFromCfg cfg Testnet
                policyId =
                    cagePolicyIdFromCfg cfg
            stateUtxosBefore <-
                Cage.queryUTxOs prov stateAddr
            findStateUtxo
                policyId
                tokenId
                stateUtxosBefore
                `shouldSatisfy` isJust

            unsignedEnd <-
                endTokenImpl
                    cfg
                    prov
                    tokenId
                    genesisAddr
            _ <- submitWithGenesis submit unsignedEnd

            stateUtxosAfter <-
                Cage.queryUTxOs prov stateAddr
            findStateUtxo
                policyId
                tokenId
                stateUtxosAfter
                `shouldSatisfy` isNothing

    it "sweeps malformed request-address UTxOs"
        $ withBootedCage
            id
            stateBytes
            requestBytes
        $ \cfg prov submit _tm tokenId -> do
            let requestAddr =
                    requestAddrFromCfg
                        cfg
                        tokenId
                        Testnet

            garbageIn <-
                submitMalformedRequestUtxo
                    cfg
                    prov
                    submit
                    tokenId
                    genesisAddr
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            findUtxoByTxIn
                garbageIn
                reqUtxosBefore
                `shouldSatisfy` isJust

            unsignedSweep <-
                sweepUtxoImpl
                    cfg
                    prov
                    tokenId
                    garbageIn
                    genesisAddr
            _ <- submitWithGenesis submit unsignedSweep

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            findUtxoByTxIn
                garbageIn
                reqUtxosAfter
                `shouldSatisfy` isNothing

    case mStakingBytes of
        Nothing ->
            it
                "skipped (staking.staking not \
                \in blueprint)"
                (pure () :: IO ())
        Just stakingBytes ->
            let stakeHash = computeScriptHash stakingBytes
             in it "Modify and End succeed with staking-script withdrawal"
                    $ withBootedCage
                        ( \cfg0 ->
                            cfg0
                                { cfgStakeScript =
                                    Just (stakingBytes, stakeHash)
                                }
                        )
                        stateBytes
                        requestBytes
                    $ \cfg prov submit tm tokenId -> do
                        registerStakingCredential
                            stakeHash
                            cfg
                            prov
                            submit
                        _ <-
                            submitInsertRequest
                                cfg
                                prov
                                submit
                                tokenId
                                "stake-key"
                                "stake-value"
                        let reqAddr =
                                requestAddrFromCfg cfg tokenId Testnet
                        reqsBefore <-
                            Cage.queryUTxOs prov reqAddr
                        length reqsBefore `shouldSatisfy` (> 0)
                        unsignedUpdate <-
                            updateTokenImpl
                                cfg
                                prov
                                tm
                                tokenId
                                genesisAddr
                        _ <- submitWithGenesis submit unsignedUpdate
                        reqsAfter <-
                            Cage.queryUTxOs prov reqAddr
                        length reqsAfter
                            `shouldSatisfy` (< length reqsBefore)
                        let policyId = cagePolicyIdFromCfg cfg
                            stateAddr = cageAddrFromCfg cfg Testnet
                        unsignedEnd <-
                            endTokenImpl
                                cfg
                                prov
                                tokenId
                                genesisAddr
                        _ <- submitWithGenesis submit unsignedEnd
                        stateUtxosAfter <-
                            Cage.queryUTxOs prov stateAddr
                        findStateUtxo
                            policyId
                            tokenId
                            stateUtxosAfter
                            `shouldSatisfy` isNothing

withBootedCage ::
    (CageConfig -> CageConfig) ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    ( CageConfig ->
      Cage.Provider IO ->
      Submitter IO ->
      TrieManager IO ->
      TokenId ->
      IO a
    ) ->
    IO a
withBootedCage adjustCfg stateBytes requestBytes action =
    withE2E stateBytes requestBytes $
        \cfg0 prov submit tm -> do
            let cfg = adjustCfg cfg0
            tokenId <- bootCage cfg prov submit tm
            action cfg prov submit tm tokenId

bootCage ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    IO TokenId
bootCage cfg prov submit tm = do
    let stateAddr =
            cageAddrFromCfg cfg Testnet
    unsignedBoot <-
        bootTokenImpl
            cfg
            prov
            genesisAddr
    signedBoot <- submitWithGenesis submit unsignedBoot
    let tokenId =
            extractTokenId cfg signedBoot
    createTrie tm tokenId
    stateUtxos <-
        Cage.queryUTxOs prov stateAddr
    stateUtxos
        `shouldSatisfy` (not . null)
    pure tokenId

submitInsertRequest ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    ByteString ->
    ByteString ->
    IO TxIn
submitInsertRequest cfg prov submit tokenId key value = do
    unsignedReq <-
        requestInsertImpl
            cfg
            prov
            (Coin 1_000_000)
            tokenId
            key
            value
            genesisAddr
    signedReq <- submitWithGenesis submit unsignedReq
    pure $
        TxIn
            (txIdTx signedReq)
            (TxIx 0)

submitMalformedRequestUtxo ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    Addr ->
    IO TxIn
submitMalformedRequestUtxo cfg prov submit tokenId addr = do
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov addr
    feeUtxo <-
        largestUtxo
            "submitMalformedRequestUtxo"
            walletUtxos
    let requestAddr =
            requestAddrFromCfg
                cfg
                tokenId
                (network cfg)
        txOut =
            mkBasicTxOut
                requestAddr
                (inject (Coin 3_000_000))
        tx =
            mkBasicTx $
                mkBasicTxBody
                    & outputsTxBodyL
                        .~ StrictSeq.singleton txOut
    case balanceTx pp [feeUtxo] [] addr tx of
        Left err ->
            error $
                "submitMalformedRequestUtxo: "
                    <> show err
        Right br -> do
            signed <-
                submitWithGenesis
                    submit
                    (balancedTx br)
            pure $
                TxIn
                    (txIdTx signed)
                    (TxIx 0)

submitWithGenesis ::
    Submitter IO ->
    ConwayTx ->
    IO ConwayTx
submitWithGenesis submit unsignedTx = do
    let signedTx =
            addKeyWitness
                genesisSignKey
                unsignedTx
    result <-
        submitTx submit signedTx
    assertSubmitted result
    awaitTx
    pure signedTx

largestUtxo ::
    String ->
    [(TxIn, TxOut ConwayEra)] ->
    IO (TxIn, TxOut ConwayEra)
largestUtxo label utxos =
    case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        [] ->
            error $
                label <> ": no UTxOs"
        u : _ -> pure u

{- | Submit a @ConwayRegCert@ for a script staking
credential. Required before the first
withdraw-zero in an End or Modify transaction.
-}
registerStakingCredential ::
    ScriptHash ->
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    IO ()
registerStakingCredential stakeHash _cfg prov submit = do
    pp <- Cage.queryProtocolParams prov
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    feeUtxo <- largestUtxo "registerStakingCredential" walletUtxos
    let evalTx :: ConwayTx -> IO (Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))
        evalTx tx = do
            r <- Cage.evaluateTx prov tx
            pure $
                Map.map
                    ( \case
                        Left e -> Left (show e)
                        Right eu -> Right eu
                    )
                    r
        prog :: Tx.TxBuild NoCtx String ()
        prog = do
            _ <- Tx.spend (fst feeUtxo)
            _ <- Tx.registerStakeScript stakeHash
            pure ()
    result <-
        Tx.build
            (Tx.mkPParamsBound pp)
            (Tx.InterpretIO (error "no ctx"))
            evalTx
            [feeUtxo]
            []
            genesisAddr
            prog
    case result of
        Left err ->
            error $
                "registerStakingCredential: "
                    <> show err
        Right tx -> do
            _ <- submitWithGenesis submit tx
            pure ()

fastRetractCfg :: CageConfig -> CageConfig
fastRetractCfg cfg =
    cfg
        { defaultProcessTime = 1_000
        , defaultRetractTime = 30_000
        }

fastRejectCfg :: CageConfig -> CageConfig
fastRejectCfg cfg =
    cfg
        { defaultProcessTime = 1_000
        , defaultRetractTime = 1_000
        }

-- ---------------------------------------------------------
-- Bracket
-- ---------------------------------------------------------

{- | Start a devnet node, connect via N2C,
build Provider and Submitter, then run.
-}
withE2E ::
    -- | Unparameterized state compiled-code bytes
    SBS.ShortByteString ->
    -- | Unparameterized request compiled-code bytes
    SBS.ShortByteString ->
    ( CageConfig ->
      Cage.Provider IO ->
      Submitter IO ->
      TrieManager IO ->
      IO a
    ) ->
    IO a
withE2E stateBytes requestBytes action = do
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <-
            async $
                runNodeClient
                    (NetworkMagic 42)
                    sock
                    lsqCh
                    ltxsCh
        threadDelay 3_000_000
        -- Verify connection
        status <- poll nodeThread
        case status of
            Just (Left err) ->
                error $
                    "Node connection failed: "
                        <> show err
            Just (Right (Left err)) ->
                error $
                    "Node connection error: "
                        <> show err
            Just (Right (Right ())) ->
                error
                    "Node connection closed \
                    \unexpectedly"
            Nothing -> pure ()
        -- Build Provider (adapt from
        -- cardano-node-clients Provider)
        let n2cProv = mkN2CProvider lsqCh
            prov = adaptProvider n2cProv
        -- Build Submitter
        let submit = mkN2CSubmitter ltxsCh
        -- Build TrieManager
        tm <- mkPureTrieManager
        -- Verify connection works
        _ <- Cage.queryProtocolParams prov
        -- Pick the seed from the genesis wallet. The state script
        -- is unparameterized; boot carries the seed in the mint
        -- redeemer.
        utxos <- Cage.queryUTxOs prov genesisAddr
        seedRef <- case utxos of
            [] ->
                error
                    "withE2E: no UTxOs in genesis \
                    \wallet — cannot pick a seed"
            (txIn, _) : _ -> pure (txInToRef txIn)
        let cfg =
                cageCfg
                    stateBytes
                    requestBytes
                    seedRef
        result <- action cfg prov submit tm
        cancel nodeThread
        pure result

{- | Adapt a @cardano-node-clients@ 'Provider' to a
@Cage@ 'Provider'. The record fields are
identical.
-}
adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs =
            N2C.queryUTxOs p
        , Cage.queryProtocolParams =
            N2C.queryProtocolParams p
        , Cage.evaluateTx =
            N2C.evaluateTx p
        , Cage.posixMsToSlot =
            N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot =
            N2C.posixMsCeilSlot p
        }

-- ---------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------

-- | Assert that a submit result is 'Submitted'.
assertSubmitted :: SubmitResult -> IO ()
assertSubmitted (Submitted _) = pure ()
assertSubmitted (Rejected reason) =
    expectationFailure $
        "Tx rejected: " <> show reason

{- | Extract the 'TokenId' from a boot
transaction's mint field.
-}
extractTokenId ::
    CageConfig -> ConwayTx -> TokenId
extractTokenId cfg tx =
    let MultiAsset ma =
            tx ^. bodyTxL . mintTxBodyL
        assets =
            Map.toList
                ( ma
                    Map.! cagePolicyIdFromCfg cfg
                )
     in case assets of
            [(an, _)] -> TokenId an
            _ ->
                error
                    "extractTokenId: \
                    \unexpected assets"

-- | Wait for a transaction to be confirmed.
awaitTx :: IO ()
awaitTx = threadDelay 5_000_000

-- ---------------------------------------------------------
-- Config
-- ---------------------------------------------------------

{- | Build a 'CageConfig' from state and request
script bytes plus the boot seed @OutputReference@.
The raw state bytes are applied to the empty
(genesis) @previousPolicies@ allowlist before
hashing, matching the parameterized on-chain state
script.
-}
cageCfg ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    OnChainTxOutRef ->
    CageConfig
cageCfg stateBytes requestBytes seed =
    let appliedStateBytes = applyPreviousPolicies [] stateBytes
     in CageConfig
            { cageScriptBytes = appliedStateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash =
                computeScriptHash appliedStateBytes
            , cageSeed = seed
            , defaultProcessTime = 30_000
            , defaultRetractTime = 30_000
            , defaultTip = Coin 1_000_000
            , network = Testnet
            , cfgStakeScript = Nothing
            }
