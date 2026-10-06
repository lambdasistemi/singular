{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.NetworkTimeSpec
Description : Source-bound time comparisons and content/rounding faults
License     : Apache-2.0
-}
module Singular.Registry.NetworkTimeSpec (spec, loadNetworkFixture) where

import Cardano.Ledger.Api.PParams (ppProtocolVersionL)
import Cardano.Ledger.BaseTypes (ProtVer (..))
import Cardano.Ledger.Binary (DecoderError, decodeFull', getVersion)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, eraProtVerLow)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Slotting.Time (RelativeTime (..), getSlotLength)
import Codec.Serialise
    ( DeserialiseFailure
    , deserialiseOrFail
    , serialise
    )
import Control.Applicative ((<|>))
import Control.Monad (forM_, unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeStrict'
    , withObject
    , (.:)
    )
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Lens.Micro ((^.))
import Ouroboros.Consensus.HardFork.History.EraParams (EraParams (..))
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraSummary (..)
    )
import Paths_singular_registry (getDataFileName)
import Singular.Registry.NetworkTime
import Singular.Registry.TimeMaterial
    ( TimeMaterial (..)
    , loadTimeMaterial
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldNotBe
    , shouldSatisfy
    , shouldThrow
    )

data TimeRow = TimeRow Integer NodeAnswer NodeAnswer
data NodeAnswer = NodeSlot SlotNo | NodeRefusal String
    deriving stock (Eq, Show)
data Fixture
    = Fixture
        NetworkTimeManifest
        ByteString
        ByteString
        ByteString
        ByteString
data StartRow = StartRow SlotNo (Either String Integer)
data SourceFile = SourceFile FilePath ByteString
newtype SourceManifest = SourceManifest [SourceFile]

instance FromJSON StartRow where
    parseJSON = withObject "recorded node slot start" $ \value ->
        StartRow . SlotNo
            <$> value .: "slot"
            <*> ( value .: "start"
                    >>= withObject
                        "start answer"
                        ( \answer ->
                            (Right <$> answer .: "posixMs") <|> (Left <$> answer .: "refused")
                        )
                )

instance FromJSON SourceFile where
    parseJSON = withObject "reviewed or generated source file" $ \value ->
        SourceFile <$> value .: "path" <*> (value .: "sha256" >>= hex)
      where
        hex = either fail pure . B16.decode . encodeUtf8

instance FromJSON SourceManifest where
    parseJSON = withObject "network source manifest" $ \value ->
        SourceManifest <$> value .: "files"

instance FromJSON NodeAnswer where
    parseJSON = withObject "recorded node time answer" $ \value ->
        (NodeSlot . SlotNo <$> value .: "slot")
            <|> (NodeRefusal <$> value .: "refused")

instance FromJSON TimeRow where
    parseJSON = withObject "recorded node time row" $ \value ->
        TimeRow
            <$> value .: "posixMs"
            <*> value .: "floor"
            <*> value .: "ceiling"

instance FromJSON Fixture where
    parseJSON = withObject "trusted network time fixture" $ \value -> do
        magic <- value .: "networkMagic"
        start <- value .: "systemStartMs"
        genesisHash <- value .: "genesisSha256" >>= hex
        historyHash <- value .: "eraHistorySha256" >>= hex
        horizon <- SlotNo <$> value .: "horizonSlot"
        major <- value .: "protocolMajor"
        source <- value .: "sourceIdentity"
        answerHash <- value .: "nodeAnswerSha256" >>= hex
        startHash <- value .: "nodeSlotStartSha256" >>= hex
        sourceHash <- value .: "nodeSourceSha256" >>= hex
        manifestHash <- value .: "sourceManifestSha256" >>= hex
        pure
            ( Fixture
                ( NetworkTimeManifest
                    magic
                    start
                    genesisHash
                    historyHash
                    horizon
                    major
                    source
                )
                answerHash
                startHash
                sourceHash
                manifestHash
            )
      where
        hex = either fail pure . B16.decode . encodeUtf8

readFixture :: FilePath -> FilePath -> IO ByteString
readFixture network name =
    getDataFileName ("data/network/" <> network <> "/" <> name)
        >>= BS.readFile

loadFixture
    :: IO (NetworkTimeManifest, ByteString, ByteString, [TimeRow])
loadFixture = loadNetworkFixture "preprod"

loadNetworkFixture
    :: FilePath
    -> IO (NetworkTimeManifest, ByteString, ByteString, [TimeRow])
loadNetworkFixture network = do
    Fixture
        manifest
        expectedAnswers
        expectedStarts
        expectedSource
        expectedManifest <-
        readFixture network "time-manifest.json" >>= decode
    genesis <- readFixture network "shelley-genesis.json"
    history <- readFixture network "era-history.cbor"
    parameterBytes <-
        readFixture network $
            if network == "preprod"
                then "evaluation/protocol-parameters.cbor"
                else "protocol-parameters.cbor"
    pp <-
        either
            (fail . show)
            pure
            ( decodeFull' (eraProtVerLow @ConwayEra) parameterBytes
                :: Either DecoderError (PParams ConwayEra)
            )
    timeProtocolMajor manifest
        `shouldBe` getVersion (pvMajor (pp ^. ppProtocolVersionL))
    answerBytes <- readFixture network "node-time-answers.json"
    startBytes <- readFixture network "node-slot-starts.json"
    sourceBytes <- readFixture network "node-source.json"
    manifestBytes <- readFixture network "manifest.json"
    forM_
        [ (expectedStarts, startBytes)
        , (expectedSource, sourceBytes)
        , (expectedManifest, manifestBytes)
        ]
        $ \(expected, actual) ->
            unless
                (expected == convert (hash actual :: Digest SHA256))
                (fail "RecordedTimeSourceHashMismatch")
    SourceManifest files <- decode manifestBytes
    unless (length files > 1) (fail "EmptyNetworkSourceExtent")
    forM_ files $ \(SourceFile path expected) -> do
        unless
            (not (null path) && all (`notElem` path) ['/', '\\'])
            (fail "InvalidNetworkSourcePath")
        actual <- readFixture network path
        unless
            (expected == convert (hash actual :: Digest SHA256))
            (fail "NetworkSourceFileHashMismatch")
    unless
        (expectedAnswers == convert (hash answerBytes :: Digest SHA256))
        (fail "RecordedNodeAnswerHashMismatch")
    rows <- decode answerBytes
    unless (length rows > 1) (fail "EmptyOrTruncatedNodeTimeExtent")
    pure (manifest, genesis, history, rows)
  where
    decode :: (FromJSON a) => ByteString -> IO a
    decode = either fail pure . eitherDecodeStrict'

matches :: NodeAnswer -> Either NetworkTimeFailure SlotNo -> Bool
matches (NodeSlot expected) actual = actual == Right expected
matches (NodeRefusal reason) actual =
    "PastHorizon" `Text.isInfixOf` Text.pack reason
        && case actual of
            Left (TimePastHorizon _) -> True
            _ -> False

-- Keep captured node refusals as history. NOTE030 changes the conversion
-- expectation there; extrapolate independently from the raw final era.
recordedRows
    :: NetworkTime -> NetworkTimeManifest -> ByteString -> [TimeRow] -> IO ()
recordedRows context manifest history rows = do
    eras <-
        either
            (fail . show)
            pure
            ( deserialiseOrFail (LBS.fromStrict history)
                :: Either DeserialiseFailure [EraSummary]
            )
    finalEra <- case reverse eras of
        era : _ -> pure era
        [] -> fail "EmptyRecordedHistory"
    let begin = eraStart finalEra
        startMs =
            fromInteger (timeSystemStartMs manifest)
                + getRelativeTime (boundTime begin) * 1000
        slotMs = getSlotLength (eraSlotLength (eraParams finalEra)) * 1000
        expected roundSlot ms =
            boundSlot begin
                + fromInteger (roundSlot ((fromInteger ms - startMs) / slotMs))
        check conversion roundSlot ms answer
            | ms < timeSystemStartMs manifest =
                conversion context ms `shouldBe` Left (TimeBeforeHistory ms)
            | otherwise = case answer of
                NodeSlot slot -> conversion context ms `shouldBe` Right slot
                NodeRefusal reason -> do
                    reason `shouldSatisfy` (Text.isInfixOf "PastHorizon" . Text.pack)
                    conversion context ms `shouldBe` Right (expected roundSlot ms)
    forM_ rows $ \(TimeRow ms floorAnswer ceilAnswer) -> do
        check posixMsFloorSlot floor ms floorAnswer
        check posixMsCeilingSlot ceiling ms ceilAnswer

spec :: Spec
spec = describe "Validity conversions from recorded preprod network data" $ do
    it
        "caps at the moving ledger horizon and refuses wholly past or empty exclusive windows"
        $ do
            (manifest, genesis, history, _) <- loadNetworkFixture "devnet"
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime 42 manifest genesis history)
            -- k=10 and f=1 in the authenticated recorded genesis; epoch size 500.
            -- These cases also distinguish ceiling from adding a whole extra epoch.
            ledgerHorizon context (SlotNo 868) `shouldBe` Right (SlotNo 1000)
            ledgerHorizon context (SlotNo 470) `shouldBe` Right (SlotNo 500)
            ledgerHorizon context (SlotNo 471) `shouldBe` Right (SlotNo 1000)
            forM_ [868, 869] $ \upper ->
                capValidityUpper context (SlotNo 868) Nothing (SlotNo upper)
                    `shouldBe` Left
                        ( WindowPastLedgerHorizon
                            (SlotNo 868)
                            (SlotNo 1000)
                            Nothing
                            (SlotNo upper)
                        )
            capValidityUpper context (SlotNo 868) Nothing (SlotNo 999)
                `shouldBe` Right (SlotNo 999)
            capValidityUpper
                context
                (SlotNo 868)
                (Just (SlotNo 868))
                (SlotNo 1113)
                `shouldBe` Right (SlotNo 999)
            capValidityUpper
                context
                (SlotNo 868)
                (Just (SlotNo 1001))
                (SlotNo 1113)
                `shouldBe` Left
                    ( WindowPastLedgerHorizon
                        (SlotNo 868)
                        (SlotNo 1000)
                        (Just (SlotNo 1001))
                        (SlotNo 1113)
                    )
            capValidityUpper
                context
                (SlotNo 868)
                (Just (SlotNo 999))
                (SlotNo 1113)
                `shouldBe` Left
                    ( WindowPastLedgerHorizon
                        (SlotNo 868)
                        (SlotNo 1000)
                        (Just (SlotNo 999))
                        (SlotNo 1113)
                    )
            capValidityUpper context (SlotNo 868) (Just (SlotNo 868)) (SlotNo 868)
                `shouldBe` Left
                    ( WindowPastLedgerHorizon
                        (SlotNo 868)
                        (SlotNo 1000)
                        (Just (SlotNo 868))
                        (SlotNo 868)
                    )
    it
        "keeps a preprod-shaped 120-second window below the moving ledger horizon"
        $ do
            (manifest, genesis, history, _) <- loadNetworkFixture "preprod"
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime 1 manifest genesis history)
            let tip = SlotNo 120_000_000
                upper = tip + 120
            capValidityUpper context tip (Just tip) upper `shouldBe` Right upper
            horizon <- either (fail . show) pure (ledgerHorizon context tip)
            horizon `shouldSatisfy` (>= tip + 129_600)
    it "keeps horizon1000 at970 and advances to1500 at971" $ do
        (manifest, genesis, history, _) <- loadNetworkFixture "devnet"
        context <-
            either
                (fail . show)
                pure
                (validateNetworkTime 42 manifest genesis history)
        ledgerHorizon context (SlotNo 970) `shouldBe` Right (SlotNo 1000)
        ledgerHorizon context (SlotNo 971) `shouldBe` Right (SlotNo 1500)
        minimumValidityWindow context (SlotNo 970) Nothing (SlotNo 1250)
            `shouldBe` Right (ValidityWindow (SlotNo 1000) (SlotNo 999) 100 True)
        minimumValidityWindow context (SlotNo 971) Nothing (SlotNo 1250)
            `shouldBe` Right (ValidityWindow (SlotNo 1500) (SlotNo 1250) 100 False)
    it
        "keeps empty refusal first and refuses short registry and exact horizon windows"
        $ do
            (manifest, genesis, history, _) <- loadNetworkFixture "devnet"
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime 42 manifest genesis history)
            minimumValidityWindow context (SlotNo 917) Nothing (SlotNo 918)
                `shouldBe` Left
                    ( WindowPastLedgerHorizon
                        (SlotNo 917)
                        (SlotNo 1000)
                        Nothing
                        (SlotNo 918)
                    )
            forM_ [999, 1000] $ \upper ->
                minimumValidityWindow context (SlotNo 917) Nothing (SlotNo upper)
                    `shouldBe` Left
                        (WindowTooShort (SlotNo 917) (SlotNo 1000) Nothing (SlotNo upper) 100)
            minimumValidityWindow context (SlotNo 899) Nothing (SlotNo 1000)
                `shouldBe` Left
                    (WindowTooShort (SlotNo 899) (SlotNo 1000) Nothing (SlotNo 1000) 100)
    it
        "uses10slots on pinned preprod and never waits in its ordinary120slot window"
        $ do
            (manifest, genesis, history, _) <- loadNetworkFixture "preprod"
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime 1 manifest genesis history)
            let tip = SlotNo 120_000_000
            result <-
                either
                    (fail . show)
                    pure
                    (minimumValidityWindow context tip Nothing (tip + 120))
            validityMinimumSlots result `shouldBe` 10
            validityNeedsHorizonWait result `shouldBe` False
            validitySelectedUpper result `shouldBe` tip + 120
    it
        "refuses before the pinned history start and accepts its exact start"
        $ forM_ [("devnet", 42), ("preprod", 1)]
        $ \(network, magic) -> do
            (manifest, genesis, history, _) <- loadNetworkFixture network
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime magic manifest genesis history)
            let start = timeSystemStartMs manifest
            posixMsFloorSlot context (start - 1)
                `shouldBe` Left (TimeBeforeHistory (start - 1))
            posixMsCeilingSlot context (start - 1)
                `shouldBe` Left (TimeBeforeHistory (start - 1))
            posixMsFloorSlot context start `shouldBe` Right (SlotNo 0)
            posixMsCeilingSlot context start `shouldBe` Right (SlotNo 0)
            slotStartMs context (SlotNo 0) `shouldBe` Right start
    it "extends the pinned final era far beyond the old horizon" $ do
        (manifest, genesis, history, _) <- loadNetworkFixture "devnet"
        context <-
            either
                (fail . show)
                pure
                (validateNetworkTime 42 manifest genesis history)
        let farSlot = timeHorizonSlot manifest + 10_000_000
            farMs = timeSystemStartMs manifest + toInteger (unSlotNo farSlot) * 100
        slotStartMs context farSlot `shouldBe` Right farMs
        posixMsFloorSlot context farMs `shouldBe` Right farSlot
        posixMsCeilingSlot context (farMs + 1) `shouldBe` Right (farSlot + 1)
    it "refuses an unsupported local time network by name" $
        loadTimeMaterial 999 "unused-for-unsupported-network"
            `shouldThrow` (== UnknownTimeNetwork 999)
    it
        "loads the packaged source and preserves valid recorded answers with amended range policy"
        $ do
            material <- loadTimeMaterial 1 "unused-for-packaged-preprod"
            context <- case material of
                PackagedTime reviewed -> pure reviewed
                GeneratedGenesis _ -> fail "PackagedPreprodSelectedGeneratedSource"
            (manifest, _, history, rows) <- loadFixture
            recordedRows context manifest history rows
    forM_ [("preprod", 1), ("devnet", 42)] $ \(network, magic) ->
        it
            ( "matches independently recorded "
                <> network
                <> " slot starts and extends its former horizon"
            )
            $ do
                (manifest, genesis, history, _) <- loadNetworkFixture network
                context <-
                    either
                        (fail . show)
                        pure
                        (validateNetworkTime magic manifest genesis history)
                rows <-
                    readFixture network "node-slot-starts.json"
                        >>= (either fail pure . eitherDecodeStrict' :: ByteString -> IO [StartRow])
                length rows `shouldSatisfy` (> 1)
                forM_ rows $ \(StartRow slot expected) -> case expected of
                    Right ms -> slotStartMs context slot `shouldBe` Right ms
                    Left reason -> do
                        reason `shouldSatisfy` (Text.isInfixOf "PastHorizon" . Text.pack)
                        -- The recorded refusal is at the old exclusive end.
                        -- Its time is independently recorded at the prior slot.
                        slot `shouldBe` timeHorizonSlot manifest
                        previous <- case [ms | StartRow s (Right ms) <- rows, s == slot - 1] of
                            [ms] -> pure ms
                            _ -> fail "MissingRecordedPreviousSlot"
                        let slotMs = if magic == 42 then 100 else 1000
                        slotStartMs context slot `shouldBe` Right (previous + slotMs)
    it
        "preserves generated-devnet rounding and extends its captured final era"
        $ do
            (manifest, genesis, history, rows) <- loadNetworkFixture "devnet"
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime 42 manifest genesis history)
            recordedRows context manifest history rows
    it
        "preserves recorded preprod rounding with explicit amended range expectations"
        $ do
            (manifest, genesis, history, rows) <- loadFixture
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime 1 manifest genesis history)
            recordedRows context manifest history rows
            length [() | TimeRow _ (NodeRefusal _) _ <- rows]
                `shouldSatisfy` (> 0)

    it "detects swapped rounding on the recorded non-boundary inputs" $ do
        (manifest, genesis, history, rows) <- loadFixture
        context <-
            either
                (fail . show)
                pure
                (validateNetworkTime 1 manifest genesis history)
        let killed =
                [ ()
                | TimeRow ms expected _ <- rows
                , not (matches expected (posixMsCeilingSlot context ms))
                ]
        length killed `shouldSatisfy` (> 1)

    it "names a wrong network before converting" $ do
        (manifest, genesis, history, _) <- loadFixture
        refusal (validateNetworkTime 42 manifest genesis history)
            `shouldBe` Just (WrongTimeNetwork 42 1)
        refusal (validateNetworkTime 9 manifest genesis history)
            `shouldBe` Just (UnknownTimeNetwork 9)

    it "refuses changed genesis bytes against their recorded identity" $ do
        (manifest, genesis, history, _) <- loadFixture
        let changed = genesis <> " "
        changed `shouldNotBe` genesis
        refusal (validateNetworkTime 1 manifest changed history)
            `shouldBe` Just (TimeSourceMismatch "genesis")

    it
        "refuses an actual shifted era start against the recorded history identity"
        $ do
            (manifest, genesis, history, _) <- loadFixture
            eras <-
                either
                    (fail . show)
                    pure
                    ( deserialiseOrFail (LBS.fromStrict history)
                        :: Either DeserialiseFailure [EraSummary]
                    )
            shifted <- case eras of
                firstEra : secondEra : rest ->
                    let start = eraStart secondEra
                        altered =
                            start
                                { boundTime = RelativeTime (getRelativeTime (boundTime start) + 1)
                                }
                    in  pure
                            ( LBS.toStrict
                                (serialise (firstEra : secondEra{eraStart = altered} : rest))
                            )
                _ -> fail "InsufficientRecordedEraExtent"
            shifted `shouldNotBe` history
            refusal (validateNetworkTime 1 manifest genesis shifted)
                `shouldBe` Just (TimeSourceMismatch "era history")

    it "refuses a manifest whose horizon differs from the source" $ do
        (manifest, genesis, history, _) <- loadFixture
        let altered = manifest{timeHorizonSlot = timeHorizonSlot manifest + 1}
        refusal (validateNetworkTime 1 altered genesis history)
            `shouldBe` Just (TimeSourceMismatch "conversion horizon")
  where
    refusal = either Just (const Nothing)
