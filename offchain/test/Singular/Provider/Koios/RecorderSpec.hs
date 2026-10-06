{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.RecorderSpec
Description : The fixture recorder: reads only, complete fixtures, no token
License     : Apache-2.0

The recorder's request type is enumerated and none of its calls is a
submission, and a submission cannot be named on its command line. A
recording made against a loopback server writes one fixture per
exchange, page by page, each carrying its request, the schema revision
the server publishes, the time and the body's SHA-256, and none
carrying the bearer token. The recorded directory then answers the
client exactly as the live server did.
-}
module Singular.Provider.Koios.RecorderSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))

import Singular.Provider.Koios.Client
import Singular.Provider.Koios.FakeServer
import Singular.Provider.Koios.Http
import Singular.Provider.Koios.Recorded
import Singular.Provider.Koios.Recorder
import Singular.Provider.Koios.Scripted
    ( assetTxRow
    , pageAnswer
    , scriptHashOfByte
    )
import Singular.Provider.Koios.Wire (Call (..))

spec :: Spec
spec = describe "Koios fixture recorder" $ do
    requestSpec
    recordSpec
    refusalSpec

requestSpec :: Spec
requestSpec = describe "read requests" $ do
    it "no read call is a submission" $
        filter ((== CallSubmitTx) . readCallCall) [minBound .. maxBound]
            `shouldBe` []

    it "a submission cannot be named" $ do
        parseReadRequest "submittx" `shouldSatisfy` isLeft'
        parseReadRequest "submittx:84a400" `shouldSatisfy` isLeft'

    it "every read call is named by its Koios endpoint" $
        forM_ [minBound .. maxBound] $ \rc ->
            readCallName rc `shouldBe` callNameOf (readCallCall rc)

    it "parses a request of every read call" $
        forM_ samples $ \(text, rc) ->
            fmap readRequestCall (parseReadRequest text) `shouldBe` Right rc

    it "locates the schema document at the origin of the base URL" $
        schemaUrlOf "https://preprod.koios.rest/api/v1"
            `shouldBe` "https://preprod.koios.rest/koiosapi.yaml"

    it "reads the schema revision from the document's info block" $ do
        parseSchemaRevision schemaDocument `shouldBe` Right "v9.9.9"
        parseSchemaRevision "openapi: 3.1.0\npaths: {}\n"
            `shouldSatisfy` isLeft'
  where
    isLeft' = either (const True) (const False)
    callNameOf = \case
        CallTip -> "tip"
        CallAddressUtxos -> "address_utxos"
        CallAssetUtxos -> "asset_utxos"
        CallAssetTxs -> "asset_txs"
        CallTxInfo -> "tx_info"
        CallTxCbor -> "tx_cbor"
        CallEpochParams -> "epoch_params"
        CallCliProtocolParams -> "cli_protocol_params"
        CallSubmitTx -> "submittx"
        CallTxStatus -> "tx_status"
        CallAccountInfo -> "account_info"
        CallReferenceScriptUtxos -> "reference_script_utxos"
        CallUtxoInfo -> "utxo_info"
        CallAssetInfo -> "asset_info"

-- | One request text per read call.
samples :: [(Text, ReadCall)]
samples =
    [ ("tip", ReadTip)
    ,
        ( "address_utxos:addr_test1vrm7e5nmgm9yul7dsl7l6v6ate6lpjjjnq6wqvkz0tpcweghrtrk6"
        , ReadAddressUtxos
        )
    , ("asset_utxos:" <> policyHex <> "." <> "ab", ReadAssetUtxos)
    , ("asset_txs:" <> policyHex <> ".", ReadAssetTxs)
    , ("tx_info:" <> txHex <> "," <> txHex, ReadTxInfo)
    , ("tx_cbor:" <> txHex, ReadTxCbor)
    , ("epoch_params:317", ReadEpochParams)
    , ("cli_protocol_params", ReadCliProtocolParams)
    , ("tx_status:" <> txHex, ReadTxStatus)
    ,
        ( "account_info:stake_test17zy7ujlley7twgsnlqmpkue5338vgkqucz2uky864020czgktxcpl"
        , ReadAccountInfo
        )
    ]
  where
    policyHex = T.replicate 56 "1"
    txHex = T.replicate 64 "2"

schemaDocument :: BS.ByteString
schemaDocument =
    "openapi: 3.1.0\ninfo:\n  title: Koios API\n  contact:\n    name: Koios\n  version: v9.9.9\n  description: |\n    version: not this one\npaths: {}\n"

tipBody :: BS.ByteString
tipBody =
    "[{\"hash\":\"a276580588fa929d282d3466faccd85ea6f816d53f9cb6e9d57ac3cbd1935160\",\
    \\"epoch_no\":317,\"abs_slot\":135445500,\"epoch_slot\":143100,\
    \\"block_height\":5253272,\"block_no\":5253272,\"block_time\":1791128700}]"

token :: Text
token = "recorder-test-token-91c2-synthetic-credential"

-- | The loopback server: schema document, tip, and a five-row history.
scene :: Scene
scene s _ = case seenPath s of
    "/tip" -> respond 200 [] tipBody
    "/asset_txs" ->
        let rows =
                [ assetTxRow (T.justifyRight 64 '0' (T.pack (show i))) 317 i
                | i <- [1 .. 5]
                ]
        in  case exchangeResult (pageAnswer rows (param "offset") (param "limit")) of
                Right a -> respond 206 (answerHeaders a) (answerBody a)
                Left _ -> respond 500 [] ""
    _ -> respond 404 [] "not found"
  where
    param key = maybe 0 (read . T.unpack) (lookup key (seenQuery s))

-- | The schema document lives above the base URL, at the server's root.
withServer :: (Text -> IO [Seen] -> IO a) -> IO a
withServer = withFakeKoios $ \s n ->
    if seenPath s == "/koiosapi.yaml"
        then
            respond 200 [("content-type", "application/x-yaml")] schemaDocument
        else scene s n

recordSpec :: Spec
recordSpec = describe "recording"
    $ it
        "writes one complete fixture per exchange, without the token, replayable as recorded"
    $ withSystemTempDirectory "koios-record"
    $ \dir ->
        withServer $ \base logOf -> do
            let tokenFile = dir </> "token"
                out = dir </> "fixtures"
                http =
                    (defaultHttpConfig base)
                        { httpTokenFile = Just tokenFile
                        , httpAttempts = 1
                        }
                clientCfg = ClientConfig{pageSize = 2, pageCeiling = 10}
                policy = PolicyID (scriptHashOfByte 5)
            writeFile tokenFile (T.unpack token)
            start <- getCurrentTime
            written <-
                recordFixtures
                    RecorderConfig
                        { recorderHttp = http
                        , recorderClient = clientCfg
                        , recorderDirectory = out
                        }
                    [TipOf, AssetTxsOf policy (AssetName "")]
            end <- getCurrentTime
            files <- either (fail . show) pure written
            -- one fixture per exchange: the tip and three pages
            length files `shouldBe` 4
            seen <- logOf
            filter ((/= "/koiosapi.yaml") . seenPath) seen
                `shouldSatisfy` ((== 4) . length)
            -- every exchange carried the token; no fixture does
            names <- filter (".json" `isSuffixOf`) <$> listDirectory out
            length names `shouldBe` 4
            forM_ names $ \name -> do
                bytes <- BS.readFile (out </> name)
                TE.encodeUtf8 token `BS.isInfixOf` bytes `shouldBe` False
            -- request, revision, time and hash on every fixture
            set <- loadFixtureSet out >>= either (fail . show) pure
            setRevision set `shouldBe` "v9.9.9"
            forM_ (setFixtures set) $ \f -> do
                fixtureRevision f `shouldBe` "v9.9.9"
                fixtureSha256 f `shouldBe` bodySha256 (answerBody (fixtureAnswer f))
                fixtureRecordedAt f `shouldSatisfy` (\t -> t >= start && t <= end)
            map (fixtureCall . fixtureRequest) (setFixtures set)
                `shouldMatchList` [CallTip, CallAssetTxs, CallAssetTxs, CallAssetTxs]
            -- the recording answers the client as the server did
            live <- newHttpTransport http >>= either (fail . show) pure
            let viaLive = Koios clientCfg live
                viaRecorded = Koios clientCfg (recordedTransport set)
            liveTip <- tip viaLive
            recordedTip <- tip viaRecorded
            recordedTip `shouldBe` liveTip
            liveTxs <- assetTxs viaLive policy (AssetName "")
            recordedTxs <- assetTxs viaRecorded policy (AssetName "")
            fmap length recordedTxs `shouldBe` Right 5
            recordedTxs `shouldBe` liveTxs

-- | A recorder configuration over a base URL, recording into a directory.
recorderAt :: Text -> FilePath -> Maybe FilePath -> RecorderConfig
recorderAt base out tokenFile =
    RecorderConfig
        { recorderHttp =
            (defaultHttpConfig base)
                { httpTokenFile = tokenFile
                , httpAttempts = 3
                , httpBaseDelay = 0.02
                , httpMaxDelay = 0.1
                }
        , recorderClient = ClientConfig{pageSize = 2, pageCeiling = 10}
        , recorderDirectory = out
        }

refusalSpec :: Spec
refusalSpec = describe "refusals before and while recording" $ do
    it
        "reads the token file before any request, the schema document included"
        $ withSystemTempDirectory "koios-record"
        $ \dir ->
            withServer $ \base logOf -> do
                written <-
                    recordFixtures
                        (recorderAt base (dir </> "out") (Just (dir </> "no-such-token")))
                        [TipOf]
                case written of
                    Left (RecordTransport (TokenFileUnreadable _ _)) -> pure ()
                    other -> expectationFailure (show other)
                map seenPath <$> logOf `shouldReturn` []

    it "fetches the schema document under the configured retry bounds" $
        withSystemTempDirectory "koios-record" $ \dir ->
            withFakeKoios
                ( \s n -> case seenPath s of
                    "/koiosapi.yaml"
                        | n == 0 -> respond 503 [] "busy"
                        | otherwise -> respond 200 [] schemaDocument
                    _ -> scene s n
                )
                $ \base logOf -> do
                    written <-
                        recordFixtures (recorderAt base (dir </> "out") Nothing) [TipOf]
                    written `shouldSatisfy` either (const False) ((== 1) . length)
                    countAt "/koiosapi.yaml" <$> logOf `shouldReturn` 2

    it "records no echoed token" $
        withSystemTempDirectory "koios-record" $ \dir -> do
            let file = dir </> "token"
                out = dir </> "out"
            writeFile file (T.unpack token)
            withFakeKoios
                ( \s n -> case seenPath s of
                    "/koiosapi.yaml" -> respond 200 [] schemaDocument
                    _ ->
                        let bearer = fromMaybe "" (lookup "authorization" (seenHeaders s))
                        in  if n == 0
                                then
                                    respond
                                        200
                                        [ ("x-echo", bearer)
                                        , (fromMaybe bearer (T.stripPrefix "Bearer " bearer), "1")
                                        ]
                                        ("[{\"hash\": \"" <> TE.encodeUtf8 bearer <> "\"}]")
                                else respond 200 [] tipBody
                )
                $ \base logOf -> do
                    _ <- recordFixtures (recorderAt base out (Just file)) [TipOf]
                    seen <- logOf
                    -- the token did travel, so an echo was possible
                    filter
                        ((== Just ("Bearer " <> token)) . lookup "authorization" . seenHeaders)
                        seen
                        `shouldSatisfy` (not . null)
                    names <- filter (".json" `isSuffixOf`) <$> listDirectory out
                    names `shouldSatisfy` (not . null)
                    forM_ names $ \name -> do
                        bytes <- BS.readFile (out </> name)
                        TE.encodeUtf8 token `BS.isInfixOf` bytes `shouldBe` False

    it "names a fixture directory it cannot create" $
        withSystemTempDirectory "koios-record" $ \dir ->
            withServer $ \base _ -> do
                let blocker = dir </> "a-file"
                writeFile blocker "not a directory"
                written <-
                    recordFixtures (recorderAt base (blocker </> "out") Nothing) [TipOf]
                case written of
                    Left (RecordWrite path _) -> path `shouldBe` blocker </> "out"
                    other -> expectationFailure (show other)
