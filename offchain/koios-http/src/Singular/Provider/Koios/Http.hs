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
retried only when no answer arrived.

The transport returns the last raw answer and the attempt count; it
neither pages nor decodes. The token is read once, before any request:
a missing or unreadable file is
'Singular.Provider.Koios.Client.TokenFileUnreadable'. The token is sent
only in the request header and appears in no failure.
-}
module Singular.Provider.Koios.Http
    ( HttpConfig (..)
    , defaultHttpConfig
    , newHttpTransport
    ) where

import Data.Text (Text)
import Data.Time (NominalDiffTime)

import Singular.Provider.Koios.Client
    ( FailureReason
    , Transport
    )

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
newHttpTransport = error "Singular.Provider.Koios.Http: not implemented"
