{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.SettingsFileSpec
Description : The writer of the settings file the commands share
License     : Apache-2.0

A command that keeps a setting for the commands after it writes it into the
settings file they read. These cases hold what a person is promised about that
file: the keys they did not ask about keep their values and their kind, the
new text is one indented object, the old file's permissions are kept, a file
that cannot be written is left whole with nothing beside it, and the reason a
file cannot be written is said before a command that would write it begins.
-}
module Singular.CLI.SettingsFileSpec (spec) where

import Control.Exception (finally)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (complement, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Either (isLeft)
import Data.List (isInfixOf)
import System.Directory (createDirectory, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
    ( fileMode
    , getFileStatus
    , setFileCreationMask
    , setFileMode
    )
import Test.Hspec

import Singular.CLI.SettingsFile
    ( mergeSettings
    , saveSettings
    , settingsFileRefusal
    )

-- | A file holding text and a number, and a name to be replaced.
existing :: ByteString
existing =
    "{\"koios-url\": \"http://koios.example\", \"network-magic\": 42,\
    \ \"state-token\": \"stale.token\", \"trace\": null}"

keysOf :: ByteString -> IO Aeson.Object
keysOf bytes = case Aeson.eitherDecodeStrict bytes of
    Right (Object o) -> pure o
    other -> fail ("not one object: " <> show other)

-- | A directory the test may lock, and unlock again whatever happens.
locked :: FilePath -> IO a -> IO a
locked dir act = setFileMode dir 0o555 >> act `finally` setFileMode dir 0o755

spec :: Spec
spec = describe "the settings file writer" $ do
    describe "the text of the new file" $ do
        it
            "keeps every other key with its value and its kind, and sets the key"
            $ do
                new <-
                    either
                        fail
                        pure
                        (mergeSettings (Just existing) [("state-token", "p.n")])
                keys <- keysOf new
                KeyMap.toList keys
                    `shouldMatchList` [ ("koios-url", String "http://koios.example")
                                      , ("network-magic", Number 42)
                                      , ("state-token", String "p.n")
                                      , ("trace", Null)
                                      ]
        it "is one indented object ended by a line" $ do
            new <-
                either
                    fail
                    pure
                    (mergeSettings (Just existing) [("state-token", "p.n")])
            length (BC.lines new) `shouldSatisfy` (> 2)
            BC.last new `shouldBe` '\n'
        it "is made from nothing when the file does not exist" $ do
            new <-
                either fail pure (mergeSettings Nothing [("state-token", "p.n")])
            keys <- keysOf new
            KeyMap.toList keys `shouldBe` [("state-token", String "p.n")]
        it "is the same text when the same value is set again" $ do
            once <-
                either
                    fail
                    pure
                    (mergeSettings (Just existing) [("state-token", "p.n")])
            twice <-
                either fail pure (mergeSettings (Just once) [("state-token", "p.n")])
            twice `shouldBe` once
        it "sets several keys together" $ do
            new <-
                either fail pure (mergeSettings Nothing [("a", "1"), ("b", "2")])
            keys <- keysOf new
            KeyMap.toList keys
                `shouldMatchList` [("a", String "1"), ("b", String "2")]
        it "refuses a file that is not one JSON object, saying so" $
            mapM_
                ( \bytes ->
                    mergeSettings (Just bytes) [("state-token", "p.n")]
                        `shouldSatisfy` \case
                            Left why -> "JSON object" `isInfixOf` why
                            Right _ -> False
                )
                ["[1, 2, 3]", "\"text\"", "{", "", "null"]
    describe "the file" $ do
        it "keeps its permissions when it is replaced" $
            withSystemTempDirectory "settings" $ \dir -> do
                let file = dir </> "settings.json"
                BS.writeFile file existing
                setFileMode file 0o640
                saveSettings file [("state-token", "p.n")] `shouldReturn` Right ()
                (.&. 0o7777) . fileMode <$> getFileStatus file `shouldReturn` 0o640
        it
            "is made readable by all and writable by its owner, less the mask, when new"
            $ withSystemTempDirectory "settings"
            $ \dir -> do
                let file = dir </> "settings.json"
                mask <- setFileCreationMask 0o022
                _ <- setFileCreationMask mask
                saveSettings file [("state-token", "p.n")] `shouldReturn` Right ()
                (.&. 0o7777) . fileMode <$> getFileStatus file
                    `shouldReturn` (0o644 .&. complement mask)
        it "leaves nothing beside it" $
            withSystemTempDirectory "settings" $ \dir -> do
                let file = dir </> "settings.json"
                BS.writeFile file existing
                saveSettings file [("state-token", "p.n")] `shouldReturn` Right ()
                listDirectory dir `shouldReturn` ["settings.json"]
        it
            "is left whole, with nothing beside it, when its folder cannot be written"
            $ withSystemTempDirectory "settings"
            $ \dir -> do
                let home = dir </> "home"
                    file = home </> "settings.json"
                createDirectory home
                BS.writeFile file existing
                result <- locked home (saveSettings file [("state-token", "p.n")])
                result `shouldSatisfy` \case
                    Left why -> "permission denied" `isInfixOf` why
                    Right _ -> False
                BS.readFile file `shouldReturn` existing
                listDirectory home `shouldReturn` ["settings.json"]
        it "is left whole when it is read-only, and the reason says so" $
            withSystemTempDirectory "settings" $ \dir -> do
                let file = dir </> "settings.json"
                BS.writeFile file existing
                setFileMode file 0o444
                result <- saveSettings file [("state-token", "p.n")]
                result `shouldSatisfy` \case
                    Left why -> "read-only" `isInfixOf` why
                    Right _ -> False
                BS.readFile file `shouldReturn` existing
        it "is left whole when it is not one JSON object" $
            withSystemTempDirectory "settings" $ \dir -> do
                let file = dir </> "settings.json"
                BS.writeFile file "[1, 2, 3]"
                saveSettings file [("state-token", "p.n")]
                    >>= (`shouldSatisfy` isLeft)
                BS.readFile file `shouldReturn` "[1, 2, 3]"
                listDirectory dir `shouldReturn` ["settings.json"]
    describe
        "the reason a file cannot be written, before a command that would write it"
        $ do
            let refusedWith result needle =
                    result `shouldSatisfy` \case
                        Just why -> needle `isInfixOf` why
                        Nothing -> False
            it "is none when no file is asked for" $
                settingsFileRefusal Nothing `shouldReturn` Nothing
            it
                "is none for a file that can be written, and for a missing one in a writable folder"
                $ withSystemTempDirectory "settings"
                $ \dir -> do
                    let file = dir </> "settings.json"
                    settingsFileRefusal (Just file) `shouldReturn` Nothing
                    BS.writeFile file existing
                    settingsFileRefusal (Just file) `shouldReturn` Nothing
            it "names the switch, the file and the cause for a read-only file" $
                withSystemTempDirectory "settings" $ \dir -> do
                    let file = dir </> "settings.json"
                    BS.writeFile file existing
                    setFileMode file 0o444
                    refusal <- settingsFileRefusal (Just file)
                    refusal `refusedWith` "--save-state-token"
                    refusal `refusedWith` file
                    refusal `refusedWith` "read-only"
            it
                "says the folder cannot be written for a missing file in a locked folder"
                $ withSystemTempDirectory "settings"
                $ \dir -> do
                    let file = dir </> "settings.json"
                    refusal <- locked dir (settingsFileRefusal (Just file))
                    refusal `refusedWith` file
                    refusal `refusedWith` "cannot be written"
            it
                "says the folder cannot take the replacement for a file in a locked folder"
                $ withSystemTempDirectory "settings"
                $ \dir -> do
                    let home = dir </> "home"
                        file = home </> "settings.json"
                    createDirectory home
                    BS.writeFile file existing
                    refusal <- locked home (settingsFileRefusal (Just file))
                    refusal `refusedWith` "cannot be written"
            it
                "says the folder does not exist for a file in a folder that is not there"
                $ withSystemTempDirectory "settings"
                $ \dir -> do
                    refusal <-
                        settingsFileRefusal (Just (dir </> "nowhere" </> "settings.json"))
                    refusal `refusedWith` "does not exist"
            it "says it is not a file for a directory in its place" $
                withSystemTempDirectory "settings" $ \dir -> do
                    let file = dir </> "settings.json"
                    createDirectory file
                    refusal <- settingsFileRefusal (Just file)
                    refusal `refusedWith` "not a file"
