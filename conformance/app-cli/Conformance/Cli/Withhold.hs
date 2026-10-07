{- | A test forwarder between a provoked @inspect@ and the run's provider.

It forwards every request to the provider and returns the provider's
answer unchanged, except one: the history listing of the targeted
registry's state asset (@GET \/asset_txs@ naming that asset's policy and
name), which it answers with a successful empty history. It counts the
answers it withholds, so a control can tell a withholding that reached the
command's history read from one that never did.

History is withheld by answering empty; a provider that errors instead
produces a client refusal, which this forwarder does not exercise.
-}
module Conformance.Cli.Withhold
    ( Withholding (..)
    , withWithholding
    , withholds
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.HTTP.Types
    ( Method
    , Query
    , methodGet
    , methodPost
    , status200
    , status502
    )
import Network.Wai
    ( Request (..)
    , Response
    , consumeRequestBodyStrict
    , responseLBS
    )
import Network.Wai.Handler.Warp (testWithApplication)
import Singular.Provider.Koios.Client
    ( Answer (..)
    , Exchange (..)
    , NoAnswer
    , RawRequest (..)
    , Retry (..)
    , Transport (..)
    )
import Singular.Provider.Koios.Http
    ( defaultHttpConfig
    , newHttpTransport
    )
import Singular.Provider.Koios.Wire (Body (..), Call (..))
import Singular.Provider.Koios.Wire qualified as Wire

-- | A running forwarder.
data Withholding = Withholding
    { withholdingUrl :: String
    -- ^ The base URL to hand the command, ending in @\/api\/v1@
    , withheldReads :: IO Int
    -- ^ How many targeted history reads it has answered empty so far
    }

{- | Run an action with a forwarder in front of the provider at @upstream@
(a base URL ending in @\/api\/v1@), withholding the history of the state
asset named by its policy and asset name, both in hexadecimal.
-}
withWithholding
    :: String
    -> (Text, Text)
    -> (Withholding -> IO a)
    -> IO a
withWithholding upstream target act = do
    transport <-
        newHttpTransport (defaultHttpConfig (T.pack upstream))
            >>= either (fail . ("the forwarder's provider: " <>) . show) pure
    withheld <- newIORef (0 :: Int)
    let app request respond
            | withholds
                target
                (requestMethod request)
                (pathInfo request)
                (queryString request) = do
                atomicModifyIORef' withheld (\n -> (n + 1, ()))
                respond emptyHistory
            | otherwise = forward transport request >>= respond
    testWithApplication (pure app) $ \port ->
        act
            Withholding
                { withholdingUrl = "http://127.0.0.1:" <> show port <> "/api/v1"
                , withheldReads = readIORef withheld
                }

{- | Is this request the history listing of the targeted state asset? The
asset is named by its policy and name in hexadecimal, as Koios takes them.
-}
withholds :: (Text, Text) -> Method -> [Text] -> Query -> Bool
withholds (policy, name) method path query =
    method == methodGet
        && lastMaybe path == Just (Wire.callName CallAssetTxs)
        && param "_asset_policy" == Just policy
        && param "_asset_name" == Just name
  where
    param k = fmap TE.decodeUtf8Lenient =<< lookup k query
    lastMaybe xs = if null xs then Nothing else Just (last xs)

-- | A successful history with no transaction, as Koios pages an empty one.
emptyHistory :: Response
emptyHistory =
    responseLBS
        status200
        [("Content-Type", "application/json"), ("Content-Range", "*/0")]
        "[]"

-- | Send a request on to the provider and return its answer as it came.
forward :: Transport IO -> Request -> IO Response
forward transport request = do
    body <- consumeRequestBodyStrict request
    case callOf request of
        Nothing ->
            pure
                ( responseLBS
                    status502
                    [("Content-Type", "text/plain")]
                    "the forwarder knows no Koios call at this path"
                )
        Just call -> do
            Exchange _ result <-
                exchange transport (rawOf call request (BL.toStrict body))
            pure (answered result)

-- | The provider's answer, or a gateway failure when none arrived.
answered :: Either NoAnswer Answer -> Response
answered result = case result of
    Left why ->
        responseLBS
            status502
            [("Content-Type", "text/plain")]
            ( BL.fromStrict
                ( TE.encodeUtf8
                    ("the forwarder's provider gave no answer: " <> T.pack (show why))
                )
            )
    Right answer ->
        responseLBS
            (toEnum (answerStatus answer))
            [ (CI.mk (TE.encodeUtf8 k), TE.encodeUtf8 v)
            | (k, v) <- answerHeaders answer
            , k `notElem` hopByHop
            ]
            (BL.fromStrict (answerBody answer))

{- | The request as the transport sends it below the provider's base URL:
the path after @\/api\/v1@, the query and the end-to-end headers, and the
body's bytes as received.
-}
rawOf :: Call -> Request -> ByteString -> RawRequest
rawOf call request body =
    RawRequest
        { rawCall = call
        , rawMethod =
            if requestMethod request == methodPost then Wire.Post else Wire.Get
        , rawPath = "/" <> T.intercalate "/" (drop 2 (pathInfo request))
        , rawQuery =
            [ (TE.decodeUtf8Lenient k, maybe "" TE.decodeUtf8Lenient v)
            | (k, v) <- queryString request
            ]
        , rawHeaders =
            [ (TE.decodeUtf8Lenient (CI.original k), TE.decodeUtf8Lenient v)
            | (k, v) <- requestHeaders request
            , T.toLower (TE.decodeUtf8Lenient (CI.original k))
                `notElem` "host" : hopByHop
            ]
        , rawBody = if body == mempty then NoBody else CborBody body
        , rawRetry = RetryUnanswered
        }

-- | The Koios call a request names by its last path segment.
callOf :: Request -> Maybe Call
callOf request = case reverse (pathInfo request) of
    segment : _ -> find ((== segment) . Wire.callName) [minBound .. maxBound]
    [] -> Nothing

-- | Headers that belong to one connection, not to the request or answer.
hopByHop :: [Text]
hopByHop =
    [ "connection"
    , "content-length"
    , "keep-alive"
    , "transfer-encoding"
    , "upgrade"
    ]
