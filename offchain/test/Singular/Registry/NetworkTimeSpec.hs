{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.NetworkTimeSpec
Description : Source-bound time comparisons and content/rounding faults
License     : Apache-2.0
-}
module Singular.Registry.NetworkTimeSpec (spec, loadNetworkFixture) where

import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Slotting.Time (RelativeTime (..))
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
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraSummary (..)
    )
import Paths_singular_registry (getDataFileName)
import Singular.Registry.NetworkTime
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldNotBe
    , shouldSatisfy
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
        source <- value .: "sourceIdentity"
        answerHash <- value .: "nodeAnswerSha256" >>= hex
        startHash <- value .: "nodeSlotStartSha256" >>= hex
        sourceHash <- value .: "nodeSourceSha256" >>= hex
        manifestHash <- value .: "sourceManifestSha256" >>= hex
        pure
            ( Fixture
                (NetworkTimeManifest magic start genesisHash historyHash horizon source)
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

spec :: Spec
spec = describe "Validity conversions from recorded preprod network data" $ do
    forM_ [("preprod", 1), ("devnet", 42)] $ \(network, magic) ->
        it
            ( "matches independently recorded "
                <> network
                <> " slot starts and horizon refusal"
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
                        slotStartMs context slot `shouldBe` Left (SlotPastHorizon slot)
    it
        "matches the exact generated-devnet context, rounding and horizon refusals"
        $ do
            (manifest, genesis, history, rows) <- loadNetworkFixture "devnet"
            context <-
                either
                    (fail . show)
                    pure
                    (validateNetworkTime 42 manifest genesis history)
            forM_ rows $ \(TimeRow ms floorAnswer ceilAnswer) -> do
                matches floorAnswer (posixMsFloorSlot context ms) `shouldBe` True
                matches ceilAnswer (posixMsCeilingSlot context ms) `shouldBe` True
    it "matches every recorded node floor, ceiling and horizon refusal" $ do
        (manifest, genesis, history, rows) <- loadFixture
        context <-
            either
                (fail . show)
                pure
                (validateNetworkTime 1 manifest genesis history)
        forM_ rows $ \(TimeRow ms floorAnswer ceilAnswer) -> do
            matches floorAnswer (posixMsFloorSlot context ms) `shouldBe` True
            matches ceilAnswer (posixMsCeilingSlot context ms) `shouldBe` True
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
