{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.CageSpec
Description : E2E tests for the full cage protocol
License     : Apache-2.0
-}
module Singular.Registry.E2E.CageSpec (
    spec,
    CageEnv (..),
    withBootedCage,
    bookAbsence,
    cageContext,
    foldCage,
    submitWithGenesis,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import System.Environment (lookupEnv)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    runIO,
    shouldSatisfy,
 )

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
    txIdTx,
 )
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value (
    MultiAsset (..),
 )
import Cardano.Ledger.TxIn (TxIn (..))
import Data.ByteString qualified as BS

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
import Cardano.Tx.Ledger (ConwayTx)
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    applyBytesParam,
    applyIntParam,
    extractCompiledCode,
    loadBlueprint,
 )
import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Ledger (
    AssetName (..),
    Coin (..),
    ConwayEra,
    TokenId (..),
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie.PureManager (
    mkPureTrieManager,
 )
import Singular.Registry.TxBuilder.Boot (
    bootTokenImpl,
 )
import Singular.Registry.TxBuilder.Internal (
    appliedApplicationBytes,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    leafAbsent,
    onChainTokenId,
    requestAddrFromCfg,
    scriptFromBytes,
    scriptHashBytes,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Register (

 )
import Singular.Registry.TxBuilder.Reject (
    rejectRequestsWithRefs,
 )
import Singular.Registry.TxBuilder.Retract (
    retractRequestImpl,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext,
    bookEdgeTx,
    foldRefScripts,
    publishRefScriptTx,
    refScriptBatches,
    registryContextFor,
    updateTokenWithDuties,
 )
import Singular.Registry.Types (
    OnChainOperation (..),
    OnChainTxOutRef,
 )

{- | Full cage protocol E2E test spec.
Skips when @REGISTRY_BLUEPRINT@ is not set.
-}
spec :: Spec
spec = describe "Cage E2E" $ do
    mPath <-
        runIO $ lookupEnv "REGISTRY_BLUEPRINT"
    -- #157 D-BOOT: the four pins a cage boots with are derived from the
    -- naming partition's script identities, and the edge these flows
    -- fold is certified by the application policy and witnessed by one
    -- of the three token policies. The naming blueprint is an input to
    -- the registry e2e for that reason alone — no naming behaviour is
    -- exercised here.
    mNaming <-
        runIO $ lookupEnv "NAMING_BLUEPRINT"
    case (mPath, mNaming) of
        (Nothing, _) ->
            it
                "skipped (REGISTRY_BLUEPRINT \
                \not set)"
                (pure () :: IO ())
        (_, Nothing) ->
            it
                "skipped (NAMING_BLUEPRINT \
                \not set)"
                (pure () :: IO ())
        (Just path, Just namingPath) -> do
            ebp <-
                runIO $ loadBlueprint path
            enbp <-
                runIO $ loadBlueprint namingPath
            case (ebp, enbp) of
                (Left err, _) ->
                    it
                        ( "blueprint error: "
                            <> err
                        )
                        (expectationFailure err)
                (_, Left err) ->
                    it
                        ( "naming blueprint error: "
                            <> err
                        )
                        (expectationFailure err)
                (Right bp, Right nbp) ->
                    case ( extractCompiledCode
                            "state.state"
                            bp
                         , extractCompiledCode
                            "request.request"
                            bp
                         , extractCompiledCode
                            "application.application"
                            nbp
                         , extractCompiledCode
                            "witness.witness.mint"
                            nbp
                         ) of
                        ( Just stateBytes
                            , Just requestBytes
                            , Just appBytes
                            , Just witnessBytes
                            ) ->
                                cageFlowSpec stateBytes requestBytes appBytes witnessBytes
                        _ ->
                            it "no compiled code" $
                                expectationFailure
                                    "state, request, application or \
                                    \witness script not found in the \
                                    \blueprints"

-- ---------------------------------------------------------
-- Test implementation
-- ---------------------------------------------------------

-- | Full cage E2E coverage.
cageFlowSpec ::
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    Spec
cageFlowSpec stateBytes requestBytes appBytes witnessBytes = do
    it "boots state and applies a request update"
        $ withBootedCage
            id
            stateBytes
            requestBytes
            appBytes
            witnessBytes
        $ \env -> do
            let cfg = ceCfg env
                prov = ceProv env
                requestAddr =
                    requestAddrFromCfg
                        cfg
                        (ceToken env)
                        Testnet

            _ <- bookAbsence env "hello"
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            unsignedUpdate <- foldCage env
            _ <- submitWithGenesis (ceSubmit env) unsignedUpdate

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

    it "retracts a phase-2 request"
        $ withBootedCage
            fastRetractCfg
            stateBytes
            requestBytes
            appBytes
            witnessBytes
        $ \env -> do
            let cfg = ceCfg env
                prov = ceProv env
                requestAddr =
                    requestAddrFromCfg
                        cfg
                        (ceToken env)
                        Testnet
            reqTxIn <- bookAbsence env "bye"
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            threadDelay 3_000_000

            unsignedRetract <-
                retractRequestImpl
                    cfg
                    prov
                    (ceToken env)
                    reqTxIn
                    genesisAddr
            _ <- submitWithGenesis (ceSubmit env) unsignedRetract

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

    it "rejects a phase-3 request"
        $ withBootedCage
            fastRejectCfg
            stateBytes
            requestBytes
            appBytes
            witnessBytes
        $ \env -> do
            let cfg = ceCfg env
                prov = ceProv env
                requestAddr =
                    requestAddrFromCfg
                        cfg
                        (ceToken env)
                        Testnet
            _ <- bookAbsence env "stale"
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            threadDelay 3_000_000

            unsignedReject <-
                rejectRequestsWithRefs
                    cfg
                    prov
                    (ceToken env)
                    genesisAddr
                    (ceRefs env)
            _ <- submitWithGenesis (ceSubmit env) unsignedReject

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

-- No End / Sweep / staking cases: termination, migration and seizure
-- refuse for every party under the ownerless ruling (NOTE-028/A-003).
-- That refusal evidence, with success controls, lives in repair-rows
-- (ownerless-end/migration/sweep, receipted) instead of here.

{- | A booted cage and everything a registry-mode flow needs against
it: the application policy that certifies its bookings, the unapplied
witness validator its three token policies come from, and the reference
outputs its folds resolve their scripts through.
-}
data CageEnv = CageEnv
    { ceCfg :: CageConfig
    , ceProv :: Cage.Provider IO
    , ceSubmit :: Submitter IO
    , ceTrie :: TrieManager IO
    , ceToken :: TokenId
    , ceAppScript :: Script ConwayEra
    , ceWitnessBytes :: SBS.ShortByteString
    , ceRefs :: [(TxIn, TxOut ConwayEra)]
    }

withBootedCage ::
    (CageConfig -> CageConfig) ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    (CageEnv -> IO a) ->
    IO a
withBootedCage adjustCfg stateBytes requestBytes appBytes witnessBytes action =
    withE2E stateBytes requestBytes appBytes witnessBytes $
        \cfg0 prov submit tm -> do
            let cfg = adjustCfg cfg0
            tokenId <- bootCage cfg prov submit tm
            refs <- publishCageRefs cfg prov submit tokenId witnessBytes
            action
                CageEnv
                    { ceCfg = cfg
                    , ceProv = prov
                    , ceSubmit = submit
                    , ceTrie = tm
                    , ceToken = tokenId
                    , ceAppScript =
                        scriptFromBytes "naming-application" $
                            appliedApplicationBytes
                                (scriptHashBytes (cfgScriptHash cfg))
                                (onChainTokenId tokenId)
                                requestBytes
                                appBytes
                    , ceWitnessBytes = witnessBytes
                    , ceRefs = refs
                    }

{- | Publish every script a fold of this cage can need as a reference
output, one transaction each. The state validator alone is fifteen
kilobytes, so a fold that attaches it beside the request validator is
over MaxTxSize before it carries a proof.
-}
publishCageRefs ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    SBS.ShortByteString ->
    IO [(TxIn, TxOut ConwayEra)]
publishCageRefs cfg prov submit tid witnessBytes = do
    pp <- Cage.queryProtocolParams prov
    concat
        <$> mapM
            (publishBatch pp)
            (refScriptBatches (foldRefScripts cfg tid witnessBytes))
  where
    publishBatch pp scripts = do
        unsigned <- publishRefScriptTx pp prov genesisAddr scripts
        signed <- submitWithGenesis submit unsigned
        utxos <- Cage.queryUTxOs prov genesisAddr
        mapM
            ( \ix ->
                let txIn = TxIn (txIdTx signed) (TxIx (fromIntegral ix))
                 in case [o | (i, o) <- utxos, i == txIn] of
                        (o : _) -> pure (txIn, o)
                        [] ->
                            error
                                "publishCageRefs: a published reference \
                                \output is not on chain"
            )
            [0 .. length scripts - 1]

{- | Book one @insertAbsent@ of @key@ (edge 0 of C2): mint the approval
that certifies it under the cage's pinned application policy, and
create the request that carries it. Edge 0 is the one edge anybody may
certify — witnessing that a name is free needs nobody's permission —
so what the approval binds is where the deposit goes back to.
-}
bookAbsence :: CageEnv -> ByteString -> IO TxIn
bookAbsence env key = do
    unsigned <-
        bookEdgeTx
            (ceCfg env)
            (ceProv env)
            (ceToken env)
            (ceAppScript env)
            genesisAddr
            key
            (OpInsert leafAbsent)
            (serialiseAddr genesisAddr, BS.empty)
            []
            cageBond
    signed <- submitWithGenesis (ceSubmit env) unsigned
    pure (TxIn (txIdTx signed) (TxIx 0))

{- | What a booking locks: the tip the registry keeps plus the deposit
that rides into custody, which must clear min-UTxO on its own because
the custody output carries the absent witness token and a datum naming
the key and the refund address.
-}
cageBond :: Integer
cageBond = 5_000_000

-- | The duties context for this cage's folds.
cageContext :: CageEnv -> IO RegistryContext
cageContext env =
    registryContextFor
        (ceCfg env)
        (ceProv env)
        (ceToken env)
        (ceWitnessBytes env)
        []
        (ceRefs env)

-- | The fold of every pending request, with its duties discharged.
foldCage :: CageEnv -> IO ConwayTx
foldCage env = do
    ctx <- cageContext env
    updateTokenWithDuties
        (ceCfg env)
        (ceProv env)
        (ceTrie env)
        (ceToken env)
        genesisAddr
        ctx

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
    -- | Naming application compiled-code bytes
    SBS.ShortByteString ->
    -- | Unapplied @witness(kind, registry)@ compiled-code bytes
    SBS.ShortByteString ->
    ( CageConfig ->
      Cage.Provider IO ->
      Submitter IO ->
      TrieManager IO ->
      IO a
    ) ->
    IO a
withE2E stateBytes requestBytes appBytes witnessBytes action = do
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
                    appBytes
                    witnessBytes
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
    {- | Naming application compiled-code bytes: its own hash is the
    application-policy pin, since it takes no parameters
    -}
    SBS.ShortByteString ->
    -- | Unapplied @witness(kind, registry)@ compiled-code bytes
    SBS.ShortByteString ->
    OnChainTxOutRef ->
    CageConfig
cageCfg stateBytes requestBytes appBytes witnessBytes seed =
    let appliedStateBytes = stateBytes
        appliedStateHash = computeScriptHash appliedStateBytes
        -- #157 D-BOOT: all four pins derived for THIS registry
        -- identity, never typed. The registry is the state policy
        -- bytes followed by the token name the seed determines.
        registryId =
            scriptHashBytes appliedStateHash <> deriveAssetName seed
        witnessPin kind =
            SBS.toShort
                ( scriptHashBytes
                    ( computeScriptHash
                        (applyBytesParam registryId (applyIntParam kind witnessBytes))
                    )
                )
     in CageConfig
            { cageScriptBytes = appliedStateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash = appliedStateHash
            , cageSeed = seed
            , defaultProcessTime = 30_000
            , defaultRetractTime = 30_000
            , defaultTip = Coin 1_000_000
            , cfgApplicationPolicy =
                SBS.toShort
                    ( scriptHashBytes
                        ( computeScriptHash
                            ( appliedApplicationBytes
                                (scriptHashBytes appliedStateHash)
                                ( onChainTokenId
                                    ( TokenId
                                        (AssetName (SBS.toShort (deriveAssetName seed)))
                                    )
                                )
                                requestBytes
                                appBytes
                            )
                        )
                    )
            , cfgActivePolicy = witnessPin 1
            , cfgAbsentPolicy = witnessPin 0
            , cfgTerminalPolicy = witnessPin 2
            , cfgConsumerScript = SBS.empty
            , network = Testnet
            }
