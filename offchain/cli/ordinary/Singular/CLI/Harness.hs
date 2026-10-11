{- |
Module      : Singular.CLI.Harness
Description : Build-selected recovery control boundary
License     : Apache-2.0

The manual test-harness Cabal flag selects exactly one implementation.
Ordinary releases prepare and submit normally and never read test inputs.
A test controller owns each release marker and the process it holds: it
must release or kill that process and join it before removing its scratch.
The command itself starts no worker and its waits remain interruptible.
-}
module Singular.CLI.Harness
    ( harnessHoldAt
    , harnessSubmission
    , holdBeforeLock
    , holdAfterSubmit
    , holdBeforeCommit
    , holdBeforeObserved
    ) where

import Control.Exception (SomeException)
import Data.Text (Text)

-- | Compatibility export; ordinary builds contain no hold implementation.
harnessHoldAt :: String -> Maybe Text -> IO ()
harnessHoldAt _ _ = pure ()

-- | Prepare and submit on the calling thread, without fault injection.
harnessSubmission
    :: Text
    -> IO b
    -> (b -> IO (Either SomeException a))
    -> IO (Either SomeException a)
harnessSubmission _ prepare send = prepare >>= send

-- | No pre-lock test pause is compiled into ordinary commands.
holdBeforeLock :: IO ()
holdBeforeLock = pure ()

-- | No post-submission test pause is compiled into ordinary commands.
holdAfterSubmit :: Text -> IO ()
holdAfterSubmit _ = pure ()

-- | No pre-replay test pause is compiled into ordinary folds.
holdBeforeCommit :: IO ()
holdBeforeCommit = pure ()

-- | No pre-observation test pause is compiled into ordinary folds.
holdBeforeObserved :: IO ()
holdBeforeObserved = pure ()
