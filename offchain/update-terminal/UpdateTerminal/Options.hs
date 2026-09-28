{-# LANGUAGE LambdaCase #-}

{- |
Module      : UpdateTerminal.Options
Description : What @update-terminal@ reads before it touches a node
License     : Apache-2.0

The command takes one optional flag and one required environment
variable:

* @--observed PATH@ — where to write the observation JSON. The first
  occurrence wins; without it nothing is written.
* @REGISTRY_BLUEPRINT@ — the archive's @onchain/plutus.json@. Every pin
  the run uses is derived from it; no naming blueprint is read.

'readStoryInputs' refuses, in this order, an unset or empty
@REGISTRY_BLUEPRINT@, a blueprint that does not parse, a blueprint
without @open.open.mint@, and one without the state or request
validator.
-}
module UpdateTerminal.Options
    ( observedPathFrom
    , StoryInputs (..)
    , readStoryInputs
    ) where

import Data.ByteString.Short qualified as SBS
import System.Environment (lookupEnv)

import Singular.Registry.Blueprint
    ( Blueprint (..)
    , Validator (..)
    , extractCompiledCode
    , loadBlueprint
    )
import UpdateTerminal.Narration (die)

-- | The path after the first @--observed@, if any.
observedPathFrom :: [String] -> Maybe FilePath
observedPathFrom = \case
    ("--observed" : p : _) -> Just p
    (_ : rest) -> observedPathFrom rest
    [] -> Nothing

-- | The compiled code and facts the story needs from the blueprint.
data StoryInputs = StoryInputs
    { inputStateBytes :: SBS.ShortByteString
    -- ^ @state.state@, unapplied
    , inputRequestBytes :: SBS.ShortByteString
    -- ^ @request.request@, unapplied
    , inputOpenParams :: Int
    {- ^ How many parameters @open.open.mint@ declares, READ from the
    blueprint entry: it is the fact that makes the open policy's
    compiled hash its policy id, so a blueprint that grew a parameter
    must change this observation rather than be contradicted by it.
    -}
    }

-- | Read @REGISTRY_BLUEPRINT@ and extract what the story needs.
readStoryInputs :: IO StoryInputs
readStoryInputs = do
    path <-
        lookupEnv "REGISTRY_BLUEPRINT" >>= \case
            Just p | not (null p) -> pure p
            _ ->
                die
                    "REGISTRY_BLUEPRINT is not set (point it at the \
                    \archive's onchain/plutus.json)"
    loaded <- loadBlueprint path
    bp <- case loaded of
        Left err -> die ("registry blueprint does not parse: " <> err)
        Right b -> pure b
    openParams <- case [v | v <- validators bp, vTitle v == "open.open.mint"] of
        (v : _) -> pure (vParameters v)
        [] -> die "open.open.mint not found in REGISTRY_BLUEPRINT"
    case ( extractCompiledCode "state.state" bp
         , extractCompiledCode "request.request" bp
         ) of
        (Just stateBytes, Just requestBytes) ->
            pure (StoryInputs stateBytes requestBytes openParams)
        _ ->
            die "state.state or request.request not found in REGISTRY_BLUEPRINT"
