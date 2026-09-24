{- |
Module      : Conformance.Run.Manifest
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Manifest (ValidatorPin (..), ScriptManifest (..), readScriptManifest, manifestPath, pinsUnder) where


import Data.Aeson (
    FromJSON (..),
    eitherDecode,
    withObject,
    (.:),
    (.:?),
 )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (readProcess)

import Conformance.Mirror (failWith)

-- ---------------------------------------------------------
-- The published script manifest (onchain/script-identity.json)
-- ---------------------------------------------------------

data ValidatorPin = ValidatorPin
    { vpTitle :: T.Text
    , vpHash :: T.Text
    , vpParams :: Maybe Int
    }

instance FromJSON ValidatorPin where
    parseJSON = withObject "ValidatorPin" $ \o ->
        ValidatorPin
            <$> o .: "title"
            <*> o .: "hash"
            <*> o .:? "parameters"


newtype ScriptManifest = ScriptManifest {smValidators :: [ValidatorPin]}

instance FromJSON ScriptManifest where
    parseJSON = withObject "ScriptManifest" $ \o ->
        ScriptManifest <$> o .: "validators"


{- | The manifest is a tracked file of the pinned onchain tree; the
run reads it, never edits it. @REGISTRY_SCRIPT_IDENTITY@ overrides the
path (the li-refusals convention); the default resolves against the
repository root, wherever the run is invoked from.
-}
readScriptManifest :: IO ScriptManifest
readScriptManifest = do
    path <- manifestPath
    bytes <- BS.readFile path
    case eitherDecode (BSL.fromStrict bytes) of
        Right m -> pure m
        Left err ->
            failWith
                ("the script manifest at " <> path <> " does not parse: " <> err)


manifestPath :: IO FilePath
manifestPath = do
    override <- lookupEnv "REGISTRY_SCRIPT_IDENTITY"
    case override of
        Just p -> pure p
        Nothing -> do
            root <- readProcess "git" ["rev-parse", "--show-toplevel"] ""
            pure (filter (/= '\n') root </> "onchain" </> "script-identity.json")


pinsUnder :: T.Text -> ScriptManifest -> [(T.Text, Maybe Int)]
pinsUnder prefix m =
    [ (vpHash v, vpParams v)
    | v <- smValidators m
    , prefix `T.isPrefixOf` vpTitle v
    ]
