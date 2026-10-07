{- | The test forwarder that withholds a registry's public history from a
provoked @inspect@: run against a loopback stand-in for the provider, it
must answer only the targeted asset's history listing empty, count it, and
pass every other request and answer through unchanged.
-}
module Conformance.Support.Withhold (spec) where

import Conformance.Cli.Withhold (Withholding (..), withWithholding)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types (status200)
import Network.Wai
    ( Application
    , Request (..)
    , consumeRequestBodyStrict
    , responseLBS
    )
import Network.Wai.Handler.Warp (testWithApplication)
import Singular.Provider.Koios.Client
    ( Answer (..)
    , Exchange (..)
    , RawRequest (..)
    , Retry (..)
    , Transport (..)
    )
import Singular.Provider.Koios.Http
    ( defaultHttpConfig
    , newHttpTransport
    )
import Singular.Provider.Koios.Wire
    ( Body (..)
    , Call (..)
    , Method (..)
    )
import Test.Hspec

-- | The targeted state asset, policy and name in hexadecimal.
target :: (Text, Text)
target = ("aa" <> T.replicate 27 "00", "bb01")

-- | What the stand-in provider saw: method, path, query, body.
type Seen = (Text, [Text], [(Text, Text)], BL.ByteString)

-- | A provider answering every request with a body naming its path.
standIn :: IORef [Seen] -> Application
standIn seen request respond = do
    body <- consumeRequestBodyStrict request
    modifyIORef'
        seen
        ( <>
            [
                ( TE.decodeUtf8 (requestMethod request)
                , pathInfo request
                , [ (TE.decodeUtf8 k, maybe "" TE.decodeUtf8 v)
                  | (k, v) <- queryString request
                  ]
                , body
                )
            ]
        )
    respond
        ( responseLBS
            status200
            [("Content-Type", "application/json"), ("Content-Range", "0-0/1")]
            ( "[\""
                <> BL.fromStrict (TE.encodeUtf8 (T.intercalate "/" (pathInfo request)))
                <> "\"]"
            )
        )

-- | Send one request to the forwarder and return its answer.
ask
    :: Withholding
    -> Call
    -> Method
    -> Text
    -> [(Text, Text)]
    -> Body
    -> IO Answer
ask w call verb path query body = do
    transport <-
        newHttpTransport (defaultHttpConfig (T.pack (withholdingUrl w)))
            >>= either (fail . show) pure
    Exchange _ result <-
        exchange
            transport
            RawRequest
                { rawCall = call
                , rawMethod = verb
                , rawPath = path
                , rawQuery = query
                , rawHeaders = [("prefer", "count=exact")]
                , rawBody = body
                , rawRetry = RetryUnanswered
                }
    either (fail . show) pure result

-- | Run a check with the forwarder in front of a fresh stand-in provider.
withForwarder
    :: (Text, Text) -> (Withholding -> IORef [Seen] -> IO a) -> IO a
withForwarder asset check = do
    seen <- newIORef []
    testWithApplication (pure (standIn seen)) $ \port ->
        withWithholding
            ("http://127.0.0.1:" <> show port <> "/api/v1")
            asset
            (`check` seen)

historyOf :: (Text, Text) -> [(Text, Text)]
historyOf (policy, name) =
    [ ("_asset_policy", policy)
    , ("_asset_name", name)
    , ("_history", "true")
    ]

spec :: Spec
spec = describe "a forwarder that withholds one registry's public history" $ do
    it
        "answers the targeted history listing empty, counts it, and never sends it on"
        $ withForwarder target
        $ \w seen -> do
            answer <-
                ask w CallAssetTxs Get "/asset_txs" (historyOf target) NoBody
            answerStatus answer `shouldBe` 200
            answerBody answer `shouldBe` "[]"
            lookup "content-range" (answerHeaders answer) `shouldBe` Just "*/0"
            withheldReads w `shouldReturn` 1
            readIORef seen `shouldReturn` []
    it
        "passes every other request through and returns the provider's answer"
        $ withForwarder target
        $ \w seen -> do
            tip <- ask w CallTip Get "/tip" [] NoBody
            answerBody tip `shouldBe` "[\"api/v1/tip\"]"
            lookup "content-range" (answerHeaders tip) `shouldBe` Just "0-0/1"
            let other = ("cc" <> T.replicate 27 "00", "bb01")
            _ <- ask w CallAssetTxs Get "/asset_txs" (historyOf other) NoBody
            let txs = object ["_tx_hashes" .= [String "ab"]]
            _ <- ask w CallTxInfo Post "/tx_info" [] (JsonBody txs)
            withheldReads w `shouldReturn` 0
            sent <- readIORef seen
            [(m, p) | (m, p, _, _) <- sent]
                `shouldBe` [ ("GET", ["api", "v1", "tip"])
                           , ("GET", ["api", "v1", "asset_txs"])
                           , ("POST", ["api", "v1", "tx_info"])
                           ]
            [q | (_, _, q, _) <- sent] !! 1 `shouldBe` historyOf other
            [b | (_, _, _, b) <- sent] !! 2 `shouldBe` "{\"_tx_hashes\":[\"ab\"]}"
    it
        "withholds nothing when it targets another asset: the count stays zero"
        $ withForwarder ("cc" <> T.replicate 27 "00", "bb01")
        $ \w seen -> do
            answer <-
                ask w CallAssetTxs Get "/asset_txs" (historyOf target) NoBody
            answerBody answer `shouldBe` "[\"api/v1/asset_txs\"]"
            withheldReads w `shouldReturn` 0
            length <$> readIORef seen `shouldReturn` 1
