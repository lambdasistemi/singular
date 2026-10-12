{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.CLISpec
Description : The keri-stub command line parses its four verbs
License     : Apache-2.0

Effect-free rows over the real parser: help, the four verbs, the
common flags, and the refusals that must happen before any file, node
or key is read. @convict@ arrives in a later brief and is an unknown
command for now.
-}
module Singular.Application.KeriStub.CLISpec (spec) where

import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Test.Hspec

import Singular.Application.KeriStub.Command
import Singular.CLI.Command
    ( CreateArgs (..)
    , EntryArgs (..)
    , Key (..)
    )
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
    it "names the four commands and only them in its keriStubUsage" $ do
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub create"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub register"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub fold"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub status"
        keriStubUsage `shouldNotSatisfy` isInfixOf "keri-stub convict"
    it "refuses a command it does not support" $
        parseKeriStubCommand ["keri-stub", "delete"]
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
    it "refuses entry flags it does not take" $ do
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
    it "reads a register with its key, deposit, payload and fold" $
        case parseKeriStubCommand
            ( [ "keri-stub"
              , "register"
              , "--key"
              , "hello"
              , "--deposit"
              , "4000000"
              , "--payload"
              , "/srv/prefix.json"
              , "--fold"
              , "--fund-input"
              , seedText
              , "--max-outlay"
              , "5000000"
              ]
                <> reg
                <> provider
                <> wallet
            ) of
            Right (KeriRegister a) -> do
                show (entryKey a) `shouldBe` show (Key "hello")
                entryDeposit a `shouldBe` Just 4000000
                entryDocument a `shouldBe` Just "/srv/prefix.json"
                entryFold a `shouldBe` True
                entryFund a `shouldSatisfy` isJust
                entryMaxOutlay a `shouldBe` Just 5000000
            other ->
                expectationFailure ("register did not parse: " <> show other)
    it
        "reads a register without deposit, payload and fold, naming the registry by its token"
        $ case parseKeriStubCommand
            ( ["keri-stub", "register", "--key", "hello"]
                <> reg
                <> provider
                <> wallet
            ) of
            Right (KeriRegister a) -> do
                entryDeposit a `shouldBe` Nothing
                entryDocument a `shouldBe` Nothing
                entryFold a `shouldBe` False
            other ->
                expectationFailure ("register did not parse: " <> show other)
    it "refuses a register with a key hex beside its key text" $
        parseKeriStubCommand
            ( ["keri-stub", "register", "--key", "hello", "--key-hex", "00ff"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it "refuses a register with no key" $
        parseKeriStubCommand
            (["keri-stub", "register"] <> reg <> provider <> wallet)
            `shouldSatisfy` isLeft
    it "refuses a register that previews: it books and submits" $ do
        parseKeriStubCommand
            ( ["keri-stub", "register", "--key", "hello", "--preview"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
        parseKeriStubCommand
            ( [ "keri-stub"
              , "register"
              , "--key"
              , "hello"
              , "--wallet-address"
              , "addr_test1vq"
              ]
                <> reg
                <> provider
            )
            `shouldSatisfy` isLeft
    it "refuses a register that names a request to fold" $
        parseKeriStubCommand
            ( ["keri-stub", "register", "--key", "hello", "--request", seedText]
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
