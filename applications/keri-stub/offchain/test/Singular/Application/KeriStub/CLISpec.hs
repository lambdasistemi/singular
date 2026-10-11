{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.CLISpec
Description : The keri-stub command line parses its three verbs
License     : Apache-2.0

Effect-free rows over the real parser: help, the three verbs, the
common flags, and the refusals that must happen before any file, node
or key is read. @register@ and @convict@ arrive in later briefs and
are unknown commands for now.
-}
module Singular.Application.KeriStub.CLISpec (spec) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Test.Hspec

import Singular.Application.KeriStub.Command
import Singular.CLI.Command (CreateArgs (..))
import Singular.CLI.FlagGroup (commonFlagGroup)

spec :: Spec
spec = describe "keri-stub commands" $ do
    commandLine
    flags

provider :: [String]
provider =
    [ "--koios-url"
    , "http://127.0.0.1:8080/api/v1"
    , "--network-magic"
    , "42"
    ]

wallet :: [String]
wallet = ["--wallet-skey", "/keys/payment.skey"]

createReg :: [String]
createReg = ["--state-dir", "/srv/reg", "--blueprint", "/srv/plutus.json"]

tokenSpelling :: String
tokenSpelling = replicate 56 '0' <> "." <> replicate 64 '0'

reg :: [String]
reg = createReg <> ["--state-token", tokenSpelling]

seedText :: String
seedText =
    replicate 64 'a' <> "#0"

commandLine :: Spec
commandLine = describe "the command line" $ do
    it "answers help at the top and under keri-stub" $ do
        parseKeriStubCommand ["--help"] `shouldBe` Right KeriHelp
        parseKeriStubCommand ["keri-stub", "--help"]
            `shouldBe` Right KeriHelp
        parseKeriStubCommand [] `shouldBe` Right KeriHelp
    it "names the three commands and only them in its keriStubUsage" $ do
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub create"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub fold"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub status"
        keriStubUsage `shouldNotSatisfy` isInfixOf "keri-stub register"
        keriStubUsage `shouldNotSatisfy` isInfixOf "keri-stub convict"
    it "refuses a command it does not support" $
        parseKeriStubCommand ["keri-stub", "delete"]
            `shouldSatisfy` isLeft
    it "leaves register for a later brief: unknown for now" $
        parseKeriStubCommand ["keri-stub", "register"]
            `shouldSatisfy` isLeft
    it "leaves convict for a later brief: unknown for now" $
        parseKeriStubCommand ["keri-stub", "convict"]
            `shouldSatisfy` isLeft
    it "reads a create with its seed, wallet and provider" $
        case parseKeriStubCommand
            ( ["keri-stub", "create", "--seed", seedText]
                <> createReg
                <> provider
                <> wallet
            ) of
            Right (KeriCreate a) -> do
                show (createSeed a) `shouldBe` show (Just seedText)
                createBlueprint a `shouldBe` "/srv/plutus.json"
                createPreview a `shouldBe` False
            other ->
                expectationFailure ("create did not parse: " <> show other)
    it "refuses a create without its seed" $
        parseKeriStubCommand
            (["keri-stub", "create"] <> createReg <> provider <> wallet)
            `shouldSatisfy` isLeft
    it "reads a fold with its token, wallet and provider" $
        parseKeriStubCommand
            (["keri-stub", "fold"] <> reg <> provider <> wallet)
            `shouldSatisfy` isRight
    it "reads a status with its token, key and provider" $
        parseKeriStubCommand
            ( ["keri-stub", "status", "--key", "hello"]
                <> reg
                <> provider
            )
            `shouldSatisfy` isRight
    it "refuses a status with a signing key" $
        parseKeriStubCommand
            ( ["keri-stub", "status", "--key", "hello"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it "refuses entry flags until register and convict arrive" $ do
        parseKeriStubCommand
            ( ["keri-stub", "create", "--seed", seedText, "--deposit", "5"]
                <> createReg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
        parseKeriStubCommand
            ( ["keri-stub", "fold", "--payload", "{}"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft

flags :: Spec
flags = describe "the common flags" $ do
    it "spells every common flag the registry-cli flag group reads" $ do
        commonFlagGroup `shouldSatisfy` elem "--state-token"
        commonFlagGroup `shouldSatisfy` elem "--koios-url"
        commonFlagGroup `shouldSatisfy` elem "--network-magic"
        commonFlagGroup `shouldSatisfy` elem "--wallet-skey"
        commonFlagGroup `shouldSatisfy` elem "--wallet-address"
        commonFlagGroup `shouldSatisfy` elem "--receipt"
        commonFlagGroup `shouldSatisfy` elem "--fund-input"
        commonFlagGroup `shouldSatisfy` elem "--max-outlay"
    it "reads SINGULAR_STATE_TOKEN when --state-token is absent" $
        parseKeriStubCommandWithEnvironment
            [("SINGULAR_STATE_TOKEN", tokenSpelling)]
            (["keri-stub", "fold"] <> createReg <> provider <> wallet)
            `shouldSatisfy` isRight
    it "names the token spelling it cannot read" $
        T.pack (renderCLIError (MissingFlag "--state-token"))
            `shouldSatisfy` (not . T.null)
