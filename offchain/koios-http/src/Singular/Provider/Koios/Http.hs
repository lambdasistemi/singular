{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.Http
Description : The live Koios transport over HTTP
License     : Apache-2.0

The live 'Transport' for "Singular.Provider.Koios.Client": a base URL,
an optional bearer token read from a file, a timeout on every request,
and bounded retries.

Transient failures — unreachable, timed out, a cut-off body, a server
error and a rate-limit answer — are retried up to the attempt bound,
with delays doubling from the base delay up to the delay cap, with
jitter. A rate-limit answer's requested wait is honoured when it is
within the wait ceiling, and ends the retries when it is not. No retry
starts that would end past the per-call ceiling. Any other refusal is
returned at once. A request marked
'Singular.Provider.Koios.Client.RetryUnanswered', as submission is, is
retried only when no answer arrived: unreachable or timed out.

The transport returns the last raw answer and the attempt count; it
neither pages nor decodes. The token is read once, before any request:
a missing, unreadable or empty file is
'Singular.Provider.Koios.Client.TokenFileUnreadable'. The token is sent
only in the request header; failures are built from the exception's
content, never from the request, so it appears in no failure.
-}
module Singular.Provider.Koios.Http
    ( HttpConfig (..)
    , defaultHttpConfig
    , newHttpTransport
    ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Aeson (encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
    ( NominalDiffTime
    , diffUTCTime
    , getCurrentTime
    , nominalDiffTimeToSeconds
    )
import Network.HTTP.Client
    ( HttpException (..)
    , HttpExceptionContent (..)
    , Manager
    , Request (..)
    , RequestBody (..)
    , httpLbs
    , parseRequest
    , responseBody
    , responseHeaders
    , responseStatus
    , responseTimeoutNone
    , setQueryString
    )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (statusCode)
import System.Random (randomRIO)
import System.Timeout (timeout)

import Singular.Provider.Koios.Client
    ( Answer (..)
    , Exchange (..)
    , FailureReason (..)
    , NoAnswer (..)
    , RawRequest (..)
    , Retry (..)
    , Transport (..)
    )
import Singular.Provider.Koios.Wire (Body (..), Method (..))

-- | Live transport configuration.
data HttpConfig = HttpConfig
    { httpBaseUrl :: Text
    -- ^ Base URL, such as @https://preprod.koios.rest/api/v1@
    , httpTokenFile :: Maybe FilePath
    -- ^ File holding a bearer token
    , httpTimeout :: NominalDiffTime
    -- ^ Timeout of one attempt
    , httpAttempts :: Int
    -- ^ Most attempts per request
    , httpBaseDelay :: NominalDiffTime
    -- ^ Delay before the first retry; doubles on each retry
    , httpMaxDelay :: NominalDiffTime
    -- ^ Cap on the delay between attempts
    , httpRateLimitCeiling :: NominalDiffTime
    -- ^ Longest rate-limit wait honoured
    , httpCallCeiling :: NominalDiffTime
    -- ^ Longest time one request may take, retries included
    }
    deriving stock (Eq, Show)

{- | The defaults for a base URL: 20 s timeout, five attempts, delays
doubling from 0.25 s to 8 s, rate-limit waits up to 30 s, 60 s per call.
-}
defaultHttpConfig :: Text -> HttpConfig
defaultHttpConfig baseUrl =
    HttpConfig
        { httpBaseUrl = baseUrl
        , httpTokenFile = Nothing
        , httpTimeout = 20
        , httpAttempts = 5
        , httpBaseDelay = 0.25
        , httpMaxDelay = 8
        , httpRateLimitCeiling = 30
        , httpCallCeiling = 60
        }

-- | Read the token, if any, and build the transport.
newHttpTransport
    :: HttpConfig -> IO (Either FailureReason (Transport IO))
newHttpTransport cfg = do
    token <- traverse readToken (httpTokenFile cfg)
    case sequence token of
        Left failure -> pure (Left failure)
        Right bearer -> do
            manager <- newTlsManager
            pure (Right (Transport (send cfg manager bearer)))

-- | The token in a file, without surrounding white space.
readToken :: FilePath -> IO (Either FailureReason BS.ByteString)
readToken path =
    try (BS.readFile path) >>= \case
        Left e ->
            pure
                (Left (TokenFileUnreadable path (T.pack (show (e :: IOException)))))
        Right bytes
            | BS.null token -> pure (Left (TokenFileUnreadable path "empty"))
            | otherwise -> pure (Right token)
          where
            token = TE.encodeUtf8 (T.strip (TE.decodeUtf8Lenient bytes))

-- | What to do after an attempt.
data Next
    = -- | Return this exchange
      Done
    | -- | Retry after the backoff delay
      Backoff
    | -- | Retry after the server's requested wait
      Wait NominalDiffTime

-- | Send a request, retrying within the configured bounds.
send
    :: HttpConfig
    -> Manager
    -> Maybe BS.ByteString
    -> RawRequest
    -> IO Exchange
send cfg manager bearer raw = do
    start <- getCurrentTime
    let loop attempt = do
            result <- once cfg manager bearer raw
            let done = pure Exchange{exchangeAttempts = attempt, exchangeResult = result}
            case next cfg raw result of
                Done -> done
                step
                    | attempt >= httpAttempts cfg -> done
                    | otherwise -> do
                        delay <- case step of
                            Wait w -> pure w
                            _ -> backoff cfg attempt
                        now <- getCurrentTime
                        if diffUTCTime now start + delay > httpCallCeiling cfg
                            then done
                            else do
                                sleep delay
                                loop (attempt + 1)
    loop 1

-- | Whether an attempt's result may be retried, and after which wait.
next :: HttpConfig -> RawRequest -> Either NoAnswer Answer -> Next
next cfg raw = \case
    Left (NoConnection _) -> Backoff
    Left NoAnswerInTime -> Backoff
    Left (BodyCutOff _) -> transient Backoff
    Left (NoRecording _) -> Done
    Right a
        | status == 429 -> transient $ case retryAfter a of
            Nothing -> Backoff
            Just w
                | w <= httpRateLimitCeiling cfg -> Wait w
                | otherwise -> Done
        | status >= 500 -> transient Backoff
        | otherwise -> Done
      where
        status = answerStatus a
  where
    transient step = case rawRetry raw of
        RetryTransient -> step
        RetryUnanswered -> Done

-- | A 429's requested wait, in whole seconds.
retryAfter :: Answer -> Maybe NominalDiffTime
retryAfter a = do
    value <- lookup "retry-after" (answerHeaders a)
    case reads (T.unpack (T.strip value)) :: [(Integer, String)] of
        [(n, "")] | n >= 0 -> Just (fromInteger n)
        _ -> Nothing

{- | The delay before retry @n + 1@: the base delay doubled @n - 1@
times, capped, with jitter in its upper half.
-}
backoff :: HttpConfig -> Int -> IO NominalDiffTime
backoff cfg attempt = do
    let full = min (httpMaxDelay cfg) (httpBaseDelay cfg * 2 ^ (attempt - 1))
    jitter <- randomRIO (0.5, 1 :: Double)
    pure (full * realToFrac jitter)

sleep :: NominalDiffTime -> IO ()
sleep d = threadDelay (micros d)

micros :: NominalDiffTime -> Int
micros d = max 0 (round (nominalDiffTimeToSeconds d * 1000000))

-- | One attempt.
once
    :: HttpConfig
    -> Manager
    -> Maybe BS.ByteString
    -> RawRequest
    -> IO (Either NoAnswer Answer)
once cfg manager bearer raw =
    try (parseRequest (T.unpack (httpBaseUrl cfg <> rawPath raw))) >>= \case
        Left e -> pure (Left (noAnswerOf e))
        Right base -> do
            let req =
                    setQueryString
                        [(TE.encodeUtf8 k, Just (TE.encodeUtf8 v)) | (k, v) <- rawQuery raw]
                        base
                            { method = case rawMethod raw of
                                Get -> "GET"
                                Post -> "POST"
                            , requestHeaders =
                                [ (CI.mk (TE.encodeUtf8 k), TE.encodeUtf8 v)
                                | (k, v) <- rawHeaders raw
                                ]
                                    <> [ ("Authorization", "Bearer " <> token)
                                       | Just token <- [bearer]
                                       ]
                            , requestBody = case rawBody raw of
                                NoBody -> RequestBodyBS ""
                                JsonBody v -> RequestBodyLBS (encode v)
                                CborBody b -> RequestBodyBS b
                            , responseTimeout = responseTimeoutNone
                            }
            outcome <-
                timeout (micros (httpTimeout cfg)) (try (httpLbs req manager))
            pure $ case outcome of
                Nothing -> Left NoAnswerInTime
                Just (Left e) -> Left (noAnswerOf e)
                Just (Right response) ->
                    Right
                        Answer
                            { answerStatus = statusCode (responseStatus response)
                            , answerHeaders =
                                [ ( T.toLower (TE.decodeUtf8Lenient (CI.original k))
                                  , TE.decodeUtf8Lenient v
                                  )
                                | (k, v) <- responseHeaders response
                                ]
                            , answerBody = BSL.toStrict (responseBody response)
                            }
  where
    -- a failure names what went wrong on the connection, never the
    -- request; the token is scrubbed from it all the same
    scrub t =
        maybe
            t
            (\token -> T.replace (TE.decodeUtf8Lenient token) "<token>" t)
            bearer
    noAnswerOf = \case
        HttpExceptionRequest _ content -> case content of
            ResponseTimeout -> NoAnswerInTime
            ConnectionTimeout -> NoAnswerInTime
            ResponseBodyTooShort expected got ->
                BodyCutOff
                    ( "expected "
                        <> T.pack (show expected)
                        <> " bytes, got "
                        <> T.pack (show got)
                    )
            other -> NoConnection (scrub (T.pack (show other)))
        InvalidUrlException url reason ->
            NoConnection
                (scrub (T.pack ("invalid URL " <> url <> ": " <> reason)))
