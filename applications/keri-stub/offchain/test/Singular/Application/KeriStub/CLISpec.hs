{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.CLISpec
Description : The keri-stub command line parses its five verbs
License     : Apache-2.0

Effect-free rows over the real parser: help, the five verbs, the
common flags, and the refusals that must happen before any file, node
or key is read.
-}
module Singular.Application.KeriStub.CLISpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
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

{- | The registration cost and booking width every create is given: neither
has a default, and both are fixed for the life of the registry.
-}
createValues :: [String]
createValues = ["--registration-cost", "3000000", "--booking-width", "20000"]

tokenSpelling :: String
tokenSpelling = replicate 56 '0' <> "." <> replicate 64 '0'

reg :: [String]
reg = createReg <> ["--state-token", tokenSpelling]

seedText :: String
seedText =
    replicate 64 'a' <> "#0"

-- | One evidence hash as the command line spells it.
evidenceHex :: String
evidenceHex =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

-- | One convict with its key and evidence.
convict :: [String]
convict =
    ["keri-stub", "convict", "--key", "hello", "--evidence", evidenceHex]

-- | One convict whose evidence is not base16 bytes.
convictBadEvidence :: [String]
convictBadEvidence =
    ["keri-stub", "convict", "--key", "hello", "--evidence", "not-hex!!"]

-- | One convict with evidence but no key.
convictNoKey :: [String]
convictNoKey =
    ["keri-stub", "convict", "--evidence", evidenceHex]

-- | The evidence hash as bytes.
evidenceBytes :: ByteString
evidenceBytes = case B16.decode (BC.pack evidenceHex) of
    Right bytes -> bytes
    Left why -> error ("CLISpec: bad evidence hex: " <> why)

commandLine :: Spec
commandLine = describe "the command line" $ do
    it "answers help at the top and under keri-stub" $ do
        parseKeriStubCommand ["--help"] `shouldBe` Right KeriHelp
        parseKeriStubCommand ["keri-stub", "--help"]
            `shouldBe` Right KeriHelp
        parseKeriStubCommand [] `shouldBe` Right KeriHelp
    it "names the five commands and only them in its keriStubUsage" $ do
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub create"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub register"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub convict"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub fold"
        keriStubUsage `shouldSatisfy` isInfixOf "keri-stub status"
    it "refuses a command it does not support" $
        parseKeriStubCommand ["keri-stub", "delete"]
            `shouldSatisfy` isLeft
    it "reads a create with its seed, wallet and provider" $
        case parseKeriStubCommand
            ( ["keri-stub", "create", "--seed", seedText]
                <> createReg
                <> createValues
                <> provider
                <> wallet
            ) of
            Right (KeriCreate a) -> do
                show (createSeed a) `shouldBe` show (Just seedText)
                createBlueprint a `shouldBe` "/srv/plutus.json"
                createPreview a `shouldBe` False
                createRegistrationCost a `shouldBe` 3_000_000
                createBookingWidth a `shouldBe` 20_000
            other ->
                expectationFailure ("create did not parse: " <> show other)
    describe "the registration cost and the booking width" $ do
        let create extra =
                parseKeriStubCommand
                    ( ["keri-stub", "create", "--seed", seedText]
                        <> createReg
                        <> provider
                        <> wallet
                        <> extra
                    )
            valuesOf =
                fmap
                    ( \case
                        KeriCreate a -> Just (createRegistrationCost a, createBookingWidth a)
                        _ -> Nothing
                    )
        it "retains the values it is given" $
            valuesOf (create createValues)
                `shouldBe` Right (Just (3_000_000, 20_000))
        it "takes a zero cost and a width of one millisecond" $
            valuesOf (create ["--registration-cost", "0", "--booking-width", "1"])
                `shouldBe` Right (Just (0, 1))
        it "refuses a create without the registration cost, naming it" $
            create ["--booking-width", "20000"]
                `shouldBe` Left (MissingFlag "--registration-cost")
        it "refuses a create without the booking width, naming it" $
            create ["--registration-cost", "3000000"]
                `shouldBe` Left (MissingFlag "--booking-width")
        it "refuses a cost that is negative, fractional or not a number" $
            mapM_
                ( \value ->
                    create ["--registration-cost", value, "--booking-width", "20000"]
                        `shouldBe` Left
                            ( BadValue
                                "--registration-cost"
                                "needs a non-negative integer number of lovelace"
                            )
                )
                ["-1", "1.5", "lots", "", "0x10"]
        it
            "refuses a width that is zero, negative, fractional or not a number"
            $ mapM_
                ( \value ->
                    create ["--registration-cost", "3000000", "--booking-width", value]
                        `shouldBe` Left
                            ( BadValue
                                "--booking-width"
                                "needs a positive integer number of milliseconds"
                            )
                )
                ["0", "-5", "1.5", "lots", "", "1e3"]
        it "refuses both flags on later commands instead of ignoring them" $
            mapM_
                ( \(flag, what) ->
                    parseKeriStubCommand
                        (["keri-stub", "fold", flag, "1"] <> reg <> provider <> wallet)
                        `shouldBe` Left
                            ( BadValue
                                flag
                                ( "is a keri-stub create flag: "
                                    <> what
                                    <> " is fixed for the life of a registry"
                                )
                            )
                )
                [ ("--registration-cost", "the registration cost")
                , ("--booking-width", "the widest booking interval")
                ]
    it "refuses a create without its seed" $
        parseKeriStubCommand
            ( ["keri-stub", "create"]
                <> createReg
                <> createValues
                <> provider
                <> wallet
            )
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
                <> createValues
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
    it "reads a convict with its key, evidence and fold" $
        case parseKeriStubCommand
            (convict <> ["--fold"] <> reg <> provider <> wallet) of
            Right (KeriConvict c) -> do
                show (entryKey (convictEntry c)) `shouldBe` show (Key "hello")
                convictEvidence c `shouldBe` evidenceBytes
                entryFold (convictEntry c) `shouldBe` True
            other ->
                expectationFailure ("convict did not parse: " <> show other)
    it "reads a convict without its fold" $
        case parseKeriStubCommand (convict <> reg <> provider <> wallet) of
            Right (KeriConvict c) -> do
                convictEvidence c `shouldBe` evidenceBytes
                entryFold (convictEntry c) `shouldBe` False
            other ->
                expectationFailure ("convict did not parse: " <> show other)
    it "refuses a convict with no evidence" $
        parseKeriStubCommand
            ( ["keri-stub", "convict", "--key", "hello"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it "refuses a convict whose evidence is not base16 bytes" $
        parseKeriStubCommand
            (convictBadEvidence <> reg <> provider <> wallet)
            `shouldSatisfy` isLeft
    it "refuses a convict that names a deposit or a payload" $ do
        parseKeriStubCommand
            (convict <> ["--deposit", "4000000"] <> reg <> provider <> wallet)
            `shouldSatisfy` isLeft
        parseKeriStubCommand
            ( convict
                <> ["--payload", "/srv/prefix.json"]
                <> reg
                <> provider
                <> wallet
            )
            `shouldSatisfy` isLeft
    it "refuses a convict that previews: it books and submits" $
        parseKeriStubCommand
            (convict <> ["--preview"] <> reg <> provider <> wallet)
            `shouldSatisfy` isLeft
    it "refuses a convict with no key" $
        parseKeriStubCommand (convictNoKey <> reg <> provider <> wallet)
            `shouldSatisfy` isLeft
    it "refuses a convict that names a request to fold" $
        parseKeriStubCommand
            (convict <> ["--request", seedText] <> reg <> provider <> wallet)
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
