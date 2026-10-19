{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.SourcesSpec
Description : open-datum reads the six standing settings from the environment and a file
License     : Apache-2.0

The chain (@koios-url@, @network-time@, @network-magic@), the compiled
contracts (@blueprint@) and the registry (@state-dir@, @state-token@) are
typed on every command today. Each has three forms: the flag, the variable
@SINGULAR_<NAME>@ and the key @<name>@ of one JSON file. With the six in the
file, @open-datum insert --key alice --payload payload.json --vault
alice.vault@ is a whole command and means what the same command with the six
flags means.
-}
module Singular.Application.OpenDatum.SourcesSpec (spec) where

import Control.Monad (forM_)
import Data.Either (isRight)
import Data.List (isInfixOf, nub, sort)
import Data.Maybe (fromMaybe, isJust)
import Test.Hspec

import Singular.Application.OpenDatum.Command
    ( CLIError (..)
    , openDatumRefusalHint
    , openDatumVersion
    , parseOpenDatumInvocation
    , parseOpenDatumInvocationFrom
    )
import Singular.Application.OpenDatum.Help (openDatumProgram)
import Singular.CLI.Options
    ( Flag (..)
    , Leaf (..)
    , Program
    , helpText
    , leafShape
    , programLeaves
    , shapeFlags
    )
import Singular.CLI.Sources (Sources (..))

program :: Program
program = openDatumProgram openDatumVersion

token :: String
token = replicate 56 'a' <> "." <> replicate 64 'b'

-- | The six standing settings: flag, variable, key and a value each.
settings :: [(String, String, String, String)]
settings =
    [
        ( "--koios-url"
        , "SINGULAR_KOIOS_URL"
        , "koios-url"
        , "http://koios.example"
        )
    , ("--network-time", "SINGULAR_NETWORK_TIME", "network-time", "/times")
    , ("--network-magic", "SINGULAR_NETWORK_MAGIC", "network-magic", "42")
    , ("--blueprint", "SINGULAR_BLUEPRINT", "blueprint", "plutus.json")
    , ("--state-dir", "SINGULAR_STATE_DIR", "state-dir", "/state")
    , ("--state-token", "SINGULAR_STATE_TOKEN", "state-token", token)
    ]

flagOf :: (String, String, String, String) -> String
flagOf (f, _, _, _) = f

-- | Each command with what it needs beside the six.
commands :: [(String, [String])]
commands =
    [ ("create", ["--vault", "alice.vault"])
    ,
        ( "insert"
        ,
            [ "--key"
            , "alice"
            , "--payload"
            , "payload.json"
            , "--vault"
            , "alice.vault"
            ]
        )
    ,
        ( "update"
        ,
            [ "--key"
            , "alice"
            , "--payload"
            , "payload.json"
            , "--vault"
            , "alice.vault"
            ]
        )
    , ("terminate", ["--key", "alice", "--vault", "alice.vault"])
    , ("fold", ["--vault", "alice.vault"])
    , ("inspect", ["--key", "alice"])
    ]

-- | The six a command declares.
takenBy :: String -> [(String, String, String, String)]
takenBy name =
    [ s
    | s <- settings
    , Just leaf <-
        [lookup name [(leafName l, l) | l <- programLeaves program]]
    , flagOf s `elem` map flagName (shapeFlags (leafShape leaf))
    ]

line :: String -> [(String, String, String, String)] -> [String]
line name kept =
    name
        : concat [[f, v] | (f, _, _, v) <- kept]
            <> fromMaybe [] (lookup name commands)

meaning :: [String] -> Either CLIError String
meaning = fmap (show . fst) . parseOpenDatumInvocation []

withEnvironment
    :: [(String, String)] -> [String] -> Either CLIError String
withEnvironment environment =
    fmap (show . fst)
        . parseOpenDatumInvocationFrom (Sources environment (Right []))

withFile :: [(String, String)] -> [String] -> Either CLIError String
withFile pairs =
    fmap (show . fst)
        . parseOpenDatumInvocationFrom (Sources [] (Right pairs))

spec :: Spec
spec = describe "the settings given by the environment and a config file" $ do
    -- The command of the Demo 1 runbook: insert --key alice
    -- --payload payload.json --vault alice.vault, with the six in the file.
    it "needs only its own options once the six are in the file" $ do
        let whole = line "insert" (takenBy "insert")
        meaning whole `shouldSatisfy` isRight
        withFile
            [(k, v) | (_, _, k, v) <- takenBy "insert"]
            (line "insert" [])
            `shouldBe` meaning whole
    forM_ (map fst commands) $ \name ->
        describe ("open-datum " <> name) $ do
            let taken = takenBy name
            it "takes the settings it declares from the variables" $
                withEnvironment
                    [(variable, v) | (_, variable, _, v) <- taken]
                    (line name [])
                    `shouldBe` meaning (line name taken)
            it "takes the settings it declares from the file" $
                withFile [(k, v) | (_, _, k, v) <- taken] (line name [])
                    `shouldBe` meaning (line name taken)
            it "has a line with every setting typed that is accepted" $
                meaning (line name taken) `shouldSatisfy` isRight
            it "lists the three forms of each on its help page" $
                forM_ taken $ \(flag, variable, key, _) ->
                    helpText program [] [name]
                        `shouldSatisfy` \page ->
                            all (`isInfixOf` page) [flag, "env: " <> variable, key <> ": "]
    describe "the declaration" $ do
        let everyFlag = nub (concatMap (shapeFlags . leafShape) (programLeaves program))
        it "gives the same six settings three forms as singular" $
            sort (nub [flagName f | f <- everyFlag, isJust (flagEnvironment f)])
                `shouldBe` sort (map flagOf settings)
    describe "a missing setting" $
        it "names its flag, its variable and its key" $
            openDatumRefusalHint (MissingFlag "--koios-url")
                `shouldSatisfy` any
                    ( \l ->
                        all
                            (`isInfixOf` l)
                            ["--koios-url", "SINGULAR_KOIOS_URL", "\"koios-url\""]
                    )
    describe "a file that cannot be used" $ do
        it "is refused for a command that runs" $
            fmap
                fst
                ( parseOpenDatumInvocationFrom
                    (Sources [] (Left "the config file x.json is not JSON"))
                    ["fold"]
                )
                `shouldBe` Left (ConfigRefused "the config file x.json is not JSON")
        it "is ignored for help" $
            parseOpenDatumInvocationFrom
                (Sources [] (Left "the config file x.json is not JSON"))
                ["insert", "--help"]
                `shouldSatisfy` isRight
