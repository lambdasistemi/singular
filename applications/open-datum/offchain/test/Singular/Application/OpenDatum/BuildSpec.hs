{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.BuildSpec
Description : The envelope built from its sources, and the readers behind it
License     : Apache-2.0

The expected side of every byte comparison is the detailed-schema JSON a
user writes by hand today (the shape @tools/demo1_cli_journey.sh@ feeds
@jq@), decoded by the generic datum reader. It is never produced by the
builder under test.
-}
module Singular.Application.OpenDatum.BuildSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec
import Test.QuickCheck

import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Build
import Singular.Application.OpenDatum.Envelope

spec :: Spec
spec = describe "the envelope built from its sources" $ do
    constants
    bytes
    perField
    keyReading
    keyRefusals
    depositReading
    payloadReading

-- ---------------------------------------------------------
-- The six sources, and the hand-built envelope they make
-- ---------------------------------------------------------

data Inputs = Inputs
    { iPolicy :: ByteString
    , iName :: ByteString
    , iActive :: ByteString
    , iKey :: ByteString
    , iController :: ByteString
    , iDeposit :: Integer
    , iPayload :: Value
    }
    deriving stock (Eq, Show)

hex :: ByteString -> Value
hex = Aeson.toJSON . TE.decodeUtf8 . B16.encode

-- | The JSON a user writes by hand: the jq shape of the journey.
handJson :: Inputs -> Value
handJson i =
    object
        [ "constructor" .= (0 :: Int)
        , "fields"
            .= [ object
                    [ "constructor" .= (0 :: Int)
                    , "fields"
                        .= [ object ["int" .= (1 :: Int)]
                           , object
                                [ "constructor" .= (0 :: Int)
                                , "fields"
                                    .= [ object ["bytes" .= hex (iPolicy i)]
                                       , object ["bytes" .= hex (iName i)]
                                       ]
                                ]
                           , object ["bytes" .= hex (iActive i)]
                           , object ["bytes" .= hex (iKey i)]
                           , object ["bytes" .= hex (iController i)]
                           , object ["int" .= iDeposit i]
                           ]
                    ]
               , iPayload i
               ]
        ]

-- | The datum the hand-built JSON is, read by the generic datum reader.
expectedData :: Inputs -> PLC.Data
expectedData = either error id . dataFromJson . handJson

-- | The envelope the builder makes from the same sources.
built :: Inputs -> Envelope
built i =
    buildEnvelope
        (StateAsset (iPolicy i) (iName i))
        (iActive i)
        (iKey i)
        (iController i)
        (iDeposit i)
        (either error id (dataFromJson (iPayload i)))

-- | The journey's own values: a nested payload, the minimum deposit.
baseline :: Inputs
baseline =
    Inputs
        { iPolicy = BS.replicate 28 0x11
        , iName = "registry-token"
        , iActive = BS.replicate 28 0x22
        , iKey = "alice-1"
        , iController = BS.replicate 28 0x33
        , iDeposit = 2_000_000
        , iPayload =
            object
                [ "map"
                    .= [ object
                            [ "k" .= object ["bytes" .= ("6e616d65" :: Text)]
                            , "v"
                                .= object
                                    [ "list"
                                        .= [ object ["int" .= (-7 :: Int)]
                                           , object ["bytes" .= ("616c696365" :: Text)]
                                           , object
                                                [ "constructor" .= (2 :: Int)
                                                , "fields" .= ([] :: [Value])
                                                ]
                                           ]
                                    ]
                            ]
                       ]
                ]
        }

genBytes :: Int -> Int -> Gen ByteString
genBytes lo hi = do
    n <- choose (lo, hi)
    BS.pack <$> vectorOf n arbitrary

genPayload :: Gen Value
genPayload =
    oneof
        [ pure (iPayload baseline)
        , (\n -> object ["int" .= (n :: Integer)]) <$> arbitrary
        , (\b -> object ["bytes" .= TE.decodeUtf8 (B16.encode b)])
            <$> genBytes 0 40
        , pure (object ["list" .= ([] :: [Value])])
        ]

genInputs :: Gen Inputs
genInputs =
    Inputs
        <$> genBytes 28 28
        <*> genBytes 0 32
        <*> genBytes 28 28
        <*> genBytes 1 32
        <*> genBytes 28 28
        <*> ((+ minimumDepositForGen) . getNonNegative <$> arbitrary)
        <*> genPayload

-- | The ruled minimum, 2 000 000 lovelace, spelled for the generator.
minimumDepositForGen :: Integer
minimumDepositForGen = 2_000_000

-- ---------------------------------------------------------
-- The constants
-- ---------------------------------------------------------

constants :: Spec
constants = describe "constants" $ do
    it "the minimum deposit is 2 000 000 lovelace" $
        minimumDeposit `shouldBe` 2_000_000
    it "a key is at most 32 bytes" $
        maxKeyBytes `shouldBe` 32

-- ---------------------------------------------------------
-- Envelope bytes match the hand-built value
-- ---------------------------------------------------------

bytes :: Spec
bytes = describe "the builder against the hand-built envelope" $ do
    it "builds the journey envelope: Data equal" $
        envelopeToData (built baseline) `shouldBe` expectedData baseline
    it "builds the journey envelope: CBOR equal" $
        envelopeCbor (built baseline)
            `shouldBe` dataCbor (expectedData baseline)
    it "builds the hand-built envelope for any sources" $
        forAll genInputs $ \i ->
            dataCbor (expectedData i) === envelopeCbor (built i)
    it "builds under the one envelope version" $
        ctlVersion (envControl (built baseline)) `shouldBe` envelopeVersion

-- ---------------------------------------------------------
-- Each field preserves the envelope bytes and source values
-- ---------------------------------------------------------

altPayload :: Value
altPayload = object ["bytes" .= ("00ff" :: Text)]

fields :: [(String, Inputs -> Inputs)]
fields =
    [ ("state policy", \i -> i{iPolicy = BS.replicate 28 0xa1})
    , ("state token name", \i -> i{iName = "another-token"})
    , ("active policy", \i -> i{iActive = BS.replicate 28 0xa2})
    , ("key", \i -> i{iKey = "bob-2"})
    , ("controller", \i -> i{iController = BS.replicate 28 0xa3})
    , ("deposit", \i -> i{iDeposit = 3_500_000})
    , ("payload", \i -> i{iPayload = altPayload})
    ]

perField :: Spec
perField =
    describe "each source reaches the envelope" $
        mapM_ one fields
  where
    one (name, change) = describe name $ do
        let moved = change baseline
        it "matches the hand-built envelope with it changed" $
            envelopeCbor (built moved)
                `shouldBe` dataCbor (expectedData moved)
        it "differs from the envelope without the change" $
            envelopeCbor (built moved)
                `shouldNotBe` envelopeCbor (built baseline)
        it "differs from the hand-built envelope without the change" $
            envelopeCbor (built moved)
                `shouldNotBe` dataCbor (expectedData baseline)

-- ---------------------------------------------------------
-- Key text and byte spelling
-- ---------------------------------------------------------

utf8 :: Text -> ByteString
utf8 = TE.encodeUtf8

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

genKeyText :: Gen Text
genKeyText = do
    n <- choose (1, 10)
    T.pack <$> vectorOf n (elements "abcXYZ019-_.é€ ")

keyReading :: Spec
keyReading = describe "reading a key" $ do
    it "reads text as its UTF-8 bytes" $
        readKey KeyText "alice-1" `shouldBe` Right "alice-1"
    it "reads hex as its bytes" $
        readKey KeyHex "616c6963652d31" `shouldBe` Right "alice-1"
    it "reads upper-case hex as its bytes" $
        readKey KeyHex "616C6963652D31" `shouldBe` Right "alice-1"
    it "reads the text and the hex of the same bytes alike" $
        forAll genKeyText $ \t ->
            readKey KeyText t === readKey KeyHex (hexText (utf8 t))
    it "builds the same envelope from either reading" $
        let envelopeOf k = built baseline{iKey = k}
        in  (envelopeOf <$> readKey KeyText "alice-1")
                `shouldBe` (envelopeOf <$> readKey KeyHex "616c6963652d31")
    it "takes a hex-looking string as text when read as text" $
        readKey KeyText "616c6963652d31"
            `shouldBe` Right (utf8 "616c6963652d31")
    it "does not take a hex-looking string for the bytes it spells" $
        readKey KeyText "616c6963652d31"
            `shouldNotBe` readKey KeyHex "616c6963652d31"
    it "accepts a key of exactly 32 bytes, in either spelling" $ do
        readKey KeyText (T.replicate 32 "k")
            `shouldBe` Right (BS.replicate 32 0x6b)
        readKey KeyHex (T.replicate 32 "6b")
            `shouldBe` Right (BS.replicate 32 0x6b)

-- ---------------------------------------------------------
-- Refusing an invalid key
-- ---------------------------------------------------------

keyRefusals :: Spec
keyRefusals = describe "refusing a key" $ do
    it "refuses empty text as empty" $
        readKey KeyText "" `shouldBe` Left KeyEmpty
    it "refuses empty hex as empty" $
        readKey KeyHex "" `shouldBe` Left KeyEmpty
    it "refuses non-hex characters as not hex" $
        readKey KeyHex "zz" `shouldBe` Left KeyNotHex
    it "refuses an odd number of hex digits as not hex" $
        readKey KeyHex "abc" `shouldBe` Left KeyNotHex
    it "refuses a 0x prefix as not hex" $
        readKey KeyHex "0x61" `shouldBe` Left KeyNotHex
    it "refuses surrounding whitespace as not hex" $ do
        readKey KeyHex " 61" `shouldBe` Left KeyNotHex
        readKey KeyHex "61 " `shouldBe` Left KeyNotHex
    it "refuses 33 bytes of text as too long, naming the length" $
        readKey KeyText (T.replicate 33 "k") `shouldBe` Left (KeyTooLong 33)
    it "refuses 33 bytes of hex as too long, naming the length" $
        readKey KeyHex (T.replicate 33 "6b") `shouldBe` Left (KeyTooLong 33)
    it "counts text in bytes, not characters" $
        -- 17 characters of two bytes each
        readKey KeyText (T.replicate 17 "é") `shouldBe` Left (KeyTooLong 34)

-- ---------------------------------------------------------
-- Refusing an invalid deposit
-- ---------------------------------------------------------

depositReading :: Spec
depositReading = describe "reading a deposit" $ do
    it "takes an absent deposit to be the minimum" $
        readDeposit Nothing `shouldBe` Right minimumDeposit
    it "accepts the minimum exactly" $
        readDeposit (Just "2000000") `shouldBe` Right 2_000_000
    it "accepts more than the minimum" $
        readDeposit (Just "3500000") `shouldBe` Right 3_500_000
    it "accepts a deposit beyond a machine word" $
        readDeposit (Just "99999999999999999999")
            `shouldBe` Right 99_999_999_999_999_999_999
    it "refuses one lovelace below the minimum, naming the amount" $
        readDeposit (Just "1999999")
            `shouldBe` Left (DepositBelowMinimum 1_999_999)
    it "refuses zero as below the minimum" $
        readDeposit (Just "0") `shouldBe` Left (DepositBelowMinimum 0)
    it "refuses a negative amount as below the minimum" $
        readDeposit (Just "-5") `shouldBe` Left (DepositBelowMinimum (-5))
    it "refuses what is not an integer, as not an integer" $
        mapM_
            ( \t ->
                (t, readDeposit (Just t)) `shouldBe` (t, Left DepositNotInteger)
            )
            [ ""
            , "abc"
            , "-"
            , "2000000.5"
            , "1e7"
            , "0x2000000"
            , " 2000000"
            , "2000000 "
            , "+2000000"
            , "2_000_000"
            , "\1639\1639\1639" -- Arabic-Indic digits
            ]

-- ---------------------------------------------------------
-- Refusing an invalid payload
-- ---------------------------------------------------------

payloadReading :: Spec
payloadReading = describe "reading a payload" $ do
    it "reads detailed-schema JSON as the datum it is" $
        forAll genData' $
            \d -> readPayload (dataToJson d) === Right d
    it "reads the journey payload as the generic reader does" $
        fmap Right (dataFromJson (iPayload baseline))
            `shouldBe` Right (readPayload (iPayload baseline))
    mapM_
        refused
        [ ("an object of no datum shape", object ["foo" .= (1 :: Int)])
        , ("a bare string", Aeson.toJSON ("plutus" :: Text))
        , ("a bare number", Aeson.toJSON (3 :: Int))
        ,
            ( "an integer written as a fraction"
            , object ["int" .= (1.5 :: Double)]
            )
        , ("bytes that are not hex", object ["bytes" .= ("zz" :: Text)])
        , ("a list that is not an array", object ["list" .= (1 :: Int)])
        ,
            ( "a negative constructor"
            , object ["constructor" .= (-1 :: Int), "fields" .= ([] :: [Value])]
            )
        ]
  where
    refused (name, v) =
        it ("refuses " <> name <> " as not Plutus data") $
            readPayload v `shouldSatisfy` isNotData
    isNotData = \case
        Left (PayloadNotPlutusData _) -> True
        Right _ -> False
    genData' =
        oneof
            [ PLC.I <$> arbitrary
            , PLC.B <$> genBytes 0 8
            , pure (PLC.Constr 3 [PLC.I 1, PLC.B "x"])
            , pure (PLC.Map [(PLC.I 1, PLC.List [PLC.I 2])])
            ]
