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

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Word (Word32)
import Test.Hspec

import Singular.Application.KeriStub.Command
import Singular.CLI.Command
    ( CreateArgs (..)
    , EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , Key (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    )
import Singular.CLI.FlagGroup (commonFlagGroup)
import Singular.Registry.StateToken (renderStateToken)

spec :: Spec
spec = describe "keri-stub commands" $ do
    commandLine
    flags
    payloadSchemaRows
    registryAddressRows

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

-- ---------------------------------------------------------
-- The payload schema (#719)
-- ---------------------------------------------------------

{- | @--payload-schema@ names the form the register's payload file is
written in. Register reads it; every other verb refuses it by name as it
refuses @--payload@; the value is one of two lower-case names.
-}
payloadSchemaRows :: Spec
payloadSchemaRows = describe "the payload schema setting (#719)" $ do
    let register extra =
            parseKeriStubCommand
                ( ["keri-stub", "register", "--key", "hello", "--payload", "/p.json"]
                    <> extra
                    <> reg
                    <> provider
                    <> wallet
                )
    forM_ ["plain", "detailed"] $ \name ->
        it ("reads --payload-schema " <> name <> " on register") $
            register ["--payload-schema", name] `shouldSatisfy` isRight
    it "reads the =value spelling on register" $
        register ["--payload-schema=detailed"] `shouldSatisfy` isRight
    it "reads a register without the setting, as before" $
        register [] `shouldSatisfy` isRight
    it "refuses a value that is not a schema name, naming the flag" $
        forM_ ["yaml", "Plain", "DETAILED", "", "plain,detailed", "json"] $ \value ->
            register ["--payload-schema", value]
                `shouldBe` Left
                    ( BadValue
                        "--payload-schema"
                        "is not a payload schema: give plain or detailed"
                    )
    it "refuses the setting with no value" $
        parseKeriStubCommand
            ( ["keri-stub", "register", "--key", "hello", "--payload", "/p.json"]
                <> reg
                <> provider
                <> wallet
                <> ["--payload-schema"]
            )
            `shouldBe` Left (BadValue "--payload-schema" "needs a value")
    forM_ ["fold", "status", "convict"] $ \verb ->
        it
            ( "refuses the setting on "
                <> verb
                <> ", by name, as it refuses --payload"
            )
            $ do
                let line extra =
                        parseKeriStubCommand
                            ( ["keri-stub", verb, "--key", "hello", "--evidence", evidenceHex]
                                <> reg
                                <> provider
                                <> wallet
                                <> extra
                            )
                    renamed = \case
                        Left (BadValue _ why) -> Left (BadValue "--payload-schema" why)
                        other -> other
                line ["--payload-schema", "plain"]
                    `shouldBe` renamed (line ["--payload", "/p.json"])
                line ["--payload-schema", "plain"]
                    `shouldSatisfy` \case
                        Left (BadValue "--payload-schema" _) -> True
                        _ -> False

-- ---------------------------------------------------------
-- A registry has an address (#728)
-- ---------------------------------------------------------

{- | The registry a command was told to act on: its state token and the
network magic of its provider.
-}
reading :: KeriStubCommand -> Maybe (String, Word32)
reading = \case
    KeriRegister a -> entry a
    KeriConvict c -> entry (convictEntry c)
    KeriFold a ->
        named (foldAccess a) (providerMagic (writeProvider (foldWrite a)))
    KeriStatus a -> named (inspectAccess a) (providerMagic (inspectProvider a))
    _ -> Nothing
  where
    entry a = named (entryAccess a) (providerMagic (entryProvider a))
    entryProvider a = case entryMode a of
        Submit settings -> writeProvider settings
        Preview settings _ -> settings
    named access magic =
        Just (T.unpack (renderStateToken (accessToken access)), magic)

{- | The addresses of one state token on two networks, made by an independent
bech32 implementation (the reference algorithm of BIP-173) and not by the
code under test: the same fixed values as the registry command suite.
-}
policyHex, nameHex, devnetAddress, preprodAddress :: String
policyHex = "68df9c42ebd4468be130e9cd5538a7af39cc31c146cda45f274cccc5"
nameHex = "1d5542bdf2b2c8c76728a5935edd71676d1df5f389c70863b6a4d15fe33bde26"
devnetAddress =
    "singular_devnet1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3x3ggs8q"
preprodAddress =
    "singular_preprod1dr0ecsht63rghcfsa8x42w984uuucvwpgmx6ghe8fnxv2824g27l9vkgcanj3fvntmwhzemdrh6l8zw8pp3mdfx3tl3nhh3xe8mmy4"

-- | The same address with its last character changed: the checksum is wrong.
mistypedAddress :: String
mistypedAddress = init devnetAddress <> "9"

registryAddressRows :: Spec
registryAddressRows = describe "a registry given by its address" $ do
    forM_ verbs $ \(verb, base) -> describe ("keri-stub " <> verb) $ do
        it
            "is named by --registry alone, which gives the state token and the network"
            $ told base [] [("--registry", devnetAddress)]
                `shouldBe` Right (policyHex <> "." <> nameHex, 42)
        it "gives the network its address names" $
            told base [] [("--registry", preprodAddress)]
                `shouldBe` Right (policyHex <> "." <> nameHex, 1)
        it "is named by the variable SINGULAR_REGISTRY alone" $
            told base [("SINGULAR_REGISTRY", devnetAddress)] []
                `shouldBe` Right (policyHex <> "." <> nameHex, 42)
        it
            "is read with a state token and a network magic that are the address's"
            $ told
                base
                []
                [ ("--registry", devnetAddress)
                , ("--state-token", policyHex <> "." <> nameHex)
                , ("--network-magic", "42")
                ]
                `shouldBe` Right (policyHex <> "." <> nameHex, 42)
        it "is refused beside a state token of another token, naming both" $
            told
                base
                []
                [ ("--registry", devnetAddress)
                , ("--state-token", policyHex <> "." <> replicate 64 '0')
                ]
                `refusedWith` [policyHex <> "." <> nameHex, replicate 64 '0']
        it "is refused beside a network magic of another network, naming both" $
            told
                base
                []
                [("--registry", devnetAddress), ("--network-magic", "1")]
                `refusedWith` ["singular_devnet", "--network-magic"]
        it
            "is refused with a word that is not an address, by what is wrong with it"
            $ do
                told base [] [("--registry", "not-an-address")]
                    `refusedWith` ["not an address"]
                told base [] [("--registry", mistypedAddress)]
                    `refusedWith` ["checksum"]
        it "is refused as before with neither a registry nor a state token" $
            told base [] [("--network-magic", "42")]
                `shouldBe` Left "missing --state-token"
        it "is no longer refused as the renamed --state-dir" $
            told base [] [("--registry", "/srv/reg")]
                `refusedNot` ["was renamed to"]
    it "is a flag of the common group" $
        commonFlagGroup `shouldSatisfy` elem "--registry"
  where
    node = ["--koios-url", "http://127.0.0.1:8080/api/v1"]
    verbs =
        [
            ( "register"
            , ["keri-stub", "register", "--key", "hello", "--payload", "/p.json"]
                <> createReg
                <> node
                <> wallet
            )
        , ("convict", convict <> createReg <> node <> wallet)
        , ("fold", ["keri-stub", "fold"] <> createReg <> node <> wallet)
        ,
            ( "status"
            , ["keri-stub", "status", "--key", "hello"] <> createReg <> node
            )
        ]
    told base environment given =
        case parseKeriStubCommandWithEnvironment
            environment
            (base <> concat [[flag, value] | (flag, value) <- given]) of
            Left err -> Left (renderCLIError err)
            Right command -> maybe (Left "not a registry command") Right (reading command)
    refusedWith result needles = case result of
        Left sentence -> forM_ needles $ \needle ->
            (needle, sentence) `shouldSatisfy` uncurry isInfixOf
        Right _ -> expectationFailure "the line was read, it should be refused"
    refusedNot result needles = case result of
        Left sentence -> forM_ needles $ \needle ->
            (needle, sentence) `shouldSatisfy` (not . uncurry isInfixOf)
        Right _ -> expectationFailure "the line was read, it should be refused"
