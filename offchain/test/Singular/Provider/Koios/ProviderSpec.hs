{-# LANGUAGE LambdaCase #-}

module Singular.Provider.Koios.ProviderSpec (spec) where

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core
    ( eraProtVerHigh
    , mkBasicTx
    , mkBasicTxBody
    , txIdTxBody
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad (forM_, void)
import Control.Monad.State.Strict (State, runState)
import Data.Aeson (Value (..), decodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (permutations, sort, sortOn, subsequences)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime (..), fromGregorian)
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
    )
import Singular.Provider.Koios.State
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.Evidence
    ( Evidenced (..)
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime (networkMagic)
import Singular.Registry.NetworkTimeSpec (loadNetworkFixture)
import Singular.Registry.PhaseLog (noPhaseLog, phaseLogAt)
import Singular.Registry.TxBuilder.BookingFixture (payer)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
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

    it
        "uses the same constructor in pure State, refuses released reads and binds raw time and parameters"
        $ do
            source <- timeSource
            set <- recordedSet
            let provider =
                    koiosProvider
                        stateRuntime
                        (Network 1)
                        source
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
                                source
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
                let provider = koiosProvider runtime (Network 1) source client
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
runHistory source client = runState action initialProviderState
  where
    provider = koiosProvider stateRuntime (Network 1) source client
    action = do
        result <- acquire provider (Latest (Network 1)) $ \session ->
            history session asset (HistoryRange Nothing Nothing) >>= \case
                Left failure -> pure (Left failure)
                Right stream ->
                    nextBlock stream >>= \case
                        Left failure -> pure (Left failure)
                        Right Nothing -> pure (Right [])
                        Right (Just (block, _)) ->
                            pure (Right (map historicalId (NE.toList (blockTransactions block))))
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
    :: [(ConwayTx, Outputs)] -> [TxId] -> Client.Koios (State ProviderState)
synthetic transactions listed =
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
    ordered = sortOn Wire.txIdHex listed
    answer request = case Client.rawCall request of
        Wire.CallAssetTxs ->
            pageAnswer
                [assetTxRow (Wire.txIdHex key) 500 20 | key <- ordered]
                (offset request)
                1
        Wire.CallTxInfo ->
            okJson
                []
                ( jsonBytes
                    [ infoRow tx inputs
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
                        , "valid_contract" .= True
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
        , "valid_contract" .= True
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
