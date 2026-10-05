{-# LANGUAGE LambdaCase #-}

module Singular.Provider.Koios.ProviderSpec (spec) where

import Cardano.Ledger.Address (AccountAddress (..), AccountId (..))
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL, vldtTxBodyL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.BaseTypes qualified as Ledger
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core
    ( eraProtVerHigh
    , mkBasicTx
    , mkBasicTxBody
    , txIdTxBody
    )
import Cardano.Ledger.Credential (Credential (ScriptHashObj))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception (finally, try)
import Control.Monad (forM_, void)
import Control.Monad.State.Strict (State, gets, modify', runState)
import Data.Aeson
    ( Value (..)
    , decodeStrict'
    , encode
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (permutations, sort, sortOn, subsequences)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
import Data.Word (Word64)
import Lens.Micro ((&), (.~), (^.))
import Singular.Provider.Koios.Client qualified as Client
import Singular.Provider.Koios.FakeServer
    ( Seen (..)
    , replayFixtures
    , withFakeKoios
    )
import Singular.Provider.Koios.Http
    ( defaultHttpConfig
    , newHttpTransport
    )
import Singular.Provider.Koios.Provider
import Singular.Provider.Koios.Recorded
    ( Fixture (..)
    , FixtureSet (..)
    , bodySha256
    , encodeFixture
    , fixtureRequestOf
    , loadFixtureSet
    , recordedTransport
    )
import Singular.Provider.Koios.Runtime (newIORuntime)
import Singular.Provider.Koios.Scripted
    ( assetTxRow
    , okJson
    , pageAnswer
    , queryParam
    , scriptHashOfByte
    , signedTransaction
    )
import Singular.Provider.Koios.State
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.Confirmation qualified as Confirmation
import Singular.Registry.Evidence
    ( Evidenced (..)
    , SessionBinding (..)
    , SessionId (..)
    , unverifiedVerifier
    )
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime
    ( NetworkTimeFailure (..)
    , NetworkTimeManifest (..)
    , networkMagic
    )
import Singular.Registry.NetworkTimeSpec (loadNetworkFixture)
import Singular.Registry.PhaseLog (noPhaseLog, phaseLogAt)
import Singular.Registry.SessionEvidence
    ( FactRecord (..)
    , observeProvider
    )
import Singular.Registry.Signing (signedTx)
import Singular.Registry.TimeSource (loadPinnedSource)
import Singular.Registry.TxBuilder.BookingFixture (payer)
import Singular.Registry.Wait (WaitFailure (..), WaitStage (..))
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "Koios ledger provider constructor" $ do
    it
        "orders a complete block by asset spends across a page despite opposite hash order"
        $ do
            source <- timeSource
            let (parent, child, output) = dependentPair True
                p = keyOf parent
                r = keyOf child
                client =
                    synthetic [(parent, []), (child, [(TxIn p (TxIx 0), output)])] [r, p]
                (result, state) = runHistory source client
            persist
                "cross-page-spend-order"
                ( object
                    [ "result" .= show result
                    , "producer_order" .= map Wire.txIdHex [p, r]
                    , "events" .= map eventJson (providerEvents state)
                    ]
                )
            Wire.txIdHex r `shouldSatisfy` (< Wire.txIdHex p)
            result `shouldBe` Right [p, r]
            length
                [ ()
                | RawExchange _ request _ <- providerEvents state
                , Client.rawCall request == Wire.CallAssetTxs
                ]
                `shouldBe` 2
            Set.null (openSessions state) `shouldBe` True

    it
        "keeps same-block non-asset funding outside the dependency listing and never fetches its creator"
        $ do
            source <- timeSource
            let (funding, child, output) = dependentPair False
                f = keyOf funding
                r = keyOf child
                client = synthetic [(funding, []), (child, [(TxIn f (TxIx 0), output)])] [r]
                (result, state) = runHistory source client
                infoRequests =
                    [ asked request
                    | RawExchange _ request _ <- providerEvents state
                    , Client.rawCall request == Wire.CallTxInfo
                    ]
            persist
                "unrelated-funding"
                ( object
                    [ "result" .= show result
                    , "funding_creator" .= Wire.txIdHex f
                    , "listed_transaction" .= Wire.txIdHex r
                    , "events" .= map eventJson (providerEvents state)
                    ]
                )
            result `shouldBe` Right [r]
            infoRequests `shouldBe` [[Wire.txIdHex r]]

    it
        "refuses a same-block asset-carrying parent omitted from the complete listing by name"
        $ do
            source <- timeSource
            let (parent, child, output) = dependentPair True
                p = keyOf parent
                r = keyOf child
                client = synthetic [(parent, []), (child, [(TxIn p (TxIx 0), output)])] [r]
                (result, state) = runHistory source client
            persist
                "missing-asset-parent"
                ( object
                    [ "result" .= show result
                    , "omitted_parent" .= Wire.txIdHex p
                    , "events" .= map eventJson (providerEvents state)
                    ]
                )
            result `shouldBe` Left (MissingInBlockParent r p)

    describe "complete history reconstruction refusals" $ do
        it
            "retains full CBOR, resolved normal and reference inputs, outputs and validity"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    (funding, _, referenceOutput) = dependentPair False
                    normal = (TxIn (keyOf parent) (TxIx 0), output)
                    reference = (TxIn (keyOf funding) (TxIx 0), referenceOutput)
                    readingChild =
                        child
                            & bodyTxL . referenceInputsTxBodyL .~ Set.singleton (fst reference)
                    r = keyOf readingChild
                    client =
                        amendHistory
                            Wire.CallTxInfo
                            (map (amendRow r "reference_inputs" (toJSON [outputRow reference])))
                            (synthetic [(parent, []), (readingChild, [normal])] [keyOf parent, r])
                    provider = koiosProvider stateRuntime (Network 1) (pure (Right source)) client
                    action = acquire provider (Latest (Network 1)) $ \session ->
                        history session asset (HistoryRange Nothing Nothing) >>= \case
                            Left failure -> pure (Left failure)
                            Right stream -> fmap (fmap (fmap (\(block, _) -> block))) (nextBlock stream)
                    (result, state) = runState action initialProviderState
                persist "complete-history-material" $
                    object
                        ["events" .= map eventJson (providerEvents state)]
                block <- case result of
                    Right (Right (Just block)) -> pure block
                    _ -> fail "complete history block did not reach the consumer"
                let material = NE.last (blockTransactions block)
                    expectedBytes = serialize' (eraProtVerHigh @ConwayEra) readingChild
                    expectedOutputs =
                        zipWith
                            (\index out -> (TxIn r (TxIx index), out))
                            [0 ..]
                            (toList (readingChild ^. bodyTxL . outputsTxBodyL))
                historicalId material `shouldBe` r
                historicalCbor material `shouldBe` expectedBytes
                historicalTx material `shouldBe` readingChild
                spentOutputs material `shouldBe` [normal]
                referenceOutputs material `shouldBe` [reference]
                createdOutputs material `shouldBe` expectedOutputs
                scriptValid material `shouldBe` True

        it
            "retains script-invalid material while excluding its attempted inputs from double-spend accounting"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    failed =
                        (child & bodyTxL . feeTxBodyL .~ Coin 17)
                            & isValidTxL .~ IsValid False
                    reference = TxIn (keyOf parent) (TxIx 0)
                    (result, state) =
                        runHistory source $
                            synthetic
                                [ (parent, [])
                                , (child, [(reference, output)])
                                , (failed, [(reference, output)])
                                ]
                                [keyOf parent, keyOf child, keyOf failed]
                retainHistory "script-invalid-spend-exclusion" result state
                fmap Set.fromList result
                    `shouldBe` Right (Set.fromList [keyOf parent, keyOf child, keyOf failed])

        it "names a selected-asset dependency cycle before fetching bodies" $ do
            source <- timeSource
            let (parent, child, output) = dependentPair True
                p = keyOf parent
                r = keyOf child
                client =
                    amendHistory
                        Wire.CallTxInfo
                        ( map
                            (amendRow p "inputs" (toJSON [outputRow (TxIn r (TxIx 0), output)]))
                        )
                        (synthetic [(parent, []), (child, [(TxIn p (TxIx 0), output)])] [p, r])
                (result, state) = runHistory source client
            retainHistory "dependency-cycle" result state
            case result of
                Left (HistoryDependencyCycle members) ->
                    Set.fromList (NE.toList members) `shouldBe` Set.fromList [p, r]
                _ ->
                    expectationFailure
                        "cyclic raw dependency graph did not refuse by name"
            [ ()
              | RawExchange _ request _ <- providerEvents state
              , Client.rawCall request == Wire.CallTxCbor
              ]
                `shouldBe` []

        it
            "names a double spend within a complete block and across block continuations"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    other = child & bodyTxL . feeTxBodyL .~ Coin 17
                    reference = TxIn (keyOf parent) (TxIx 0)
                    run heights =
                        runHistory source $
                            syntheticAt
                                heights
                                [ (parent, [])
                                , (child, [(reference, output)])
                                , (other, [(reference, output)])
                                ]
                                [keyOf parent, keyOf child, keyOf other]
                forM_ [("in-block", [20, 20, 20]), ("across-blocks", [20, 21, 22])] $ \(name, heights) -> do
                    let (result, state) = run heights
                    retainHistory ("duplicate-spend-" <> name) result state
                    result `shouldBe` Left (DuplicateSpend reference)

        it
            "validates an earlier asset parent without adding it to a requested block"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    p = keyOf parent
                    r = keyOf child
                    client =
                        syntheticAt
                            [19, 20]
                            [(parent, []), (child, [(TxIn p (TxIx 0), output)])]
                            [r]
                    (result, state) = runHistory source client
                retainHistory "earlier-asset-parent" result state
                result `shouldBe` Right [r]
                [ asked request
                  | RawExchange _ request _ <- providerEvents state
                  , Client.rawCall request == Wire.CallTxCbor
                  ]
                    `shouldBe` [[Wire.txIdHex p], [Wire.txIdHex r]]

        it
            "refuses an earlier parent whose resolved asset bytes differ from its body"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    changed =
                        output
                            & valueTxOutL
                                .~ MaryValue
                                    (Coin 1)
                                    (MultiAsset (Map.singleton (fst asset) (Map.singleton (snd asset) 1)))
                    p = keyOf parent
                    r = keyOf child
                    (result, state) =
                        runHistory source $
                            syntheticAt
                                [19, 20]
                                [(parent, []), (child, [(TxIn p (TxIx 0), changed)])]
                                [r]
                retainHistory "earlier-parent-bytes" result state
                result
                    `shouldBe` Left (HistoryMaterialMismatch r "resolved earlier asset output")

        it
            "refuses conflicting resolved in-block bytes after validating both bodies"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    changed =
                        output
                            & valueTxOutL
                                .~ MaryValue
                                    (Coin 1)
                                    (MultiAsset (Map.singleton (fst asset) (Map.singleton (snd asset) 1)))
                    p = keyOf parent
                    r = keyOf child
                    (result, state) =
                        runHistory source $
                            synthetic [(parent, []), (child, [(TxIn p (TxIx 0), changed)])] [p, r]
                retainHistory "in-block-resolved-bytes" result state
                result
                    `shouldBe` Left (HistoryMaterialMismatch r "resolved in-block output")

        it
            "refuses each inconsistent transaction material field by its identity"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    p = keyOf parent
                    r = keyOf child
                    original =
                        synthetic [(parent, []), (child, [(TxIn p (TxIx 0), output)])] [p, r]
                    corruptions =
                        [ ("script-validity", "valid_contract", Bool False, "script validity")
                        ,
                            ( "spent-references"
                            , "inputs"
                            , toJSON ([] :: [Value])
                            , "spent input references"
                            )
                        ,
                            ( "reference-references"
                            , "reference_inputs"
                            , toJSON [outputRow (TxIn p (TxIx 0), output)]
                            , "reference input references"
                            )
                        ,
                            ( "produced-outputs"
                            , "outputs"
                            , toJSON ([] :: [Value])
                            , "produced outputs"
                            )
                        ,
                            ( "height"
                            , "block_height"
                            , toJSON (21 :: Int)
                            , "listing and transaction heights disagree"
                            )
                        ]
                forM_ corruptions $ \(name, field, changed, message) -> do
                    let client =
                            amendHistory Wire.CallTxInfo (map (amendRow r field changed)) original
                        (result, state) = runHistory source client
                    retainHistory ("material-" <> name) result state
                    result `shouldBe` Left (HistoryMaterialMismatch r message)

        it
            "requires the requested complete CBOR rather than accepting missing material"
            $ do
                source <- timeSource
                let (parent, _, _) = dependentPair True
                    p = keyOf parent
                    client =
                        amendHistory Wire.CallTxCbor (const []) (synthetic [(parent, [])] [p])
                    (result, state) = runHistory source client
                retainHistory "missing-cbor" result state
                case result of
                    Left (HistoryReadFailure (BackendReadFailure reason)) -> do
                        reason `shouldSatisfy` Text.isInfixOf "UnknownTransaction"
                        reason `shouldSatisfy` Text.isInfixOf (Text.pack (show p))
                    _ ->
                        expectationFailure
                            "absent complete CBOR did not preserve the named client refusal"

        it
            "keeps later block material deferred and applies inclusive height bounds"
            $ do
                source <- timeSource
                let (parent, child, output) = dependentPair True
                    p = keyOf parent
                    r = keyOf child
                    client =
                        syntheticAt
                            [19, 20]
                            [(parent, []), (child, [(TxIn p (TxIx 0), output)])]
                            [p, r]
                    provider = koiosProvider stateRuntime (Network 1) (pure (Right source)) client
                    firstOnly = acquire provider (Latest (Network 1)) $ \session ->
                        history session asset (HistoryRange Nothing Nothing) >>= \case
                            Left failure -> pure (Left failure)
                            Right stream ->
                                nextBlock stream >>= \case
                                    Left failure -> pure (Left failure)
                                    Right Nothing -> pure (Right [])
                                    Right (Just (block, _)) ->
                                        pure (Right (map historicalId (NE.toList (blockTransactions block))))
                    (first, state) = runState firstOnly initialProviderState
                    (ranged, rangeState) = runHistoryRange source client (HistoryRange (Just 20) (Just 20))
                persist "deferred-block-material" $
                    object
                        [ "result" .= show first
                        , "events" .= map eventJson (providerEvents state)
                        ]
                retainHistory "inclusive-history-range" ranged rangeState
                first `shouldBe` Right (Right [p])
                [ asked request
                  | RawExchange _ request _ <- providerEvents state
                  , Client.rawCall request == Wire.CallTxCbor
                  ]
                    `shouldBe` [[Wire.txIdHex p]]
                ranged `shouldBe` Right [r]

    it
        "discovers actual consumed facts and their verdicts through one generic pure acquisition"
        $ do
            source <- timeSource
            set <- recordedSet
            let (parent, child, output) = dependentPair True
                p = keyOf parent
                r = keyOf child
                fixtureClient =
                    synthetic [(parent, []), (child, [(TxIn p (TxIx 0), output)])] [p, r]
                scripted = Client.Transport $ \request -> case Client.rawCall request of
                    Wire.CallTip -> Client.exchange (recordedTransport set) request
                    Wire.CallCliProtocolParams -> Client.exchange (recordedTransport set) request
                    Wire.CallAddressUtxos ->
                        pure $
                            pageAnswer [addressRow (TxIn p (TxIx 0), output)] (offsetOf request) 1
                    Wire.CallAssetUtxos ->
                        pure $
                            pageAnswer [addressRow (TxIn p (TxIx 0), output)] (offsetOf request) 1
                    Wire.CallAccountInfo ->
                        pure $
                            okJson [] $
                                jsonBytes
                                    [ object
                                        [ "stake_address"
                                            .= Wire.renderRewardAccount
                                                ( AccountAddress
                                                    Ledger.Testnet
                                                    (AccountId (ScriptHashObj (scriptHashOfByte 11)))
                                                )
                                        , "status" .= ("registered" :: Text)
                                        ]
                                    ]
                    _ -> Client.exchange (Client.koiosTransport fixtureClient) request
                addressRow pair = case outputRow pair of
                    Object fields ->
                        Object
                            (KM.insert "address" (String (Wire.renderAddress payer)) fields)
                    _ -> error "synthetic output is not a JSON row"
                offsetOf request = maybe 0 (read . Text.unpack) (queryParam "offset" request)
                runtime =
                    stateRuntimeIn
                        fst
                        (\providerState (_, observations) -> (providerState, observations))
                sink fact =
                    modify'
                        ( \(providerState, observations) -> (providerState, observations <> [fact])
                        )
                provider =
                    observeProvider unverifiedVerifier sink $
                        koiosProvider
                            runtime
                            (Network 1)
                            (pure (Right source))
                            (Client.Koios (Client.ClientConfig 1 20) scripted)
                action = acquire provider (Latest (Network 1)) $ \session -> do
                    queries <-
                        traverse
                            (fmap (fmap value) . outputs session)
                            [ AtAddress payer
                            , HoldingAsset asset
                            , AtTxIn (TxIn p (TxIx 0))
                            , AnyOf (AtAddress payer NE.:| [HoldingAsset asset])
                            , AllOf (AtAddress payer NE.:| [AtTxIn (TxIn p (TxIx 0))])
                            ]
                    pp <- fmap (fmap (const ())) (protocolParameters session)
                    observedTip <- fmap (fmap (const ())) (tipObservation session)
                    time <- fmap (fmap (const ())) (networkTime session)
                    registration <-
                        fmap (fmap value) (scriptRegistered session (scriptHashOfByte 11))
                    historyResult <-
                        history session asset (HistoryRange Nothing Nothing) >>= \case
                            Left failure -> pure (Left failure)
                            Right stream ->
                                nextBlock stream >>= \case
                                    Left failure -> pure (Left failure)
                                    Right Nothing -> pure (Right [])
                                    Right (Just (block, rest)) -> do
                                        end <- nextBlock rest
                                        pure $ case end of
                                            Left failure -> Left failure
                                            Right Nothing -> Right (map historicalId (NE.toList (blockTransactions block)))
                                            Right (Just _) -> error "unexpected second block"
                    pure (queries, pp, observedTip, time, registration, historyResult)
                (result, (state, facts)) = runState action (initialProviderState, [])
            persist "consumed-facts-pure" $
                object
                    [ "result" .= show result
                    , "raw_events" .= map eventJson (providerEvents state)
                    , "facts" .= facts
                    ]
            result
                `shouldBe` Right
                    ( replicate 5 (Right [(TxIn p (TxIx 0), output)])
                    , Right ()
                    , Right ()
                    , Right ()
                    , Right True
                    , Right [p, r]
                    )
            length facts `shouldBe` 11
            map factVerdict facts `shouldBe` replicate 11 "Unverified"
            map factReason facts
                `shouldBe` replicate 11 (Just "NoVerifierConfigured")
            map factWitnessPresent facts `shouldBe` replicate 11 False
            map factBinding facts `shouldBe` replicate 11 Unbound
            Set.size (Set.fromList (map factSession facts)) `shouldBe` 1
            nextSessionNumber state `shouldBe` 1
            Set.null (openSessions state) `shouldBe` True

    it
        "pins one explicit source per acquisition and keeps later sources out of an earlier session"
        $ do
            TimeSource manifest genesis eras <- timeSource
            set <- recordedSet
            let runtime =
                    stateRuntimeIn
                        fst
                        (\providerState (_, sourceCount) -> (providerState, sourceCount))
                loader = do
                    number <- gets snd
                    modify'
                        (\(providerState, sourceCount) -> (providerState, sourceCount + 1))
                    pure
                        ( Right
                            ( TimeSource
                                manifest{timeSourceIdentity = Text.pack (show number)}
                                genesis
                                eras
                            )
                        )
                provider =
                    koiosProvider
                        runtime
                        (Network 1)
                        loader
                        (Client.Koios recordedConfig (recordedTransport set))
                readTimes session =
                    traverse
                        (const (fmap (fmap (networkMagic . value)) (networkTime session)))
                        [1 .. 3 :: Int]
                action = do
                    wrong <- acquire provider (Latest (Network 42)) (const (pure ()))
                    point <-
                        acquire provider (AtPoint (Network 1) Genesis) (const (pure ()))
                    first <- acquire provider (Latest (Network 1)) readTimes
                    second <- acquire provider (Latest (Network 1)) readTimes
                    pure (wrong, point, first, second)
                (result, (state, count)) = runState action (initialProviderState, 0 :: Int)
            persist "per-acquisition-pinned-time" $
                object
                    [ "result" .= show result
                    , "source_loads" .= count
                    , "events" .= map eventJson (providerEvents state)
                    ]
            result
                `shouldBe` ( Left (WrongNetwork (Network 1) (Network 42))
                           , Left (PointNotSupported Genesis)
                           , Right (replicate 3 (Right 1))
                           , Right (replicate 3 (Right 1))
                           )
            count `shouldBe` 2
            [ timeSourceIdentity actual
              | RawTime _ (TimeSource actual _ _) <- providerEvents state
              ]
                `shouldBe` ["0", "1"]
            Set.null (openSessions state) `shouldBe` True

    it
        "preserves an unreadable pinned source as a named time refusal and guards it after release"
        $ do
            let failure = BackendReadFailure "public pinned source is unreadable"
                client =
                    Client.Koios
                        recordedConfig
                        ( Client.Transport
                            (const (pure (Client.Exchange 1 (Left (Client.NoRecording "unused")))))
                        )
                provider = koiosProvider stateRuntime (Network 1) (pure (Left failure)) client
                action = do
                    acquired <- acquire provider (Latest (Network 1)) $ \session -> do
                        during <- fmap (fmap (const ())) (networkTime session)
                        pure (session, during)
                    case acquired of
                        Left refused -> pure (Left refused)
                        Right (session, during) -> do
                            releasedResult <- fmap (fmap (const ())) (networkTime session)
                            pure (Right (sessionId session, during, releasedResult))
                (result, state) = runState action initialProviderState
            persist "pinned-source-refusal" $
                object
                    [ "result" .= show result
                    , "events" .= map eventJson (providerEvents state)
                    ]
            case result of
                Right (identity, during, releasedResult) -> do
                    during `shouldBe` Left failure
                    releasedResult `shouldBe` Left (ReleasedSession identity)
                _ ->
                    expectationFailure
                        "source failure changed the acquisition or read refusal"
            [f | RawTimeFailure _ f <- providerEvents state] `shouldBe` [failure]
            [() | RawExchange _ _ _ <- providerEvents state] `shouldBe` []

    it
        "loads the reviewed packaged time bytes and requires an explicit private network source"
        $ do
            TimeSource expectedManifest expectedGenesis expectedEras <- timeSource
            actual <- loadPinnedSource 1 Nothing >>= requireRight
            let TimeSource manifest genesis eras = actual
            manifest `shouldBe` expectedManifest
            genesis `shouldBe` expectedGenesis
            eras `shouldBe` expectedEras
            absent <- loadPinnedSource 42 Nothing
            fmap (const ()) absent
                `shouldBe` Left (NetworkTimeRefusal (UnknownTimeNetwork 42))

    it
        "uses the same constructor in pure State, refuses released reads and binds raw time and parameters"
        $ do
            source <- timeSource
            set <- recordedSet
            let provider =
                    koiosProvider
                        stateRuntime
                        (Network 1)
                        (pure (Right source))
                        (Client.Koios recordedConfig (recordedTransport set))
                action = do
                    escaped <- acquire provider (Latest (Network 1)) $ \session -> do
                        sessionBinding session `seq` pure ()
                        void (protocolParameters session)
                        void (tipObservation session)
                        void (networkTime session)
                        pure session
                    case escaped of
                        Left failure -> pure (Left failure, Nothing)
                        Right session -> do
                            readAfter <- tipObservation session
                            pure (Right (), Just (fmap (const ()) readAfter))
                (result, state) = runState action initialProviderState
            persist
                "pure-state-lifecycle"
                ( object
                    [ "result" .= show result
                    , "open_sessions" .= Set.size (openSessions state)
                    , "events" .= map eventJson (providerEvents state)
                    ]
                )
            fst result `shouldBe` Right ()
            case snd result of
                Just (Left (ReleasedSession _)) -> pure ()
                _ -> expectationFailure "released read did not refuse"
            length [() | RawExchange _ _ _ <- providerEvents state] `shouldBe` 2
            length [() | RawTime _ _ <- providerEvents state] `shouldBe` 1
            Set.null (openSessions state) `shouldBe` True

    it "preserves exact output identity in every pure query form" $ do
        source <- timeSource
        let (parent, _, tokenOutput) = dependentPair True
            (funding, _, plainOutput) = dependentPair False
            token = (TxIn (keyOf parent) (TxIx 0), tokenOutput)
            plain = (TxIn (keyOf funding) (TxIx 0), plainOutput)
            client = outputClient [token, plain] [token] [parent, funding]
            provider = koiosProvider stateRuntime (Network 1) (pure (Right source)) client
            address = AtAddress payer
            holding = HoldingAsset asset
            reference = AtTxIn (fst token)
            queries =
                [ address
                , holding
                , reference
                , AnyOf (address NE.:| [holding, reference])
                , AllOf (address NE.:| [holding, reference])
                ]
            (result, state) =
                runState
                    ( acquire provider (Latest (Network 1)) $ \session -> traverse (fmap (fmap value) . outputs session) queries
                    )
                    initialProviderState
        persist
            "pure-exact-queries"
            ( object
                [ "result" .= show result
                , "events" .= map eventJson (providerEvents state)
                ]
            )
        result
            `shouldBe` Right
                ( map
                    Right
                    [ sortOn fst [token, plain]
                    , [token]
                    , [token]
                    , sortOn fst [token, plain]
                    , [token]
                    ]
                )
        Set.null (openSessions state) `shouldBe` True

    it "keeps policy identity when asset names are equal" $ do
        source <- timeSource
        let (parent, _, output) = dependentPair True
            token = (TxIn (keyOf parent) (TxIx 0), output)
            client = outputClient [token] [token] [parent]
            provider = koiosProvider stateRuntime (Network 1) (pure (Right source)) client
            otherAsset = (PolicyID (scriptHashOfByte 12), snd asset)
            wanted = HoldingAsset asset
            other = HoldingAsset otherAsset
            (result, state) =
                runState
                    ( acquire provider (Latest (Network 1)) $ \session ->
                        traverse
                            (fmap (fmap value) . outputs session)
                            [ other
                            , AnyOf (other NE.:| [wanted])
                            , AllOf (AtAddress payer NE.:| [other])
                            ]
                    )
                    initialProviderState
        result `shouldBe` Right [Right [], Right [token], Right []]
        Set.null (openSessions state) `shouldBe` True

    it
        "refuses conflicting references in direct and composed pure queries"
        $ do
            source <- timeSource
            let (parent, _, output) = dependentPair True
                reference = TxIn (keyOf parent) (TxIx 0)
                conflicting = output & valueTxOutL .~ MaryValue (Coin 123) (MultiAsset Map.empty)
                client =
                    outputClient
                        [(reference, output), (reference, conflicting)]
                        [(reference, output), (reference, conflicting)]
                        [parent]
                provider = koiosProvider stateRuntime (Network 1) (pure (Right source)) client
                queries =
                    [ AtAddress payer
                    , HoldingAsset asset
                    , AtTxIn reference
                    , AnyOf (AtAddress payer NE.:| [HoldingAsset asset])
                    , AllOf (AtAddress payer NE.:| [AtTxIn reference])
                    ]
                (result, state) =
                    runState
                        ( acquire provider (Latest (Network 1)) $ \session -> traverse (fmap (fmap value) . outputs session) queries
                        )
                        initialProviderState
            persist
                "pure-conflicting-queries"
                ( object
                    [ "result" .= show result
                    , "events" .= map eventJson (providerEvents state)
                    ]
                )
            result
                `shouldBe` Right
                    (replicate (length queries) (Left (ConflictingOutput reference)))

    it
        "refuses wrong networks and unsupported points before acquisition effects"
        $ do
            source <- timeSource
            set <- recordedSet
            let provider =
                    koiosProvider
                        stateRuntime
                        (Network 1)
                        (pure (Right source))
                        (Client.Koios recordedConfig (recordedTransport set))
                requests =
                    [ Latest (Network 42)
                    , AtPoint (Network 42) Genesis
                    , AtPoint (Network 1) Genesis
                    ]
                (result, state) =
                    runState
                        ( traverse
                            (\request -> acquire provider request (const (pure ())))
                            requests
                        )
                        initialProviderState
            result
                `shouldBe` [ Left (WrongNetwork (Network 1) (Network 42))
                           , Left (WrongNetwork (Network 1) (Network 42))
                           , Left (PointNotSupported Genesis)
                           ]
            nextSessionNumber state `shouldBe` 0
            length (providerEvents state) `shouldBe` 0

    it "refuses every released read and deferred history continuation" $ do
        source <- timeSource
        let (parent, child, output) = dependentPair True
            reference = TxIn (keyOf parent) (TxIx 0)
            client =
                synthetic
                    [(parent, []), (child, [(reference, output)])]
                    [keyOf child, keyOf parent]
            provider = koiosProvider stateRuntime (Network 1) (pure (Right source)) client
            action = do
                acquired <- acquire provider (Latest (Network 1)) $ \session -> do
                    stream <- history session asset (HistoryRange Nothing Nothing)
                    pure (session, stream)
                case acquired of
                    Right (session, Right stream) -> do
                        let voidFact readAction = fmap (fmap (const ())) readAction
                        releasedAnswers <-
                            sequence
                                [ voidFact (outputs session (AtAddress payer))
                                , voidFact (outputs session (HoldingAsset asset))
                                , voidFact (outputs session (AtTxIn reference))
                                , voidFact
                                    (outputs session (AnyOf (AtAddress payer NE.:| [HoldingAsset asset])))
                                , voidFact
                                    (outputs session (AllOf (AtAddress payer NE.:| [AtTxIn reference])))
                                , voidFact (protocolParameters session)
                                , voidFact (tipObservation session)
                                , voidFact (networkTime session)
                                , voidFact (scriptRegistered session (scriptHashOfByte 11))
                                ]
                        newStream <-
                            voidFact (history session asset (HistoryRange Nothing Nothing))
                        continued <- voidFact (nextBlock stream)
                        pure (Just (sessionId session, releasedAnswers, newStream, continued))
                    _ -> pure Nothing
            (result, state) = runState action initialProviderState
        case result of
            Just (identity, releasedAnswers, newStream, continued) -> do
                releasedAnswers
                    `shouldBe` replicate 9 (Left (ReleasedSession identity))
                newStream
                    `shouldBe` Left (HistoryReadFailure (ReleasedSession identity))
                continued
                    `shouldBe` Left (HistoryReadFailure (ReleasedSession identity))
            Nothing ->
                expectationFailure
                    "could not acquire history for the released-read control"
        Set.null (openSessions state) `shouldBe` True
        -- Acquiring the cursor fetches its first page. Released continuation
        -- refuses before fetching another page or reconstruction material.
        length [() | RawExchange _ _ _ <- providerEvents state] `shouldBe` 1

    it
        "polls exact output visibility past the finite horizon in pure State"
        $ do
            (manifest, genesis, eras, _) <- loadNetworkFixture "devnet"
            let source = TimeSource manifest genesis eras
                base = timeSystemStartMs manifest + 1000
                (target, _, _) = dependentPair True
                makeProvider visibleAt =
                    koiosProvider
                        ( stateRuntimeIn
                            (\(state, _, _) -> state)
                            (\state (_, now, bounds) -> (state, now, bounds))
                        )
                        (Network 42)
                        (pure (Right source))
                        (pollingClient target visibleAt (timeSystemStartMs manifest))
            forM_ [Just (base + 10000), Nothing] $ \visibleAt -> do
                let action =
                        Confirmation.confirmTransaction
                            (pollingRuntime base)
                            (makeProvider visibleAt)
                            (Network 42)
                            target
                    (result, (state, now, bounds)) = runState action (initialProviderState, base, [])
                persist
                    ( if visibleAt == Nothing
                        then "pure-poll-expired"
                        else "pure-poll-visible"
                    )
                    ( object
                        [ "result" .= show result
                        , "clock_ms" .= now
                        , "bounds_seconds" .= bounds
                        , "events" .= map eventJson (providerEvents state)
                        ]
                    )
                bounds `shouldBe` [30, 310]
                Set.null (openSessions state) `shouldBe` True
                case (visibleAt, result) of
                    (Just wantedAt, Right ()) -> now `shouldBe` wantedAt
                    (Nothing, Left (Confirmation.ConfirmationWaitFailure failure)) -> do
                        waitStage failure `shouldBe` SessionConfirmationWait
                        waitTxId failure `shouldBe` keyOf target
                        waitClosedAt failure `shouldBe` Just (base + 300000)
                        waitBound failure `shouldBe` 310
                    _ ->
                        expectationFailure
                            "bounded output visibility produced another outcome"
                nextSessionNumber state `shouldSatisfy` (> 2)
                [ Client.rawCall request
                  | RawExchange _ request _ <- providerEvents state
                  ]
                    `shouldSatisfy` all (/= Wire.CallTxStatus)

    it "retains the validated upper-bound start and uncapped margin" $ do
        (manifest, genesis, eras, _) <- loadNetworkFixture "devnet"
        let source = TimeSource manifest genesis eras
            base = timeSystemStartMs manifest + 1000
            (original, _, _) = dependentPair True
            target =
                original
                    & bodyTxL . vldtTxBodyL
                        .~ ValidityInterval SNothing (SJust (SlotNo 400))
            provider =
                koiosProvider
                    pollProviderRuntime
                    (Network 42)
                    (pure (Right source))
                    (pollingClient target Nothing (timeSystemStartMs manifest))
            (result, (state, now, bounds)) =
                runState
                    ( Confirmation.confirmTransaction
                        (pollingRuntime base)
                        provider
                        (Network 42)
                        target
                    )
                    (initialProviderState, base, [])
        persist "pure-upper-bound-expired" $
            object
                [ "result" .= show result
                , "clock_ms" .= now
                , "bounds_seconds" .= bounds
                , "events" .= map eventJson (providerEvents state)
                ]
        bounds `shouldBe` [30, 169]
        case result of
            Left (Confirmation.ConfirmationWaitFailure failure) -> do
                waitClosedAt failure
                    `shouldBe` Just (timeSystemStartMs manifest + 160000)
                waitBound failure `shouldBe` 169
                now `shouldBe` base + 160000
            _ ->
                expectationFailure
                    "the finite validity window did not end at its validated deadline"
        Set.null (openSessions state) `shouldBe` True

    it "refuses a ledger upper bound outside the horizon before polling" $ do
        (manifest, genesis, eras, _) <- loadNetworkFixture "devnet"
        let source = TimeSource manifest genesis eras
            base = timeSystemStartMs manifest + 1000
            upper = SlotNo 501
            (original, _, _) = dependentPair True
            target =
                original
                    & bodyTxL . vldtTxBodyL .~ ValidityInterval SNothing (SJust upper)
            provider =
                koiosProvider
                    pollProviderRuntime
                    (Network 42)
                    (pure (Right source))
                    (pollingClient target (Just base) (timeSystemStartMs manifest))
            (result, (state, now, bounds)) =
                runState
                    ( Confirmation.confirmTransaction
                        (pollingRuntime base)
                        provider
                        (Network 42)
                        target
                    )
                    (initialProviderState, base, [])
        persist "pure-upper-bound-refused" $
            object
                [ "result" .= show result
                , "events" .= map eventJson (providerEvents state)
                ]
        case result of
            Left (Confirmation.ConfirmationTimeFailure (SlotPastHorizon observed)) -> do
                observed `shouldBe` upper
            _ ->
                expectationFailure
                    "a ledger horizon refusal was weakened into a fallback"
        bounds `shouldBe` [30]
        now `shouldBe` base
        length [() | RawExchange _ _ _ <- providerEvents state] `shouldBe` 0
        nextSessionNumber state `shouldBe` 1
        Set.null (openSessions state) `shouldBe` True

    it
        "uses signed-only submission in pure State with network and verdict preservation"
        $ do
            source <- timeSource
            let expectedId = keyOf (signedTx signedTransaction)
                accepted = okJson [] (LBS.toStrict (encode (Wire.txIdHex expectedId)))
                refused = Client.Exchange 1 (Right (Client.Answer 400 [] "BadInputsUTxO"))
                unavailable = Client.Exchange 1 (Left (Client.NoRecording "unavailable submit"))
                run response =
                    let client = Client.Koios recordedConfig $ Client.Transport $ \request -> do
                            modify' (\(state, requests) -> (state, requests <> [request]))
                            pure response
                        provider =
                            koiosProvider
                                (stateRuntimeIn fst (\state (_, requests) -> (state, requests)))
                                (Network 1)
                                (pure (Right source))
                                client
                    in  runState
                            ( do
                                wrong <- submitTx provider (Network 42) signedTransaction
                                answer <- submitTx provider (Network 1) signedTransaction
                                pure (wrong, answer)
                            )
                            (initialProviderState, [])
            forM_
                [ ("accepted", accepted)
                , ("refused", refused)
                , ("unavailable", unavailable)
                ]
                $ \(name, response) -> do
                    let ((wrong, answer), (state, requests)) = run response
                    persist ("pure-submit-" <> name) $
                        object
                            [ "result" .= show answer
                            , "wrong_network" .= show wrong
                            , "signed_cbor_hex"
                                .= TE.decodeUtf8
                                    ( B16.encode
                                        (serialize' (eraProtVerHigh @ConwayEra) (signedTx signedTransaction))
                                    )
                            , "requests" .= map (show . Client.rawBody) requests
                            ]
                    wrong `shouldBe` SubmitWrongNetwork (Network 1) (Network 42)
                    case (name, answer) of
                        ("accepted", SubmitAccepted key) -> key `shouldBe` expectedId
                        ("refused", SubmitRefused reason) -> reason `shouldBe` "BadInputsUTxO"
                        ("unavailable", SubmitFailed reason) -> reason `shouldSatisfy` Text.isInfixOf "unavailable submit"
                        _ -> expectationFailure "the actual raw submit verdict changed class"
                    map Client.rawCall requests `shouldBe` [Wire.CallSubmitTx]
                    map Client.rawBody requests
                        `shouldBe` [ Wire.requestBody
                                        ( Wire.submitTxRequest
                                            (serialize' (eraProtVerHigh @ConwayEra) (signedTx signedTransaction))
                                        )
                                   ]
                    nextSessionNumber state `shouldBe` 0

    it
        "cancels a stalled constructor window read under the public IO confirmation bound"
        $ do
            source <- timeSource
            events <- newIORef []
            requests <- newIORef []
            released <- newIORef False
            runtime <-
                newIORuntime noPhaseLog (\event -> modifyIORef' events (<> [event]))
            let client = Client.Koios recordedConfig $ Client.Transport $ \request -> do
                    modifyIORef' requests (<> [request])
                    ( threadDelay 60000000
                            >> pure (Client.Exchange 1 (Left (Client.NoRecording "stalled tip")))
                        )
                        `finally` writeIORef released True
                provider = koiosProvider runtime (Network 1) (pure (Right source)) client
                (target, _, _) = dependentPair True
            result <-
                try
                    ( timeout
                        35000000
                        (Confirmation.awaitTransaction provider (Network 1) target)
                    )
            observations <- readIORef events
            seen <- readIORef requests
            wasReleased <- readIORef released
            persist "io-window-cancelled" $
                object
                    [ "result" .= show (result :: Either WaitFailure (Maybe ()))
                    , "raw_read_cancelled" .= wasReleased
                    , "requests" .= map (show . Client.rawCall) seen
                    , "events" .= map eventJson observations
                    ]
            case result of
                Left failure -> do
                    waitStage failure `shouldBe` SessionConfirmationWait
                    waitTxId failure `shouldBe` keyOf target
                    waitBound failure `shouldBe` 30
                    waitClosedAt failure `shouldBe` Nothing
                    waitElapsed failure
                        `shouldSatisfy` (\seconds -> seconds >= 29.9 && seconds < 35)
                _ ->
                    expectationFailure
                        "the public IO confirmation did not preserve its cancellation failure"
            wasReleased `shouldBe` True
            map Client.rawCall seen `shouldBe` [Wire.CallTip]
            length [() | SessionOpened _ _ <- observations] `shouldBe` 1
            length [() | SessionClosed _ <- observations] `shouldBe` 1

    it
        "reconciles every real constructor HTTP read, time and parameters with phase logging"
        $ do
            source <- timeSource
            set <- recordedSet
            withSystemTempDirectory "provider-log" $ \directory ->
                withFakeKoios (replayFixtures set) $ \url serverSeen -> do
                    events <- newIORef []
                    let logPath = directory </> "phases.jsonl"
                    runtime <-
                        newIORuntime
                            (phaseLogAt logPath)
                            (\event -> modifyIORef' events (<> [event]))
                    transport <- newHttpTransport (defaultHttpConfig url) >>= requireRight
                    let provider =
                            koiosProvider
                                runtime
                                (Network 1)
                                (pure (Right source))
                                (Client.Koios recordedConfig transport)
                    acquire
                        provider
                        (Latest (Network 1))
                        ( \session -> do
                            sessionBinding session `shouldBe` Unbound
                            params <- protocolParameters session >>= requireRight
                            case witness params of
                                Nothing -> pure ()
                                Just _ -> expectationFailure "concrete witness"
                            void (tipObservation session >>= requireRight)
                            timeContext <- networkTime session >>= requireRight
                            networkMagic (value timeContext) `shouldBe` 1
                        )
                        >>= requireRight
                    requests <- serverSeen
                    observations <- readIORef events
                    phaseBytes <- BS.readFile logPath
                    phases <- mapM decodeLine (BS8.lines phaseBytes)
                    persist
                        "constructor-live-read-log"
                        ( object
                            [ "events" .= map eventJson observations
                            , "server_requests" .= map seenJson requests
                            , "phase_bytes_sha256" .= bodySha256 phaseBytes
                            , "phases" .= phases
                            ]
                        )
                    let httpFacts =
                            [ (Client.rawPath request, response)
                            | RawExchange _ request response <- observations
                            ]
                    map fst httpFacts `shouldBe` map seenPath requests
                    length [() | RawTime _ _ <- observations] `shouldBe` 1
                    let queries =
                            [ name
                            | Object line <- phases
                            , Just (String "query") <- [KM.lookup "phase" line]
                            , Just (String name) <- [KM.lookup "query" line]
                            ]
                    sort queries
                        `shouldBe` sort (map (dropSlash . seenPath) requests <> ["network-time"])
                    length
                        [ ()
                        | Object line <- phases
                        , KM.lookup "phase" line == Just (String "view")
                        ]
                        `shouldBe` 1
                    length
                        [ ()
                        | Object line <- phases
                        , KM.lookup "phase" line == Just (String "view-release")
                        ]
                        `shouldBe` 1

    it
        "disabled phase logging preserves the real constructor's named refusal"
        $ do
            source <- timeSource
            let missing =
                    TxIn
                        (keyOf (let (parent, _, _) = dependentPair True in parent))
                        (TxIx 0)
                client =
                    Client.Koios
                        recordedConfig
                        ( Client.Transport
                            ( \_ ->
                                pure (Client.Exchange 1 (Left (Client.NoRecording "missing-query")))
                            )
                        )
            forM_ [False, True] $ \enabled -> withSystemTempDirectory "provider-refusal" $ \directory -> do
                runtime <-
                    newIORuntime
                        (if enabled then phaseLogAt (directory </> "phase.log") else noPhaseLog)
                        (const (pure ()))
                let provider = koiosProvider runtime (Network 1) (pure (Right source)) client
                result <-
                    acquire
                        provider
                        (Latest (Network 1))
                        (\session -> outputs session (AtTxIn missing))
                persist
                    (if enabled then "enabled-log-refusal" else "disabled-log-refusal")
                    ( object
                        [ "refusal" .= case result of
                            Right (Left failure) -> show failure
                            Left failure -> show failure
                            _ -> "unexpected success"
                        ]
                    )
                case result of
                    Right (Left (BackendReadFailure reason)) ->
                        reason
                            `shouldBe` Text.pack
                                ( show
                                    ( Client.ClientFailure
                                        Wire.CallTxInfo
                                        1
                                        (Client.NotRecorded "missing-query")
                                    )
                                )
                    _ ->
                        expectationFailure "missing recorded answer became an output success"

recordedConfig :: Client.ClientConfig
recordedConfig = Client.ClientConfig 20 10

recordedSet :: IO FixtureSet
recordedSet = loadFixtureSet "test/fixtures/koios/preprod" >>= requireRight

timeSource :: IO TimeSource
timeSource = do
    (manifest, genesis, historyBytes, _) <- loadNetworkFixture "preprod"
    pure (TimeSource manifest genesis historyBytes)

requireRight :: (Show e) => Either e a -> IO a
requireRight = either (fail . show) pure

decodeLine :: BS.ByteString -> IO Value
decodeLine = maybe (fail "phase is not JSON") pure . decodeStrict'

-- Optional audit artifact output belongs to the test harness. It retains
-- complete raw answers and the independent server/phase observations before
-- assertions, so a reached failing mutation retains its actual inputs too.
persist :: FilePath -> Value -> IO ()
persist name evidence =
    lookupEnv "SINGULAR_PROVIDER_CONTROL_EVIDENCE" >>= \case
        Nothing -> pure ()
        Just directory -> do
            createDirectoryIfMissing True directory
            let path = directory </> name <> ".json"
            exists <- doesFileExist path
            if exists
                then fail "refusing to overwrite provider control evidence"
                else LBS.writeFile path (encode evidence)

eventJson :: ProviderEvent -> Value
eventJson = \case
    SessionOpened (SessionId identity) network ->
        object
            [ "kind" .= ("acquire" :: Text)
            , "session" .= identity
            , "network" .= show network
            , "binding" .= ("Unbound" :: Text)
            ]
    SessionClosed (SessionId identity) -> object ["kind" .= ("release" :: Text), "session" .= identity]
    RawTime
        (SessionId identity)
        (TimeSource manifest genesis historyBytes) ->
            object
                [ "kind" .= ("raw-time" :: Text)
                , "session" .= identity
                , "manifest" .= show manifest
                , "genesis_hex" .= TE.decodeUtf8 (B16.encode genesis)
                , "era_history_hex" .= TE.decodeUtf8 (B16.encode historyBytes)
                ]
    RawTimeFailure (SessionId identity) failure ->
        object
            [ "kind" .= ("raw-time-refusal" :: Text)
            , "session" .= identity
            , "refusal" .= show failure
            ]
    RawExchange (SessionId identity) request exchange ->
        let response = case Client.exchangeResult exchange of
                Left failure -> object ["no_answer" .= show failure]
                Right answer ->
                    maybe
                        (error "could not retain encoded raw fixture")
                        id
                        ( decodeStrict'
                            ( LBS.toStrict
                                ( encodeFixture
                                    ( Fixture
                                        (fixtureRequestOf request)
                                        "control observation"
                                        (UTCTime (fromGregorian 2026 10 5) 0)
                                        (bodySha256 (Client.answerBody answer))
                                        answer
                                    )
                                )
                            )
                        )
        in  object
                [ "kind" .= ("raw-exchange" :: Text)
                , "session" .= identity
                , "attempts" .= Client.exchangeAttempts exchange
                , "fixture" .= response
                ]

seenJson :: Seen -> Value
seenJson seen =
    object
        [ "method" .= seenMethod seen
        , "path" .= seenPath seen
        , "query" .= seenQuery seen
        , "headers" .= filter ((/= "authorization") . fst) (seenHeaders seen)
        , "body_hex" .= TE.decodeUtf8 (B16.encode (seenBody seen))
        , "arrival" .= seenAt seen
        ]

dropSlash :: Text -> Text
dropSlash = TE.decodeUtf8 . BS.dropWhile (== 47) . TE.encodeUtf8

asset :: Asset
asset = (PolicyID (scriptHashOfByte 11), AssetName "state")

keyOf :: ConwayTx -> TxId
keyOf tx = txIdTxBody (tx ^. bodyTxL)

-- Synthetic raw material: real ledger CBOR and hashes, with resolved inputs
-- derived from those bodies. These do not claim ledger admission or scripts.
dependentPair :: Bool -> (ConwayTx, ConwayTx, TxOut ConwayEra)
dependentPair carrying = choose [1 .. 10000]
  where
    tokenValue =
        MultiAsset (Map.singleton (fst asset) (Map.singleton (snd asset) 1))
    parentOutput =
        mkBasicTxOut
            payer
            ( MaryValue
                (Coin 5000000)
                (if carrying then tokenValue else MultiAsset Map.empty)
            )
    childOutput = mkBasicTxOut payer (MaryValue (Coin 4000000) tokenValue)
    pair salt =
        let parent =
                mkBasicTx
                    ( mkBasicTxBody
                        & outputsTxBodyL .~ Seq.singleton parentOutput
                        & feeTxBodyL .~ Coin salt
                    )
            child =
                mkBasicTx
                    ( mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton (TxIn (keyOf parent) (TxIx 0))
                        & outputsTxBodyL .~ Seq.singleton childOutput
                    )
        in  (parent, child, parentOutput)
    choose [] = error "could not construct opposite hash order"
    choose (salt : rest) =
        let candidate@(parent, child, _) = pair salt
        in  if Wire.txIdHex (keyOf child) < Wire.txIdHex (keyOf parent)
                then candidate
                else choose rest

runHistory
    :: TimeSource
    -> Client.Koios (State ProviderState)
    -> (Either HistoryFailure [TxId], ProviderState)
runHistory source client = runHistoryRange source client (HistoryRange Nothing Nothing)

runHistoryRange
    :: TimeSource
    -> Client.Koios (State ProviderState)
    -> HistoryRange
    -> (Either HistoryFailure [TxId], ProviderState)
runHistoryRange source client range = runState action initialProviderState
  where
    provider = koiosProvider stateRuntime (Network 1) (pure (Right source)) client
    consume stream =
        nextBlock stream >>= \case
            Left failure -> pure (Left failure)
            Right Nothing -> pure (Right [])
            Right (Just (block, rest)) ->
                fmap
                    (fmap (map historicalId (NE.toList (blockTransactions block)) <>))
                    (consume rest)
    action = do
        result <- acquire provider (Latest (Network 1)) $ \session ->
            history session asset range >>= \case
                Left failure -> pure (Left failure)
                Right stream -> consume stream

        pure
            ( either
                ( Left
                    . HistoryReadFailure
                    . BackendReadFailure
                    . TE.decodeUtf8
                    . LBS.toStrict
                    . encode
                    . show
                )
                id
                result
            )

synthetic
    :: (Monad m) => [(ConwayTx, Outputs)] -> [TxId] -> Client.Koios m
synthetic = syntheticAt []

syntheticAt
    :: (Monad m)
    => [Word64]
    -> [(ConwayTx, Outputs)]
    -> [TxId]
    -> Client.Koios m
syntheticAt heights transactions listed =
    Client.Koios (Client.ClientConfig 1 20) (recordedTransport fixtures)
  where
    -- Synthetic recordings are explicit, with bytes derived independently
    -- from complete ledger bodies. They use the shipping Recorded transport
    -- and single Wire decoder, and never assert on-chain admission.
    fixtures = FixtureSet "synthetic Koios 1.4.2 control" (map recorded requests)
    requests =
        [ (Client.rawRequest (uncurry Wire.assetTxsRequest asset))
            { Client.rawQuery =
                Wire.requestQuery (uncurry Wire.assetTxsRequest asset)
                    <> [ ("order", "block_height.asc,tx_hash.asc")
                       , ("offset", Text.pack (show index))
                       , ("limit", "1")
                       ]
            }
        | index <- [0 .. max 0 (length listed - 1)]
        ]
            <> [Client.rawRequest (Wire.txInfoRequest keys) | keys <- selections]
            <> [Client.rawRequest (Wire.txCborRequest keys) | keys <- selections]
    selections =
        concatMap
            permutations
            (filter (not . null) (subsequences (map (keyOf . fst) transactions)))
    recorded request = case answer request of
        Client.Exchange _ (Right response) ->
            Fixture
                (fixtureRequestOf request)
                "synthetic Koios 1.4.2 control"
                (UTCTime (fromGregorian 2026 10 5) 0)
                (bodySha256 (Client.answerBody response))
                response
        _ -> error "synthetic recording generator has no answer"
    heightOf key =
        Map.findWithDefault 20 key $
            Map.fromList
                (zip (map (keyOf . fst) transactions) heights)
    ordered = sortOn (\key -> (heightOf key, Wire.txIdHex key)) listed
    answer request = case Client.rawCall request of
        Wire.CallAssetTxs ->
            pageAnswer
                [ assetTxRow (Wire.txIdHex key) 500 (toInteger (heightOf key))
                | key <- ordered
                ]
                (offset request)
                1
        Wire.CallTxInfo ->
            okJson
                []
                ( jsonBytes
                    [ amendRow
                        (keyOf tx)
                        "block_height"
                        (toJSON (heightOf (keyOf tx)))
                        (infoRow tx inputs)
                    | (tx, inputs) <- transactions
                    , Wire.txIdHex (keyOf tx) `elem` asked request
                    ]
                )
        Wire.CallTxCbor ->
            okJson
                []
                ( jsonBytes
                    [ object
                        [ "tx_hash" .= Wire.txIdHex (keyOf tx)
                        , "cbor"
                            .= TE.decodeUtf8 (B16.encode (serialize' (eraProtVerHigh @ConwayEra) tx))
                        , "valid_contract" .= let IsValid valid = tx ^. isValidTxL in valid
                        ]
                    | (tx, _) <- transactions
                    , Wire.txIdHex (keyOf tx) `elem` asked request
                    ]
                )
        _ ->
            Client.Exchange
                1
                ( Left
                    (Client.NoRecording "synthetic history has no unrelated endpoint")
                )
    offset request = maybe 0 (read . Text.unpack) (queryParam "offset" request)

-- Synthetic query answers retain independently constructed outputs, including
-- deliberately conflicting identities. The production decoder sees raw JSON.
outputClient
    :: Outputs -> Outputs -> [ConwayTx] -> Client.Koios (State ProviderState)
outputClient addressOutputs assetOutputs producers =
    Client.Koios
        recordedConfig
        ( recordedTransport
            (FixtureSet "synthetic exact-output control" fixtures)
        )
  where
    page request =
        let raw = Client.rawRequest request
        in  raw
                { Client.rawQuery =
                    Client.rawQuery raw
                        <> [ ("order", "tx_hash.asc,tx_index.asc")
                           , ("offset", "0")
                           , ("limit", "20")
                           ]
                }
    addressRow pair = case outputRow pair of
        Object row ->
            Object (KM.insert "address" (String (Wire.renderAddress payer)) row)
        _ -> error "output row is not an object"
    answers =
        [
            ( page (Wire.addressUtxosRequest [payer])
            , pageAnswer (map addressRow addressOutputs) 0 20
            )
        ,
            ( page (Wire.assetUtxosRequest [asset])
            , pageAnswer (map addressRow assetOutputs) 0 20
            )
        ,
            ( page
                (Wire.assetUtxosRequest [(PolicyID (scriptHashOfByte 12), snd asset)])
            , pageAnswer [] 0 20
            )
        ]
            <> [ ( Client.rawRequest (Wire.txInfoRequest [keyOf tx])
                 , okJson [] (jsonBytes [infoRow tx []])
                 )
               | tx <- producers
               ]
    fixtures =
        [ Fixture
            (fixtureRequestOf request)
            "synthetic exact-output control"
            (UTCTime (fromGregorian 2026 10 5) 0)
            (bodySha256 (Client.answerBody answer))
            answer
        | (request, Client.Exchange _ (Right answer)) <- answers
        ]

type PollState = (ProviderState, Integer, [Int])

pollProviderRuntime :: ProviderRuntime (State PollState)
pollProviderRuntime =
    stateRuntimeIn
        (\(state, _, _) -> state)
        (\state (_, now, bounds) -> (state, now, bounds))

-- A logical clock and bounds interpreter; no real sleep or external State
-- effects. The IO cancellation boundary is checked separately.
pollingRuntime
    :: Integer -> Confirmation.ConfirmationRuntime (State PollState)
pollingRuntime origin =
    Confirmation.ConfirmationRuntime
        { Confirmation.currentPosixMs = gets (\(_, now, _) -> now)
        , Confirmation.attemptWindowRead = fmap Right
        , Confirmation.pausePolling = \seconds ->
            modify'
                ( \(state, now, bounds) -> (state, now + toInteger seconds * 1000, bounds)
                )
        , Confirmation.boundedConfirmation = \tid bound action -> do
            started <- gets (\(_, now, _) -> now)
            modify' (\(state, now, bounds) -> (state, now, bounds <> [bound]))
            outcome <- action
            ended <- gets (\(_, now, _) -> now)
            let failure closedAt =
                    WaitFailure
                        SessionConfirmationWait
                        tid
                        (fromInteger (ended - origin) / 1000)
                        bound
                        closedAt
            pure $ case outcome of
                Left deadline -> Left (failure (Just deadline))
                Right answer
                    | ended - started >= toInteger bound * 1000 -> Left (failure Nothing)
                    | otherwise -> Right answer
        }

-- Synthetic time-dependent raw responses pass through the actual shared
-- client/Wire and shipping constructor. An unrelated output is visible first.
pollingClient
    :: ConwayTx -> Maybe Integer -> Integer -> Client.Koios (State PollState)
pollingClient target visibleAt genesisMs = Client.Koios recordedConfig (Client.Transport answer)
  where
    reference = TxIn (keyOf target) (TxIx 0)
    output = case toList (target ^. bodyTxL . outputsTxBodyL) of
        first : _ -> first
        [] -> error "empty polling control body"
    (other, _, otherOutput) = dependentPair False
    row pair = case outputRow pair of
        Object fields ->
            Object
                (KM.insert "address" (String (Wire.renderAddress payer)) fields)
        _ -> error "output row is not an object"
    answer request = do
        now <- gets (\(_, clock, _) -> clock)
        pure $ case Client.rawCall request of
            Wire.CallTip ->
                okJson
                    []
                    ( jsonBytes
                        [ object
                            [ "abs_slot" .= ((now - genesisMs) `div` 100)
                            , "hash" .= Text.replicate 32 "ab"
                            , "block_height" .= (1 :: Int)
                            , "epoch_no" .= (0 :: Int)
                            , "block_time" .= (now `div` 1000)
                            ]
                        ]
                    )
            Wire.CallTxInfo -> okJson [] (jsonBytes [infoRow target []])
            Wire.CallAddressUtxos ->
                pageAnswer
                    [ row pair
                    | pair <-
                        (TxIn (keyOf other) (TxIx 0), otherOutput)
                            : [(reference, output) | maybe False (now >=) visibleAt]
                    ]
                    0
                    20
            _ ->
                Client.Exchange
                    1
                    (Left (Client.NoRecording "unexpected polling endpoint"))

asked :: Client.RawRequest -> [Text]
asked request = case Client.rawBody request of
    Wire.JsonBody (Object body) -> case KM.lookup "_tx_hashes" body of
        Just (Array keys) -> [key | String key <- toList keys]
        _ -> []
    _ -> []

jsonBytes :: [Value] -> BS.ByteString
jsonBytes = LBS.toStrict . encode

infoRow :: ConwayTx -> Outputs -> Value
infoRow tx inputs =
    object
        [ "tx_hash" .= Wire.txIdHex (keyOf tx)
        , "block_height" .= (20 :: Int)
        , "inputs" .= map outputRow inputs
        , "reference_inputs" .= ([] :: [Value])
        , "outputs"
            .= zipWith
                (\index output -> outputRow (TxIn (keyOf tx) (TxIx index), output))
                [0 ..]
                (toList (tx ^. bodyTxL . outputsTxBodyL))
        , "valid_contract" .= let IsValid valid = tx ^. isValidTxL in valid
        ]

outputRow :: (TxIn, TxOut ConwayEra) -> Value
outputRow (TxIn key (TxIx index), output) =
    let MaryValue (Coin lovelace) (MultiAsset assets) = output ^. valueTxOutL
    in  object
            [ "tx_hash" .= Wire.txIdHex key
            , "tx_index" .= index
            , "payment_addr" .= object ["bech32" .= Wire.renderAddress payer]
            , "value" .= show lovelace
            , "asset_list"
                .= [ object
                        [ "policy_id" .= Wire.policyHex policy
                        , "asset_name" .= Wire.assetNameHex name
                        , "quantity" .= show quantity
                        ]
                   | (policy, names) <- Map.toList assets
                   , (name, quantity) <- Map.toList names
                   ]
            ]

-- Changes here are explicit synthetic raw-source faults, never an override
-- of decoded facts or of the constructor's invariant decision.
amendHistory
    :: Wire.Call
    -> ([Value] -> [Value])
    -> Client.Koios (State ProviderState)
    -> Client.Koios (State ProviderState)
amendHistory call amend client =
    client
        { Client.koiosTransport = Client.Transport $ \request -> do
            response <- Client.exchange (Client.koiosTransport client) request
            pure $
                if Client.rawCall request /= call
                    then response
                    else
                        response
                            { Client.exchangeResult = fmap change (Client.exchangeResult response)
                            }
        }
  where
    change answer = case decodeStrict' (Client.answerBody answer) of
        Just rows -> answer{Client.answerBody = jsonBytes (amend rows)}
        Nothing -> error "synthetic history response is not a JSON row list"

amendRow :: TxId -> AesonKey.Key -> Value -> Value -> Value
amendRow key field replacement (Object fields)
    | KM.lookup "tx_hash" fields == Just (String (Wire.txIdHex key)) =
        Object (KM.insert field replacement fields)
amendRow _ _ _ row = row

retainHistory
    :: FilePath -> Either HistoryFailure [TxId] -> ProviderState -> IO ()
retainHistory name result state =
    persist name $
        object
            [ "result" .= show result
            , "events" .= map eventJson (providerEvents state)
            ]
