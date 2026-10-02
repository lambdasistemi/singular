{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.PhaseLogFixture
Description : Reading the phase log in the rows that hold a path to it
License     : Apache-2.0

The rows of #363 that run a real constructor (a node adapter, an indexer
view, a confirmation wait) cannot be handed a log; the constructor reads
@SINGULAR_LOG@ as a command does. 'withLogEnv' sets it for one action
and restores it, and the helpers read what the action appended.
-}
module Singular.PhaseLogFixture
    ( withLogEnv
    , withLogFile
    , logObjects
    , phaseLines
    , queryNames
    , textField
    , numberField
    ) where

import Control.Exception (bracket_)
import Control.Monad (join)
import Data.Aeson ((.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | Run with @SINGULAR_LOG@ set to a path or unset, restoring it after.
withLogEnv :: Maybe FilePath -> IO a -> IO a
withLogEnv new act = do
    old <- lookupEnv "SINGULAR_LOG"
    let put = maybe (unsetEnv "SINGULAR_LOG") (setEnv "SINGULAR_LOG")
    bracket_ (put new) (put old) act

-- | Run an action with a fresh log file named by the environment.
withLogFile :: (FilePath -> IO a) -> IO a
withLogFile k = withSystemTempDirectory "phase-log" $ \dir -> do
    let path = dir </> "phase.log"
    withLogEnv (Just path) (k path)

-- | Every line of the log, each a JSON object; none when no file exists.
logObjects :: FilePath -> IO [Aeson.Object]
logObjects path = do
    there <- doesFileExist path
    if not there
        then pure []
        else do
            raw <- BS.readFile path
            either fail pure $ traverse Aeson.eitherDecodeStrict' (BC.lines raw)

textField :: Aeson.Key -> Aeson.Object -> Maybe Text
textField k o = join (Aeson.parseMaybe (.:? k) o)

numberField :: Aeson.Key -> Aeson.Object -> Maybe Integer
numberField k o = join (Aeson.parseMaybe (.:? k) o)

-- | The lines of one phase.
phaseLines :: Text -> [Aeson.Object] -> [Aeson.Object]
phaseLines p = filter ((== Just p) . textField "phase")

-- | The query each @query@ line names.
queryNames :: [Aeson.Object] -> [Text]
queryNames = mapMaybe (textField "query") . phaseLines "query"
