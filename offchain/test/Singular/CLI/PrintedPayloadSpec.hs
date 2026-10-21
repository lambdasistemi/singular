{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.PrintedPayloadSpec
Description : A payload is printed with the schema it is printed in
License     : Apache-2.0

Inspect and the update receipt print a payload through one function
(#719): the plain JSON when the data has a plain reading, else the detailed
schema, and always beside the name of the schema. Each expected value is the
JSON the spec states for the data, and the property reads the printed
payload back under the schema it names and requires the data it was
printed from.
-}
module Singular.CLI.PrintedPayloadSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isRight)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import PlutusCore.Data qualified as PLC
import Test.Hspec
import Test.QuickCheck

import Singular.CLI.Registry (payloadFields)
import Singular.Registry.Application (datumFromJson)
import Singular.Registry.PlainJson
    ( PayloadSchema (..)
    , payloadFromJson
    , plainToData
    )

-- | A JSON document from its text.
json :: LBS.ByteString -> Value
json = either (error . ("not JSON: " <>)) id . Aeson.eitherDecode

-- | The two fields a printed payload gives: the JSON, then the name of its schema.
printed :: Value -> T.Text -> [(T.Text, Value)]
printed payload schema = [("payload", payload), ("payloadSchema", String schema)]

-- | Data of every shape, with byte strings that are and are not text.
genData :: Gen PLC.Data
genData = sized (go . min 3 . (`div` 20))
  where
    leaf =
        oneof
            [ PLC.I <$> arbitrary
            , PLC.B . BS.pack <$> listOf arbitrary
            , PLC.B . TE.encodeUtf8 . T.pack <$> listOf (elements "abc \233")
            , elements [PLC.Constr 0 [], PLC.Constr 1 []]
            , datumShaped
            ]
    -- plain objects shaped like the detailed schema, on purpose: their plain
    -- reading is deliberately narrower than the guarded reader of a file
    datumShaped =
        oneof
            [ PLC.Map . pure . (,) (PLC.B "int") . PLC.I <$> arbitrary
            , PLC.Map . pure . (,) (PLC.B "bytes") . PLC.B . TE.encodeUtf8 . T.pack
                <$> listOf (elements "ab")
            , pure (PLC.Map [(PLC.B "list", PLC.List [])])
            , pure (PLC.Map [(PLC.B "map", PLC.List [])])
            , PLC.Map
                <$> sequence
                    [ (,) (PLC.B "constructor") . PLC.I <$> choose (0, 3)
                    , pure (PLC.B "fields", PLC.List [])
                    ]
            ]
    go depth
        | depth <= (0 :: Int) = leaf
        | otherwise =
            frequency
                [ (3, leaf)
                , (1, PLC.List <$> children (go (depth - 1)))
                , (1, PLC.Map <$> children ((,) <$> go (depth - 1) <*> go (depth - 1)))
                , (1, PLC.Constr <$> choose (0, 4) <*> children (go (depth - 1)))
                ]
    children g = choose (0, 3) >>= (`vectorOf` g)

spec :: Spec
spec = describe "payloadFields" $ do
    describe "data with a plain reading is printed as plain JSON" $
        forM_ plainRows $ \(name, datum, expected) ->
            it name $ payloadFields datum `shouldBe` printed expected "plain"
    describe "data without one is printed in the detailed schema" $
        forM_ detailedRows $ \(name, datum, expected) ->
            it name $ payloadFields datum `shouldBe` printed expected "detailed"
    it
        "always prints the payload and then the name of its schema, and nothing else"
        $ property
        $ forAll genData
        $ \d ->
            map fst (payloadFields d) === ["payload", "payloadSchema"]
    it
        "prints data shaped like the detailed schema as plain JSON, which the guarded file reader refuses"
        $ do
            let datum = PLC.Map [(PLC.B "int", PLC.I 5)]
            payloadFields datum `shouldBe` printed (json "{\"int\": 5}") "plain"
            plainToData (json "{\"int\": 5}") `shouldBe` Right datum
            case payloadFromJson PlainSchema (json "{\"int\": 5}") of
                Left why -> T.unpack why `shouldSatisfy` isInfixOf "--payload-schema detailed"
                Right stored -> expectationFailure ("stored as plain: " <> show stored)
    it
        "reaches the plain objects shaped like the detailed schema that the reading must keep apart from the file reader"
        $ checkCoverage
        $ forAll genData
        $ \d ->
            cover
                3
                (datumShapedPlain d)
                "a plain payload that is a document of the detailed schema"
                $ cover 3 (not (datumShapedPlain d)) "any other payload"
                $ property True
    it
        "prints a payload that reads back, under the schema it names, as the data it was printed from"
        $ withMaxSuccess 500
        $ forAll genData
        $ \d -> case payloadFields d of
            [("payload", doc), ("payloadSchema", String name)]
                | name == "plain" -> plainToData doc === Right d
                | name == "detailed" -> datumFromJson doc === Right d
            other -> counterexample (show other) False
  where
    plainRows =
        [ ("an integer", PLC.I 42, Number 42)
        , ("a negative integer", PLC.I (-7), Number (-7))
        , ("a text", PLC.B "alice", String "alice")
        , ("the empty text", PLC.B "", String "")
        , ("true", PLC.Constr 1 [], Bool True)
        , ("false", PLC.Constr 0 [], Bool False)
        , ("a list", PLC.List [PLC.I 1, PLC.Constr 1 []], json "[1, true]")
        ,
            ( "a map from texts in ascending order"
            , PLC.Map [(PLC.B "a", PLC.I 1), (PLC.B "b", PLC.I 2)]
            , json "{\"a\": 1, \"b\": 2}"
            )
        ,
            ( "the worked example of the spec"
            , PLC.Map [(PLC.B "answer", PLC.I 42)]
            , json "{\"answer\": 42}"
            )
        ]
    detailedRows =
        [
            ( "a byte string that is not text"
            , PLC.B "\xff"
            , json "{\"bytes\":\"ff\"}"
            )
        ,
            ( "a constructor that is not a boolean"
            , PLC.Constr 2 [PLC.I 5]
            , json "{\"constructor\":2,\"fields\":[{\"int\":5}]}"
            )
        ,
            ( "a boolean constructor with a field"
            , PLC.Constr 1 [PLC.I 5]
            , json "{\"constructor\":1,\"fields\":[{\"int\":5}]}"
            )
        ,
            ( "a map with a key that is not text"
            , PLC.Map [(PLC.I 1, PLC.I 2)]
            , json "{\"map\":[{\"k\":{\"int\":1},\"v\":{\"int\":2}}]}"
            )
        ,
            ( "a map with its keys out of order"
            , PLC.Map [(PLC.B "b", PLC.I 1), (PLC.B "a", PLC.I 2)]
            , json
                "{\"map\":[{\"k\":{\"bytes\":\"62\"},\"v\":{\"int\":1}},{\"k\":{\"bytes\":\"61\"},\"v\":{\"int\":2}}]}"
            )
        ,
            ( "a list holding data without a plain reading"
            , PLC.List [PLC.I 1, PLC.B "\xff"]
            , json "{\"list\":[{\"int\":1},{\"bytes\":\"ff\"}]}"
            )
        ]

-- | Whether the data prints as plain JSON that is itself a document of the detailed schema.
datumShapedPlain :: PLC.Data -> Bool
datumShapedPlain d = case payloadFields d of
    [("payload", doc), ("payloadSchema", String "plain")] -> isRight (datumFromJson doc)
    _ -> False
