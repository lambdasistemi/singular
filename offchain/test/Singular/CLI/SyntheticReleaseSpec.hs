{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.SyntheticReleaseSpec
Description : Loader for synthetic blueprint fixtures in the shared pin tests

These titles and scripts are synthetic test data. They establish no identity
of a published contract and read no release manifest or pin.
-}
module Singular.CLI.SyntheticReleaseSpec (loadReleaseCodes) where

import Data.ByteString.Short qualified as SBS
import Data.Text qualified as T
import Singular.Registry.Application
    ( Application (..)
    , ApplicationPin (..)
    )
import Singular.Registry.Blueprint
    ( NamingCodes (..)
    , extractCompiledCode
    , loadBlueprint
    )
import Singular.Registry.StateToken (Release (..))

loadReleaseCodes
    :: Application -> FilePath -> IO (Either String Release)
loadReleaseCodes app path = do
    loaded <- loadBlueprint path
    pure $ do
        bp <-
            either (Left . ("the blueprint does not parse: " <>)) Right loaded
        let code name =
                maybe
                    (Left ("the blueprint carries no " <> name))
                    Right
                    (extractCompiledCode (T.pack name) bp)
        state <- code "state.state"
        request <- code "request.request"
        -- The application code the pin names, or none when the pin is a hash
        -- or read from state (slice 2: its script bytes do not exist there).
        application <- case appPin app of
            PinByHash _ -> pure SBS.empty
            PinFromState -> pure SBS.empty
            PinByScript title -> code (T.unpack title)
            PinAsCompiled title -> code (T.unpack title)
        witness <- code "witness.witness"
        pure
            ( Release
                state
                request
                NamingCodes{ncApplication = application, ncWitness = witness}
            )
