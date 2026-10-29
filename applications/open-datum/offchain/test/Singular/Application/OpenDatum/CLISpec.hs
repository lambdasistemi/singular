{-# LANGUAGE LambdaCase #-}

module Singular.Application.OpenDatum.CLISpec (spec) where

import Control.Monad (forM_)
import Control.Tracer (nullTracer)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BC
import Data.List qualified
import Singular.Application.OpenDatum.Command
    ( CLIError (BadValue, MissingFlag, UnknownCommand)
    , OpenDatumCommand (OpenStateFold)
    , StateFoldArgs (..)
    , parseOpenDatumCommand
    )
import Singular.Application.OpenDatum.CommandRunSpec (captured)
import Singular.Application.OpenDatum.Root (runPackagedOpenDatumVia)
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Session (Env (..))
import System.Exit (ExitCode (..))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
    describe "discovering a fold's public requests" $ do
        let line =
                [ "fold"
                , "--state-token"
                , replicate 56 'a' <> "." <> replicate 64 '1'
                , "--blueprint"
                , "blueprint.json"
                , "--wallet-skey"
                , "folder.skey"
                , "--koios-url"
                , "http://fixture.invalid"
                , "--network-magic"
                , "42"
                ]
            accepts count = \case
                Right (OpenStateFold args) -> length (stateFoldPending args) == count
                _ -> False
        it "keeps the explicit pending batch as a passing parser control" $
            parseOpenDatumCommand
                (line <> ["--pending", replicate 64 'b' <> "#0"])
                `shouldSatisfy` accepts 1
        it "accepts a fold with no pending reference" $
            parseOpenDatumCommand line `shouldSatisfy` accepts 0
        it "accepts an optional discovery limit" $
            parseOpenDatumCommand (line <> ["--limit", "2"])
                `shouldSatisfy` accepts 0
        forM_ ["-1", "1.5", "4294967296"] $ \value ->
            it ("refuses an invalid request-count limit: " <> value) $
                parseOpenDatumCommand (line <> ["--limit", value]) `shouldSatisfy` \case
                    Left (BadValue "--limit" _) -> True
                    _ -> False
        forM_ ["reclaim", "cleanup"] $ \verb -> do
            it (verb <> " still requires one explicit pending reference") $
                parseOpenDatumCommand (verb : drop 1 line)
                    `shouldBe` Left (MissingFlag "--pending")
            it (verb <> " refuses a discovery limit") $
                parseOpenDatumCommand
                    ( (verb : drop 1 line)
                        <> ["--pending", replicate 64 'b' <> "#0", "--limit", "1"]
                    )
                    `shouldSatisfy` \case
                        Left (BadValue "--limit" _) -> True
                        _ -> False

    describe "reading a key without a signer" $ do
        it
            "runs inspect and reports an unavailable provider as structured data"
            $ do
                let provider _ =
                        Env
                            { envTracer = nullTracer
                            , envSource = "fixture"
                            , envReaderReads = \_ _ -> ioError (userError "provider disconnected")
                            , envReads = \_ _ -> fail "inspect opened builder startup"
                            , envWrites = \_ _ -> fail "inspect opened a writer"
                            }
                    line =
                        [ "inspect"
                        , "--state-token"
                        , replicate 56 'a' <> "." <> replicate 64 '1'
                        , "--network-magic"
                        , "42"
                        , "--koios-url"
                        , "http://fixture.invalid"
                        , "--key"
                        , "a-key"
                        , "--json"
                        ]
                (code, out, _) <-
                    captured
                        ( runPackagedOpenDatumVia
                            provider
                            openDatumApplication
                            (pure Nothing)
                            line
                            []
                        )
                code `shouldBe` ExitFailure 1
                (Aeson.eitherDecodeStrict' out :: Either String Aeson.Value)
                    `shouldSatisfy` either (const False) (const True)
                BC.unpack out
                    `shouldSatisfy` (\s -> "unavailable" `Data.List.isInfixOf` s)
    describe "unsupported public routes" $
        forM_ ["create", "insert", "update", "terminate", "fold", "inspect"] $ \verb ->
            forM_ [["open-datum", verb]] $ \line ->
                it ("refuses " <> unwords line <> " without an alias") $
                    parseOpenDatumCommand line `shouldBe` Left (UnknownCommand line)
