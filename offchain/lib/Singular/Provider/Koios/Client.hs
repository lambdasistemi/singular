{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

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
every answer is paged and decoded here, once. The status is classified
here too: 2xx is an answer, 429 is rate limited, 5xx is server failing,
any other status is refused by the server — except a 400 at @submittx@,
which is the server's refusal of the transaction.

Every call ends in its decoded answer or in one 'ClientFailure' naming
the call, the attempts the transport made and the evidence. An honestly
empty answer, such as an address with no outputs, is a success with an
empty list and is distinct from every failure. A requested fact absent
from an answer — a transaction, a registration, the tip — is an
'UnknownFact', never a default.

Paged calls ask for an exact row total (@Prefer: count=exact@) and are
read in a stable order, page after page, until the total is reached or a
page comes back shorter than the limit. A page that is cut off, a page
larger than the limit, a range that does not match the page asked for, a
total that is missing or changes between pages, rows missing before the
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
    , Page
    , pageRows
    , nextPage
    , assetTxsPage
    , txInfo
    , txCbor
    , epochParams
    , cliProtocolParams
    , SubmitOutcome (..)
    , submitTx
    , txStatus
    , accountRegistered
    , referenceScriptUtxos
    , utxoInfo
    , assetInfo
    ) where

import Data.Aeson (Value)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.BaseTypes (EpochNo)
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, eraProtVerHigh)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (AssetName, PolicyID)
import Cardano.Ledger.TxIn (TxId, TxIn)

import Singular.Provider.Koios.Wire
    ( AccountStatus (..)
    , AssetInfo
    , AssetTx
    , Body (..)
    , Call (..)
    , DecodeFailure
    , Method
    , Request (..)
    , Tip
    , TxCbor (..)
    , TxInfo (..)
    , TxStatus (..)
    , UtxoInfo
    , accountInfoRequest
    , addressUtxosRequest
    , assetInfoRequest
    , assetTxsRequest
    , assetUtxosRequest
    , cliProtocolParamsRequest
    , decodeAccountStatuses
    , decodeAssetInfos
    , decodeAssetTxs
    , decodeCliProtocolParams
    , decodeEpochParams
    , decodeReferenceScriptUtxos
    , decodeSubmitted
    , decodeTip
    , decodeTxCbors
    , decodeTxInfos
    , decodeTxStatuses
    , decodeUtxoInfos
    , decodeUtxos
    , epochParamsRequest
    , parseBody
    , referenceScriptUtxosRequest
    , renderRewardAccount
    , submitTxRequest
    , tipRequest
    , txCborRequest
    , txInfoRequest
    , txStatusRequest
    , utxoInfoRequest
    )
import Singular.Registry.Signing (SignedTx, signedTx)

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

{- | The raw request of an unpaged request: its body's content type, and
retries limited to unanswered requests for a submission.
-}
rawRequest :: Request a -> RawRequest
rawRequest r =
    RawRequest
        { rawCall = requestCall r
        , rawMethod = requestMethod r
        , rawPath = requestPath r
        , rawQuery = requestQuery r
        , rawHeaders = ("accept", "application/json") : contentType
        , rawBody = requestBody r
        , rawRetry =
            if requestCall r == CallSubmitTx
                then RetryUnanswered
                else RetryTransient
        }
  where
    contentType = case requestBody r of
        NoBody -> []
        JsonBody _ -> [("content-type", "application/json")]
        CborBody _ -> [("content-type", "application/cbor")]

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
    | {- | 429 past the retry bound or beyond the wait ceiling; the last
      wait asked, in seconds
      -}
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
    | -- | The file's token is outside the accepted bearer domain; nothing was sent
      TokenFileInvalid FilePath Text
    | -- | A recorded transport holds no answer for the request
      NotRecorded Text
    deriving stock (Eq, Show)

-- | Why a page cannot be part of a whole answer.
data PageRefusal
    = -- | The body at this offset is cut off or not one JSON document
      PageCutOff Int Text
    | -- | The page at this offset has more rows than the limit: rows, limit
      PageOverLimit Int Int Int
    | -- | The total at this offset differs from the first page's: first, now
      TotalChanged Int Integer Integer
    | -- | The answer at this offset states no exact total: its range header
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

-- ---------------------------------------------------------------------------
-- Exchanges
-- ---------------------------------------------------------------------------

-- | A failure of a call.
type Fails = Int -> FailureReason -> ClientFailure

failing :: Call -> Fails
failing = ClientFailure

-- | The answer of an exchange when its status is a success.
answerOf :: Fails -> Int -> Exchange -> Either ClientFailure Answer
answerOf failure offset ex = case exchangeResult ex of
    Left none -> Left (failure attempts (noAnswer none))
    Right a
        | status >= 200 && status < 300 -> Right a
        | otherwise -> Left (failure attempts (refusal a))
      where
        status = answerStatus a
  where
    attempts = exchangeAttempts ex
    noAnswer = \case
        NoConnection t -> Unreachable t
        NoAnswerInTime -> TimedOut
        BodyCutOff t -> IncompletePage (PageCutOff offset t)
        NoRecording t -> NotRecorded t

-- | The failure an unsuccessful status names.
refusal :: Answer -> FailureReason
refusal a
    | status == 429 = RateLimited (header "retry-after" a >>= readInt)
    | status >= 500 = ServerFailing status (bodyText a)
    | otherwise = RefusedByServer status (bodyText a)
  where
    status = answerStatus a

header :: Text -> Answer -> Maybe Text
header name = lookup name . answerHeaders

bodyText :: Answer -> Text
bodyText = TE.decodeUtf8Lenient . answerBody

readInt :: Text -> Maybe Int
readInt t = case reads (T.unpack (T.strip t)) of
    [(n, "")] -> Just n
    _ -> Nothing

-- | One unpaged request, decoded, with the attempts it took.
single
    :: (Monad m)
    => Koios m
    -> Request a
    -> (Value -> Either DecodeFailure b)
    -> m (Either ClientFailure (Int, b))
single k req decode = do
    ex <- exchange (koiosTransport k) (rawRequest req)
    let failure = failing (requestCall req)
        attempts = exchangeAttempts ex
        undecodable = failure attempts . Undecodable
    pure $ do
        a <- answerOf failure 0 ex
        v <- first undecodable (parseBody (answerBody a))
        (,) attempts <$> first undecodable (decode v)

{- | A checked page and its deferred continuation over the same request.
No subsequent HTTP exchange happens until the continuation is executed.
The continuation retains the first total and the configured page ceiling;
it cannot turn a cut-off answer into a shorter successful history.
-}
data Page m a = Page
    { pageRows :: [a]
    -- ^ Rows on this page, after the shared decoder and range checks.
    , nextPage :: Maybe (m (Either ClientFailure (Page m a)))
    -- ^ Nothing only when this page reaches the exact advertised total.
    }

-- | Convenience join of the same checked, incremental pages.
paged
    :: (Monad m)
    => Koios m
    -> Request a
    -> (Value -> Either DecodeFailure [b])
    -> m (Either ClientFailure [b])
paged k req decode = firstPage k req decode >>= collect []
  where
    collect chunks = \case
        Left failure -> pure (Left failure)
        Right page ->
            let chunks' = pageRows page : chunks
            in  case nextPage page of
                    Nothing -> pure (Right (concat (reverse chunks')))
                    Just more -> more >>= collect chunks'

-- | Start a paged request using the single shared decoder/checking path.
firstPage
    :: (Monad m)
    => Koios m
    -> Request a
    -> (Value -> Either DecodeFailure [b])
    -> m (Either ClientFailure (Page m b))
firstPage k req decode = go 0 0 Nothing
  where
    ClientConfig{pageSize = size, pageCeiling = ceiling'} = koiosConfig k
    failure = failing (requestCall req)
    order = maybe [] (\o -> [("order", o)]) (requestOrder req)
    pageRequest offset =
        let raw = rawRequest req
        in  raw
                { rawQuery =
                    rawQuery raw
                        <> order
                        <> [ ("offset", T.pack (show offset))
                           , ("limit", T.pack (show size))
                           ]
                , rawHeaders = ("prefer", "count=exact") : rawHeaders raw
                }
    go pages offset total
        | pages >= ceiling' =
            pure (Left (failure 0 (IncompletePage (PageCeilingReached ceiling'))))
        | otherwise = do
            ex <- exchange (koiosTransport k) (pageRequest offset)
            let attempts = exchangeAttempts ex
                refuse = Left . failure attempts . IncompletePage
                page = do
                    a <- answerOf failure offset ex
                    v <-
                        first
                            (failure attempts . IncompletePage . PageCutOff offset . reasonOf)
                            (parseBody (answerBody a))
                    rows <- first (failure attempts . Undecodable) (decode v)
                    pure (a, rows)
            case page of
                Left f -> pure (Left f)
                Right (a, rows) ->
                    let n = length rows
                        here = toInteger offset + toInteger n
                    in  case rangeOf a of
                            _ | n > size -> pure (refuse (PageOverLimit offset n size))
                            Nothing ->
                                pure (refuse (TotalMissing offset (header "content-range" a)))
                            Just (span', t)
                                | not (spanMatches offset n span') || here > t ->
                                    pure (refuse (RangeMismatch offset (rangeText a)))
                                | Just t0 <- total
                                , t0 /= t ->
                                    pure (refuse (TotalChanged offset t0 t))
                                | n < size || here == t ->
                                    if here == t
                                        then pure (Right (Page rows Nothing))
                                        else pure (refuse (RowsMissing t here))
                                | otherwise ->
                                    pure
                                        ( Right
                                            ( Page
                                                rows
                                                (Just (go (pages + 1) (offset + size) (Just t)))
                                            )
                                        )
    reasonOf = T.pack . show
    rangeText = fromMaybe "" . header "content-range"

{- | The span and exact total of a @Content-Range@ header: @a-b/T@, or
@*/T@ for an empty page. 'Nothing' when absent or when the total is not
exact.
-}
rangeOf :: Answer -> Maybe (Maybe (Integer, Integer), Integer)
rangeOf a = do
    range <- header "content-range" a
    let (span', rest) = T.breakOn "/" range
    total <- readInteger (T.drop 1 rest)
    case span' of
        "*" -> Just (Nothing, total)
        _ ->
            let (from, to) = T.breakOn "-" span'
            in  do
                    f <- readInteger from
                    t <- readInteger (T.drop 1 to)
                    Just (Just (f, t), total)
  where
    readInteger t = case reads (T.unpack t) of
        [(n, "")] -> Just n
        _ -> Nothing

-- | Whether a range span names exactly the rows at an offset.
spanMatches :: Int -> Int -> Maybe (Integer, Integer) -> Bool
spanMatches offset n = \case
    Nothing -> n == 0
    Just (from, to) ->
        n > 0
            && from == toInteger offset
            && to == toInteger offset + toInteger n - 1

-- | The first row, or the unknown fact.
firstOr
    :: Fails
    -> UnknownFact
    -> Either ClientFailure (Int, [a])
    -> Either ClientFailure a
firstOr failure unknown = \case
    Left f -> Left f
    Right (_, x : _) -> Right x
    Right (attempts, []) -> Left (failure attempts (UnknownFact unknown))

-- | Each asked transaction's row, in the order asked.
eachAsked
    :: Fails
    -> (a -> TxId)
    -> [TxId]
    -> Either ClientFailure (Int, [a])
    -> Either ClientFailure [a]
eachAsked failure key ids result = do
    (attempts, found) <- result
    traverse
        ( \i -> case find ((== i) . key) found of
            Just row -> Right row
            Nothing -> Left (failure attempts (UnknownFact (UnknownTransaction i)))
        )
        ids

-- ---------------------------------------------------------------------------
-- Calls
-- ---------------------------------------------------------------------------

-- | The chain tip.
tip :: (Monad m) => Koios m -> m (Either ClientFailure Tip)
tip k =
    firstOr (failing CallTip) UnknownTip <$> single k tipRequest decodeTip

-- | Every output at the addresses, read page by page.
addressUtxos
    :: (Monad m)
    => Koios m
    -> [Addr]
    -> m (Either ClientFailure [(TxIn, TxOut ConwayEra)])
addressUtxos k addrs = paged k (addressUtxosRequest addrs) decodeUtxos

-- | Every output holding the assets, read page by page.
assetUtxos
    :: (Monad m)
    => Koios m
    -> [(PolicyID, AssetName)]
    -> m (Either ClientFailure [(TxIn, TxOut ConwayEra)])
assetUtxos k assets = paged k (assetUtxosRequest assets) decodeUtxos

{- | Every transaction that included the asset, read page by page, in
block height then transaction id order. That order makes pages stable;
it is not the order in which the asset was passed on.
-}
assetTxs
    :: (Monad m)
    => Koios m
    -> PolicyID
    -> AssetName
    -> m (Either ClientFailure [AssetTx])
assetTxs k p n = paged k (assetTxsRequest p n) decodeAssetTxs

{- | Start the asset transaction listing without joining its entire history.
Each continuation uses the same Wire decoder and range/total/refusal
checks as 'assetTxs'. HTTP ordering is stable height/hash order; consumers
must assemble a whole block and resolve spend dependencies before replay.
-}
assetTxsPage
    :: (Monad m)
    => Koios m
    -> PolicyID
    -> AssetName
    -> m (Either ClientFailure (Page m AssetTx))
assetTxsPage k p n = firstPage k (assetTxsRequest p n) decodeAssetTxs

-- | The named transactions, in the order asked.
txInfo
    :: (Monad m) => Koios m -> [TxId] -> m (Either ClientFailure [TxInfo])
txInfo k ids =
    eachAsked (failing CallTxInfo) txInfoId ids
        <$> single k (txInfoRequest ids) decodeTxInfos

-- | The named transactions' bytes, in the order asked.
txCbor
    :: (Monad m) => Koios m -> [TxId] -> m (Either ClientFailure [TxCbor])
txCbor k ids =
    eachAsked (failing CallTxCbor) txCborId ids
        <$> single k (txCborRequest ids) decodeTxCbors

-- | The protocol parameters of an epoch.
epochParams
    :: (Monad m)
    => Koios m
    -> EpochNo
    -> m (Either ClientFailure (PParams ConwayEra))
epochParams k e =
    firstOr (failing CallEpochParams) (UnknownEpoch e)
        <$> single k (epochParamsRequest e) decodeEpochParams

-- | The current protocol parameters in the node's own JSON form.
cliProtocolParams
    :: (Monad m)
    => Koios m
    -> m (Either ClientFailure (PParams ConwayEra))
cliProtocolParams k =
    fmap snd <$> single k cliProtocolParamsRequest decodeCliProtocolParams

-- | What the server did with a submitted transaction.
data SubmitOutcome
    = -- | Accepted, with the transaction id Koios returned
      SubmitAccepted TxId
    | -- | Refused (400), with the server's reason
      SubmitRefused Text
    deriving stock (Eq, Show)

{- | Submit a 'SignedTx', whose hidden constructor requires a payment-key
witness through 'Singular.Registry.Signing.signTx'. Serialize that
signed transaction as Conway CBOR without changing its body or witnesses.
A 400 is the server's refusal of the transaction and is returned as its
text; the transport retries the submission only when no answer arrived.
-}
submitTx
    :: (Monad m)
    => Koios m
    -> SignedTx
    -> m (Either ClientFailure SubmitOutcome)
submitTx k tx = do
    let bytes = serialize' (eraProtVerHigh @ConwayEra) (signedTx tx)
    ex <- exchange (koiosTransport k) (rawRequest (submitTxRequest bytes))
    let failure = failing CallSubmitTx
        attempts = exchangeAttempts ex
    pure $ case exchangeResult ex of
        Right a
            | answerStatus a == 400 -> Right (SubmitRefused (bodyText a))
        _ -> do
            a <- answerOf failure 0 ex
            first
                (failure attempts . Undecodable)
                (SubmitAccepted <$> decodeSubmitted (answerBody a))

{- | Confirmations of the named transactions, in the order asked. A
transaction absent from the answer is not yet seen.
-}
txStatus
    :: (Monad m)
    => Koios m
    -> [TxId]
    -> m (Either ClientFailure [TxStatus])
txStatus k ids =
    fmap (complete . snd)
        <$> single k (txStatusRequest ids) decodeTxStatuses
  where
    complete found =
        [ fromMaybe (TxStatus i Nothing) (find ((== i) . txStatusId) found)
        | i <- ids
        ]

{- | Whether the reward account is registered: 'True' or 'False' only
when Koios says registered or not registered; no row, or any other
status, is an 'UnknownRegistration'.
-}
accountRegistered
    :: (Monad m)
    => Koios m
    -> AccountAddress
    -> m (Either ClientFailure Bool)
accountRegistered k account = do
    result <- single k (accountInfoRequest account) decodeAccountStatuses
    let stake = renderRewardAccount account
    pure $ do
        (attempts, statuses) <- result
        let unknown =
                Left
                    . failing CallAccountInfo attempts
                    . UnknownFact
                    . UnknownRegistration stake
        case find ((== stake) . accountStakeAddress) statuses of
            Nothing -> unknown Nothing
            Just AccountStatus{accountStatus = s}
                | s == "registered" -> Right True
                | s == "not registered" -> Right False
                | otherwise -> unknown (Just s)

{- | Every live output whose reference script is one of the hashes, with
the hash Koios names for it, read page by page. An empty answer means
not found by this provider.
-}
referenceScriptUtxos
    :: (Monad m)
    => Koios m
    -> NonEmpty ScriptHash
    -> m (Either ClientFailure [(ScriptHash, TxIn)])
referenceScriptUtxos k hashes =
    paged
        k
        (referenceScriptUtxosRequest (toList hashes))
        decodeReferenceScriptUtxos

-- | Whether each named output is spent, as Koios reports it.
utxoInfo
    :: (Monad m)
    => Koios m
    -> NonEmpty TxIn
    -> m (Either ClientFailure [UtxoInfo])
utxoInfo k references =
    fmap snd
        <$> single k (utxoInfoRequest (toList references)) decodeUtxoInfos

-- | The asset's latest minting transaction and supply, or no row.
assetInfo
    :: (Monad m)
    => Koios m
    -> (PolicyID, AssetName)
    -> m (Either ClientFailure (Maybe AssetInfo))
assetInfo k asset =
    fmap (listToMaybe . snd)
        <$> single k (assetInfoRequest asset) decodeAssetInfos
