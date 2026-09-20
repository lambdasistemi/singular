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
    withBootedCage,
    submitInsertRequest,
    submitWithGenesis,
    publishCageRefs,
    registryContextFor,
    bookEdge,
    foldEdge,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Data.ByteString (ByteString)
import Control.Monad (when)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.ByteString.Lazy qualified as BSL
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    referenceInputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Wits (scriptTxWitsL)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Core (eraProtVerHigh)
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

import Cardano.Ledger.Api.Tx (
    bodyTxL,
    txIdTx,
 )
import Cardano.Ledger.Api.Tx.Body (mintTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (SNothing), TxIx (..))
import Cardano.Ledger.Mary.Value (
    MultiAsset (..),
 )
import Cardano.Ledger.TxIn (TxIn (..))

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
    NamingCodes,
    extractCompiledCode,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Ledger (
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
import Singular.Registry.TxBuilder.Edges (SubmitSigned)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    requestAddrFromCfg,
    scriptFromBytes,
    scriptHashBytes,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Reject (
    rejectRequestsWithRefs,
 )
import Singular.Registry.TxBuilder.Request (
    requestEdgeImpl,
 )
import Singular.Registry.TxBuilder.Retract (
    retractRequestImpl,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext,
    updateTokenWithDuties,
 )
import Singular.Registry.Types (Edge, edgeInsertAbsent, edgeInsertActive, OnChainTxOutRef)

{- | Full cage protocol E2E test spec.
Skips when @REGISTRY_BLUEPRINT@ is not set.
-}
spec :: Spec
spec = describe "Cage E2E" $ do
    mPath <-
        runIO $ lookupEnv "REGISTRY_BLUEPRINT"
    case mPath of
        Nothing ->
            it
                "skipped (REGISTRY_BLUEPRINT \
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
                        (Just stateBytes, Just requestBytes, _) ->
                            cageFlowSpec stateBytes requestBytes
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
    Spec
cageFlowSpec stateBytes requestBytes = do
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

            -- #157 C2: an insert takes an edge only when its value is a
            -- leaf. This row books the witnessed absence of "hello"
            -- (edge 0), carrying the approval the cage demands of every
            -- processed request, and folds it.
            refs <- publishCageRefs cfg prov submit tokenId
            _ <-
                bookEdge
                    cfg
                    prov
                    submit
                    tokenId
                    "hello"
                    edgeInsertAbsent
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            ctx <- registryContextFor cfg prov tokenId refs
            unsignedUpdate <-
                updateTokenWithDuties
                    cfg
                    prov
                    tm
                    tokenId
                    genesisAddr
                    ctx
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
                    edgeInsertActive
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
                    edgeInsertActive
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            threadDelay 3_000_000

            -- The state validator alone is fifteen kilobytes: a reject
            -- that attaches it and the request script is 18317 bytes
            -- against a 16384-byte protocol maximum. Published
            -- references carry both instead.
            refs <- publishCageRefs cfg prov submit tokenId
            unsignedReject <-
                rejectRequestsWithRefs
                    cfg
                    prov
                    tokenId
                    genesisAddr
                    refs
            _ <- submitWithGenesis submit unsignedReject

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

-- No End / Sweep / staking cases: termination, migration and seizure
-- refuse for every party under the ownerless ruling (NOTE-028/A-003).
-- That refusal evidence, with success controls, lives in repair-rows
-- (ownerless-end/migration/sweep, receipted) instead of here.

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
    bootWallet <- Cage.queryUTxOs prov genesisAddr
    unsignedBoot <-
        bootTokenImpl
            cfg
            prov
            genesisAddr
    -- #177 A-003: the boot transaction must RESOLVE the state validator
    -- through the published reference output, not carry it. The
    -- validator is fifteen kilobytes against a sixteen-kilobyte cap, so
    -- an inline boot leaves the registry no room to grow — that is what
    -- the retirement guard ran out of. Asserted on the transaction the
    -- chain accepted, and printed with its size so a reviewer can see
    -- the budget rather than take it on trust.
    let bootScripts = unsignedBoot ^. witsTxL . scriptTxWitsL
        bootRefs = unsignedBoot ^. bodyTxL . referenceInputsTxBodyL
        bootBytes =
            BSL.length (serialize (eraProtVerHigh @ConwayEra) unsignedBoot)
    putStrLn
        ( "[boot] bytes="
            <> show bootBytes
            <> " inline-scripts="
            <> show (Map.size bootScripts)
            <> " reference-inputs="
            <> show (Set.size bootRefs)
            <> " fee="
            <> show (unsignedBoot ^. bodyTxL . feeTxBodyL)
            <> " collateral-coins="
            <> show
                [ c
                | i <- Set.toList (unsignedBoot ^. bodyTxL . collateralInputsTxBodyL)
                , (j, o) <- bootWallet
                , i == j
                , let Coin c = o ^. coinTxOutL
                ]
            <> " wallet-coins="
            <> show [c | (_, o) <- bootWallet, let Coin c = o ^. coinTxOutL]
        )
    when (Map.member (cfgScriptHash cfg) bootScripts) $
        expectationFailure
            "#177 A-003: the boot transaction carries the state validator \
            \INLINE. It must reference the published output instead; an \
            \inline boot is what left no room for the retirement guard."
    when (Set.null bootRefs) $
        expectationFailure
            "#177 A-003: the boot transaction resolves no reference input, \
            \so the state validator was not published before it."
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
    Edge ->
    IO TxIn
submitInsertRequest cfg prov submit tokenId key edge = do
    unsignedReq <-
        requestEdgeImpl
            cfg
            prov
            (Coin 1_000_000)
            tokenId
            key
            edge
            genesisAddr
    signedReq <- submitWithGenesis submit unsignedReq
    pure $
        TxIn
            (txIdTx signedReq)
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
        -- #177 A-003: publish the state validator as a reference output
        -- BEFORE the seed is chosen. The publication spends the
        -- wallet's largest ada-only output, which is exactly the one a
        -- seed picked first would have pinned — the boot would then
        -- look for a UTxO the publication had already spent.
        _ <-
            Edges.publishRefScript
                prov
                (submitWithGenesis submit)
                genesisAddr
                (scriptFromBytes "state" stateBytes)
        -- Pick the seed from the genesis wallet. The state script
        -- is unparameterized; boot carries the seed in the mint
        -- redeemer.
        utxos <- Cage.queryUTxOs prov genesisAddr
        -- #177 A-003: never seed from the reference publication. Boot
        -- REFERENCES that output, and a transaction may not both spend
        -- and reference the same one — the ledger calls it
        -- `BabbageNonDisjointRefInputs`.
        seedRef <- case filter (\(_, o) -> o ^. referenceScriptTxOutL == SNothing) utxos of
            [] ->
                error
                    "withE2E: no spendable UTxO in the genesis \
                    \wallet — cannot pick a seed"
            (txIn, _) : _ -> pure (txInToRef txIn)
        codes <- loadRegistryCodesFromEnv
        let cfg =
                cageCfg
                    stateBytes
                    requestBytes
                    codes
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
    NamingCodes ->
    OnChainTxOutRef ->
    CageConfig
cageCfg stateBytes requestBytes codes seed =
    let appliedStateBytes = stateBytes
        stateHash = computeScriptHash appliedStateBytes
        -- #157 D-BOOT: the four pins for THIS registry identity, derived
        -- from the naming partition's own compiled code exactly as the
        -- conformance rows derive them (A-014). The registry id a witness
        -- policy is parameterized by is the state policy plus the token
        -- name the seed determines.
        registryId = scriptHashBytes stateHash <> deriveAssetName seed
        (appPin, absentPin, activePin, terminalPin) =
            Edges.namingPins codes registryId
     in CageConfig
            { cageScriptBytes = appliedStateBytes
            , requestScriptBytes = requestBytes
            , cfgScriptHash = stateHash
            , cageSeed = seed
            , defaultProcessTime = 30_000
            , defaultRetractTime = 30_000
            , defaultTip = Coin 1_000_000
            , cfgApplicationPolicy = appPin
            , cfgAbsentPolicy = absentPin
            , cfgActivePolicy = activePin
            , cfgTerminalPolicy = terminalPin
            , cfgConsumerScript = SBS.empty
            , network = Testnet
            }

-- ---------------------------------------------------------
-- Registry-mode edges (#157 C2, C4, D-APPROVAL)
-- ---------------------------------------------------------

{- | Sign with the genesis key, submit and wait: the submission
discipline every transaction of this suite uses.
-}
genesisSubmit :: Submitter IO -> SubmitSigned
genesisSubmit = submitWithGenesis

{- | Publish this cage's scripts as reference outputs. The state
validator alone is fifteen kilobytes, so a fold or a reject that
attaches it and the request script does not fit in a transaction; with
references every purpose resolves through them instead.
-}
publishCageRefs ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    IO [(TxIn, TxOut ConwayEra)]
publishCageRefs cfg prov submit tokenId = do
    codes <- loadRegistryCodesFromEnv
    Edges.publishCageRefs cfg codes prov (genesisSubmit submit) genesisAddr tokenId

-- | The duties context a fold of tree edges discharges its obligations from.
registryContextFor ::
    CageConfig ->
    Cage.Provider IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    IO RegistryContext
registryContextFor cfg prov _tokenId refs = do
    codes <- loadRegistryCodesFromEnv
    Edges.registryContextFor cfg codes prov refs

{- | Book one tree edge: the approval the naming application mints
certifies the edge, and the request carries it to the fold.
-}
bookEdge ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TokenId ->
    ByteString ->
    Edge ->
    IO TxIn
bookEdge cfg prov submit tokenId key op = do
    codes <- loadRegistryCodesFromEnv
    Edges.bookEdge cfg codes prov (genesisSubmit submit) genesisAddr tokenId key op

-- | Book one edge and fold it, end to end on a real devnet.
foldEdge ::
    CageConfig ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    [(TxIn, TxOut ConwayEra)] ->
    ByteString ->
    Edge ->
    IO ConwayTx
foldEdge cfg prov submit tm tokenId refs key op = do
    _ <- bookEdge cfg prov submit tokenId key op
    ctx <- registryContextFor cfg prov tokenId refs
    unsigned <- updateTokenWithDuties cfg prov tm tokenId genesisAddr ctx
    submitWithGenesis submit unsigned
