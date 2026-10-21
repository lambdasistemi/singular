{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.SaveStateTokenSpec
Description : The switch that has create keep the registry's name in the settings file
License     : Apache-2.0

@singular registry create --save-state-token@ writes the new registry's state
token into the settings file, so the commands after it can leave
@--state-token@ out. These cases hold what the command line tells a person
before anything is read or spent: the switch is taken by create alone, it is
refused when no registry will exist to name (a preview, an external signer),
it has no variable and no key of the settings file, and the help says what it
does. What the switch does to the settings file after a create is held where
a create can be run, in "Singular.CLI.CommandRunSpec".

Every refusal is paired with the same line without the switch, which must
still be read, so a refusal cannot be mistaken for a line the program never
understood.
-}
module Singular.CLI.SaveStateTokenSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.List (isInfixOf)
import Test.Hspec

import Singular.CLI.Command
    ( parseInvocation
    , renderCLIError
    , singularVersion
    )
import Singular.CLI.Help (singularHelp, singularProgram)
import Singular.CLI.Options (Program)
import Singular.CLI.Sources (configFromValue)

program :: Program
program = singularProgram singularVersion

switch :: String
switch = "--save-state-token"

address :: String
address = "addr_test1vpd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95kj6tfd95ksypknf7"

-- | A create that signs from a vault.
signed :: [String]
signed =
    [ "registry"
    , "create"
    , "--blueprint"
    , "plutus.json"
    , "--koios-url"
    , "http://koios.example"
    , "--network-magic"
    , "42"
    , "--vault"
    , "alice.vault"
    ]

-- | A preview of the same create, for a public address.
previewed :: [String]
previewed =
    [ "registry"
    , "create"
    , "--preview"
    , "--blueprint"
    , "plutus.json"
    , "--koios-url"
    , "http://koios.example"
    , "--network-magic"
    , "42"
    , "--wallet-address"
    , address
    ]

-- | A create written for an external signer.
external :: [String]
external =
    [ "registry"
    , "create"
    , "--blueprint"
    , "plutus.json"
    , "--koios-url"
    , "http://koios.example"
    , "--network-magic"
    , "42"
    , "--wallet-address"
    , address
    , "--bundle"
    , "create.bundle"
    ]

-- | What a person is told about a line, or that it was read.
told :: [String] -> Either String ()
told line = case parseInvocation [] line of
    Left err -> Left (renderCLIError err)
    Right _ -> Right ()

refusedWith :: Either String () -> [String] -> Expectation
refusedWith result needles = case result of
    Left sentence -> forM_ needles $ \needle ->
        (needle, sentence) `shouldSatisfy` uncurry isInfixOf
    Right () -> expectationFailure "the line was read, it should be refused"

spec :: Spec
spec = describe "the switch --save-state-token of registry create" $ do
    describe "a create that signs" $ do
        it "is read with the switch" $
            told (signed <> [switch]) `shouldBe` Right ()
        it "is read with the switch anywhere on the line" $ do
            told (take 2 signed <> [switch] <> drop 2 signed) `shouldBe` Right ()
            told (switch : signed) `shouldBe` Right ()
        it "is read without it, as it always was" $
            told signed `shouldBe` Right ()
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
            told ["registry", "create", switch, "--preview"]
                `refusedWith` [switch, "--preview"]
    describe "every other command"
        $ forM_
            [ ["registry", "fold"]
            , ["registry", "reject"]
            , ["registry", "reclaim"]
            , ["registry", "inspect"]
            , ["registry", "describe"]
            , ["submit", "create.bundle"]
            , ["wallet", "create"]
            , ["wallet", "address"]
            , ["wallet", "sign", "create.bundle"]
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
        let page = singularHelp singularVersion [] ["registry", "create"]
        it "of create lists the switch and says what it does" $ do
            page `shouldSatisfy` isInfixOf switch
            page `shouldSatisfy` isInfixOf "state-token"
            page `shouldSatisfy` isInfixOf "settings file"
        it "of the other registry commands does not mention it" $
            forM_ ["fold", "reject", "reclaim", "inspect", "describe"] $ \command ->
                singularHelp singularVersion [] ["registry", command]
                    `shouldSatisfy` (not . isInfixOf switch)
