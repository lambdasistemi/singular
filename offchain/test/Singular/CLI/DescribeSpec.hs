{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.DescribeSpec
Description : Parsing and first refusals of singular registry describe
License     : Apache-2.0

Describe reads the registry page from the chain alone: it takes the state
token, the blueprint of the packaged release, a provider and a network, and
refuses every wallet, key, state directory or other write setting by name
before anything is read.
-}
module Singular.CLI.DescribeSpec (spec) where

import Control.Exception (try)
import Control.Monad (forM_)
import Control.Tracer (nullTracer)
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Data.Text qualified as T
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Singular.CLI.Command
    ( CLIError (..)
    , Command (..)
    , DescribeArgs (..)
    , parseCommand
    , renderCLIError
    , usage
    )
import Singular.CLI.Describe (readVersionLabel, runDescribe)
import Singular.CLI.FlagGroup (commonFlagGroup, commonSwitches)
import Singular.CLI.Session (CommandFailure, Env (..))
import Singular.Registry.Application (neutralApplication)
import Singular.Registry.Page
    ( Page
    , PageRefusal (..)
    , renderPageRefusal
    )

spec :: Spec
spec = describe "Singular.CLI.Describe" $ do
    it "parses a minimal describe command" $ do
        case parseCommand validArgs of
            Left err -> expectationFailure ("refused: " <> renderCLIError err)
            Right (Describe args) -> do
                describeBlueprint args `shouldBe` "blueprint.json"
                describeJson args `shouldBe` False
            Right other -> expectationFailure ("another command: " <> show other)
    it "reads --json as the JSON page" $ do
        case parseCommand (validArgs <> ["--json"]) of
            Left err -> expectationFailure ("refused: " <> renderCLIError err)
            Right (Describe args) -> describeJson args `shouldBe` True
            Right other -> expectationFailure ("another command: " <> show other)
    it "refuses every write setting by name" $ do
        forM_ valuedRefusals $ \flag ->
            parseCommand (validArgs <> [flag, "x"])
                `shouldBe` Left (RefusedSetting flag)
        forM_ switchRefusals $ \flag ->
            parseCommand (validArgs <> [flag])
                `shouldBe` Left (RefusedSetting flag)
    it "refuses every setting outside the describe set by name" $ do
        forM_
            [ "--fold"
            , "--request"
            , "--application-policy"
            , "--process-time"
            , "--retract-time"
            , "--outputs-at"
            ]
            $ \flag -> refusedComplement `shouldSatisfy` elem flag
        forM_ refusedComplement $ \flag -> do
            let args = validArgs <> [flag] <> ["x" | flag `notElem` commonSwitches]
            case parseCommand args of
                Left err -> renderCLIError err `shouldSatisfy` isInfixOf flag
                Right _ -> expectationFailure (flag <> " accepted")
    it "needs its state token" $ do
        parseCommand argsWithoutToken
            `shouldBe` Left (MissingFlag "--state-token")
        parseCommand validArgs `shouldSatisfy` (not . isLeft)
    it "names describe in its usage" $ do
        usage `shouldSatisfy` isInfixOf "registry describe"
        usage `shouldSatisfy` isInfixOf "--json"
    it "names the refused setting and describe" $ do
        renderCLIError (RefusedSetting "--wallet-skey")
            `shouldSatisfy` isInfixOf "--wallet-skey"
        renderCLIError (RefusedSetting "--wallet-skey")
            `shouldSatisfy` isInfixOf "describe"
    it "reads the version beside the blueprint or refuses it by name" $
        withSystemTempDirectory "describe-version-file" $ \dir -> do
            readVersionLabel (dir </> "blueprint.json")
                `shouldReturn` Left VersionMissing
            renderPageRefusal VersionMissing
                `shouldSatisfy` T.isInfixOf "version-missing"
            writeFile (dir </> "version.txt") "not a version\n"
            outcome <- readVersionLabel (dir </> "blueprint.json")
            case outcome of
                Left refusal ->
                    renderPageRefusal refusal
                        `shouldSatisfy` T.isInfixOf "version-malformed"
                Right label ->
                    expectationFailure
                        ("a malformed version was accepted: " <> show label)
            writeFile (dir </> "version.txt") "0.10.1\n"
            readVersionLabel (dir </> "blueprint.json")
                `shouldReturn` Right "0.10.1"
    it "refuses a missing version before any provider read" $
        withSystemTempDirectory "describe-version-first" $ \dir -> do
            let blueprint = dir </> "blueprint.json"
            writeFile blueprint "{}"
            case parseCommand (argsWithBlueprint blueprint) of
                Left err -> expectationFailure ("refused: " <> renderCLIError err)
                Right (Describe args) -> do
                    result <-
                        try (runDescribe neutralApplication testEnv args)
                            :: IO (Either CommandFailure Page)
                    case result of
                        Left failure ->
                            show failure `shouldSatisfy` isInfixOf "version-missing"
                        Right _ ->
                            expectationFailure "a page without a version was accepted"
                Right other -> expectationFailure ("another command: " <> show other)

tokenSpelling :: String
tokenSpelling = concat (replicate 28 "ab") <> "." <> concat (replicate 32 "cd")

validArgs :: [String]
validArgs = argsWithBlueprint "blueprint.json"

argsWithBlueprint :: FilePath -> [String]
argsWithBlueprint blueprint =
    [ "registry"
    , "describe"
    , "--blueprint"
    , blueprint
    , "--state-token"
    , tokenSpelling
    , "--koios-url"
    , "https://koios.example.invalid"
    , "--network-magic"
    , "42"
    ]

argsWithoutToken :: [String]
argsWithoutToken =
    [ "registry"
    , "describe"
    , "--blueprint"
    , "blueprint.json"
    , "--koios-url"
    , "https://koios.example.invalid"
    , "--network-magic"
    , "42"
    ]

-- | Valued flags describe refuses, each with a value to carry.
valuedRefusals :: [String]
valuedRefusals =
    [ "--wallet-skey"
    , "--state-dir"
    , "--receipt"
    , "--wallet-address"
    , "--seed"
    , "--key"
    , "--key-hex"
    , "--deposit"
    , "--payload"
    , "--fund-input"
    , "--max-outlay"
    , "--confirm-timeout"
    , "--request"
    ]

-- | Switches describe refuses.
switchRefusals :: [String]
switchRefusals = ["--preview", "--fold"]

{- | Every flag the parser reads that describe does not take, discovered
from the parser's own closed sets: the valued flags, the switches and
the create-only application policy, minus what describe accepts and
what selects help.
-}
refusedComplement :: [String]
refusedComplement =
    [ flag
    | flag <- commonFlagGroup <> commonSwitches <> ["--application-policy"]
    , flag `notElem` allowedDescribeFlags
    ]

{- | What describe accepts: the token, the blueprint, the provider and
the network. @--json@ never reaches the tokenizer and @--help@ selects
help; neither is refused.
-}
allowedDescribeFlags :: [String]
allowedDescribeFlags =
    [ "--blueprint"
    , "--state-token"
    , "--koios-url"
    , "--network-magic"
    , "--koios-token-file"
    , "--network-time"
    , "--help"
    , "-h"
    ]

{- | An environment that fails the test when the page reads or writes: the
version refusal must come before any of it.
-}
testEnv :: Env
testEnv =
    Env
        { envTracer = nullTracer
        , envSource = "describe-test"
        , envLoadRelease = \_ _ -> pure (Left "no release in this test")
        , envReads = \_ _ -> fail "the page read the provider before refusing the version"
        , envWrites = \_ _ -> fail "the page wrote before refusing the version"
        }
