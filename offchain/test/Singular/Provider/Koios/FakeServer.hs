{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.FakeServer
Description : A loopback Koios server with scripted answers
License     : Apache-2.0

A small HTTP server on loopback for the live transport's tests. Each
request is logged — method, path, query, headers, body and arrival
time — and answered by the script, given the request and how many
requests to the same path preceded it. Tests assert on the named failure
the client returns and on the attempts this server counted, never on
the public service.
-}
module Singular.Provider.Koios.FakeServer
    ( Seen (..)
    , Scene
    , withFakeKoios
    , countAt
    , respond
    , respondAfter
    , replayFixtures
    ) where

import Control.Concurrent (threadDelay)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, getCurrentTime)
import Network.HTTP.Types (Status, mkStatus, status404)
import Network.HTTP.Types.URI (parseQueryText)
import Network.Wai
    ( Application
    , Response
    , rawPathInfo
    , rawQueryString
    , requestHeaders
    , requestMethod
    , responseLBS
    , strictRequestBody
    )
import Network.Wai.Handler.Warp (testWithApplication)

import Data.Aeson (decodeStrict')
import Singular.Provider.Koios.Client (Answer (..))
import Singular.Provider.Koios.Recorded
    ( Fixture (..)
    , FixtureRequest (..)
    , FixtureSet (..)
    )
import Singular.Provider.Koios.Wire (Body (..), Method (..))

-- | One request the server received.
data Seen = Seen
    { seenMethod :: Text
    , seenPath :: Text
    -- ^ Path below @/api/v1@
    , seenQuery :: [(Text, Text)]
    , seenHeaders :: [(Text, Text)]
    -- ^ Header names in lower case
    , seenBody :: ByteString
    , seenAt :: UTCTime
    }
    deriving stock (Show)

-- | The answer to a request, given how many requests to its path came before.
type Scene = Seen -> Int -> IO Response

{- | Run the server on a free loopback port and hand the action the
base URL (ending in @/api/v1@) and the request log.
-}
withFakeKoios :: Scene -> (Text -> IO [Seen] -> IO a) -> IO a
withFakeKoios scene action = do
    logRef <- newIORef []
    testWithApplication (pure (app logRef scene)) $ \port ->
        action
            ("http://127.0.0.1:" <> T.pack (show port) <> "/api/v1")
            (readIORef logRef)

app :: IORef [Seen] -> Scene -> Application
app logRef scene request reply = do
    body <- BSL.toStrict <$> strictRequestBody request
    now <- getCurrentTime
    let path = TE.decodeUtf8 (rawPathInfo request)
        seen =
            Seen
                { seenMethod = TE.decodeUtf8 (requestMethod request)
                , seenPath = fromMaybe path (T.stripPrefix "/api/v1" path)
                , seenQuery =
                    [ (k, fromMaybe "" v)
                    | (k, v) <- parseQueryText (rawQueryString request)
                    ]
                , seenHeaders =
                    [ (T.toLower (TE.decodeUtf8 (CI.original k)), TE.decodeUtf8 v)
                    | (k, v) <- requestHeaders request
                    ]
                , seenBody = body
                , seenAt = now
                }
    before <-
        atomicModifyIORef' logRef $ \xs ->
            (xs <> [seen], length (filter ((== seenPath seen) . seenPath) xs))
    response <- scene seen before
    reply response

-- | How many requests the log holds for a path.
countAt :: Text -> [Seen] -> Int
countAt path = length . filter ((== path) . seenPath)

-- | A response with a status, headers and body.
respond :: Int -> [(Text, Text)] -> ByteString -> IO Response
respond code headers body =
    pure $
        responseLBS
            (statusOf code)
            [(CI.mk (TE.encodeUtf8 k), TE.encodeUtf8 v) | (k, v) <- headers]
            (BSL.fromStrict body)

-- | The same response, sent after a delay in seconds.
respondAfter
    :: Double -> Int -> [(Text, Text)] -> ByteString -> IO Response
respondAfter seconds code headers body = do
    threadDelay (round (seconds * 1000000))
    respond code headers body

statusOf :: Int -> Status
statusOf code = mkStatus code ""

{- | Answer every request from a fixture set, matching method, path,
query and body; an unmatched request is a 404.
-}
replayFixtures :: FixtureSet -> Scene
replayFixtures set seen _ =
    case filter (matches . fixtureRequest) (setFixtures set) of
        fixture : _ ->
            let a = fixtureAnswer fixture
            in  respond
                    (answerStatus a)
                    (filter ((`notElem` hopByHop) . fst) (answerHeaders a))
                    (answerBody a)
        [] -> pure (responseLBS status404 [] "no fixture")
  where
    hopByHop =
        [ "content-length"
        , "transfer-encoding"
        , "connection"
        , "content-encoding"
        ]
    matches r =
        methodText (fixtureMethod r) == seenMethod seen
            && fixturePath r == seenPath seen
            && sort (fixtureQuery r) == sort (seenQuery seen)
            && bodyMatches (fixtureBody r)
    bodyMatches = \case
        NoBody -> seenBody seen == ""
        JsonBody v -> decodeStrict' (seenBody seen) == Just v
        CborBody b -> seenBody seen == b
    methodText = \case
        Get -> "GET"
        Post -> "POST"
