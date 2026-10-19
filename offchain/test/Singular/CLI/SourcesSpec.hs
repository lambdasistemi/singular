{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.SourcesSpec
Description : The settings a command line may leave to the environment and a file
License     : Apache-2.0

The six standing settings (the chain, the compiled contracts and the registry)
have three forms: a flag, a variable and a key of one JSON file. These cases
hold what a person is told: a setting left out of the command line is the
same setting given by its variable or by its key, the flag wins over the
variable and the variable over the file, a command takes only the settings it
declares, a file that says something it should not is refused in a sentence,
and a missing setting names all three of its forms.
-}
module Singular.CLI.SourcesSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Char (toUpper)
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf, nub, sort)
import Data.Maybe (isJust)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Singular.CLI.Command
    ( CLIError (..)
    , parseInvocation
    , parseInvocationFrom
    , refusalHint
    , singularVersion
    )
import Singular.CLI.Help (singularProgram)
import Singular.CLI.Options
    ( Flag (..)
    , Leaf (..)
    , Program
    , Raw (..)
    , leafShape
    , programLeaves
    , shapeFlags
    , shortenedExample
    )
import Singular.CLI.Sources
    ( Sources (..)
    , configFromValue
    , configPath
    , loadSourcesAt
    )

program :: Program
program = singularProgram singularVersion

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

-- | A fold with the named settings on its command line and a vault.
foldWith :: [(String, String, String, String)] -> [String]
foldWith kept =
    ["registry", "fold"]
        <> concat [[f, v] | (f, _, _, v) <- kept]
        <> ["--vault", "alice.vault"]

meaning :: [String] -> Either CLIError String
meaning = fmap (show . fst) . parseInvocation []

withEnvironment
    :: [(String, String)] -> [String] -> Either CLIError String
withEnvironment environment =
    fmap (show . fst)
        . parseInvocationFrom (Sources environment (Right []))

withFile :: [(String, String)] -> [String] -> Either CLIError String
withFile pairs =
    fmap (show . fst) . parseInvocationFrom (Sources [] (Right pairs))

spec :: Spec
spec = describe "the settings given by the environment and a config file" $ do
    it "has a command line with all six that is accepted" $
        meaning (foldWith settings) `shouldSatisfy` isRight
    describe "each of the six" $
        forM_ settings $ \setting@(flag, variable, key, value) -> do
            let others = filter ((/= flag) . flagOf) settings
            it (flag <> " left out is read from " <> variable) $
                withEnvironment [(variable, value)] (foldWith others)
                    `shouldBe` meaning (foldWith settings)
            it (flag <> " left out is read from the key " <> key) $
                withFile [(key, value)] (foldWith others)
                    `shouldBe` meaning (foldWith settings)
            it (flag <> " names itself, its variable and its key when missing") $
                refusalHint (MissingFlag (flagOf setting))
                    `shouldSatisfy` \ls ->
                        any
                            ( \l ->
                                all
                                    (`isInfixOf` l)
                                    [flag, variable, "\"" <> key <> "\""]
                            )
                            ls
    describe "precedence" $ do
        let at url =
                [ if f == "--koios-url" then (f, v, k, url) else s
                | s@(f, v, k, _) <- settings
                ]
            without = filter ((/= "--koios-url") . flagOf) settings
            environment = [("SINGULAR_KOIOS_URL", "http://env.example")]
            file = [("koios-url", "http://file.example")]
        it "gives the flag over the variable and the file" $
            fmap
                (show . fst)
                ( parseInvocationFrom
                    (Sources environment (Right file))
                    (foldWith (at "http://flag.example"))
                )
                `shouldBe` meaning (foldWith (at "http://flag.example"))
        it "gives the variable over the file" $
            fmap
                (show . fst)
                ( parseInvocationFrom
                    (Sources environment (Right file))
                    (foldWith without)
                )
                `shouldBe` meaning (foldWith (at "http://env.example"))
        it "gives the file when the line and the environment leave it out" $
            withFile file (foldWith without)
                `shouldBe` meaning (foldWith (at "http://file.example"))
    describe "only the settings a command takes" $ do
        it "gives wallet create no Koios address" $
            withEnvironment
                [("SINGULAR_KOIOS_URL", "http://koios.example")]
                ["wallet", "create", "--vault", "new.vault", "--network-magic", "1"]
                `shouldBe` meaning
                    ["wallet", "create", "--vault", "new.vault", "--network-magic", "1"]
        it "gives describe no state directory to refuse" $ do
            let line =
                    ["registry", "describe"]
                        <> concat
                            [ [f, v]
                            | (f, _, _, v) <- settings
                            , f /= "--state-dir"
                            ]
            withEnvironment [("SINGULAR_STATE_DIR", "/state")] line
                `shouldBe` meaning line
    describe "an empty setting" $ do
        let without = filter ((/= "--koios-url") . flagOf) settings
        it "is not a setting in the environment" $
            withEnvironment [("SINGULAR_KOIOS_URL", "")] (foldWith without)
                `shouldBe` meaning (foldWith without)
        it "is not a setting in the file" $
            withFile [("koios-url", "")] (foldWith without)
                `shouldBe` meaning (foldWith without)
    describe "a file that cannot be used" $ do
        it "is refused for a command that runs, before any missing flag" $
            fmap
                fst
                ( parseInvocationFrom
                    (Sources [] (Left "the config file x.json does not exist"))
                    ["registry", "fold"]
                )
                `shouldBe` Left (ConfigRefused "the config file x.json does not exist")
        it "is ignored for a request for help" $
            parseInvocationFrom
                (Sources [] (Left "the config file x.json does not exist"))
                ["registry", "fold", "--help"]
                `shouldSatisfy` isRight
    describe "the keys of a file" $ do
        let read' = configFromValue program "demo.json"
        it "are the six settings, numbers allowed" $
            read'
                ( object
                    [ "koios-url" .= String "http://koios.example"
                    , "network-magic" .= Number 42
                    ]
                )
                `shouldSatisfy` \case
                    Right pairs ->
                        sort pairs
                            == [ ("koios-url", "http://koios.example")
                               , ("network-magic", "42")
                               ]
                    Left _ -> False
        it "may be null, which is no setting" $
            read' (object ["koios-url" .= Null])
                `shouldBe` Right [("koios-url", "")]
        it "name the nearest setting for a misspelling" $
            read' (object ["koios_url" .= String "x"])
                `shouldSatisfy` mentions ["demo.json", "did you mean \"koios-url\""]
        it "refuse a passphrase in words about passphrases" $
            read' (object ["passphrase" .= String "x"])
                `shouldSatisfy` mentions ["passphrase is never read from a file"]
        it "refuse a setting that is typed on the command line" $
            forM_ ["vault", "passphrase-fd", "wallet-skey", "preview", "config"] $ \name ->
                read' (object [Key.fromString name .= String "x"])
                    `shouldSatisfy` mentions ["cannot come from a file", name]
        it "refuse a value that is not text or a number" $ do
            read' (object ["koios-url" .= Bool True]) `shouldSatisfy` isLeft
            read' (object ["koios-url" .= Array mempty]) `shouldSatisfy` isLeft
        it "refuse a file that is not one object" $
            read' (Array mempty) `shouldSatisfy` isLeft
    describe "the file a command names" $ do
        it "is the flag, then the variable" $ do
            configPath
                [("SINGULAR_CONFIG", "env.json")]
                (Raw [] [("--config", Just "flag.json")])
                `shouldBe` Just "flag.json"
            configPath [("SINGULAR_CONFIG", "env.json")] (Raw [] [])
                `shouldBe` Just "env.json"
            configPath [("SINGULAR_CONFIG", "")] (Raw [] []) `shouldBe` Nothing
        it "is read, or refused in a sentence when it is not there" $
            withSystemTempDirectory "sources" $ \dir -> do
                writeFile
                    (dir </> "demo.json")
                    "{\"koios-url\": \"http://koios.example\"}"
                writeFile (dir </> "broken.json") "not json"
                found <-
                    loadSourcesAt
                        (dir </> "none.json")
                        program
                        []
                        (Raw [] [("--config", Just (dir </> "demo.json"))])
                sourceConfig found
                    `shouldBe` Right [("koios-url", "http://koios.example")]
                missing <-
                    loadSourcesAt
                        (dir </> "none.json")
                        program
                        []
                        (Raw [] [("--config", Just (dir </> "absent.json"))])
                sourceConfig missing
                    `shouldSatisfy` mentionsLeft ["absent.json", "does not exist"]
                broken <-
                    loadSourcesAt
                        (dir </> "none.json")
                        program
                        []
                        (Raw [] [("--config", Just (dir </> "broken.json"))])
                sourceConfig broken
                    `shouldSatisfy` mentionsLeft ["broken.json", "is not JSON"]
        it "is the default file when it is there and none is named" $
            withSystemTempDirectory "sources" $ \dir -> do
                writeFile (dir </> "default.json") "{\"blueprint\": \"plutus.json\"}"
                present <-
                    loadSourcesAt (dir </> "default.json") program [] (Raw [] [])
                sourceConfig present `shouldBe` Right [("blueprint", "plutus.json")]
                absent <- loadSourcesAt (dir </> "absent.json") program [] (Raw [] [])
                sourceConfig absent `shouldBe` Right []
    describe "the declaration" $ do
        let everyFlag = nub (concatMap (shapeFlags . leafShape) (programLeaves program))
            standing = [f | f <- everyFlag, isJust (flagEnvironment f)]
        it
            "gives exactly the six settings three forms"
            $ sort (nub (map flagName standing))
                `shouldBe` sort (map flagOf settings)
        it "names each variable and key after its flag" $
            forM_ standing $ \f -> do
                let name = drop 2 (flagName f)
                flagEnvironment f
                    `shouldBe` Just
                        ("SINGULAR_" <> map (\c -> if c == '-' then '_' else toUpper c) name)
                flagConfig f `shouldBe` Just name
        it "gives no passphrase an environment variable or a key" $
            [ flagName f
            | f <- everyFlag
            , "pass" `isInfixOf` flagName f
            , isJust (flagEnvironment f) || isJust (flagConfig f)
            ]
                `shouldBe` []
    describe "an example in the help that leaves its settings to the file" $
        forM_ (programLeaves program) $ \leaf ->
            forM_ (shortened leaf) $ \(full, short) ->
                it (leafName leaf <> " means the example with every setting typed") $ do
                    let pairs =
                            [ (key, placeholder value)
                            | (flag, _, key, _) <- settings
                            , (name, value) <- adjacent full
                            , name == flag
                            ]
                    meaning (placeholders full)
                        `shouldBe` withFile pairs (placeholders short)
  where
    mentions needles = \case
        Left why -> all (`isInfixOf` why) needles
        Right _ -> False
    mentionsLeft = mentions
    standingFlags leaf =
        [ f
        | f <- nub (shapeFlags (leafShape leaf))
        , isJust (flagEnvironment f)
        ]
    shortened leaf =
        [ (words' full, words' short)
        | not (null (leafExamples leaf))
        , Just shortLines <-
            [shortenedExample (standingFlags leaf) (leafExamples leaf)]
        , let full = leafExamples leaf
              short = shortLines
        ]
    -- The command line an example is: its words after the program's name.
    words' ls = drop 1 (filter (/= "\\") (words (unwords ls)))
    adjacent ws = zip ws (drop 1 ws)
    placeholders = map placeholder
    placeholder w = if w == "<policy>.<name>" then token else w
