{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.Config
Description : Resolve the E2E blueprint before reporting any examples
License     : Apache-2.0

The suite shares one parsed blueprint. Missing configuration, unreadable
files and missing compiled validators are startup failures.
-}
module Singular.Registry.E2E.Config (resolveBlueprint) where

import Control.Exception (IOException, try)
import Control.Monad (forM_, unless)
import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import System.Environment (lookupEnv)
import System.Exit (die)

import Singular.Registry.Blueprint (Blueprint, extractCompiledCode, loadBlueprint)

-- | Require all scripts used by the suite before Hspec can run an example.
resolveBlueprint :: IO Blueprint
resolveBlueprint = do
    configured <- lookupEnv "REGISTRY_BLUEPRINT"
    path <- case configured of
        Just value | not (null value) -> pure value
        _ -> die "REGISTRY_BLUEPRINT is not set or is empty"
    loaded <- try (loadBlueprint path) :: IO (Either IOException (Either String Blueprint))
    blueprint <- case loaded of
        Left err -> die $ "REGISTRY_BLUEPRINT cannot read " <> path <> ": " <> show err
        Right (Left err) -> die $ "REGISTRY_BLUEPRINT invalid blueprint at " <> path <> ": " <> err
        Right (Right value) -> pure value
    forM_ ["state.state", "request.request", "open.open", "witness.witness"] $ \validator ->
        unless (maybe False (not . SBS.null) (extractCompiledCode validator blueprint)) $
            die $
                "REGISTRY_BLUEPRINT missing compiled validator " <> T.unpack validator <> " at " <> path
    pure blueprint
