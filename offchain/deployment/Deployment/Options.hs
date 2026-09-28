{- |
Module      : Deployment.Options
Description : The four verbs' flags, read from the command line
License     : Apache-2.0

Flags are read by name from anywhere on the command line, in both
spellings, @--name value@ and @--name=value@ ('flagValue'); the manifest
path of @verify@ and @count@ comes from
'Singular.Registry.Deployment.deploymentPathFromArgs', which reads
@--deployment@ the same two ways. Each verb's reader refuses its missing
required flag by name before anything is loaded. The node and wallet
flags (@--node-socket@, @--network-magic@, @--wallet-skey@) are not read
here: "Singular.Registry.Node" reads them when a session opens.

Which verb runs is decided in @Main@: the first argument that is not a
flag.
-}
module Deployment.Options (
    usage,
    flagValue,
    requireEnv,
    DeployOptions (..),
    deployOptions,
    verifyManifest,
    CountOptions (..),
    countOptions,
    genesisKeyPath,
) where

import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (lookupEnv)

import Deployment.Narration (failWith)
import Singular.Registry.Deployment (deploymentPathFromArgs)

-- | The refusal for a missing or unknown verb.
usage :: String
usage =
    "usage: deployment deploy --out MANIFEST [--release TAG] \
    \[--node-socket P --network-magic N --wallet-skey F]\n\
    \       deployment verify --deployment MANIFEST \
    \[--node-socket P --network-magic N --wallet-skey F]"

-- | The value of a flag, as @--name value@ or @--name=value@.
flagValue :: String -> [String] -> Maybe String
flagValue name = go
  where
    go (a : rest)
        | a == name = case rest of
            (v : _) -> Just v
            [] -> Nothing
        | (name <> "=") `isPrefixOf` a = Just (drop (length name + 1) a)
        | otherwise = go rest
    go [] = Nothing

-- | An environment variable the command cannot run without.
requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe (failWith (name <> " is not set")) pure

-- | What @deploy@ is asked to make.
data DeployOptions = DeployOptions
    { deployOut :: FilePath
    -- ^ @--out@: where the manifest is written
    , deployRelease :: Text
    -- ^ @--release@, @unreleased@ when absent
    , deployLeanRevision :: Text
    -- ^ @--lean-revision@, @unrecorded@ when absent
    , deployProcessTime :: Integer
    -- ^ @--process-time@ in milliseconds, 120000 when absent
    , deployRetractTime :: Integer
    -- ^ @--retract-time@ in milliseconds, 30000 when absent
    }

-- | Read @deploy@'s flags, refusing a missing @--out@ or a bad window.
deployOptions :: [String] -> IO DeployOptions
deployOptions args = do
    out <- case flagValue "--out" args of
        Just p -> pure p
        Nothing -> failWith "deploy needs --out MANIFEST"
    let release = maybe "unreleased" T.pack (flagValue "--release" args)
        leanRev = maybe "unrecorded" T.pack (flagValue "--lean-revision" args)
    processTime <- case flagValue "--process-time" args of
        Nothing -> pure 120_000
        Just ms -> case reads ms of
            [(n :: Integer, "")] | n > 0 -> pure n
            _ -> failWith "--process-time needs a positive number of milliseconds"
    retractTime <- case flagValue "--retract-time" args of
        Nothing -> pure 30_000
        Just ms -> case reads ms of
            [(n :: Integer, "")] | n > 0 -> pure n
            _ -> failWith "--retract-time needs a positive number of milliseconds"
    pure (DeployOptions out release leanRev processTime retractTime)

-- | The manifest @verify@ checks.
verifyManifest :: [String] -> IO FilePath
verifyManifest args = case deploymentPathFromArgs args of
    Just p -> pure p
    Nothing -> failWith "verify needs --deployment MANIFEST"

-- | What @count@ is asked to count.
data CountOptions = CountOptions
    { countManifest :: FilePath
    , countWhat :: String
    -- ^ @--what@, checked against @state@ and @reference@ once a node answers
    , countReferenceAddress :: Maybe String
    -- ^ @--reference-address-bytes@, hex, decoded only for @reference@
    }

-- | Read @count@'s flags, refusing a missing manifest or @--what@.
countOptions :: [String] -> IO CountOptions
countOptions args = do
    path <- case deploymentPathFromArgs args of
        Just p -> pure p
        Nothing -> failWith "count needs --deployment MANIFEST"
    what <- case flagValue "--what" args of
        Just w -> pure w
        Nothing -> failWith "count needs --what state|reference"
    pure (CountOptions path what (flagValue "--reference-address-bytes" args))

-- | Where @genesis-skey@ writes the key.
genesisKeyPath :: [String] -> IO FilePath
genesisKeyPath args = case flagValue "--out" args of
    Just p -> pure p
    Nothing -> failWith "genesis-skey needs --out FILE"
