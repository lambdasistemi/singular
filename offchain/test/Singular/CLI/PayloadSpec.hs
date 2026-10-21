{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.PayloadSpec
Description : The one reader of a payload file
License     : Apache-2.0

Every command that takes @--payload@ reads the file through
'readPayloadFile' (#719). The data of an accepted file is the data the
detailed-schema reader of the previous release gives for the detailed
document the spec works out by hand; every refusal is a client refusal that
names the file and the flag, and the reasons the previous release printed
for a file that is not Plutus data are unchanged inside the one sentence.
-}
module Singular.CLI.PayloadSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromLeft)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text qualified as T
import PlutusCore.Data qualified as PLC
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Singular.CLI.Payload (readPayloadFile)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (CommandFailure (..))
import Singular.Registry.Application (datumFromJson)
import Singular.Registry.PlainJson
    ( PayloadSchema (..)
    , payloadFromJson
    )

-- | A file holding this text, for the length of the action.
withPayload :: LBS.ByteString -> (FilePath -> IO a) -> IO a
withPayload text use = withSystemTempDirectory "payload" $ \dir -> do
    let path = dir </> "payload.json"
    LBS.writeFile path text
    use path

-- | What the reader does with a file: the data, or the class and sentence of its refusal.
attempt
    :: PayloadSchema
    -> FilePath
    -> IO (Either (OutcomeClass, String) PLC.Data)
attempt schema path =
    either (\(CommandFailure c why _) -> Left (c, why)) Right
        <$> try (readPayloadFile schema path)

-- | A document read the way a file is read.
document :: LBS.ByteString -> Value
document = either (error . ("not JSON: " <>)) id . Aeson.eitherDecode

-- | The data of a detailed-schema document, by the reader of the previous release.
detailedData :: LBS.ByteString -> PLC.Data
detailedData =
    either (error . ("not detailed: " <>)) id . datumFromJson . document

-- | The reason the previous release gave for a document that is not a datum.
datumReason :: LBS.ByteString -> String
datumReason =
    fromLeft (error "it is a datum") . datumFromJson . document

spec :: Spec
spec = describe "readPayloadFile" $ do
    describe "the plain schema" $ do
        let rows =
                [
                    ( "{\"answer\": 42}"
                    , "{\"map\":[{\"k\":{\"bytes\":\"616e73776572\"},\"v\":{\"int\":42}}]}"
                    )
                , ("42", "{\"int\":42}")
                , ("\"alice\"", "{\"bytes\":\"616c696365\"}")
                ,
                    ( "[1, true, {\"b\": 2, \"a\": 1}]"
                    , "{\"list\":[{\"int\":1},{\"constructor\":1,\"fields\":[]},{\"map\":[{\"k\":{\"bytes\":\"61\"},\"v\":{\"int\":1}},{\"k\":{\"bytes\":\"62\"},\"v\":{\"int\":2}}]}]}"
                    )
                ]
        forM_ rows $ \(file, detailed) ->
            it ("reads " <> show file <> " as the data of its detailed document") $
                withPayload file $ \path ->
                    attempt PlainSchema path `shouldReturn` Right (detailedData detailed)
        it
            "refuses a number with a fraction, naming the file, the flag, the value and its path"
            $ withPayload "{\"price\": 1.5}"
            $ \path ->
                attempt PlainSchema path
                    `shouldReturn` Left
                        ( ClientRefusal
                        , path
                            <> ": --payload cannot be stored as plain JSON: the number 1.5 at $.price has a fraction; only whole numbers are stored"
                        )
        it "refuses null, naming its path" $
            withPayload "{\"gone\": null}" $ \path ->
                attempt PlainSchema path
                    `shouldReturn` Left
                        ( ClientRefusal
                        , path
                            <> ": --payload cannot be stored as plain JSON: null at $.gone has no Plutus data counterpart"
                        )
        it "refuses a number past the digit limit, however large its exponent" $
            withPayload "1e1000000000" $ \path ->
                attempt PlainSchema path >>= \case
                    Left (ClientRefusal, why) ->
                        why
                            `shouldSatisfy` isPrefixOf
                                ( path
                                    <> ": --payload cannot be stored as plain JSON: the number at $ is too large: more than 1000 digits"
                                )
                    other -> expectationFailure ("not a client refusal: " <> show other)
        it
            "refuses a document of the detailed schema with the instruction to say so"
            $ forM_
                [ "{\"int\":5}"
                , "{\"constructor\":0,\"fields\":[{\"int\":42}]}"
                , "{\"map\":[]}"
                ]
            $ \file ->
                withPayload file $ \path ->
                    case payloadFromJson PlainSchema (document file) of
                        Left instruction -> do
                            attempt PlainSchema path
                                `shouldReturn` Left
                                    ( ClientRefusal
                                    , path
                                        <> ": --payload cannot be stored as plain JSON: "
                                        <> T.unpack instruction
                                    )
                            T.unpack instruction
                                `shouldSatisfy` isInfixOf "--payload-schema detailed"
                        Right stored ->
                            expectationFailure ("stored as plain: " <> show stored)
        it
            "reads a detailed-looking object nested in a larger document as plain JSON"
            $ withPayload "{\"wrapper\": {\"int\": 5}}"
            $ \path ->
                attempt PlainSchema path
                    `shouldReturn` Right
                        (PLC.Map [(PLC.B "wrapper", PLC.Map [(PLC.B "int", PLC.I 5)])])
    describe "the detailed schema" $ do
        let docs =
                [ "{\"int\":42}"
                , "{\"constructor\":0,\"fields\":[{\"int\":42}]}"
                , "{\"map\":[{\"k\":{\"bytes\":\"616e73776572\"},\"v\":{\"int\":42}}]}"
                , "{\"list\":[{\"bytes\":\"\"},{\"int\":-7}]}"
                ]
        forM_ docs $ \file ->
            it ("reads " <> show file <> " as the previous release did") $
                withPayload file $ \path ->
                    attempt DetailedSchema path `shouldReturn` Right (detailedData file)
        it
            "refuses a plain document with the previous release's reason inside one sentence"
            $ withPayload "{\"answer\": 42}"
            $ \path ->
                attempt DetailedSchema path
                    `shouldReturn` Left
                        ( ClientRefusal
                        , path
                            <> ": --payload is not Plutus data: "
                            <> datumReason "{\"answer\": 42}"
                        )
        it
            "keeps the reason the previous release printed for a document that is not a datum"
            $ withPayload "{\"answer\": 42}"
            $ \path ->
                attempt DetailedSchema path
                    `shouldReturn` Left
                        ( ClientRefusal
                        , path
                            <> ": --payload is not Plutus data: a datum is one of constructor+fields, map, list, int, bytes; found keys [\"answer\"]"
                        )
        it "refuses a plain number the same way" $
            withPayload "42" $ \path ->
                attempt DetailedSchema path
                    `shouldReturn` Left
                        ( ClientRefusal
                        , path <> ": --payload is not Plutus data: a datum is a JSON object"
                        )
    describe "a file that is not JSON" $
        forM_ [PlainSchema, DetailedSchema] $ \schema ->
            forM_ ["", "{", "not json", "{\"a\": }"] $ \file ->
                it
                    ( "is refused under the "
                        <> show schema
                        <> " with the JSON reader's reason: "
                        <> show file
                    )
                    $ withPayload file
                    $ \path -> do
                        reader <-
                            Aeson.eitherDecodeFileStrict' path :: IO (Either String Value)
                        case reader of
                            Left reason ->
                                attempt schema path
                                    `shouldReturn` Left (ClientRefusal, path <> ": " <> reason)
                            Right _ -> expectationFailure "the test file is JSON"
