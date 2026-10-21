{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.SettingsFile
Description : Write keys into the settings file the commands read
License     : Apache-2.0

The settings file ("Singular.CLI.Sources") is read by every command and
written here, so a person never edits JSON by hand. A write sets some keys,
keeps every other key with its value and its kind (text stays text, a number
stays a number), and replaces the file in one step: the new text is written
and synchronised beside the old file and renamed over it, so a failure at any
point leaves the old file or the new one and never a partial one. The new file
has the permissions of the old; a file that did not exist is readable by
everyone and writable by its owner, as the umask allows. The file is
rewritten as one indented JSON object, so its key order and spacing may
change.

@create --save-state-token@ is the first user: after a create whose outcome
is @success@ it sets the key @state-token@ to the receipt's @stateToken@
('keepStateToken'), so the commands after it name no registry on their line.
It is judged beforehand ('unwritableBecause') by the packaged command, so a
file that cannot be written is refused before a wallet is opened or the chain
is read; the write after the create still handles its own failure, because
the check can be out of date by then.
-}
module Singular.CLI.SettingsFile
    ( -- * Writing
      mergeSettings
    , saveSettings

      -- * Before a command runs
    , settingsFileRefusal

      -- * After a create
    , keepStateToken
    ) where

import Control.Exception (IOException, onException, try)
import Control.Monad (void)
import Data.Aeson (Value (..), eitherDecodeStrict)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (complement, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory
    ( Permissions (..)
    , doesDirectoryExist
    , doesPathExist
    , getPermissions
    , removeFile
    , renameFile
    )
import System.FilePath (takeDirectory, takeFileName)
import System.IO (hClose, hPutStrLn, openTempFile, stderr)
import System.Posix.Files
    ( fileMode
    , getFileStatus
    , isRegularFile
    , setFileCreationMask
    , setFileMode
    )
import System.Posix.Types (FileMode)

import Singular.CLI.Receipt
    ( OutcomeClass (Success)
    , durableWrite
    , outcomeName
    , syncDirectory
    )
import Singular.CLI.Vault (ioReason)

-- | The key the registry's name is kept under.
stateTokenKey :: Text
stateTokenKey = "state-token"

{- | The text of the settings file after these keys are set, from the text it
has now (none when it does not exist): another key keeps its value and its
kind, a key set is replaced or added. A file that is not one JSON object is
not touched, and the reason says so.
-}
mergeSettings
    :: Maybe ByteString -> [(Text, Text)] -> Either String ByteString
mergeSettings current pairs = do
    kept <- case current of
        Nothing -> Right KeyMap.empty
        Just bytes -> case eitherDecodeStrict bytes of
            Right (Object o) -> Right o
            _ -> Left "it does not hold one JSON object"
    let set = KeyMap.fromList [(Key.fromText k, String v) | (k, v) <- pairs]
    pure
        (BL.toStrict (encodePretty (Object (KeyMap.union set kept))) <> "\n")

{- | Set these keys in the file and replace it in one step. The reason it
could not, as a person says it, when it could not; the file is then as it
was.
-}
saveSettings :: FilePath -> [(Text, Text)] -> IO (Either String ())
saveSettings file pairs =
    either (Left . ioReason) id <$> try save
  where
    save :: IO (Either String ())
    save = do
        present <- doesPathExist file
        current <- if present then Just <$> BS.readFile file else pure Nothing
        case mergeSettings current pairs of
            Left why -> pure (Left why)
            Right bytes -> do
                open <-
                    if present then writable <$> getPermissions file else pure True
                if open
                    then Right <$> replace present bytes
                    else pure (Left "the file is read-only")
    replace :: Bool -> ByteString -> IO ()
    replace present bytes = do
        mode <- if present then currentMode else newMode
        let directory = takeDirectory file
        (temporary, handle) <-
            openTempFile directory ("." <> takeFileName file <> ".")
        hClose handle
        ( do
                durableWrite temporary bytes
                setFileMode temporary mode
                renameFile temporary file
                syncDirectory directory
            )
            `onException` removeQuietly temporary
    currentMode :: IO FileMode
    currentMode = (.&. 0o7777) . fileMode <$> getFileStatus file
    -- A new file is readable by everyone and writable by its owner, less the
    -- process's mask.
    newMode :: IO FileMode
    newMode = do
        mask <- setFileCreationMask 0o022
        void (setFileCreationMask mask)
        pure (0o644 .&. complement mask)
    removeQuietly path =
        void (try (removeFile path) :: IO (Either IOException ()))

{- | Why a file cannot be written, before a command that will write it runs:
nothing when it can. A file that is there must be a writable regular file in a
folder that can take the replacement; a file that is not there needs its
folder to exist and take it. This is a courtesy, not the guard: the write
itself handles its own failure.
-}
unwritableBecause :: FilePath -> IO (Maybe String)
unwritableBecause file = do
    present <- doesPathExist file
    folderThere <- doesDirectoryExist directory
    folderOpen <-
        if folderThere
            then writable <$> getPermissions directory
            else pure False
    regular <-
        if present
            then attempt False (isRegularFile <$> getFileStatus file)
            else pure True
    fileOpen <-
        if present
            then attempt False (writable <$> getPermissions file)
            else pure True
    pure (reason folderThere folderOpen regular fileOpen)
  where
    directory = takeDirectory file
    shown = if directory == "." then "the working directory" else directory
    attempt :: a -> IO a -> IO a
    attempt fallback act = either (\(_ :: IOException) -> fallback) id <$> try act
    reason folderThere folderOpen regular fileOpen
        | not folderThere = Just ("its folder " <> shown <> " does not exist")
        | not regular = Just "it is not a file"
        | not fileOpen = Just "the file is read-only"
        | not folderOpen =
            Just ("its folder " <> shown <> " cannot be written")
        | otherwise = Nothing

{- | The refusal for the switch that keeps the registry's name when the file
cannot be written: one sentence naming the switch, the file and the cause.
Nothing when no file is asked for or the file can be written.
-}
settingsFileRefusal :: Maybe FilePath -> IO (Maybe String)
settingsFileRefusal = \case
    Nothing -> pure Nothing
    Just file -> fmap (sentence file) <$> unwritableBecause file
  where
    sentence file cause =
        "--save-state-token cannot keep the registry's name in the settings file "
            <> file
            <> ": "
            <> cause

{- | Run a create and, when its receipt says @success@, keep the registry's
name in the settings file: the key @state-token@ gets the receipt's
@stateToken@. Any other outcome writes nothing. The receipt is returned as it
is, so it and the exit status are the create's whatever happens to the file;
one line on standard error says which file now holds the name or, when the
write failed after the registry exists, one sentence saying so, naming the
file and the cause and where the name still is.
-}
keepStateToken
    :: String
    -- ^ the program, which opens each line
    -> Maybe FilePath
    -- ^ the settings file, when the switch was given
    -> IO Value
    -- ^ the create
    -> IO Value
keepStateToken program target create = do
    receipt <- create
    case target of
        Just file | succeeded receipt -> keep file (textField "stateToken" receipt)
        _ -> pure ()
    pure receipt
  where
    -- A preview says `success` too, and names a registry that does not exist.
    succeeded receipt =
        textField "outcome" receipt == Just (outcomeName Success)
            && not (previewed receipt)
    previewed = \case
        Object o -> KeyMap.lookup "preview" o == Just (Bool True)
        _ -> False
    keep file = \case
        Nothing -> failed file "the receipt names no state token"
        Just token ->
            saveSettings file [(stateTokenKey, token)] >>= \case
                Right () ->
                    say
                        ( file
                            <> " now holds the state token, as the key "
                            <> T.unpack stateTokenKey
                        )
                Left cause -> failed file cause
    failed file cause =
        say
            ( "the registry was created, but its state token could not be saved in "
                <> file
                <> ": "
                <> cause
                <> ". The state token is in the receipt."
            )
    say line =
        void
            ( try (hPutStrLn stderr (program <> ": " <> line))
                :: IO (Either IOException ())
            )
    textField key = \case
        Object o | Just (String t) <- KeyMap.lookup key o -> Just t
        _ -> Nothing
