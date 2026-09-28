{- |
Module      : Journey.Options
Description : What the journey reads from its environment
License     : Apache-2.0

The journey takes no command-line arguments. It reads:

* @REGISTRY_BLUEPRINT@ — required, the compiled registry blueprint whose
  state, request and staking validators the run executes;
* @REGISTRY_SCRIPT_IDENTITY@ — optional, the pinned-identity manifest,
  @../onchain/script-identity.json@ by default (relative to @offchain/@,
  where the flake app and the CI job run it).
-}
module Journey.Options
    ( requireEnv
    , defaultIdentityPath
    , identityPathFromEnv
    ) where

import System.Environment (lookupEnv)

import Journey.Narration (failWith)

-- | An environment variable the journey cannot run without.
requireEnv :: String -> IO String
requireEnv name =
    lookupEnv name
        >>= maybe
            (failWith ("missing environment variable " <> name))
            pure

{- | Default location of the pinned-identity manifest, relative
to @offchain/@ (where the flake app and the CI job run it).
-}
defaultIdentityPath :: FilePath
defaultIdentityPath = "../onchain/script-identity.json"

identityPathFromEnv :: IO FilePath
identityPathFromEnv =
    lookupEnv "REGISTRY_SCRIPT_IDENTITY"
        >>= maybe (pure defaultIdentityPath) pure
