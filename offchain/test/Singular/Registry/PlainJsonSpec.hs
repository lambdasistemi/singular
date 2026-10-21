{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.PlainJsonSpec
Description : A payload written as plain JSON
License     : Apache-2.0

The plain mapping from JSON to Plutus data and its reading back (#719).
The worked examples are the spec's table; the expected data of each comes
from the detailed-schema reader that shipped before the mapping existed,
read from the detailed document the spec works out by hand, never typed
as data here. The properties are over generated documents, and every
refusal is checked for the path it names against a path the generator
chose.
-}
module Singular.Registry.PlainJsonSpec (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Foldable (toList)
import Data.List (isInfixOf, sortOn)
import Data.Maybe (isJust, isNothing)
import Data.Ratio (denominator, numerator)
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import PlutusCore.Data qualified as PLC
import System.Timeout (timeout)
import Test.Hspec
import Test.QuickCheck

import Singular.Registry.Application (datumFromJson, datumToJson)
import Singular.Registry.PlainJson
    ( PathStep (..)
    , PayloadSchema (..)
    , PayloadView (..)
    , PlainReason (..)
    , PlainRefusal (..)
    , parseSchemaName
    , payloadFromJson
    , payloadView
    , plainDigitLimit
    , plainFromData
    , plainToData
    , renderPlainRefusal
    , schemaName
    )

-- ---------------------------------------------------------
-- Reading documents the way a file is read
-- ---------------------------------------------------------

-- | A JSON document from its text, as a payload file is parsed.
parseJson :: LBS.ByteString -> Value
parseJson =
    either (error . ("test document is not JSON: " <>)) id
        . Aeson.eitherDecode

{- | The data a detailed-schema document stands for, by the reader that
shipped before the plain mapping.
-}
detailedData :: LBS.ByteString -> PLC.Data
detailedData =
    either (error . ("test document is not detailed: " <>)) id
        . datumFromJson
        . parseJson

-- | The sentence of a refusal, or the marker that the document was mapped.
refusalText :: Value -> Text
refusalText = either renderPlainRefusal (const "<mapped>") . plainToData

-- ---------------------------------------------------------
-- The table of the spec: file, detailed document of the same data
-- ---------------------------------------------------------

tableRows :: [(String, LBS.ByteString, LBS.ByteString)]
tableRows =
    [ ("a whole number", "42", "{\"int\":42}")
    , ("a negative number", "-7", "{\"int\":-7}")
    , ("zero", "0", "{\"int\":0}")
    , ("a number written 1.0", "1.0", "{\"int\":1}")
    , ("a number written 5e2", "5e2", "{\"int\":500}")
    ,
        ( "a number written 0.5e1000"
        , "0.5e1000"
        , "{\"int\":5" <> LBS.replicate 999 48 <> "}"
        )
    , ("a text", "\"alice\"", "{\"bytes\":\"616c696365\"}")
    , ("the empty text", "\"\"", "{\"bytes\":\"\"}")
    , ("a text outside ASCII", "\"\\u00e9\"", "{\"bytes\":\"c3a9\"}")
    ,
        ( "a text outside the basic plane"
        , "\"\\ud800\\udc00\""
        , "{\"bytes\":\"f0908080\"}"
        )
    , ("true", "true", "{\"constructor\":1,\"fields\":[]}")
    , ("false", "false", "{\"constructor\":0,\"fields\":[]}")
    , ("the empty array", "[]", "{\"list\":[]}")
    ,
        ( "an array"
        , "[1, \"a\", true, [2]]"
        , "{\"list\":[{\"int\":1},{\"bytes\":\"61\"},{\"constructor\":1,\"fields\":[]},{\"list\":[{\"int\":2}]}]}"
        )
    , ("the empty object", "{}", "{\"map\":[]}")
    ,
        ( "an object with one key"
        , "{\"answer\": 42}"
        , "{\"map\":[{\"k\":{\"bytes\":\"616e73776572\"},\"v\":{\"int\":42}}]}"
        )
    ,
        ( "an object, entries in ascending order of key"
        , "{\"b\": 2, \"a\": 1}"
        , "{\"map\":[{\"k\":{\"bytes\":\"61\"},\"v\":{\"int\":1}},{\"k\":{\"bytes\":\"62\"},\"v\":{\"int\":2}}]}"
        )
    ,
        ( "an object, keys ordered by bytes and not by letters"
        , "{\"a\": 1, \"B\": 2, \"\": 3}"
        , "{\"map\":[{\"k\":{\"bytes\":\"\"},\"v\":{\"int\":3}},{\"k\":{\"bytes\":\"42\"},\"v\":{\"int\":2}},{\"k\":{\"bytes\":\"61\"},\"v\":{\"int\":1}}]}"
        )
    ,
        ( "an object, keys ordered by UTF-8 bytes and not by UTF-16 units"
        , "{\"\\ud800\\udc00\": 1, \"\\uff61\": 2}"
        , "{\"map\":[{\"k\":{\"bytes\":\"efbda1\"},\"v\":{\"int\":2}},{\"k\":{\"bytes\":\"f0908080\"},\"v\":{\"int\":1}}]}"
        )
    ,
        ( "an object inside an object"
        , "{\"outer\": {\"inner\": []}}"
        , "{\"map\":[{\"k\":{\"bytes\":\"6f75746572\"},\"v\":{\"map\":[{\"k\":{\"bytes\":\"696e6e6572\"},\"v\":{\"list\":[]}}]}}]}"
        )
    ,
        ( "an object that looks like a datum, nested in a larger document"
        , "{\"wrapper\": {\"int\": 5}}"
        , "{\"map\":[{\"k\":{\"bytes\":\"77726170706572\"},\"v\":{\"map\":[{\"k\":{\"bytes\":\"696e74\"},\"v\":{\"int\":5}}]}}]}"
        )
    ,
        ( "an array of objects that look like datums"
        , "[{\"int\": 5}]"
        , "{\"list\":[{\"map\":[{\"k\":{\"bytes\":\"696e74\"},\"v\":{\"int\":5}}]}]}"
        )
    ,
        ( "an object whose int is not a number, which the detailed schema does not accept"
        , "{\"int\": \"x\"}"
        , "{\"map\":[{\"k\":{\"bytes\":\"696e74\"},\"v\":{\"bytes\":\"78\"}}]}"
        )
    ,
        ( "a repeated key keeps its first value, as the JSON reader does"
        , "{\"a\": 1, \"a\": 2}"
        , "{\"map\":[{\"k\":{\"bytes\":\"61\"},\"v\":{\"int\":1}}]}"
        )
    ]

-- ---------------------------------------------------------
-- Generators
-- ---------------------------------------------------------

-- | A text that includes characters outside the basic plane.
genText :: Gen Text
genText = T.pack <$> listOf genChar
  where
    genChar =
        frequency
            [ (8, choose ('a', 'e'))
            , (2, arbitraryASCIIChar)
            , (2, choose ('\x80', '\x7ff'))
            , (1, choose ('\x800', '\xd7ff'))
            , (1, choose ('\xe000', '\x10ffff'))
            ]

-- | A key from a small set, so documents repeat keys, or any text.
genKey :: Gen Text
genKey =
    frequency
        [(3, elements ["a", "b", "", "int", "map", "\233"]), (2, genText)]

-- | A whole number in one of the spellings a file may use, up to the limit.
genWholeNumber :: Gen Scientific
genWholeNumber =
    oneof
        [ fromInteger <$> arbitrary
        , Sci.scientific <$> choose (-1000, 1000) <*> choose (0, 30)
        , do
            n <- arbitrary
            k <- choose (1, 12)
            pure (Sci.scientific (n * 10 ^ k) (negate k))
        , fromInteger <$> genDigits
        , elements
            [ fromInteger (10 ^ (999 :: Int))
            , fromInteger (negate (10 ^ (999 :: Int)))
            ]
        ]

-- | The spec's limit, written here so the module's own constant is checked against it.
specLimit :: Int
specLimit = 1000

-- | An integer of one to the limit digits, sometimes close to the limit.
genDigits :: Gen Integer
genDigits = do
    digits <-
        frequency [(5, choose (1, 40)), (1, choose (990, specLimit))]
    lead <- choose (1, 9)
    rest <- vectorOf (digits - 1) (choose (0, 9))
    sign <- elements [1, -1]
    pure (sign * foldl (\acc d -> acc * 10 + d) 0 (lead : rest))

-- | A whole integer, any size up to the limit.
genWholeInteger :: Gen Integer
genWholeInteger = oneof [arbitrary, genDigits]

-- | A leaf the plain mapping accepts.
genScalar :: Gen Value
genScalar =
    oneof
        [ Number <$> genWholeNumber
        , String <$> genText
        , Bool <$> arbitrary
        ]

{- | How deep a generated tree may go for the size QuickCheck asks for, so a
document stays a few hundred nodes however large the size grows.
-}
depthFor :: Int -> Int
depthFor size = min 4 (size `div` 15)

-- | A few children, at most four.
genChildren :: Gen a -> Gen [a]
genChildren child = choose (0, 4) >>= (`vectorOf` child)

-- | A tree of arrays and objects over a leaf generator, to a depth.
genTree :: Gen Value -> Int -> Gen Value
genTree leaf depth
    | depth <= 0 = leaf
    | otherwise =
        frequency
            [ (4, leaf)
            , (2, Aeson.toJSON <$> genChildren below)
            , (2, objectOf <$> genChildren ((,) <$> genKey <*> below))
            ]
  where
    below = genTree leaf (depth - 1)

-- | A JSON document the plain mapping accepts.
genPlainJson :: Gen Value
genPlainJson = sized (genTree genScalar . depthFor)

objectOf :: [(Text, Value)] -> Value
objectOf entries = Object (KeyMap.fromList [(Key.fromText k, v) | (k, v) <- entries])

-- | A leaf the plain mapping refuses, with the kind of reason it gives.
genBadLeaf :: Gen (Value, PlainReason -> Bool)
genBadLeaf =
    oneof
        [ pure (Null, (== IsNull))
        , do
            whole <- fromInteger <$> arbitrary
            frac <-
                elements
                    [ Sci.scientific 5 (-1)
                    , Sci.scientific 1 (-3)
                    , Sci.scientific 123456789 (-4)
                    ]
            let n = whole + frac
            pure (Number n, isFraction)
        , pure (Number (Sci.scientific 1 5000), isTooLarge)
        , pure (Number (Sci.scientific 7 1000000000), isTooLarge)
        , pure (Number (Sci.scientific (-3) (-1000000000)), isFraction)
        , do
            extra <- choose (1, 50)
            pure (Number (fromInteger (10 ^ (specLimit + extra - 1))), isTooLarge)
        ]
  where
    isFraction = \case HasFraction _ -> True; _ -> False
    isTooLarge = \case TooLarge _ -> True; _ -> False

-- | A document that may hold refused values anywhere, several at once.
genAnyJson :: Gen Value
genAnyJson = sized (genTree leaf . depthFor)
  where
    leaf =
        frequency
            [ (6, genScalar)
            , (2, fst <$> genBadLeaf)
            ]

-- | Put one refused value at a random place of an accepted document; say where.
injectBad :: Value -> Gen (Value, [PathStep], PlainReason -> Bool)
injectBad doc = do
    (bad, isReason) <- genBadLeaf
    (doc', path) <- place bad doc
    pure (doc', path, isReason)
  where
    place bad v = case v of
        Array xs
            | items@(_ : _) <- toList xs ->
                frequency
                    [ (1, pure (bad, []))
                    ,
                        ( 3
                        , do
                            i <- choose (0, length items - 1)
                            (child, path) <- place bad (items !! i)
                            pure
                                ( Aeson.toJSON (take i items <> [child] <> drop (i + 1) items)
                                , IndexStep i : path
                                )
                        )
                    ]
        Object o
            | entries@(_ : _) <- KeyMap.toList o ->
                frequency
                    [ (1, pure (bad, []))
                    ,
                        ( 3
                        , do
                            i <- choose (0, length entries - 1)
                            let (key, value) = entries !! i
                            (child, path) <- place bad value
                            pure
                                ( Object
                                    ( KeyMap.fromList
                                        (take i entries <> [(key, child)] <> drop (i + 1) entries)
                                    )
                                , KeyStep (Key.toText key) : path
                                )
                        )
                    ]
        _ -> pure (bad, [])

-- | The value a path names in a document, when there is one.
valueAt :: [PathStep] -> Value -> Maybe Value
valueAt [] v = Just v
valueAt (KeyStep k : rest) (Object o) = KeyMap.lookup (Key.fromText k) o >>= valueAt rest
valueAt (IndexStep i : rest) (Array xs)
    | i >= 0, i < length xs = valueAt rest (toList xs !! i)
valueAt _ _ = Nothing

-- | Data with a plain reading, built from its description and not from the mapping.
genPlainData :: Gen PLC.Data
genPlainData = sized (go . depthFor)
  where
    leaf =
        oneof
            [ PLC.I <$> genWholeInteger
            , PLC.B . TE.encodeUtf8 <$> genText
            , pure (PLC.Constr 0 [])
            , pure (PLC.Constr 1 [])
            ]
    go depth
        | depth <= 0 = leaf
        | otherwise =
            frequency
                [ (4, leaf)
                , (2, PLC.List <$> genChildren (go (depth - 1)))
                , (2, genPlainMap (go (depth - 1)))
                ]

-- | A map whose keys are texts in strictly ascending order of their bytes.
genPlainMap :: Gen PLC.Data -> Gen PLC.Data
genPlainMap value = do
    keys <-
        Set.toAscList . Set.fromList . map TE.encodeUtf8
            <$> genChildren genKey
    PLC.Map <$> mapM (\k -> (,) (PLC.B k) <$> value) keys

-- | A node the plain reading cannot read: one of the cases the spec lists.
genNonPlainNode :: Gen PLC.Data
genNonPlainNode =
    oneof
        [ PLC.B <$> elements ["\xff", "\xc0\xaf", "\xed\xa0\x80", "a\x80"]
        , PLC.Constr <$> elements [2, 3, 7, 100] <*> pure []
        , PLC.Constr <$> elements [0, 1] <*> (pure . PLC.I <$> arbitrary)
        , PLC.Map . pure . (,) (PLC.I 1) . PLC.I <$> arbitrary
        , pure (PLC.Map [(PLC.B "b", PLC.I 1), (PLC.B "a", PLC.I 2)])
        , pure (PLC.Map [(PLC.B "a", PLC.I 1), (PLC.B "a", PLC.I 2)])
        , PLC.I . (10 ^ specLimit *) <$> elements [1, -1, 3]
        ]

-- | A plain datum with one place replaced by a node that has no plain reading.
genNonPlainData :: Gen PLC.Data
genNonPlainData = genPlainData >>= place
  where
    place d = do
        bad <- genNonPlainNode
        case d of
            PLC.List items@(_ : _) ->
                frequency
                    [ (1, pure bad)
                    ,
                        ( 3
                        , do
                            i <- choose (0, length items - 1)
                            c <- place (items !! i)
                            pure (PLC.List (take i items <> [c] <> drop (i + 1) items))
                        )
                    ]
            PLC.Map entries@(_ : _) ->
                frequency
                    [ (1, pure bad)
                    ,
                        ( 3
                        , do
                            i <- choose (0, length entries - 1)
                            let (k, v) = entries !! i
                             in do
                                    c <- place v
                                    pure (PLC.Map (take i entries <> [(k, c)] <> drop (i + 1) entries))
                        )
                    ]
            _ -> pure bad

-- | Any data, of any constructor, whether or not it has a plain reading.
genAnyData :: Gen PLC.Data
genAnyData = sized (go . depthFor)
  where
    leaf =
        oneof
            [ PLC.I <$> genWholeInteger
            , PLC.B . BS.pack <$> listOf arbitrary
            , PLC.B . TE.encodeUtf8 <$> genText
            ]
    go depth
        | depth <= 0 = leaf
        | otherwise =
            frequency
                [ (4, leaf)
                ,
                    ( 1
                    , PLC.Constr . getNonNegative <$> arbitrary <*> genChildren below
                    )
                , (1, PLC.List <$> genChildren below)
                , (1, PLC.Map <$> genChildren ((,) <$> below <*> below))
                , (2, genPlainData)
                ]
      where
        below = go (depth - 1)

-- | A document of the detailed schema, or one of plain JSON.
genDocument :: Gen Value
genDocument = oneof [genAnyJson, datumToJson <$> genAnyData]

-- ---------------------------------------------------------
-- Spec
-- ---------------------------------------------------------

spec :: Spec
spec = do
    describe "the schema setting" $ do
        it "names the two schemas in lower case" $ do
            schemaName PlainSchema `shouldBe` "plain"
            schemaName DetailedSchema `shouldBe` "detailed"
        it "parses exactly the two names" $ do
            parseSchemaName "plain" `shouldBe` Just PlainSchema
            parseSchemaName "detailed" `shouldBe` Just DetailedSchema
            forM_
                [ ""
                , "Plain"
                , "DETAILED"
                , "plain "
                , "json"
                , "detail"
                , "plain,detailed"
                ]
                $ \name ->
                    (name, parseSchemaName name) `shouldBe` (name, Nothing)
        it "gives the name back for the schema" $
            forM_ [PlainSchema, DetailedSchema] $ \schema ->
                parseSchemaName (schemaName schema) `shouldBe` Just schema

    describe "the table of the mapping" $ do
        forM_ tableRows $ \(name, file, detailed) ->
            it ("maps " <> name <> " to the data of its detailed document") $
                plainToData (parseJson file) `shouldBe` Right (detailedData detailed)
        it "stores the spec's worked example as a map from answer to 42" $
            plainToData (parseJson "{\"answer\": 42}")
                `shouldBe` Right (PLC.Map [(PLC.B "answer", PLC.I 42)])
        it
            "stores the plain 42 and the detailed {\"int\":42} as the same data"
            $ do
                payloadFromJson PlainSchema (parseJson "42")
                    `shouldBe` Right (PLC.I 42)
                payloadFromJson DetailedSchema (parseJson "{\"int\":42}")
                    `shouldBe` Right (PLC.I 42)
        -- instrument control: the round trip compares documents with this equality
        it
            "stores, for a repeated key, the value the JSON reader returns for it"
            $ forM_
                ["{\"a\": 1, \"a\": 2}", "{\"a\": 5, \"b\": 0, \"a\": 6, \"a\": 7}"]
            $ \file ->
                case parseJson file of
                    Object o ->
                        plainToData (Object o)
                            `shouldBe` Right
                                ( PLC.Map
                                    [ (PLC.B (TE.encodeUtf8 (Key.toText k)), PLC.I (wholeValue v))
                                    | (k, v) <- sortOn fst (KeyMap.toList o)
                                    ]
                                )
                    other -> expectationFailure ("not an object: " <> show other)
        it "compares numbers by value, so 1.0 and 1 are one JSON value" $
            parseJson "1.0" `shouldBe` parseJson "1"

    describe "the digit limit" $ do
        it "is a thousand digits" $
            plainDigitLimit `shouldBe` 1000
        let digitsText n =
                LBS.fromStrict (TE.encodeUtf8 (T.pack ('1' : replicate (n - 1) '0')))
        it "accepts a number of exactly the limit and refuses one more" $ do
            plainToData (parseJson (digitsText 1000))
                `shouldBe` Right (PLC.I (10 ^ (999 :: Int)))
            refusalText (parseJson (digitsText 1001))
                `shouldSatisfy` T.isPrefixOf "the number at $ is too large: more than 1000 digits"
        it "does the same for negative numbers and for exponents" $ do
            plainToData (parseJson ("-" <> digitsText 1000))
                `shouldBe` Right (PLC.I (negate (10 ^ (999 :: Int))))
            refusalText (parseJson ("-" <> digitsText 1001))
                `shouldSatisfy` T.isInfixOf "too large"
            plainToData (parseJson "1e999")
                `shouldBe` Right (PLC.I (10 ^ (999 :: Int)))
            refusalText (parseJson "1e1000")
                `shouldSatisfy` T.isInfixOf "too large"
            plainToData (parseJson "0.5e1000")
                `shouldBe` Right (PLC.I (5 * 10 ^ (999 :: Int)))
        it "refuses 1e5000 naming the whole document" $
            refusalText (parseJson "1e5000")
                `shouldSatisfy` T.isPrefixOf "the number at $ is too large: more than 1000 digits"
        it
            "gives an answer at once for a number with a huge exponent and names it"
            $ do
                let answers =
                        [ ("1e1000000000", "too large")
                        , ("-1e1000000000", "too large")
                        , ("123456789e999999999", "too large")
                        , ("1e-1000000000", "fraction")
                        , ("-3e-1000000000", "fraction")
                        ]
                forM_ answers $ \(file, word) -> do
                    outcome <-
                        timeout 10000000 (evaluate (T.length (refusalText (parseJson file))))
                    outcome `shouldSatisfy` (> Just 0)
                    T.unpack (refusalText (parseJson file)) `shouldSatisfy` isInfixOf word
        it "accepts zero however it is spelled" $
            forM_ ["0e1000000000", "0.000e-1000000000", "-0", "0e0"] $ \file -> do
                outcome <- timeout 10000000 (evaluate (plainToData (parseJson file)))
                outcome `shouldBe` Just (Right (PLC.I 0))
        it "accepts a number whose fraction digits are all zero" $ do
            plainToData (parseJson "10000e-4") `shouldBe` Right (PLC.I 1)
            plainToData (parseJson "1000.000") `shouldBe` Right (PLC.I 1000)

    describe "the refusals" $ do
        it
            "names the value, the path and the reason of a number with a fraction"
            $ refusalText (parseJson "{\"price\": 1.5}")
                `shouldBe` "the number 1.5 at $.price has a fraction; only whole numbers are stored"
        it "names null and its path" $
            refusalText (parseJson "{\"gone\": null}")
                `shouldBe` "null at $.gone has no Plutus data counterpart"
        it "names the document when the document is the refused value" $ do
            refusalText (parseJson "null")
                `shouldBe` "null at $ has no Plutus data counterpart"
            refusalText (parseJson "0.25")
                `shouldBe` "the number 0.25 at $ has a fraction; only whole numbers are stored"
        it "writes a path from the document through keys and items" $ do
            refusalText (parseJson "{\"a\": [0, {\"b\": null}]}")
                `shouldBe` "null at $.a[1].b has no Plutus data counterpart"
            refusalText (parseJson "[0, 1.5]")
                `shouldBe` "the number 1.5 at $[1] has a fraction; only whole numbers are stored"
        it "reports the structured path and the reason" $
            plainToData (parseJson "{\"a\": [0, {\"b\": null}]}")
                `shouldBe` Left (PlainRefusal [KeyStep "a", IndexStep 1, KeyStep "b"] IsNull)
        it
            "reports the first refused value in the order of the key bytes, whatever the object keeps"
            $ do
                let keys = [T.pack ('k' : pad (show i)) | i <- [0 .. 59 :: Int]]
                    pad s = replicate (2 - length s) '0' <> s
                    document = objectOf [(k, Null) | k <- reverse keys]
                fmap refusalPath (either Just (const Nothing) (plainToData document))
                    `shouldBe` Just [KeyStep "k00"]
        it "refuses a document whose only refused value is deep" $
            refusalText (parseJson "[[[[[[{\"x\": [1e5000]}]]]]]]")
                `shouldSatisfy` T.isInfixOf "$[0][0][0][0][0][0].x[0]"
        it "answers for a document nested ten thousand deep" $ do
            let nested = iterate (Array . pure) Null !! 10000
            outcome <-
                timeout
                    10000000
                    ( evaluate
                        ( T.length
                            (either renderPlainRefusal (T.pack . show) (plainToData nested))
                        )
                    )
            outcome `shouldSatisfy` (> Just 10000)

    describe "a detailed document under the plain schema" $ do
        let detailedDocs =
                [ "{\"constructor\":0,\"fields\":[{\"int\":42}]}"
                , "{\"int\":5}"
                , "{\"bytes\":\"61\"}"
                , "{\"list\":[]}"
                , "{\"map\":[]}"
                , "{\"map\":[{\"k\":{\"int\":1},\"v\":{\"int\":2}}]}"
                ]
        it "is refused with the instruction to say so" $
            forM_ detailedDocs $ \file ->
                case payloadFromJson PlainSchema (parseJson file) of
                    Left why -> do
                        T.unpack why `shouldSatisfy` isInfixOf "--payload-schema detailed"
                        T.unpack why `shouldSatisfy` isInfixOf "detailed schema"
                    Right d ->
                        expectationFailure (show file <> " was stored as plain: " <> show d)
        it "is read as before under the detailed schema" $
            forM_ detailedDocs $ \file ->
                payloadFromJson DetailedSchema (parseJson file)
                    `shouldBe` Right (detailedData file)
        it "is refused only as a whole document; nested, it is plain JSON" $
            forM_ tableRows $ \(_, file, detailed) ->
                payloadFromJson PlainSchema (parseJson file)
                    `shouldBe` Right (detailedData detailed)
        it "is refused whatever datum it stands for" $
            property $
                forAll genAnyData $ \d ->
                    case payloadFromJson PlainSchema (datumToJson d) of
                        Left why -> property ("--payload-schema detailed" `isInfixOf` T.unpack why)
                        Right stored -> counterexample ("stored as plain: " <> show stored) False
        it "is accepted unchanged under the detailed schema" $
            property $
                forAll genAnyData $ \d ->
                    payloadFromJson DetailedSchema (datumToJson d) === Right d
        it "leaves the detailed schema's own refusals unchanged" $
            property $
                forAll genDocument $ \doc ->
                    payloadFromJson DetailedSchema doc
                        === either (Left . T.pack) Right (datumFromJson doc)
        it
            "maps what the detailed schema does not accept, whichever the schema says first"
            $ property
            $ forAll genDocument
            $ \doc ->
                isLeft (datumFromJson doc) ==>
                    payloadFromJson PlainSchema doc
                        === either (Left . renderPlainRefusal) Right (plainToData doc)

    describe "plain-reading-returns-the-same-json" $ do
        it "reads back every document the mapping accepts" $
            withMaxSuccess 500 $
                forAll genPlainJson $ \doc ->
                    fmap plainFromData (plainToData doc) === Right (Just doc)
        it "reads back the table's documents" $
            forM_ tableRows $ \(name, file, _) ->
                (name, fmap plainFromData (plainToData (parseJson file)))
                    `shouldBe` (name, Right (Just (parseJson file)))
        it "reads back a number spelled with an exponent as the number" $
            fmap plainFromData (plainToData (parseJson "5e2"))
                `shouldBe` Right (Just (Number 500))

    describe "plain-mapping-is-total-over-what-it-accepts" $ do
        it "maps or refuses every document, and names the place it refuses" $
            withMaxSuccess 500 $
                forAll genAnyJson $ \doc -> ioProperty $ do
                    outcome <- timeout 10000000 (evaluate (forced (plainToData doc)))
                    pure $ case outcome of
                        Nothing -> counterexample "no answer within ten seconds" False
                        Just (Right d) -> plainFromData d === Just doc
                        Just (Left refusal) ->
                            let sentence = T.unpack (renderPlainRefusal refusal)
                            in  counterexample sentence $
                                    conjoin
                                        [ property
                                            ( refusedValueIs
                                                (refusalReason refusal)
                                                (valueAt (refusalPath refusal) doc)
                                            )
                                        , property
                                            (T.unpack (renderPath (refusalPath refusal)) `isInfixOf` sentence)
                                        ]
        it
            "refuses the place the generator put the refused value, and no other"
            $ withMaxSuccess 500
            $ forAllShow
                (genPlainJson >>= injectBad)
                (\(doc, path, _) -> show (doc, path))
            $ \(doc, path, isReason) ->
                case plainToData doc of
                    Left refusal ->
                        conjoin
                            [ refusalPath refusal === path
                            , counterexample
                                (show (refusalReason refusal))
                                (isReason (refusalReason refusal))
                            , counterexample (show (renderPlainRefusal refusal)) $
                                T.isInfixOf (renderPath path) (renderPlainRefusal refusal)
                            ]
                    Right d -> counterexample ("mapped to " <> show d) False
        it "writes the refused number as a reader would" $ do
            refusalText (Number (Sci.scientific (-125) (-1)))
                `shouldBe` "the number -12.5 at $ has a fraction; only whole numbers are stored"
            refusalText (Number (Sci.scientific 1 (-3)))
                `shouldBe` "the number 0.001 at $ has a fraction; only whole numbers are stored"
            refusalText (Number (Sci.scientific 123456789 (-4)))
                `shouldBe` "the number 12345.6789 at $ has a fraction; only whole numbers are stored"
        it "names a number of any size without expanding it" $ do
            T.unpack (refusalText (parseJson "7e1000000000"))
                `shouldSatisfy` isInfixOf "1000000000"
            T.unpack (refusalText (parseJson "1e5000"))
                `shouldSatisfy` isInfixOf "5000"
            T.unpack (refusalText (parseJson "-3e-1000000000"))
                `shouldSatisfy` isInfixOf "1000000000"
        it "does not print a number of thousands of digits whole" $ do
            let huge = LBS.fromStrict (TE.encodeUtf8 (T.pack ('9' : replicate 5000 '9')))
            T.length (refusalText (parseJson huge)) `shouldSatisfy` (< 200)
            T.unpack (refusalText (parseJson huge))
                `shouldSatisfy` isInfixOf "too large"

    describe "a number with any exponent an Int can hold" $ do
        it
            "is judged and named at once, as the exact rule says, for every combination"
            $ forM_ [(c, e) | c <- extremeCoefficients, e <- extremeExponents]
            $ \(c, e) -> do
                let n = Sci.scientific c e
                    expected = expectedVerdict c e
                outcome <-
                    timeout 5000000 (evaluate (forced (plainToData (Number n))))
                case outcome of
                    Nothing ->
                        expectationFailure
                            ("no answer within five seconds for " <> show (c, e))
                    Just result -> do
                        (c, e, verdictOf result) `shouldBe` (c, e, expected)
                        case result of
                            Right _ -> pure ()
                            Left refusal -> do
                                let sentence = T.unpack (renderPlainRefusal refusal)
                                length sentence `shouldSatisfy` (< 400)
                                -- a number written in the exponent form names its true exponent
                                forM_ (exponentNamed c e) $ \named ->
                                    (c, e, sentence) `shouldSatisfy` \(_, _, s) -> ("e" <> named) `isInfixOf` s
        it "agrees, where exact arithmetic is cheap, with exact arithmetic" $
            property $
                forAll genExactCase $ \(c, e) ->
                    expectedVerdict c e === exactVerdict c e
        it
            "answers for the same numbers written in a file, in a detailed-looking object, and under both schemas"
            $ forM_
                [ "1e-9223372036854775808"
                , "10e9223372036854775807"
                , "1e9223372036854775807"
                , "-3e-9223372036854775807"
                , "{\"int\": 1e-9223372036854775808}"
                , "{\"int\": 1e9223372036854775807}"
                , "{\"a\": [1e-9223372036854775808, 1e9223372036854775807]}"
                ]
            $ \file -> do
                let doc = parseJson file
                outcome <-
                    timeout 5000000 $
                        evaluate $
                            length (show (plainToData doc))
                                + length (show (payloadFromJson PlainSchema doc))
                                + length (show (payloadFromJson DetailedSchema doc))
                (file, fmap (< 4000) outcome) `shouldBe` (file, Just True)

    describe "plain-reading-is-a-function-of-the-data" $ do
        it "maps data with a plain reading back to itself" $
            withMaxSuccess 500 $
                forAll genPlainData $ \d ->
                    case plainFromData d of
                        Nothing -> counterexample "no plain reading for plain data" False
                        Just doc -> plainToData doc === Right d
        it "has no plain reading for data outside the spec's list" $
            withMaxSuccess 500 $
                forAll genNonPlainData $
                    \d -> plainFromData d === Nothing
        it "reads an integer only up to the limit" $ do
            plainFromData (PLC.I (10 ^ (999 :: Int)))
                `shouldBe` Just (Number (fromInteger (10 ^ (999 :: Int))))
            plainFromData (PLC.I (negate (10 ^ (999 :: Int))))
                `shouldSatisfy` (/= Nothing)
            plainFromData (PLC.I (10 ^ (1000 :: Int))) `shouldBe` Nothing
            plainFromData (PLC.I (negate (10 ^ (1000 :: Int)))) `shouldBe` Nothing
        it "reads a byte string as text only when it is UTF-8" $ do
            plainFromData (PLC.B "alice") `shouldBe` Just (String "alice")
            plainFromData (PLC.B "") `shouldBe` Just (String "")
            plainFromData (PLC.B "\xff") `shouldBe` Nothing
            plainFromData (PLC.B "\xed\xa0\x80") `shouldBe` Nothing
        it "reads the two booleans and no other constructor" $ do
            plainFromData (PLC.Constr 1 []) `shouldBe` Just (Bool True)
            plainFromData (PLC.Constr 0 []) `shouldBe` Just (Bool False)
            plainFromData (PLC.Constr 2 []) `shouldBe` Nothing
            plainFromData (PLC.Constr 0 [PLC.I 1]) `shouldBe` Nothing
        it
            "reads a map only with text keys in strictly ascending order of bytes"
            $ do
                plainFromData (PLC.Map [(PLC.B "a", PLC.I 1), (PLC.B "b", PLC.I 2)])
                    `shouldBe` Just (parseJson "{\"a\":1,\"b\":2}")
                plainFromData (PLC.Map [(PLC.B "b", PLC.I 2), (PLC.B "a", PLC.I 1)])
                    `shouldBe` Nothing
                plainFromData (PLC.Map [(PLC.B "a", PLC.I 1), (PLC.B "a", PLC.I 2)])
                    `shouldBe` Nothing
                plainFromData (PLC.Map [(PLC.I 1, PLC.I 1)]) `shouldBe` Nothing
                plainFromData (PLC.Map [(PLC.B "\xff", PLC.I 1)]) `shouldBe` Nothing
                plainFromData (PLC.Map [(PLC.B "a", PLC.Constr 2 [])])
                    `shouldBe` Nothing
        it "reads a list only when every item has a plain reading" $ do
            plainFromData (PLC.List [PLC.I 1, PLC.B "a"])
                `shouldBe` Just (parseJson "[1,\"a\"]")
            plainFromData (PLC.List [PLC.I 1, PLC.B "\xff"]) `shouldBe` Nothing

    describe "what a command prints of a payload" $ do
        it
            "prints the plain JSON and says plain when the data has a plain reading"
            $ withMaxSuccess 500
            $ forAll genPlainData
            $ \d ->
                case payloadView d of
                    PayloadView PlainSchema doc -> plainToData doc === Right d
                    PayloadView DetailedSchema doc -> counterexample (show doc) False
        it "prints the detailed schema and says detailed when it has none" $
            withMaxSuccess 500 $
                forAll genAnyData $ \d ->
                    case payloadView d of
                        PayloadView DetailedSchema doc ->
                            conjoin
                                [ doc === datumToJson d
                                , datumFromJson doc === Right d
                                , plainFromData d === Nothing
                                ]
                        PayloadView PlainSchema doc ->
                            conjoin
                                [ plainFromData d === Just doc
                                , plainToData doc === Right d
                                ]
        it
            "says plain for the integer the detailed {\"int\":42} and the plain 42 both store"
            $ payloadView (detailedData "{\"int\":42}")
                `shouldBe` PayloadView PlainSchema (Number 42)
        it "says detailed for a byte string that is not text" $
            payloadView (PLC.B "\xff")
                `shouldBe` PayloadView DetailedSchema (parseJson "{\"bytes\":\"ff\"}")
        it "says detailed for a constructor that is not a boolean" $
            payloadView
                (detailedData "{\"constructor\":2,\"fields\":[{\"int\":1}]}")
                `shouldBe` PayloadView
                    DetailedSchema
                    (parseJson "{\"constructor\":2,\"fields\":[{\"int\":1}]}")

    describe "the generators reach what they claim" $ do
        it "builds documents with arrays, objects, big numbers and every leaf" $
            checkCoverage $
                forAll genPlainJson $ \doc ->
                    cover 10 (isArray doc) "array at the root" $
                        cover 10 (isObject doc) "object at the root" $
                            cover 3 (hasBigNumber doc) "a number of more than 900 digits" $
                                cover 3 (hasString doc) "a text" $
                                    cover 3 (hasBool doc) "a boolean" $
                                        isRight (plainToData doc)
        it "builds data with each case the reading separates" $
            checkCoverage $
                forAll genAnyData $ \d ->
                    cover 10 (isJust (plainFromData d)) "data with a plain reading" $
                        cover 10 (isNothing (plainFromData d)) "data without one" $
                            property True
  where
    isArray = \case Array _ -> True; _ -> False
    isObject = \case Object _ -> True; _ -> False
    hasString = anyLeaf (\case String _ -> True; _ -> False)
    hasBool = anyLeaf (\case Bool _ -> True; _ -> False)
    hasBigNumber =
        anyLeaf (\case Number n -> abs n >= Sci.scientific 1 900; _ -> False)

-- | Whether any leaf of a document satisfies a test.
anyLeaf :: (Value -> Bool) -> Value -> Bool
anyLeaf test = \case
    Array xs -> any (anyLeaf test) xs
    Object o -> any (anyLeaf test) (KeyMap.elems o)
    leaf -> test leaf

-- | A path as the sentence writes it.
renderPath :: [PathStep] -> Text
renderPath steps = "$" <> T.concat (map step steps)
  where
    step = \case
        KeyStep k -> "." <> k
        IndexStep i -> "[" <> T.pack (show i) <> "]"

-- | Force a mapping result completely, so a time limit measures all of it.
forced :: Either PlainRefusal PLC.Data -> Either PlainRefusal PLC.Data
forced result = length (show result) `seq` result

-- | Whether the value at a refused path is the one the reason names.
refusedValueIs :: PlainReason -> Maybe Value -> Bool
refusedValueIs reason found = case (reason, found) of
    (IsNull, Just Null) -> True
    (HasFraction n, Just (Number m)) -> n == m
    (TooLarge n, Just (Number m)) -> n == m
    _ -> False

-- | The integer of a whole JSON number the reader returned.
wholeValue :: Value -> Integer
wholeValue = \case
    Number n ->
        either
            (error . ("not whole: " <>) . (show :: Double -> String))
            id
            (Sci.floatingOrInteger n)
    other -> error ("not a number: " <> show other)

-- | What the spec says of a stored number: whole, with a fraction, or too large.
data Verdict = VWhole | VFraction | VTooLarge
    deriving stock (Eq, Show)

-- | The verdict of what the mapping gave.
verdictOf :: Either PlainRefusal PLC.Data -> Verdict
verdictOf = \case
    Right _ -> VWhole
    Left (PlainRefusal _ (HasFraction _)) -> VFraction
    Left (PlainRefusal _ (TooLarge _)) -> VTooLarge
    Left (PlainRefusal _ IsNull) -> error "null from a number"

{- | A coefficient without its trailing decimal zeros, and how many it had,
by repeated division and not by the library's normalisation.
-}
stripZeros :: Integer -> (Integer, Integer)
stripZeros c
    | c == 0 = (0, 0)
    | c `mod` 10 == 0 =
        let (c', k) = stripZeros (c `div` 10) in (c', k + 1)
    | otherwise = (c, 0)

{- | The spec's rule in integer arithmetic that never forms the power: zero
is whole; once the trailing zeros are counted into the exponent, a
negative exponent is a fraction, and digits plus exponent past the limit is
too large.
-}
expectedVerdict :: Integer -> Int -> Verdict
expectedVerdict c e
    | c == 0 = VWhole
    | e' < 0 = VFraction
    | toInteger (length (show (abs c'))) + e' > 1000 = VTooLarge
    | otherwise = VWhole
  where
    (c', k) = stripZeros c
    e' = toInteger e + k

{- | The exact verdict, by rational arithmetic: only for exponents small
enough to expand.
-}
exactVerdict :: Integer -> Int -> Verdict
exactVerdict c e
    | c == 0 = VWhole
    | denominator r /= 1 = VFraction
    | length (show (abs (numerator r))) > 1000 = VTooLarge
    | otherwise = VWhole
  where
    r = fromInteger c * (10 ^^ e) :: Rational

{- | The exponent a refusal names when it writes the number in the exponent
form: that of the number without its trailing zeros, as an integer.
-}
exponentNamed :: Integer -> Int -> Maybe String
exponentNamed c e
    | c == 0 || abs (toInteger e) <= 30 = Nothing
    | otherwise = Just (show (toInteger e + snd (stripZeros c)))

-- | Coefficients that stress the rule: signs, trailing zeros, long ones.
extremeCoefficients :: [Integer]
extremeCoefficients =
    [ 0
    , 1
    , -1
    , 7
    , 10
    , 100
    , 123456789
    , 10 ^ (40 :: Int)
    , 10 ^ (1500 :: Int)
    , 3 * 10 ^ (1500 :: Int) + 1
    , negate (10 ^ (3000 :: Int))
    ]

-- | Exponents from one end of an Int to the other, with the neighbours of each limit.
extremeExponents :: [Int]
extremeExponents =
    [ minBound
    , minBound + 1
    , minBound + 100
    , -4611686018427387904
    , -1000000000
    , -1001
    , -1000
    , -31
    , -30
    , -1
    , 0
    , 1
    , 30
    , 31
    , 999
    , 1000
    , 1001
    , 1000000000
    , 4611686018427387904
    , maxBound - 100
    , maxBound - 3
    , maxBound - 1
    , maxBound
    ]

-- | A coefficient with a chosen number of trailing zeros and an exponent small enough to expand.
genExactCase :: Gen (Integer, Int)
genExactCase = do
    base <- arbitrary
    zeros <- choose (0, 40)
    e <- choose (-1100, 1100)
    pure (base * 10 ^ (zeros :: Int), e)
