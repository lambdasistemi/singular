{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.PayloadReadSpec
Description : Register reads its payload file as every command does
License     : Apache-2.0

@keri-stub register@ reads its @--payload@ through the one reader the other
commands use (#719): the same file and the same setting give the same
data, or the same refusal sentence, and the refusal comes before the node
is read. The environment of these rows cannot read a node, so a file the
reader accepts is seen as a run that gets past the payload and stops
somewhere else.
-}
module Singular.Application.KeriStub.PayloadReadSpec (spec) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM_)
import Control.Tracer (nullTracer)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.List (isInfixOf)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Singular.Application.KeriStub.Command
    ( KeriStubCommand (..)
    , parseKeriStubCommand
    )
import Singular.Application.KeriStub.Register (runRegister)
import Singular.CLI.Payload (readPayloadFile)
import Singular.CLI.Session (CommandFailure (..), Env (..))
import Singular.Registry.PlainJson
    ( PayloadSchema (..)
    , payloadFromJson
    )

-- | What a file must do: be accepted, or be refused with this sentence.
data Expectation = Accepted | Refused (FilePath -> String)

spec :: Spec
spec = describe "keri-stub register reads its payload" $
    forM_ rows $ \(label, file, setting, expectation) ->
        it label $ withPayload file $ \path -> do
            let schema =
                    if setting == ["--payload-schema", "detailed"]
                        then DetailedSchema
                        else PlainSchema
            shared <- try (readPayloadFile schema path)
            registered <- registerOutcome path setting
            case expectation of
                Accepted -> do
                    either failureText (const "") shared `shouldBe` ""
                    registered `shouldNotSatisfy` maybe False (isInfixOf "--payload")
                Refused sentence -> do
                    either failureText (const "") shared `shouldBe` sentence path
                    registered `shouldBe` Just (sentence path)
  where
    failureText :: CommandFailure -> String
    failureText (CommandFailure _ why _) = why
    rows =
        [
            ( "a plain object with no setting"
            , "{\"answer\": 42}"
            , []
            , Accepted
            )
        ,
            ( "a detailed document with the setting detailed"
            , "{\"constructor\":0,\"fields\":[{\"int\":42}]}"
            , ["--payload-schema", "detailed"]
            , Accepted
            )
        ,
            ( "a detailed document without the setting"
            , "{\"constructor\":0,\"fields\":[{\"int\":42}]}"
            , []
            , Refused $ \path ->
                path
                    <> ": --payload cannot be stored as plain JSON: "
                    <> detailedInstruction
            )
        ,
            ( "a number with a fraction"
            , "{\"price\": 1.5}"
            , []
            , Refused $ \path ->
                path
                    <> ": --payload cannot be stored as plain JSON: the number 1.5 at $.price has a fraction; only whole numbers are stored"
            )
        ,
            ( "a plain object under the setting detailed"
            , "{\"answer\": 42}"
            , ["--payload-schema", "detailed"]
            , Refused $ \path ->
                path
                    <> ": --payload is not Plutus data: a datum is one of constructor+fields, map, list, int, bytes; found keys [\"answer\"]"
            )
        ]
    detailedInstruction = case payloadFromJson PlainSchema (decoded "{\"int\":1}") of
        Left why -> T.unpack why
        Right _ -> ""
    decoded :: LBS.ByteString -> Aeson.Value
    decoded = either (error . ("not JSON: " <>)) id . Aeson.eitherDecode

-- | A file holding this text, for the length of the action.
withPayload :: LBS.ByteString -> (FilePath -> IO a) -> IO a
withPayload text use = withSystemTempDirectory "payload" $ \dir -> do
    let path = dir </> "payload.json"
    LBS.writeFile path text
    use path

{- | What @keri-stub register@ ends in on this file where no node can be
read: the sentence of its refusal, and nothing when it ends otherwise.
-}
registerOutcome :: FilePath -> [String] -> IO (Maybe String)
registerOutcome path setting = do
    command <-
        either (fail . show) pure $
            parseKeriStubCommand
                ( ["keri-stub", "register", "--key", "hello", "--payload", path]
                    <> setting
                    <> ["--state-dir", "/srv/reg", "--blueprint", "/srv/plutus.json"]
                    <> ["--state-token", replicate 56 '0' <> "." <> replicate 64 '0']
                    <> [ "--koios-url"
                       , "http://127.0.0.1:8080/api/v1"
                       , "--network-magic"
                       , "42"
                       ]
                    <> ["--wallet-skey", "/keys/payment.skey"]
                )
    entry <- case command of
        KeriRegister a -> pure a
        other -> fail ("not a register: " <> show other)
    outcome <- try (runRegister blindEnv entry)
    pure $ case outcome of
        Left (e :: SomeException) -> case fromException e of
            Just (CommandFailure _ why _) -> Just why
            Nothing -> Nothing
        Right _ -> Nothing

-- | An environment that cannot read a node or load a release.
blindEnv :: Env
blindEnv =
    Env
        { envTracer = nullTracer
        , envSource = "blind"
        , envLoadRelease = \_ _ -> pure (Left "the blueprint was read")
        , envReads = \_ _ -> fail "the node was read"
        , envWrites = \_ _ -> fail "the node was read"
        }
