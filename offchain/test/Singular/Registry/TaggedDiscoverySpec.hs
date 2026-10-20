{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TaggedDiscoverySpec
Description : Finding a registry's pending requests by the request policy's tag
License     : Apache-2.0

Pending requests are found by the one read the request policy's tags allow:
the outputs holding any asset of the request policy, which Koios gives as an
ordered, exactly counted listing of the policy's assets followed by one
singleton asset read per listed name. Untagged outputs at the request address
are never read, so they cannot change which requests are found, which are
refused, or how the fold goes; a listing that is cut off, refused or changing
is a named failure and never an empty list. What the read lists still has to
be a genuine request: at the registry's request address, holding the tag its
own datum commits to.

The bodies below are the six reads taken from public preprod
(@evidence/koios-paging@), byte for byte, with the digest each read recorded
asserted first. The listing reads (a policy with two assets and a policy with
none) and the singleton asset read answer the provider exactly as the live
service did, and the same provider code is then pushed through the refusals
the client names.
-}
module Singular.Registry.TaggedDiscoverySpec
    ( spec
    , retainedListingBody
    , retainedFirstPageBody
    , retainedSecondPageBody
    , retainedEmptyBody
    , retainedUtxosBody
    , retainedPolicy
    , retainedNames
    ) where

import Control.Exception (try)
import Control.Monad (forM_)
import Control.Tracer (nullTracer)
import Data.Aeson (Value (..), decodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data (Data (..))
import Test.Hspec

import Cardano.Crypto.Hash.Class (hashFromBytes)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes qualified as Ledger
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)

import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Provider.Koios.Client
    ( Answer (..)
    , Exchange (..)
    , NoAnswer (..)
    , RawRequest (..)
    )
import Singular.Provider.Koios.Provider (koiosProvider)
import Singular.Provider.Koios.Recorded (bodySha256)
import Singular.Provider.Koios.Runtime (newIORuntime)
import Singular.Provider.Koios.Scripted
    ( koiosWith
    , queryParam
    , scriptedTransport
    )
import Singular.Provider.Koios.Wire
    ( Body (..)
    , Call (..)
    , Method (..)
    , decodeUtxos
    )
import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    )
import Singular.Registry.Ledger (Addr, ConwayEra, TokenId (..))
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTimeSpec (loadNetworkFixture)
import Singular.Registry.StubSession
import Singular.Registry.TimeSource (TimeSource (..))
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.Internal
    ( mkInlineDatum
    , pendingByTag
    , policyIdFromPin
    , requestAddrFromCfg
    , toPlcData
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRequest (..)
    , OnChainTokenId (..)
    , trieReadyTagName
    )

-- ---------------------------------------------------------
-- The retained reads (written by a program from the retained files)
-- ---------------------------------------------------------

unhex :: ByteString -> ByteString
unhex = either (error . ("unhex: " <>)) id . B16.decode

{- | Read 1 of @evidence/koios-paging@: the listing of the assets minted under
policy @8ac9562f…a62@, @order=asset_name.asc&limit=1000&offset=0@, status 200,
@content-range: 0-1/2@. Written from the retained file by
@retained_reads.hs.txt@ (evidence/cp3-red-dev/vectors), not typed.
-}
retainedListingBody :: ByteString
retainedListingBody =
    unhex . mconcat $
        [ "5b7b2261737365745f6e616d65223a226262343130383166353464396332636164383833646265666536393061666662"
        , "3064623439636666383030653735373438323266643166353764373665373738222c2266696e6765727072696e74223a"
        , "2261737365743173333278657732376a3738677235686b67707972656b72616e6470673966766172716e787a71222c22"
        , "746f74616c5f737570706c79223a2231222c22646563696d616c73223a307d2c200a207b2261737365745f6e616d6522"
        , "3a2265383266356533343833336437613734616430333539373838646661333164373837396438353164326166366335"
        , "643466306638383531386631313433336239222c2266696e6765727072696e74223a2261737365743171307a30743765"
        , "327a6e36736766346b707465723063617a716c347532687271726866796a32222c22746f74616c5f737570706c79223a"
        , "2231222c22646563696d616c73223a307d5d"
        ]

retainedFirstPageBody :: ByteString
retainedFirstPageBody =
    unhex . mconcat $
        [ "5b7b2261737365745f6e616d65223a226262343130383166353464396332636164383833646265666536393061666662"
        , "3064623439636666383030653735373438323266643166353764373665373738222c2266696e6765727072696e74223a"
        , "2261737365743173333278657732376a3738677235686b67707972656b72616e6470673966766172716e787a71222c22"
        , "746f74616c5f737570706c79223a2231222c22646563696d616c73223a307d5d"
        ]

retainedSecondPageBody :: ByteString
retainedSecondPageBody =
    unhex . mconcat $
        [ "5b7b2261737365745f6e616d65223a226538326635653334383333643761373461643033353937383864666133316437"
        , "3837396438353164326166366335643466306638383531386631313433336239222c2266696e6765727072696e74223a"
        , "2261737365743171307a30743765327a6e36736766346b707465723063617a716c347532687271726866796a32222c22"
        , "746f74616c5f737570706c79223a2231222c22646563696d616c73223a307d5d"
        ]

retainedEmptyBody :: ByteString
retainedEmptyBody =
    unhex . mconcat $
        [ "5b5d"
        ]

retainedUtxosBody :: ByteString
retainedUtxosBody =
    unhex . mconcat $
        [ "5b7b2274785f68617368223a226338633562653033303233623832386366666431646336323362333435633365663036"
        , "3166373362306437646462316238623464393234643261316335376133222c2274785f696e646578223a302c22616464"
        , "72657373223a22616464725f7465737431777a39766a34333074376d746178756d6a7961773974667663387637717738"
        , "683775706579346833346a306835637365336e773672222c2276616c7565223a2232303030303030222c227374616b65"
        , "5f61646472657373223a6e756c6c2c227061796d656e745f63726564223a223861633935363266356662366265396239"
        , "623931336165326164326363316439653033386637663730333932353666316163396637613632222c2265706f63685f"
        , "6e6f223a3331332c22626c6f636b5f686569676874223a353137393935302c22626c6f636b5f74696d65223a31373839"
        , "3437383737312c22646174756d5f68617368223a22326265383966396133326233313566373337623838326331396236"
        , "65643733623930343737393235663362353533386465363438333933666466326661616130222c22696e6c696e655f64"
        , "6174756d223a7b226279746573223a202264383761396664383739396635383230623230333637366661636161333566"
        , "366661356664623863373337333539356635323731356633616633333566633230316263616339366261636661333239"
        , "623161303030663432343031613030303932376330316130303034393365303538316336346164626439636439343437"
        , "333836383066363730636264303435363239343935316232306163313265623166336562656230646338383538316362"
        , "626531363666666237303664336637653035623934316464633736313564653339353735616632616232623363636132"
        , "6132356263373066666666222c202276616c7565223a207b226669656c6473223a205b7b226669656c6473223a205b7b"
        , "226279746573223a20226232303336373666616361613335663666613566646238633733373335393566353237313566"
        , "3361663333356663323031626361633936626163666133323962227d2c207b22696e74223a20313030303030307d2c20"
        , "7b22696e74223a203630303030307d2c207b22696e74223a203330303030307d2c207b226279746573223a2022363461"
        , "646264396364393434373338363830663637306362643034353632393439353162323061633132656231663365626562"
        , "3064633838227d2c207b226279746573223a202262626531363666666237303664336637653035623934316464633736"
        , "31356465333935373561663261623262336363613261323562633730227d5d2c2022636f6e7374727563746f72223a20"
        , "307d5d2c2022636f6e7374727563746f72223a20317d7d2c227265666572656e63655f736372697074223a6e756c6c2c"
        , "2261737365745f6c697374223a5b7b22646563696d616c73223a20302c20227175616e74697479223a202231222c2022"
        , "706f6c6963795f6964223a20223861633935363266356662366265396239623931336165326164326363316439653033"
        , "386637663730333932353666316163396637613632222c202261737365745f6e616d65223a2022626234313038316635"
        , "346439633263616438383364626566653639306166666230646234396366663830306537353734383232666431663537"
        , "64373665373738222c202266696e6765727072696e74223a202261737365743173333278657732376a3738677235686b"
        , "67707972656b72616e6470673966766172716e787a71227d5d2c2269735f7370656e74223a66616c73657d5d"
        ]

-- ---------------------------------------------------------
-- What the retained reads say, read without the code under test
-- ---------------------------------------------------------

-- | The policy of the retained reads: a registry's request-script hash.
retainedPolicyHex :: Text
retainedPolicyHex = "8ac9562f5fb6be9b9b913ae2ad2cc1d9e038f7f7039256f1ac9f7a62"

retainedPolicy :: PolicyID
retainedPolicy =
    PolicyID
        ( ScriptHash
            ( fromMaybe
                (error "retained policy is not 28 bytes")
                (hashFromBytes (unhex (TE.encodeUtf8 retainedPolicyHex)))
            )
        )

-- | The assets the retained listing names, in its order, read by a plain JSON parse.
retainedNames :: [AssetName]
retainedNames = case decodeStrict' retainedListingBody of
    Just (Array rows) ->
        [ AssetName (SBS.toShort (unhex (TE.encodeUtf8 name)))
        | Object row <- toList rows
        , Just (String name) <- [KM.lookup "asset_name" row]
        ]
    _ -> error "the retained listing is not an array"

nameOne :: AssetName
nameOne = case retainedNames of
    one : _ -> one
    [] -> error "the retained listing names no asset"

nameOneHex, nameTwoHex :: Text
(nameOneHex, nameTwoHex) = case map nameHex retainedNames of
    [one, two] -> (one, two)
    other -> error ("the retained listing names " <> show (length other))

nameHex :: AssetName -> Text
nameHex (AssetName n) = TE.decodeUtf8 (B16.encode (SBS.fromShort n))

{- | The output reference of the one output the retained asset read answers,
read by a plain JSON parse: transaction hash and index of its first row.
-}
retainedRef :: TxIn
retainedRef = case decodeStrict' retainedUtxosBody of
    Just (Array rows)
        | Object row : _ <- toList rows
        , Just (String hash) <- KM.lookup "tx_hash" row
        , Just (Number ix) <- KM.lookup "tx_index" row ->
            either
                (error . ("retained reference: " <>))
                id
                (parseOutRef (hash <> "#" <> T.pack (show (round ix :: Integer))))
    _ -> error "the retained asset read has no row"

-- | The outputs the retained asset read answers, by the client's existing decoder.
retainedOutputs :: Outputs
retainedOutputs = case decodeStrict' retainedUtxosBody of
    Just value -> either (error . show) id (decodeUtxos value)
    Nothing -> error "the retained asset read is not JSON"

-- ---------------------------------------------------------
-- A scripted Koios over the retained answers
-- ---------------------------------------------------------

answerWith :: Int -> [(Text, Text)] -> ByteString -> Exchange
answerWith status headers body =
    Exchange
        { exchangeAttempts = 1
        , exchangeResult =
            Right
                Answer
                    { answerStatus = status
                    , answerHeaders = ("content-type", "application/json") : headers
                    , answerBody = body
                    }
        }

notScripted :: Exchange
notScripted = Exchange 1 (Left (NoRecording "this request is not scripted"))

-- | What the scripted service answers to each call, given what it was asked.
data Serving = Serving
    { listingFor :: RawRequest -> Exchange
    , assetFor :: RawRequest -> AssetName -> Exchange
    , addressFor :: RawRequest -> Exchange
    }

-- | The service as it answered the retained reads, at any page size it was read at.
honest :: Serving
honest =
    Serving
        { listingFor = \raw -> case (offsetOf raw, limitOf raw) of
            (0, n)
                | n >= 2 ->
                    answerWith 200 [("content-range", "0-1/2")] retainedListingBody
            (0, 1) -> answerWith 206 [("content-range", "0-0/2")] retainedFirstPageBody
            (1, 1) -> answerWith 206 [("content-range", "1-1/2")] retainedSecondPageBody
            _ -> notScripted
        , assetFor = \_ name ->
            if name == nameOne
                then answerWith 200 [("content-range", "0-0/1")] retainedUtxosBody
                else answerWith 200 [("content-range", "*/0")] "[]"
        , addressFor = const notScripted
        }

offsetOf, limitOf :: RawRequest -> Int
offsetOf = maybe 0 (read . T.unpack) . queryParam "offset"
limitOf = maybe 0 (read . T.unpack) . queryParam "limit"

-- | The assets a @asset_utxos@ request names, as (policy, name) texts.
assetListOf :: RawRequest -> [(Text, Text)]
assetListOf raw = case rawBody raw of
    JsonBody (Object o)
        | Just (Array pairs) <- KM.lookup "_asset_list" o ->
            [ (p, n)
            | Array pair <- toList pairs
            , [String p, String n] <- [toList pair]
            ]
    _ -> []

route :: Serving -> RawRequest -> Int -> IO Exchange
route serving raw _ = pure $ case rawCall raw of
    CallPolicyAssetList -> listingFor serving raw
    CallAssetUtxos -> case assetListOf raw of
        [(_, n)] ->
            assetFor
                serving
                raw
                (AssetName (SBS.toShort (unhex (TE.encodeUtf8 n))))
        _ -> notScripted
    CallAddressUtxos -> addressFor serving raw
    _ -> notScripted

-- | Read one query through the Koios provider built over the scripted service.
readWith
    :: Int
    -> Serving
    -> OutputQuery
    -> IO (Either ReadFailure Outputs, [RawRequest])
readWith size serving query = do
    (transport, seen) <- scriptedTransport (route serving)
    (manifest, genesis, history, _) <- loadNetworkFixture "preprod"
    runtime <- newIORuntime nullTracer (\_ -> pure ())
    let provider =
            koiosProvider
                runtime
                (Network 1)
                (pure (Right (TimeSource manifest genesis history)))
                (koiosWith size 10 transport)
    result <-
        acquire
            provider
            (Latest (Network 1))
            (\session -> fmap (fmap value) (outputs session query))
    requests <- seen
    pure (either (error . show) id result, requests)

holdingRetained :: OutputQuery
holdingRetained = HoldingPolicy retainedPolicy

namesFailure :: String -> Serving -> Int -> Expectation
namesFailure marker serving size = do
    (result, _) <- readWith size serving holdingRetained
    case result of
        Left (BackendReadFailure reason) ->
            T.unpack reason `shouldSatisfy` isInfixOf marker
        other ->
            expectationFailure ("expected a named failure, got " <> show other)

-- | A body with its first occurrence of one text replaced by another.
replaceOnce :: ByteString -> ByteString -> ByteString -> ByteString
replaceOnce from to body = case BS.breakSubstring from body of
    (prefix, rest)
        | not (BS.null rest) -> prefix <> to <> BS.drop (BS.length from) rest
    _ -> error "replaceOnce: the text is not in the body"

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec = describe "chunk3 offchain" $ do
    retainedSpec
    providerSpec
    consumerSpec

retainedSpec :: Spec
retainedSpec = describe "the retained Koios reads" $ do
    it "hold the bytes each read returned" $ do
        let digests =
                [
                    ( "the listing"
                    , retainedListingBody
                    , "7657b2d4d27ab272dca62b011a3c24f3eefece13dc8153440e3ad9f80c334410"
                    )
                ,
                    ( "the first one-row page"
                    , retainedFirstPageBody
                    , "e715f246f53c6c55f1f6d49a05bc6c964f999ff648c32ec9478d7b7fd67cd2c4"
                    )
                ,
                    ( "the second one-row page"
                    , retainedSecondPageBody
                    , "0d40817dfb7a71b5867338bab1f7821887d40f5ad78bc4dca5e9785a5a8df4c2"
                    )
                ,
                    ( "the empty listing"
                    , retainedEmptyBody
                    , "4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
                    )
                ,
                    ( "the asset read"
                    , retainedUtxosBody
                    , "63c5b66e6101cfd4e1f39b4acfebe1082e08f578e534cdd88ab1bfc39a9d7216"
                    )
                ]
        forM_ digests $ \(what, body, digest) ->
            (what :: String, bodySha256 body) `shouldBe` (what, digest)
    it
        "list two assets, of which the asset read answers the first (preserved)"
        $ do
            length retainedNames `shouldBe` 2
            map fst retainedOutputs `shouldBe` [retainedRef]

providerSpec :: Spec
providerSpec = describe "the Koios provider reads a policy" $ do
    it
        "lists the policy's assets, then reads each singly, and returns the live outputs"
        $ do
            (result, requests) <- readWith 1000 honest holdingRetained
            result `shouldBe` Right retainedOutputs
            map rawCall requests
                `shouldBe` [CallPolicyAssetList, CallAssetUtxos, CallAssetUtxos]
            case requests of
                listing : first : second : _ -> do
                    rawMethod listing `shouldBe` Get
                    rawPath listing `shouldBe` "/policy_asset_list"
                    queryParam "_asset_policy" listing `shouldBe` Just retainedPolicyHex
                    queryParam "order" listing `shouldBe` Just "asset_name.asc"
                    lookup "prefer" (rawHeaders listing) `shouldBe` Just "count=exact"
                    assetListOf first `shouldBe` [(retainedPolicyHex, nameOneHex)]
                    assetListOf second `shouldBe` [(retainedPolicyHex, nameTwoHex)]
                other -> expectationFailure ("requests: " <> show (length other))
    it "never asks for the outputs at an address while it lists a policy" $ do
        (result, requests) <- readWith 1000 honest holdingRetained
        fmap (map fst) result `shouldBe` Right [retainedRef]
        map rawCall requests `shouldNotContain` [CallAddressUtxos]
    it
        "answers an empty complete listing with an empty list and reads nothing more"
        $ do
            let serving =
                    honest
                        { listingFor =
                            const (answerWith 200 [("content-range", "*/0")] retainedEmptyBody)
                        }
            (result, requests) <- readWith 1000 serving holdingRetained
            result `shouldBe` Right []
            map rawCall requests `shouldBe` [CallPolicyAssetList]
    it "reads a listing that arrives in 206 pages, one row at a time" $ do
        (result, requests) <- readWith 1 honest holdingRetained
        result `shouldBe` Right retainedOutputs
        map rawCall requests
            `shouldBe` [ CallPolicyAssetList
                       , CallPolicyAssetList
                       , CallAssetUtxos
                       , CallAssetUtxos
                       ]
        map offsetOf (take 2 requests) `shouldBe` [0, 1]
    describe "never turns a failed read into an empty list" $ do
        it "a listing cut off in the middle of its array" $
            namesFailure
                "PageCutOff"
                honest
                    { listingFor =
                        const
                            ( answerWith
                                200
                                [("content-range", "0-1/2")]
                                (BS.take 100 retainedListingBody)
                            )
                    }
                1000
        it "a listing with no exact total" $
            namesFailure
                "TotalMissing"
                honest
                    { listingFor = const (answerWith 200 [] retainedListingBody)
                    }
                1000
        it "a listing whose total changes between pages" $
            namesFailure
                "TotalChanged"
                honest
                    { listingFor = \raw -> case offsetOf raw of
                        0 -> answerWith 206 [("content-range", "0-0/2")] retainedFirstPageBody
                        _ -> answerWith 206 [("content-range", "1-1/3")] retainedSecondPageBody
                    }
                1
        it "a listing page with more rows than the limit" $
            namesFailure
                "PageOverLimit"
                honest
                    { listingFor =
                        const
                            (answerWith 200 [("content-range", "0-1/2")] retainedListingBody)
                    }
                1
        it "a listing that ends before its stated total" $
            namesFailure
                "RowsMissing"
                honest
                    { listingFor = \raw -> case offsetOf raw of
                        0 -> answerWith 206 [("content-range", "0-0/2")] retainedFirstPageBody
                        _ -> answerWith 200 [("content-range", "*/2")] retainedEmptyBody
                    }
                1
        it "a refused listing page" $
            namesFailure
                "RefusedByServer 400"
                honest
                    { listingFor = const (answerWith 400 [] "{\"message\":\"bad request\"}")
                    }
                1000
        it "a listing row without an asset name" $
            namesFailure
                "Undecodable"
                honest
                    { listingFor =
                        const
                            ( answerWith
                                200
                                [("content-range", "0-0/1")]
                                "[{\"fingerprint\":\"asset1\"}]"
                            )
                    }
                1000
        it "an asset read the service refuses as too large" $
            namesFailure
                "RefusedByServer 413"
                honest
                    { assetFor = \_ name ->
                        if name == nameOne
                            then answerWith 200 [("content-range", "0-0/1")] retainedUtxosBody
                            else answerWith 413 [] "payload too large"
                    }
                1000
        it "an asset read whose total changes between its pages" $
            namesFailure
                "TotalChanged"
                honest
                    { assetFor = \raw name ->
                        if name == nameOne
                            then case offsetOf raw of
                                0 -> answerWith 200 [("content-range", "0-0/2")] retainedUtxosBody
                                _ -> answerWith 200 [("content-range", "1-1/3")] retainedUtxosBody
                            else answerWith 200 [("content-range", "*/0")] "[]"
                    }
                1
    describe "merges what the singleton reads return" $ do
        it "one output returned by two reads is one output" $ do
            let serving =
                    honest
                        { assetFor = \_ _ ->
                            answerWith 200 [("content-range", "0-0/1")] retainedUtxosBody
                        }
            (result, _) <- readWith 1000 serving holdingRetained
            result `shouldBe` Right retainedOutputs
        it "one reference returned with two different contents is a conflict" $ do
            let altered =
                    replaceOnce
                        "\"value\":\"2000000\""
                        "\"value\":\"2000001\""
                        retainedUtxosBody
                serving =
                    honest
                        { assetFor = \_ name ->
                            if name == nameOne
                                then answerWith 200 [("content-range", "0-0/1")] retainedUtxosBody
                                else answerWith 200 [("content-range", "0-0/1")] altered
                        }
            (result, _) <- readWith 1000 serving holdingRetained
            result `shouldBe` Left (ConflictingOutput retainedRef)
    describe "composes with the other queries" $ do
        let retainedOut = case retainedOutputs of
                (_, out) : _ -> out
                [] -> error "no retained output"
            atRetained = AtAddress (retainedOut ^. addrTxOutL)
            addressAnswers ex = honest{addressFor = const ex}
            holdsOutput = answerWith 200 [("content-range", "0-0/1")] retainedUtxosBody
            holdsNothing = answerWith 200 [("content-range", "*/0")] retainedEmptyBody
        it "any-of a policy and an address is the union" $ do
            (result, _) <-
                readWith
                    1000
                    (addressAnswers holdsOutput)
                    (AnyOf (holdingRetained :| [atRetained]))
            result `shouldBe` Right retainedOutputs
        it "all-of a policy and the address of its output keeps the output" $ do
            (result, _) <-
                readWith
                    1000
                    (addressAnswers holdsOutput)
                    (AllOf (holdingRetained :| [atRetained]))
            result `shouldBe` Right retainedOutputs
        it
            "all-of a policy and an address that holds none of its outputs is empty"
            $ do
                (result, _) <-
                    readWith
                        1000
                        (addressAnswers holdsNothing)
                        (AllOf (holdingRetained :| [atRetained]))
                result `shouldBe` Right []
        it "any-of a policy and an address whose read fails refuses the whole" $ do
            (result, _) <-
                readWith
                    1000
                    ( addressAnswers
                        (answerWith 400 [] "{\"message\":\"bad request\"}")
                    )
                    (AnyOf (holdingRetained :| [atRetained]))
            case result of
                Left (BackendReadFailure reason) ->
                    T.unpack reason `shouldSatisfy` isInfixOf "RefusedByServer 400"
                other -> expectationFailure ("expected a refusal, got " <> show other)

-- ---------------------------------------------------------
-- What the consumer accepts of what discovery lists
-- ---------------------------------------------------------

cfg :: CageConfig
cfg = Fixture.cfg

tokenId :: TokenId
tokenId = Fixture.tokenId

requestAddr :: Addr
requestAddr = requestAddrFromCfg cfg tokenId Ledger.Testnet

requestPolicyId :: PolicyID
requestPolicyId = policyIdFromPin Fixture.requestPin

registryName :: ByteString
registryName = case unTokenId tokenId of
    AssetName n -> SBS.fromShort n

outRef :: Char -> Int -> TxIn
outRef c i =
    either
        (error . ("TaggedDiscoverySpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#" <> show i)))

nameOf :: ByteString -> AssetName
nameOf = AssetName . SBS.toShort

registrationFor :: ByteString -> OnChainRegistrationRequest
registrationFor key =
    OnChainRegistrationRequest
        { regRegistry = OnChainTokenId (BuiltinByteString registryName)
        , regKey = key
        , regRefundAddress = BuiltinByteString (BS.replicate 28 0xd1)
        , regDestination = BS.cons 0x60 (BS.replicate 28 0x77)
        , regDatum = Just (I 7)
        , regSubmittedAt = 5_000
        , regRegistrationCost = 2_000_000
        , regDeclaredTip = 1_500_000
        , regCarrierAda = 1_500_000
        , regNonce = 5
        }

tagsFor :: ByteString -> MultiAsset
tagsFor trieName =
    MultiAsset
        (Map.singleton requestPolicyId (Map.singleton (nameOf trieName) 1))

-- | A booked registration at the request address, tagged by the name its own datum commits to.
registrationOutput :: OnChainRegistrationRequest -> TxOut ConwayEra
registrationOutput r =
    mkBasicTxOut
        requestAddr
        (MaryValue (Coin 5_000_000) (tagsFor (trieReadyTagName r)))
        & datumTxOutL .~ mkInlineDatum (toPlcData (RegistrationDatum r))

{- | A booked termination at the request address: the datum written field by
field without the codec, tagged by the name a program computed for it.
-}
terminationOutput :: TxOut ConwayEra
terminationOutput =
    mkBasicTxOut
        requestAddr
        (MaryValue (Coin 4_000_000) (tagsFor terminationTag))
        & datumTxOutL .~ mkInlineDatum terminationDatum

terminationTag :: ByteString
terminationTag =
    unhex
        "054c1c37bccb9747e1b4e0b76a7ddd96daf15b06d109654eecab7cde86b02e8a"

-- | The vector's key, empty destination and nonce 1: the preimage the tag was computed from.
terminationDatum :: Data
terminationDatum =
    Constr
        4
        [ Constr
            0
            [ Constr 0 [B registryName]
            , B (unhex "6b657942")
            , B BS.empty
            , I 1_500_000
            , I 2_500_000
            , I 1
            ]
        ]

genuineList :: [(TxIn, TxOut ConwayEra)]
genuineList =
    [ (outRef 'a' 0, registrationOutput (registrationFor "key-a"))
    , (outRef 'a' 1, registrationOutput (registrationFor "key-b"))
    , (outRef 'a' 2, terminationOutput)
    ]

-- | Each way an output can hold a request-policy tag without being a request of this registry.
impostors :: [(String, (TxIn, TxOut ConwayEra))]
impostors =
    [
        ( "an output at another address holding a valid booking"
        ,
            ( outRef 'b' 0
            , registrationOutput (registrationFor "key-c") `at` Fixture.payer
            )
        )
    ,
        ( "an output at the request address whose tag is not the name its datum commits to"
        ,
            ( outRef 'b' 1
            , mkBasicTxOut
                requestAddr
                ( MaryValue
                    (Coin 5_000_000)
                    (tagsFor (flipFirstByte (trieReadyTagName (registrationFor "key-d"))))
                )
                & datumTxOutL
                    .~ mkInlineDatum
                        (toPlcData (RegistrationDatum (registrationFor "key-d")))
            )
        )
    ,
        ( "an output at the request address whose datum is the legacy edge-only request"
        ,
            ( outRef 'b' 2
            , mkBasicTxOut
                requestAddr
                (MaryValue (Coin 5_000_000) (tagsFor "any legacy tag"))
                & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum legacyRequest))
            )
        )
    ,
        ( "an output at the request address whose datum is not a cage datum"
        ,
            ( outRef 'b' 3
            , mkBasicTxOut
                requestAddr
                (MaryValue (Coin 5_000_000) (tagsFor "any malformed tag"))
                & datumTxOutL .~ mkInlineDatum (I 7)
            )
        )
    ,
        ( "an output at the request address with no datum"
        ,
            ( outRef 'b' 4
            , mkBasicTxOut
                requestAddr
                (MaryValue (Coin 5_000_000) (tagsFor "any bare tag"))
            )
        )
    ,
        ( "a booking for another registry, rightly tagged"
        ,
            ( outRef 'b' 5
            , registrationOutput
                (registrationFor "key-e")
                    { regRegistry = OnChainTokenId (BuiltinByteString "another registry")
                    }
            )
        )
    ]
  where
    at out address = out & addrTxOutL .~ address
    flipFirstByte b = BS.cons (BS.head b + 1) (BS.tail b)
    legacyRequest =
        OnChainRequest
            { requestToken = OnChainTokenId (BuiltinByteString registryName)
            , requestOwner = BuiltinByteString (BS.replicate 28 0xd1)
            , requestKey = "legacy-key"
            , requestEdge = 1
            , requestDeposit = 2_000_000
            , requestSubmittedAt = 1_000
            , requestDestination = (BS.cons 0x60 (BS.replicate 28 0x77), Nothing)
            }

-- | Untagged outputs at the request address: pollution that no tag read can see.
pollution :: [(TxIn, TxOut ConwayEra)]
pollution =
    [ ( outRef 'c' i
      , mkBasicTxOut
            requestAddr
            (MaryValue (Coin (2_000_000 + toInteger i)) mempty)
      )
    | i <- [0 .. 4]
    ]

{- | A session that serves a policy listing and the request address's outputs,
and remembers every query it is asked.
-}
viewOver
    :: IORef [OutputQuery]
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Session NoWitness IO
viewOver asked listed atAddress =
    recording $
        withAddressOutputs
            (\a -> pure (if a == requestAddr then atAddress else []))
            (withPolicyOutputs (\_ -> pure listed) stubSession)
  where
    recording session =
        session
            { outputs = \query -> do
                modifyIORef' asked (<> [query])
                outputs session query
            }

consumerSpec :: Spec
consumerSpec = describe "the consumer authenticates what discovery lists" $ do
    it
        "finds the genuine registrations and terminations in output-reference order"
        $ do
            asked <- newIORef []
            found <-
                pendingByTag cfg (viewOver asked genuineList genuineList) tokenId
            found `shouldBe` sort' genuineList
    it
        "asks for the outputs holding the request policy and for nothing else"
        $ do
            asked <- newIORef []
            found <-
                pendingByTag cfg (viewOver asked genuineList genuineList) tokenId
            length found `shouldBe` length genuineList
            readIORef asked `shouldReturn` [HoldingPolicy requestPolicyId]
    describe
        "excludes an output that holds the tag without being a genuine request"
        $ forM_ impostors
        $ \(what, impostor) ->
            it what $ do
                asked <- newIORef []
                let listed = genuineList <> [impostor]
                found <- pendingByTag cfg (viewOver asked listed listed) tokenId
                found `shouldBe` sort' genuineList
    it "is not changed by untagged outputs at the request address" $ do
        askedClean <- newIORef []
        askedPolluted <- newIORef []
        clean <-
            pendingByTag cfg (viewOver askedClean genuineList genuineList) tokenId
        polluted <-
            pendingByTag
                cfg
                (viewOver askedPolluted genuineList (genuineList <> pollution))
                tokenId
        polluted `shouldBe` clean
        clean `shouldBe` sort' genuineList
    it "finds nothing when the complete listing is empty" $ do
        asked <- newIORef []
        found <- pendingByTag cfg (viewOver asked [] pollution) tokenId
        found `shouldBe` []
        readIORef asked `shouldReturn` [HoldingPolicy requestPolicyId]
    it "fails with the listing's own failure instead of finding nothing" $ do
        let failing =
                stubSession
                    { outputs = \_ -> pure (Left (BackendReadFailure "page refused"))
                    }
        outcome <- try (pendingByTag cfg failing tokenId)
        case outcome of
            Left (BackendReadFailure reason) ->
                T.unpack reason `shouldSatisfy` isInfixOf "page refused"
            Left other -> expectationFailure ("another failure: " <> show other)
            Right found ->
                expectationFailure ("found " <> show (length found) <> " requests")
  where
    sort' = sortOn fst
