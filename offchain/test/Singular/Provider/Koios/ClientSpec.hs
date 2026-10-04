{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Provider.Koios.ClientSpec
Description : Koios client: paging refusals, failure names, unknown facts
License     : Apache-2.0

The client over a scripted transport that hands it raw answers, as a
live or recorded transport would. Paged answers are generated at more
than one page, and each way a page can fail to belong to a whole answer
is introduced on one page after the first: every one ends in its named
refusal and never in a shorter answer.
-}
module Singular.Provider.Koios.ClientSpec (spec) where

import Control.Monad (void)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import Cardano.Ledger.Address (AccountAddress (..), AccountId (..))
import Cardano.Ledger.BaseTypes (EpochNo (..), Network (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))
import Cardano.Ledger.TxIn (TxId)

import Singular.Provider.Koios.Client
import Singular.Provider.Koios.Scripted
import Singular.Provider.Koios.Wire
    ( AssetTx (..)
    , Call (..)
    , DecodeFailure (..)
    , TxStatus (..)
    , renderRewardAccount
    )

spec :: Spec
spec = describe "Koios client" $ do
    pagingSpec
    failureSpec
    unknownSpec
    submitSpec

-- ---------------------------------------------------------------------------
-- Paging
-- ---------------------------------------------------------------------------

-- | A paged call's rows, its page size, and a page after the first.
data Paged = Paged
    { pagedRows :: [Value]
    , pagedSize :: Int
    , pagedPage :: Int
    }

instance Show Paged where
    show p =
        "rows="
            <> show (length (pagedRows p))
            <> " size="
            <> show (pagedSize p)
            <> " page="
            <> show (pagedPage p)

-- | At least three pages, and a chosen page after the first.
genPaged :: Gen Paged
genPaged = do
    size <- chooseInt (1, 6)
    n <- chooseInt (2 * size + 1, 6 * size)
    let rows =
            [ assetTxRow (hexOf i) 300 (fromIntegral i)
            | i <- [1 .. n]
            ]
        pages = (n + size - 1) `div` size
    page <- chooseInt (1, pages - 1)
    pure Paged{pagedRows = rows, pagedSize = size, pagedPage = page}

hexOf :: Int -> Text
hexOf i = T.justifyRight 64 '0' (T.pack (show i))

pagesOf :: Paged -> Int
pagesOf p = (length (pagedRows p) + pagedSize p - 1) `div` pagedSize p

offsetOf :: RawRequest -> Int
offsetOf = maybe 0 (read . T.unpack) . queryParam "offset"

limitOf :: RawRequest -> Int
limitOf = maybe 0 (read . T.unpack) . queryParam "limit"

{- | Serve the rows honestly, except that the answer at the chosen page
is replaced by the tamper.
-}
serve
    :: Paged
    -> (Int -> Int -> Exchange -> Exchange)
    -> IO (Koios IO, IO [RawRequest])
serve p tamper = do
    (transport, seen) <- scriptedTransport $ \raw _ -> do
        let off = offsetOf raw
            lim = limitOf raw
            honest = pageAnswer (pagedRows p) off lim
        pure $
            if off == pagedPage p * pagedSize p
                then tamper off lim honest
                else honest
    pure (koiosWith (pagedSize p) 100 transport, seen)

runAssetTxs :: Koios IO -> IO (Either ClientFailure [AssetTx])
runAssetTxs k = assetTxs k somePolicy someName

somePolicy :: PolicyID
somePolicy = PolicyID (scriptHashOfByte 1)

someName :: AssetName
someName = AssetName "name"

withBody :: BS.ByteString -> Exchange -> Exchange
withBody body ex =
    ex
        { exchangeResult = fmap (\a -> a{answerBody = body}) (exchangeResult ex)
        }

withRange :: Text -> Exchange -> Exchange
withRange range ex =
    ex
        { exchangeResult =
            fmap
                ( \a ->
                    a
                        { answerHeaders =
                            ("content-range", range)
                                : filter ((/= "content-range") . fst) (answerHeaders a)
                        }
                )
                (exchangeResult ex)
        }

rangeOf :: Exchange -> Text
rangeOf ex = case exchangeResult ex of
    Right a -> fromMaybe "" (lookup "content-range" (answerHeaders a))
    Left _ -> ""

isRefusal :: (PageRefusal -> Bool) -> Either ClientFailure a -> Bool
isRefusal match = \case
    Left ClientFailure{failureReason = IncompletePage r} -> match r
    _ -> False

pagingSpec :: Spec
pagingSpec = describe "paging" $ do
    it
        "reads every page in order, with offset, limit, order and an exact count"
        $ forAll genPaged
        $ \p -> ioProperty $ do
            (k, seen) <- serve p (\_ _ ex -> ex)
            result <- runAssetTxs k
            requests <- seen
            let heights = map assetTxBlockHeight <$> result
            pure $
                conjoin
                    [ heights
                        === Right (map fromIntegral [1 .. length (pagedRows p)])
                    , length requests === pagesOf p
                    , map offsetOf requests
                        === [0, pagedSize p .. (pagesOf p - 1) * pagedSize p]
                    , all
                        ((== Just (T.pack (show (pagedSize p)))) . queryParam "limit")
                        requests
                        === True
                    , all ((/= Nothing) . queryParam "order") requests === True
                    , all
                        (elem ("prefer", "count=exact") . lowerHeaders)
                        requests
                        === True
                    ]

    it "refuses a page cut off mid-array" $
        forAll genPaged $ \p -> ioProperty $ do
            (k, _) <- serve p $ \_ _ ex ->
                case exchangeResult ex of
                    Right a ->
                        withBody
                            (BS.take (BS.length (answerBody a) `div` 2) (answerBody a))
                            ex
                    Left _ -> ex
            result <- runAssetTxs k
            pure $
                counterexample (show result) $
                    isRefusal
                        (\case PageCutOff o _ -> o == pagedPage p * pagedSize p; _ -> False)
                        result

    it "refuses a page with more rows than the limit" $
        forAll genPaged $ \p -> ioProperty $ do
            (k, _) <- serve p $ \off lim _ ->
                let rows = take (lim + 1) (drop off (pagedRows p) <> pagedRows p)
                in  okJson
                        [
                            ( "content-range"
                            , T.pack (show off)
                                <> "-"
                                <> T.pack (show (off + lim))
                                <> "/"
                                <> T.pack (show (length (pagedRows p)))
                            )
                        ]
                        (BSL.toStrict (encode rows))
            result <- runAssetTxs k
            pure $
                counterexample (show result) $
                    isRefusal (\case PageOverLimit{} -> True; _ -> False) result

    it "refuses a total that changes between pages" $
        forAll genPaged $ \p -> ioProperty $ do
            (k, _) <- serve p $ \_ _ ex ->
                let range = rangeOf ex
                    (span', _) = T.breakOn "/" range
                in  withRange
                        (span' <> "/" <> T.pack (show (length (pagedRows p) + 1)))
                        ex
            result <- runAssetTxs k
            pure $
                counterexample (show result) $
                    isRefusal (\case TotalChanged{} -> True; _ -> False) result

    it "refuses a missing middle page answered as empty" $
        forAll genPaged $ \p -> ioProperty $ do
            (k, _) <- serve p $ \_ _ _ ->
                okJson
                    [("content-range", "*/" <> T.pack (show (length (pagedRows p))))]
                    "[]"
            result <- runAssetTxs k
            pure $
                counterexample (show result) $
                    isRefusal (\case RowsMissing{} -> True; _ -> False) result

    it "refuses a page that repeats another page's rows" $
        forAll genPaged $ \p -> ioProperty $ do
            (k, _) <- serve p $ \off lim _ ->
                pageAnswer (pagedRows p) (off - lim) lim
            result <- runAssetTxs k
            pure $
                counterexample (show result) $
                    isRefusal (\case RangeMismatch{} -> True; _ -> False) result

    it "refuses an answer with no exact total" $
        forAll genPaged $ \p -> ioProperty $ do
            (k, _) <- serve p $ \_ _ ex ->
                let (span', _) = T.breakOn "/" (rangeOf ex)
                in  withRange (span' <> "/*") ex
            result <- runAssetTxs k
            pure $
                counterexample (show result) $
                    isRefusal (\case TotalMissing{} -> True; _ -> False) result

    it "refuses at the page ceiling instead of answering with fewer rows" $
        forAll genPaged $ \p -> ioProperty $ do
            (transport, seen) <- scriptedTransport $ \raw _ ->
                pure (pageAnswer (pagedRows p) (offsetOf raw) (limitOf raw))
            let ceiling' = pagesOf p - 1
            result <- runAssetTxs (koiosWith (pagedSize p) ceiling' transport)
            requests <- seen
            pure $
                counterexample (show result) $
                    isRefusal (== PageCeilingReached ceiling') result
                        .&&. length requests === ceiling'

    it "answers an honestly empty history with an empty success" $ do
        (transport, _) <- scriptedTransport $ \raw _ ->
            pure (pageAnswer [] (offsetOf raw) (limitOf raw))
        runAssetTxs (koiosWith 5 3 transport) `shouldReturn` Right []
  where
    lowerHeaders raw = [(T.toLower h, v) | (h, v) <- rawHeaders raw]

-- ---------------------------------------------------------------------------
-- Failure names
-- ---------------------------------------------------------------------------

answered :: Int -> Int -> [(Text, Text)] -> BS.ByteString -> Exchange
answered attempts status headers body =
    Exchange
        { exchangeAttempts = attempts
        , exchangeResult =
            Right
                Answer
                    { answerStatus = status
                    , answerHeaders = headers
                    , answerBody = body
                    }
        }

unanswered :: Int -> NoAnswer -> Exchange
unanswered attempts reason =
    Exchange{exchangeAttempts = attempts, exchangeResult = Left reason}

tipWith :: Exchange -> IO (Either ClientFailure ())
tipWith ex = do
    (transport, _) <- scriptedTransport (\_ _ -> pure ex)
    void <$> tip (koiosWith 10 10 transport)

failureSpec :: Spec
failureSpec = describe "failure names carry the call, the attempts and the evidence" $ do
    let failsWith ex reason =
            tipWith ex
                `shouldReturn` Left
                    ClientFailure
                        { failureCall = CallTip
                        , failureAttempts = exchangeAttempts ex
                        , failureReason = reason
                        }
    it "a 429 is rate limited, with the wait asked" $
        failsWith
            (answered 5 429 [("retry-after", "7")] "slow down")
            (RateLimited (Just 7))
    it "a 5xx is server failing, with status and body" $
        failsWith (answered 5 503 [] "down") (ServerFailing 503 "down")
    it "a 401 is refused by the server" $
        failsWith
            (answered 1 401 [] "bad token")
            (RefusedByServer 401 "bad token")
    it "a 400 on a read is refused by the server" $
        failsWith
            (answered 1 400 [] "bad request")
            (RefusedByServer 400 "bad request")
    it "no connection is unreachable" $
        failsWith
            (unanswered 5 (NoConnection "refused"))
            (Unreachable "refused")
    it "no answer in time is timed out" $
        failsWith (unanswered 5 NoAnswerInTime) TimedOut
    it "a body cut off on the connection is an incomplete page" $
        failsWith
            (unanswered 5 (BodyCutOff "short"))
            (IncompletePage (PageCutOff 0 "short"))
    it "a request with no recording is not recorded" $
        failsWith (unanswered 1 (NoRecording "tip")) (NotRecorded "tip")
    it "a body that is not JSON is undecodable, at its position" $ do
        result <- tipWith (okJson [] "[{\"hash\": 12")
        case result of
            Left ClientFailure{failureReason = Undecodable _} -> pure ()
            other -> expectationFailure (show other)
    it "a row that does not decode is undecodable, at its path" $ do
        result <- tipWith (okJson [] "[{\"hash\": 12}]")
        case result of
            Left ClientFailure{failureReason = Undecodable f} ->
                T.unpack (decodePosition f) `shouldContain` "[0]"
            other -> expectationFailure (show other)

-- ---------------------------------------------------------------------------
-- Unknown facts
-- ---------------------------------------------------------------------------

once' :: BS.ByteString -> IO (Koios IO)
once' body = do
    (transport, _) <- scriptedTransport (\_ _ -> pure (okJson [] body))
    pure (koiosWith 10 10 transport)

reasonOf :: Either ClientFailure a -> Maybe FailureReason
reasonOf = either (Just . failureReason) (const Nothing)

stakeAccount :: AccountAddress
stakeAccount =
    AccountAddress
        Testnet
        (AccountId (ScriptHashObj (scriptHashOfByte 2)))

accountRow :: Text -> Value
accountRow status =
    object
        [ "stake_address" .= renderRewardAccount stakeAccount
        , "status" .= status
        ]

unknownSpec :: Spec
unknownSpec = describe "unknown is not false" $ do
    it "an empty tip answer is an unknown tip" $ do
        k <- once' "[]"
        reasonOf <$> tip k `shouldReturn` Just (UnknownFact UnknownTip)
    it "an empty epoch_params answer is an unknown epoch" $ do
        k <- once' "[]"
        reasonOf <$> epochParams k (EpochNo 9)
            `shouldReturn` Just (UnknownFact (UnknownEpoch (EpochNo 9)))
    it "a transaction absent from tx_info is an unknown transaction" $ do
        k <- once' "[]"
        let missing = someTxId
        reasonOf <$> txInfo k [missing]
            `shouldReturn` Just (UnknownFact (UnknownTransaction missing))
    it "a transaction absent from tx_cbor is an unknown transaction" $ do
        k <- once' "[]"
        reasonOf <$> txCbor k [someTxId]
            `shouldReturn` Just (UnknownFact (UnknownTransaction someTxId))
    it "a stake address with no row is an unknown registration" $ do
        k <- once' "[]"
        reasonOf <$> accountRegistered k stakeAccount
            `shouldReturn` Just
                ( UnknownFact
                    (UnknownRegistration (renderRewardAccount stakeAccount) Nothing)
                )
    it "a status other than registered or not registered is unknown" $ do
        k <- once' (BSL.toStrict (encode [accountRow "retired"]))
        reasonOf <$> accountRegistered k stakeAccount
            `shouldReturn` Just
                ( UnknownFact
                    ( UnknownRegistration
                        (renderRewardAccount stakeAccount)
                        (Just "retired")
                    )
                )
    it "registered is true and not registered is false" $ do
        yes <- once' (BSL.toStrict (encode [accountRow "registered"]))
        no <- once' (BSL.toStrict (encode [accountRow "not registered"]))
        accountRegistered yes stakeAccount `shouldReturn` Right True
        accountRegistered no stakeAccount `shouldReturn` Right False
    it "a transaction absent from tx_status is not yet seen" $ do
        k <- once' "[]"
        txStatus k [someTxId] `shouldReturn` Right [TxStatus someTxId Nothing]

someTxId :: TxId
someTxId = txIdOfByte 0xaa

-- ---------------------------------------------------------------------------
-- Submission
-- ---------------------------------------------------------------------------

submitSpec :: Spec
submitSpec = describe "submission" $ do
    it "a 400 is the server's refusal of the transaction, not a failure" $ do
        (transport, seen) <-
            scriptedTransport (\_ _ -> pure (answered 1 400 [] "BadInputsUTxO"))
        result <- submitTx (koiosWith 10 10 transport) "tx-bytes"
        result `shouldBe` Right (SubmitRefused "BadInputsUTxO")
        map rawRetry <$> seen `shouldReturn` [RetryUnanswered]
    it "a 202 returns the accepted transaction id" $ do
        (transport, _) <-
            scriptedTransport
                ( \_ _ ->
                    pure (answered 1 202 [] (BSL.toStrict (encode (T.replicate 64 "a"))))
                )
        submitTx (koiosWith 10 10 transport) "tx-bytes"
            `shouldReturn` Right (SubmitAccepted someTxId)
    it "reads are retried as transient, submission only when unanswered" $ do
        (transport, seen) <- scriptedTransport (\_ _ -> pure (okJson [] "[]"))
        _ <- txStatus (koiosWith 10 10 transport) [someTxId]
        map rawRetry <$> seen `shouldReturn` [RetryTransient]
