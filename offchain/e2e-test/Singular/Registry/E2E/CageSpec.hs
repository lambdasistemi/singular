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
    withE2E,
    submitInsertRequest,
    submitWithGenesis,
    publishCageRefs,
    registryContextFor,
    bookEdge,
    foldEdge,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))
import Test.Hspec (
    Expectation,
    Spec,
    describe,
    expectationFailure,
    it,
    shouldSatisfy,
 )

import Cardano.Ledger.Api.Tx (
    bodyTxL,
    txIdTx,
 )
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    referenceScriptTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.BaseTypes (Network (..), StrictMaybe (SNothing), TxIx (..))
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..), MultiAsset (..))
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
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Tx.Ledger (ConwayTx)
import Ouroboros.Network.Magic (NetworkMagic (..))
import PlutusTx.Builtins (fromBuiltin)
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Blueprint (
    Blueprint,
    NamingCodes,
    extractCompiledCode,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Driver qualified as Driver
import Singular.Registry.Ledger (
    Coin (..),
    ConwayEra,
    TokenId (..),
 )
import Singular.Registry.Node (adaptProvider, awaitConnection, awaitIndexed, followedProvider, withDevnetIndexer)
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie.PureManager (
    mkPureTrieManager,
 )
import Singular.Registry.TxBuilder.Edges (SubmitSigned)
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    addrKeyHashBytes,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    extractCageDatum,
    findUtxoByTxIn,
    mkInlineDatum,
    policyIdFromPin,
    requestAddrFromCfg,
    scriptFromBytes,
    scriptHashBytes,
    toPlcData,
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
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRequest (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
    edgeInsertAbsent,
    edgeInsertActive,
 )

{- | Full cage protocol E2E test spec.
Receives the blueprint resolved by the E2E entrypoint.
-}
spec :: Blueprint -> Spec
spec bp = describe "Request processing, retraction and rejection" $ do
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
        $ \cfg prov submit tm reg -> do
            let tokenId = Driver.registryTokenId reg
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
            reqTxIn <-
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

            request <- observedRequest reqTxIn reqUtxosBefore
            stateBefore <- currentState cfg prov tokenId
            oldState <- observedState (snd stateBefore)

            ctx <- registryContextFor cfg prov tokenId refs
            unsignedUpdate <-
                updateTokenWithDuties
                    cfg
                    prov
                    tm
                    tokenId
                    genesisAddr
                    ctx
            assertConsumedRequest reqTxIn reqUtxosBefore unsignedUpdate
            let updateBody = unsignedUpdate ^. bodyTxL
                updateOutputs = toList (updateBody ^. outputsTxBodyL)
                expectedAbsent =
                    MultiAsset $
                        Map.singleton
                            (policyIdFromPin (SBS.toShort (fromBuiltin (stateAbsentPolicy oldState))))
                            (Map.singleton (AssetName (SBS.toShort (requestKey request))) 1)
            -- Singular.txOfExit: the fold also spends its state.
            assertEqual
                "update spent state"
                True
                (Set.member (fst stateBefore) (updateBody ^. inputsTxBodyL))
            newStateOut <- stateContinuation cfg tokenId updateOutputs
            newState <- observedState newStateOut
            -- Singular.step (.insertAbsent): only the root changes.
            assertEqual
                "update state datum except root"
                oldState
                newState{stateRoot = stateRoot oldState}
            assertEffect
                "update root did not change"
                (stateRoot newState /= stateRoot oldState)
            assertEqual
                "update state value"
                (snd stateBefore ^. valueTxOutL)
                (newStateOut ^. valueTxOutL)
            -- Singular.delta / applyEdge (.insertAbsent).
            assertEqual "update mint" expectedAbsent (updateBody ^. mintTxBodyL)
            -- Singular.txCageOutputs / obligations (.fold .insertAbsent).
            (custodyOut, custodyRefund) <-
                exactlyOne
                    "update custody output"
                    [ (out, refund)
                    | out <- updateOutputs
                    , Just (AbsentCustody refund) <- [extractCageDatum out]
                    ]
            let MaryValue custodyCoin custodyAssets = custodyOut ^. valueTxOutL
            assertEqual "update custody token" expectedAbsent custodyAssets
            assertEqual
                "update custody address"
                (cageAddrFromCfg cfg (network cfg))
                (custodyOut ^. addrTxOutL)
            assertAtLeast
                "update custody deposit"
                (Coin (requestDeposit request))
                custodyCoin
            assertEqual
                "update custody refund address"
                (fst (requestDestination request))
                custodyRefund
            signedUpdate <- submitWithGenesis submit unsignedUpdate

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)
            -- Singular.txOfExit / txCageOutputs, observed after inclusion.
            assertEqual
                "update request remains after submission"
                Nothing
                (findUtxoByTxIn reqTxIn reqUtxosAfter)
            stateAfter <- currentState cfg prov tokenId
            assertEqual "update observed state" newStateOut (snd stateAfter)
            assertLandedOutput prov signedUpdate newStateOut
            assertLandedOutput prov signedUpdate custodyOut

    it "retracts a phase-2 request"
        $ withBootedCage
            fastRetractCfg
            stateBytes
            requestBytes
        $ \cfg prov submit _tm reg -> do
            let tokenId = Driver.registryTokenId reg
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

            request <- observedRequest reqTxIn reqUtxosBefore
            stateBefore <- currentState cfg prov tokenId
            oldState <- observedState (snd stateBefore)
            stateUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
            walletUtxos <- Cage.queryUTxOs prov genesisAddr

            threadDelay 3_000_000

            unsignedRetract <-
                retractRequestImpl
                    cfg
                    prov
                    tokenId
                    reqTxIn
                    genesisAddr
            assertConsumedRequest reqTxIn reqUtxosBefore unsignedRetract
            let retractBody = unsignedRetract ^. bodyTxL
                retractInputs = retractBody ^. inputsTxBodyL
                retractOutputs = toList (retractBody ^. outputsTxBodyL)
                knownInputs = reqUtxosBefore <> stateUtxos <> walletUtxos
            -- Singular.spendRefusal .retract: inspect every spent input,
            -- including other registries' tokens under the state policy.
            forM_ (Set.toList retractInputs) $ \ref -> do
                out <- case lookup ref knownInputs of
                    Nothing -> fail ("retraction input was not observed: " <> show ref)
                    Just found -> pure found
                let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
                    stateAssets = Map.findWithDefault Map.empty (cagePolicyIdFromCfg cfg) assets
                assertEffect
                    "retraction spent an input holding a state token"
                    (all (<= 0) (Map.elems stateAssets))
            -- Singular.exitStep .retract / obligations / receivedBy (.bound).
            assertEqual "retraction mint" mempty (retractBody ^. mintTxBodyL)
            let ownerOutputs = filter (paysOwner request) retractOutputs
                boundOutputs =
                    [ out
                    | out <- ownerOutputs
                    , out ^. datumTxOutL == mkInlineDatum (toPlcData (txInToRef reqTxIn))
                    ]
                floorCoin = Coin (requestDeposit request + stateMaxFee oldState)
            assertEffect "retraction refund recipient missing" (not (null ownerOutputs))
            assertEffect
                "retraction refund is not bound inline to the consumed request"
                (not (null boundOutputs))
            assertAtLeast
                "retraction bound refund (deposit plus tip)"
                floorCoin
                (maximum (Coin 0 : map (^. coinTxOutL) boundOutputs))
            _ <- submitWithGenesis submit unsignedRetract

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

            -- Singular.exitStep .retract: the identical state UTxO survives.
            assertEqual
                "retraction request remains after submission"
                Nothing
                (findUtxoByTxIn reqTxIn reqUtxosAfter)
            stateAfter <- currentState cfg prov tokenId
            assertEqual "retraction observed state UTxO" stateBefore stateAfter

    it "rejects a phase-3 request"
        $ withBootedCage
            fastRejectCfg
            stateBytes
            requestBytes
        $ \cfg prov submit _tm reg -> do
            let tokenId = Driver.registryTokenId reg
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
                    "stale"
                    edgeInsertActive
            reqUtxosBefore <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosBefore
                `shouldSatisfy` (> 0)

            request <- observedRequest reqTxIn reqUtxosBefore
            stateBefore <- currentState cfg prov tokenId
            oldState <- observedState (snd stateBefore)

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
            assertConsumedRequest reqTxIn reqUtxosBefore unsignedReject
            let rejectBody = unsignedReject ^. bodyTxL
                rejectOutputs = toList (rejectBody ^. outputsTxBodyL)
            -- Singular.txOfExit .reject spends and continues the state.
            assertEqual
                "rejection spent state"
                True
                (Set.member (fst stateBefore) (rejectBody ^. inputsTxBodyL))
            newStateOut <- stateContinuation cfg tokenId rejectOutputs
            newState <- observedState newStateOut
            -- Singular.exitStep .reject: datum (including root), value, mint.
            assertEqual "rejection state datum and root" oldState newState
            assertEqual
                "rejection state value"
                (snd stateBefore ^. valueTxOutL)
                (newStateOut ^. valueTxOutL)
            assertEqual "rejection mint" mempty (rejectBody ^. mintTxBodyL)
            -- Singular.obligations .reject / receivedBy (.owner).
            let ownerOutputs = filter (paysOwner request) rejectOutputs
            assertEffect "rejection refund recipient missing" (not (null ownerOutputs))
            assertAtLeast
                "rejection owner refund"
                (Coin (requestDeposit request))
                (Coin (sum [amount | out <- ownerOutputs, let Coin amount = out ^. coinTxOutL]))
            signedReject <- submitWithGenesis submit unsignedReject

            reqUtxosAfter <-
                Cage.queryUTxOs prov requestAddr
            length reqUtxosAfter
                `shouldSatisfy` (< length reqUtxosBefore)

            -- Singular.exitStep .reject, observed after inclusion.
            assertEqual
                "rejection request remains after submission"
                Nothing
                (findUtxoByTxIn reqTxIn reqUtxosAfter)
            stateAfter <- currentState cfg prov tokenId
            assertEqual "rejection observed state" newStateOut (snd stateAfter)
            assertLandedOutput prov signedReject newStateOut

-- No End / Sweep / staking cases: termination, migration and seizure
-- refuse for every party under the ownerless ruling (NOTE-028/A-003).
-- That refusal evidence, with success controls, lives in repair-rows
-- (ownerless-end/migration/sweep, receipted) instead of here.

{- | Boot a cage and hand the caller the driver's registry handle.

The boot itself belongs to 'Driver.bootRegistry' (#190): minting the
token, creating the trie, publishing the cage references and the three
checks that used to live in this module's own 'bootCage'. A caller that
wants only the token asks the handle for it.
-}
withBootedCage ::
    (CageConfig -> CageConfig) ->
    SBS.ShortByteString ->
    SBS.ShortByteString ->
    ( CageConfig ->
      Cage.Provider IO ->
      Submitter IO ->
      TrieManager IO ->
      Driver.Registry ->
      IO a
    ) ->
    IO a
withBootedCage adjustCfg stateBytes requestBytes action =
    withE2E stateBytes requestBytes $
        \cfg0 prov submit tm -> do
            let cfg = adjustCfg cfg0
            codes <- loadRegistryCodesFromEnv
            reg <-
                Driver.bootRegistry cfg codes prov (submitWithGenesis submit) genesisAddr tm
            action cfg prov submit tm reg

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
    awaitIndexed signedTx
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
    withCardanoNode gDir $ \sock _startMs -> withDevnetIndexer sock $ do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <-
            async $
                runNodeClient
                    (NetworkMagic 42)
                    sock
                    lsqCh
                    ltxsCh
        let nodeProv = adaptProvider (mkN2CProvider lsqCh)
        awaitConnection (NetworkMagic 42) sock nodeThread nodeProv
        let submit = mkN2CSubmitter ltxsCh
        -- Address reads from here on are the indexer's.
        prov <- followedProvider nodeProv submit
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

-- ---------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------

-- | Report effect failures separately from request-selection failures.
assertEffect :: String -> Bool -> Expectation
assertEffect label holds =
    unless holds (expectationFailure ("wrong effect: " <> label))

-- | Compare an effect while retaining both observed and expected values.
assertEqual :: (Eq a, Show a) => String -> a -> a -> Expectation
assertEqual label expected actual =
    unless (actual == expected) $
        expectationFailure $
            "wrong effect: " <> label <> "; expected " <> show expected <> "; observed " <> show actual

-- | Singular.settle: a payment is a floor, with any surplus unconstrained.
assertAtLeast :: String -> Coin -> Coin -> Expectation
assertAtLeast label expected actual =
    unless (actual >= expected) $
        expectationFailure $
            "wrong effect: " <> label <> "; expected at least " <> show expected <> "; observed " <> show actual

-- | Singular.txOfExit: spend precisely the selected request from the queue.
assertConsumedRequest :: TxIn -> [(TxIn, TxOut ConwayEra)] -> ConwayTx -> Expectation
assertConsumedRequest selected requests tx = do
    let consumed =
            [ ref
            | (ref, _) <- requests
            , Set.member ref (tx ^. bodyTxL . inputsTxBodyL)
            ]
    unless (consumed == [selected]) $
        expectationFailure $
            "wrong consumed request: expected " <> show [selected] <> "; observed " <> show consumed

-- | Require an unambiguous observed output, rather than picking the first.
exactlyOne :: (Show a) => String -> [a] -> IO a
exactlyOne _ [found] = pure found
exactlyOne label found = do
    expectationFailure ("wrong effect: " <> label <> "; expected one, observed " <> show found)
    fail label

-- | Read the request's expected effects from its pre-transaction chain datum.
observedRequest :: TxIn -> [(TxIn, TxOut ConwayEra)] -> IO OnChainRequest
observedRequest ref utxos = case lookup ref utxos >>= extractCageDatum of
    Just (RequestDatum request) -> pure request
    _ -> fail "selected request was not observable with an inline request datum"

-- | Decode the state used as the pre-transaction expectation or continuation.
observedState :: TxOut ConwayEra -> IO OnChainTokenState
observedState out = case extractCageDatum out of
    Just (StateDatum state) -> pure state
    _ -> fail "wrong effect: state output has no inline state datum"

-- | Recognize the state by its ledger token, not just by a decodable datum.
holdsState :: CageConfig -> TokenId -> TxOut ConwayEra -> Bool
holdsState cfg tokenId out =
    let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
     in (Map.lookup (cagePolicyIdFromCfg cfg) assets >>= Map.lookup (unTokenId tokenId)) == Just 1

-- | Singular.txStateOutput: exactly one state continuation at the cage.
stateContinuation :: CageConfig -> TokenId -> [TxOut ConwayEra] -> IO (TxOut ConwayEra)
stateContinuation cfg tokenId outputs = do
    out <- exactlyOne "state continuation" (filter (holdsState cfg tokenId) outputs)
    assertEqual "state continuation address" (cageAddrFromCfg cfg (network cfg)) (out ^. addrTxOutL)
    pure out

-- | Read the registry state and retain its reference to distinguish an unspent UTxO.
currentState :: CageConfig -> Cage.Provider IO -> TokenId -> IO (TxIn, TxOut ConwayEra)
currentState cfg prov tokenId = do
    utxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    exactlyOne "observed registry state" (filter (holdsState cfg tokenId . snd) utxos)

-- | Singular.paysRecipient: ownership is the payment key, independent of staking.
paysOwner :: OnChainRequest -> TxOut ConwayEra -> Bool
paysOwner request out = addrKeyHashBytes (out ^. addrTxOutL) == fromBuiltin (requestOwner request)

-- | Check the actual output at the submitted transaction's output reference.
assertLandedOutput :: Cage.Provider IO -> ConwayTx -> TxOut ConwayEra -> Expectation
assertLandedOutput prov tx expected = do
    ix <-
        exactlyOne
            "built output reference"
            [ ix
            | (ix, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
            , out == expected
            ]
    observed <- Cage.queryUTxOs prov (expected ^. addrTxOutL)
    -- Singular.txOfExit / txCageOutputs: value and datum agree after inclusion.
    assertEqual
        "output after submission"
        (Just expected)
        (lookup (TxIn (txIdTx tx) (TxIx ix)) observed)

-- | Assert that a submit result is 'Submitted'.
assertSubmitted :: SubmitResult -> IO ()
assertSubmitted (Submitted _) = pure ()
assertSubmitted (Rejected reason) =
    expectationFailure $
        "Tx rejected: " <> show reason

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
