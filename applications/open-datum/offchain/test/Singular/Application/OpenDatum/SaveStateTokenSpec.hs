{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.SaveStateTokenSpec
Description : The switch that has open-datum create keep the registry's name in the settings file
License     : Apache-2.0

@open-datum create --save-state-token@ writes the new registry's state token
into the settings file, so the commands after it can leave @--state-token@
out. These cases hold what the command line tells a person before anything is
read or spent: the switch is taken by create alone, in either spelling of the
command and with or without @--closed@; it is refused when no registry will
exist to name (a preview, an external signer); it has no key of the settings
file; and the help says what it does. What the switch does to the settings
file after a create is held where a create can be run, in
"Singular.Application.OpenDatum.CommandRunSpec".

Every refusal is paired with the same line without the switch, which must
still be read, so a refusal cannot be mistaken for a line never understood.
-}
module Singular.Application.OpenDatum.SaveStateTokenSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.List (isInfixOf)
import Test.Hspec

import Singular.Application.OpenDatum.Command
    ( openDatumHelp
    , openDatumVersion
    , parseOpenDatumInvocation
    , renderCLIError
    )
import Singular.Application.OpenDatum.Help (openDatumProgram)
import Singular.CLI.Options (Program)
import Singular.CLI.Sources (configFromValue)

program :: Program
program = openDatumProgram openDatumVersion

switch :: String
switch = "--save-state-token"

address :: String
address = "addr_test1vpd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95ksypknf7"

provider :: [String]
provider =
    [ "--blueprint"
    , "plutus.json"
    , "--koios-url"
    , "http://koios.example"
    , "--network-magic"
    , "42"
    ]

-- | A create that signs from a vault, in the namespaced spelling.
signed :: [String]
signed = ["open-datum", "create"] <> provider <> ["--vault", "alice.vault"]

-- | A preview of the same create, for a public address.
previewed :: [String]
previewed =
    ["open-datum", "create", "--preview"]
        <> provider
        <> ["--wallet-address", address]

-- | A create written for an external signer.
external :: [String]
external =
    ["open-datum", "create"]
        <> provider
        <> ["--wallet-address", address, "--bundle", "create.bundle"]

-- | What a person is told about a line, or that it was read.
told :: [String] -> Either String ()
told line = case parseOpenDatumInvocation [] line of
    Left err -> Left (renderCLIError err)
    Right _ -> Right ()

refusedWith :: Either String () -> [String] -> Expectation
refusedWith result needles = case result of
    Left sentence -> forM_ needles $ \needle ->
        (needle, sentence) `shouldSatisfy` uncurry isInfixOf
    Right () -> expectationFailure "the line was read, it should be refused"

spec :: Spec
spec = describe "the switch --save-state-token of open-datum create" $ do
    describe "a create that signs" $ do
        it "is read with the switch" $
            told (signed <> [switch]) `shouldBe` Right ()
        it "is read with the switch in the bare spelling of the command" $
            told ("create" : drop 2 signed <> [switch]) `shouldBe` Right ()
        it "is read with the switch beside --closed" $
            told (signed <> [switch, "--closed"]) `shouldBe` Right ()
        it "is read without it, as it always was" $ do
            told signed `shouldBe` Right ()
            told (signed <> ["--closed"]) `shouldBe` Right ()
    describe "a create that names no registry" $ do
        it "is read without the switch" $
            told previewed `shouldBe` Right ()
        it "is refused with a preview, which creates nothing" $
            told (previewed <> [switch])
                `refusedWith` [switch, "--preview", "nothing is created"]
        it "is read without the switch for an external signer" $
            told external `shouldBe` Right ()
        it
            "is refused with an external signer, whose registry does not exist yet"
            $ told (external <> [switch])
                `refusedWith` [ switch
                              , "--wallet-address"
                              , "--bundle"
                              , "until the bundle is submitted"
                              ]
        it "is refused before any other missing setting is" $
            told ["open-datum", "create", switch, "--preview"]
                `refusedWith` [switch, "--preview"]
    describe "every other command"
        $ forM_
            [ ["open-datum", "insert"]
            , ["open-datum", "update"]
            , ["open-datum", "terminate"]
            , ["open-datum", "fold"]
            , ["open-datum", "inspect"]
            ]
        $ \command ->
            it (unwords command <> " refuses it by name") $
                told (command <> [switch])
                    `refusedWith` [switch, "create flag"]
    describe "a setting that is not standing" $
        it "has no key of the settings file: the file may not name it" $
            configFromValue
                program
                "demo.json"
                (object ["save-state-token" .= String "true"])
                `shouldSatisfy` \case
                    Left sentence ->
                        all
                            (`isInfixOf` sentence)
                            ["demo.json", "save-state-token", "cannot come from a file"]
                    Right _ -> False
    describe "the help" $ do
        let page = openDatumHelp ["create"]
        it "of create lists the switch and says what it does" $ do
            page `shouldSatisfy` isInfixOf switch
            page `shouldSatisfy` isInfixOf "state-token"
            page `shouldSatisfy` isInfixOf "settings file"
        it "of the other commands does not mention it" $
            forM_ ["insert", "update", "terminate", "fold", "inspect"] $ \command ->
                openDatumHelp [command] `shouldSatisfy` (not . isInfixOf switch)
