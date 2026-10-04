{-# LANGUAGE DataKinds #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

{- |
Module      : Singular.Provider.Koios.Client
Description : Typed Koios calls over a chosen transport
License     : Apache-2.0

The Koios client: typed calls built from a 'Transport' and the request
descriptions and decoders of "Singular.Provider.Koios.Wire".

A transport carries one request to one raw answer — status, headers and
body — and nothing else. It does not page and it does not decode, so the
recorded transport ("Singular.Provider.Koios.Recorded") and the live
HTTP transport (@koios-http@) hand this module the same raw answers and
every answer is paged and decoded here, once.

Every call ends in its decoded answer or in one 'ClientFailure' naming
the call, the attempts the transport made and the evidence. An honestly
empty answer, such as an address with no outputs, is a success with an
empty list and is distinct from every failure.

Paged calls ask for an exact row total and are read in a stable order
until the total is reached. A page that is cut off, a page larger than
the limit, a total that changes between pages, rows missing before the
total, or more pages than the configured ceiling each refuse the whole
call: the client never returns a shorter answer as a whole one.
-}
module Singular.Provider.Koios.Client
    ( -- * Transport
      Transport (..)
    , RawRequest (..)
    , Retry (..)
    , Answer (..)
    , NoAnswer (..)
    , Exchange (..)
    , rawRequest

      -- * Client
    , Koios (..)
    , ClientConfig (..)
    , defaultClientConfig

      -- * Failures
    , ClientFailure (..)
    , FailureReason (..)
    , PageRefusal (..)
    , UnknownFact (..)

      -- * Calls
    , tip
    , addressUtxos
    , assetUtxos
    , assetTxs
    , txInfo
    , txCbor
    , epochParams
    , cliProtocolParams
    , SubmitOutcome (..)
    , submitTx
    , txStatus
    , accountRegistered
    ) where

import Data.ByteString (ByteString)
import Data.Text (Text)

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (EpochNo)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Mary.Value (AssetName, PolicyID)
import Cardano.Ledger.TxIn (TxId, TxIn)

import Singular.Provider.Koios.Wire
    ( AssetTx
    , Body
    , Call
    , DecodeFailure
    , Method
    , Request
    , Tip
    , TxCbor
    , TxInfo
    , TxStatus
    )

-- | How a transport may retry a request.
data Retry
    = {- | Retry unreachable, timed out, rate limited and server-failing
      answers within the transport's bounds
      -}
      RetryTransient
    | {- | Retry only when no answer arrived: unreachable or timed out.
      Submission uses this, since resending the same signed bytes cannot
      apply them twice, while a refusal or a server error is final.
      -}
      RetryUnanswered
    deriving stock (Eq, Show)

-- | One HTTP request as the transport sends it.
data RawRequest = RawRequest
    { rawCall :: Call
    , rawMethod :: Method
    , rawPath :: Text
    , rawQuery :: [(Text, Text)]
    , rawHeaders :: [(Text, Text)]
    , rawBody :: Body
    , rawRetry :: Retry
    }
    deriving stock (Eq, Show)

-- | The raw request of an unpaged request.
rawRequest :: Request a -> RawRequest
rawRequest = notImplemented

-- | One raw answer: status, headers with lower-case names, and body.
data Answer = Answer
    { answerStatus :: Int
    , answerHeaders :: [(Text, Text)]
    , answerBody :: ByteString
    }
    deriving stock (Eq, Show)

-- | Why a transport has no answer to return.
data NoAnswer
    = -- | Connection, DNS or TLS failure
      NoConnection Text
    | -- | No complete answer within the request timeout
      NoAnswerInTime
    | -- | The connection delivered fewer body bytes than announced
      BodyCutOff Text
    | -- | A recorded transport holds no answer for this request
      NoRecording Text
    deriving stock (Eq, Show)

-- | One request's outcome after the transport's retries.
data Exchange = Exchange
    { exchangeAttempts :: Int
    , exchangeResult :: Either NoAnswer Answer
    }
    deriving stock (Eq, Show)

-- | One request to one raw answer, in any monad.
newtype Transport m = Transport
    { exchange :: RawRequest -> m Exchange
    }

-- | Paging configuration.
data ClientConfig = ClientConfig
    { pageSize :: Int
    -- ^ Rows asked for per page
    , pageCeiling :: Int
    -- ^ Most pages one call reads
    }
    deriving stock (Eq, Show)

-- | Pages of 1000 rows, Koios's maximum, and at most 100 pages.
defaultClientConfig :: ClientConfig
defaultClientConfig = ClientConfig{pageSize = 1000, pageCeiling = 100}

-- | A Koios client: a paging configuration and a transport.
data Koios m = Koios
    { koiosConfig :: ClientConfig
    , koiosTransport :: Transport m
    }

-- | Why a call stopped.
data ClientFailure = ClientFailure
    { failureCall :: Call
    , failureAttempts :: Int
    -- ^ Attempts the transport made for the request that failed
    , failureReason :: FailureReason
    }
    deriving stock (Eq, Show)

-- | The closed list of reasons a call stops.
data FailureReason
    = -- | Connection, DNS or TLS failure past the retry bound
      Unreachable Text
    | -- | No complete answer within the timeout, past the retry bound
      TimedOut
    | -- | 429 past the retry bound or beyond the wait ceiling; the last wait asked, in seconds
      RateLimited (Maybe Int)
    | -- | 5xx past the retry bound: status and body
      ServerFailing Int Text
    | -- | Any other 4xx, including a rejected token: status and body
      RefusedByServer Int Text
    | -- | A page that cannot be part of a whole answer
      IncompletePage PageRefusal
    | -- | A requested fact absent from the answer
      UnknownFact UnknownFact
    | -- | An answer that does not decode
      Undecodable DecodeFailure
    | -- | The token file could not be read; no request was made
      TokenFileUnreadable FilePath Text
    | -- | A recorded transport holds no answer for the request
      NotRecorded Text
    deriving stock (Eq, Show)

-- | Why a page cannot be part of a whole answer.
data PageRefusal
    = -- | The body at this offset is cut off or not one JSON document
      PageCutOff Int Text
    | -- | The page at this offset has more rows than the limit
      PageOverLimit Int Int Int
    | -- | The total at this offset differs from the first page's
      TotalChanged Int Integer Integer
    | -- | The answer at this offset states no exact total
      TotalMissing Int (Maybe Text)
    | -- | The range header at this offset does not match the rows
      RangeMismatch Int Text
    | -- | Fewer rows than the stated total arrived: total, received
      RowsMissing Integer Integer
    | -- | The configured number of pages was read and more remain
      PageCeilingReached Int
    deriving stock (Eq, Show)

-- | A fact the answer does not contain.
data UnknownFact
    = UnknownTip
    | UnknownEpoch EpochNo
    | UnknownTransaction TxId
    | {- | The stake address had no row, or a status that is neither
      registered nor not registered
      -}
      UnknownRegistration Text (Maybe Text)
    deriving stock (Eq, Show)

-- | The chain tip.
tip :: (Monad m) => Koios m -> m (Either ClientFailure Tip)
tip = notImplemented

-- | Every output at the addresses, read page by page.
addressUtxos
    :: (Monad m)
    => Koios m
    -> [Addr]
    -> m (Either ClientFailure [(TxIn, TxOut ConwayEra)])
addressUtxos = notImplemented

-- | Every output holding the assets, read page by page.
assetUtxos
    :: (Monad m)
    => Koios m
    -> [(PolicyID, AssetName)]
    -> m (Either ClientFailure [(TxIn, TxOut ConwayEra)])
assetUtxos = notImplemented

-- | Every transaction that moved the asset, read page by page.
assetTxs
    :: (Monad m)
    => Koios m
    -> PolicyID
    -> AssetName
    -> m (Either ClientFailure [AssetTx])
assetTxs = notImplemented

-- | The named transactions, in the order asked.
txInfo
    :: (Monad m) => Koios m -> [TxId] -> m (Either ClientFailure [TxInfo])
txInfo = notImplemented

-- | The named transactions' bytes, in the order asked.
txCbor
    :: (Monad m) => Koios m -> [TxId] -> m (Either ClientFailure [TxCbor])
txCbor = notImplemented

-- | The protocol parameters of an epoch.
epochParams
    :: (Monad m)
    => Koios m
    -> EpochNo
    -> m (Either ClientFailure (PParams ConwayEra))
epochParams = notImplemented

-- | The current protocol parameters in the node's own JSON form.
cliProtocolParams
    :: (Monad m)
    => Koios m
    -> m (Either ClientFailure (PParams ConwayEra))
cliProtocolParams = notImplemented

-- | What the server did with a submitted transaction.
data SubmitOutcome
    = -- | Accepted, with the transaction id Koios returned
      SubmitAccepted TxId
    | -- | Refused (400), with the server's reason
      SubmitRefused Text
    deriving stock (Eq, Show)

-- | Submit a signed transaction's CBOR.
submitTx
    :: (Monad m)
    => Koios m
    -> ByteString
    -> m (Either ClientFailure SubmitOutcome)
submitTx = notImplemented

-- | Confirmations of the named transactions, in the order asked.
txStatus
    :: (Monad m)
    => Koios m
    -> [TxId]
    -> m (Either ClientFailure [TxStatus])
txStatus = notImplemented

{- | Whether the reward account is registered: 'True' or 'False' only
when Koios says registered or not registered.
-}
accountRegistered
    :: (Monad m)
    => Koios m
    -> AccountAddress
    -> m (Either ClientFailure Bool)
accountRegistered = notImplemented

notImplemented :: a
notImplemented = error "Singular.Provider.Koios.Client: not implemented"
