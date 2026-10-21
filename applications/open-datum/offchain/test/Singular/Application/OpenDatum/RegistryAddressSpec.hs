{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.RegistryAddressSpec
Description : A registry named by its address on the open-datum command line
License     : Apache-2.0

The commands of @open-datum@ that take a state token take the registry's
address as well, as a standing setting in the three forms of the earlier
settings: the flag, the variable and the key of the settings file. The address
gives the state token and the network, and a state token or a network magic
beside it that disagrees is refused naming both.

The addresses below were made by an independent bech32 implementation (the
reference algorithm of BIP-173), not by the code under test: the same fixed
values as the registry command suite.
-}
module Singular.Application.OpenDatum.RegistryAddressSpec (spec) where

import Control.Monad (forM_)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Word (Word32)
import Test.Hspec

import Singular.Application.OpenDatum.Command
    ( EntryArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , OpenDatumCommand (..)
    , ProviderSettings (..)
    , RegistryAccess (..)
    , WriteSettings (..)
    , parseOpenDatumInvocationFrom
    , renderCLIError
    )
import Singular.CLI.Sources (Sources (..))
import Singular.Registry.StateToken (renderStateToken)

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

tokenText :: String
tokenText = policyHex <> "." <> nameHex

-- | The registry a command was told to act on: its state token and its network.
reading :: OpenDatumCommand -> Maybe (String, Word32)
reading = \case
    OpenInsert a -> entry a
    OpenUpdate a -> entry a
    OpenTerminate a -> entry a
    OpenFold a -> named (foldAccess a) (providerMagic (writeProvider (foldWrite a)))
    OpenInspect a -> named (inspectAccess a) (providerMagic (inspectProvider a))
    _ -> Nothing
  where
    entry a = named (entryAccess a) (providerMagic (entryProvider a))
    entryProvider a = case entryMode a of
        Submit settings -> writeProvider settings
        Preview settings _ -> settings
    named access magic =
        Just (T.unpack (renderStateToken (accessToken access)), magic)

-- | What a person is told about a line: the reading, or the sentence.
told
    :: [String]
    -> [(String, String)]
    -> [(String, String)]
    -> [(String, String)]
    -> Either String (String, Word32)
told base flags environment keys =
    case parseOpenDatumInvocationFrom
        (Sources environment (Right keys))
        (base <> concat [[flag, value] | (flag, value) <- flags]) of
        Left err -> Left (renderCLIError err)
        Right (command, _) ->
            maybe (Left "not a registry command") Right (reading command)

refusedWith :: Either String a -> [String] -> Expectation
refusedWith result needles = case result of
    Left sentence -> forM_ needles $ \needle ->
        (needle, sentence) `shouldSatisfy` uncurry isInfixOf
    Right _ -> expectationFailure "the line was read, it should be refused"

refusedNot :: Either String a -> [String] -> Expectation
refusedNot result needles = case result of
    Left sentence -> forM_ needles $ \needle ->
        (needle, sentence) `shouldSatisfy` (not . uncurry isInfixOf)
    Right _ -> expectationFailure "the line was read, it should be refused"

spec :: Spec
spec = describe "a registry given by its address" $ do
    forM_ verbs $ \(verb, base) -> describe ("open-datum " <> verb) $ do
        it
            "is named by --registry alone, which gives the state token and the network"
            $ told base [("--registry", devnetAddress)] [] []
                `shouldBe` Right (tokenText, 42)
        it "is named by the variable SINGULAR_REGISTRY alone" $
            told base [] [("SINGULAR_REGISTRY", devnetAddress)] []
                `shouldBe` Right (tokenText, 42)
        it "is named by the key registry of the settings file alone" $
            told base [] [] [("registry", devnetAddress)]
                `shouldBe` Right (tokenText, 42)
        it
            "is read with a state token and a network magic that are the address's"
            $ told
                base
                [ ("--registry", devnetAddress)
                , ("--state-token", tokenText)
                , ("--network-magic", "42")
                ]
                []
                []
                `shouldBe` Right (tokenText, 42)
        it "is refused beside a state token of another token, naming both" $
            told
                base
                [ ("--registry", devnetAddress)
                , ("--state-token", policyHex <> "." <> replicate 64 '0')
                ]
                []
                []
                `refusedWith` [tokenText, replicate 64 '0']
        it "is refused beside a network magic of another network, naming both" $
            told
                base
                [("--registry", devnetAddress), ("--network-magic", "1")]
                []
                []
                `refusedWith` ["singular_devnet", "--network-magic"]
        it "is refused beside a stale state-token key, saying what disagrees" $
            told
                base
                [("--registry", devnetAddress)]
                []
                [("state-token", policyHex <> "." <> replicate 64 '0')]
                `refusedWith` [tokenText, replicate 64 '0']
        it "reads an address of another network with the magic it names" $
            told base [("--registry", preprodAddress)] [] []
                `shouldBe` Right (tokenText, 1)
        it
            "is refused with a word that is not an address, by what is wrong with it"
            $ do
                told base [("--registry", "not-an-address")] [] []
                    `refusedWith` ["not an address"]
                told base [("--registry", mistypedAddress)] [] []
                    `refusedWith` ["checksum"]
        it "is refused as before with neither a registry nor a state token" $
            told base [("--network-magic", "42")] [] []
                `shouldBe` Left "missing --state-token"
        it "is no longer refused as the renamed --state-dir" $
            told base [("--registry", "/srv/reg")] [] []
                `refusedNot` ["was renamed to"]
  where
    node = ["--koios-url", "http://127.0.0.1:8080/api/v1"]
    createReg = ["--state-dir", "/srv/reg", "--blueprint", "/srv/plutus.json"]
    wallet = ["--wallet-skey", "/keys/payment.skey"]
    verbs =
        [
            ( "insert"
            , ["insert", "--key", "key", "--payload", "/p.json"]
                <> createReg
                <> node
                <> wallet
            )
        ,
            ( "update"
            , ["update", "--key", "key", "--payload", "/p.json"]
                <> createReg
                <> node
                <> wallet
            )
        ,
            ( "terminate"
            , ["terminate", "--key", "key"]
                <> createReg
                <> node
                <> wallet
            )
        , ("fold", ["fold"] <> createReg <> node <> wallet)
        ,
            ( "inspect"
            , ["inspect", "--key", "key"] <> createReg <> node
            )
        ]
