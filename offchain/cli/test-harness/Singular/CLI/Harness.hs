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

import Control.Concurrent (threadDelay)
import Control.Exception (ErrorCall (..), SomeException, toException)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)

-- | Pause before locking so the controller can run the competing create.
holdBeforeLock :: IO ()
holdBeforeLock = do
    target <- lookupEnv "SINGULAR_HARNESS_HOLD_BEFORE_LOCK"
    maybe (pure ()) waitAt target

-- | Pause at an explicitly selected test boundary until its owner releases it.
harnessHoldAt :: String -> Maybe Text -> IO ()
harnessHoldAt var step = do
    path <- lookupEnv var
    wanted <- lookupEnv "SINGULAR_HARNESS_HOLD_STEP"
    let here = maybe True (\s -> fmap T.pack wanted == Just s) step
    case path of
        Just p | here -> waitAt p
        _ -> pure ()

-- | Preserve the recovery control's send, answer and journal ordering.
harnessSubmission
    :: Text
    -> IO b
    -> (b -> IO (Either SomeException a))
    -> IO (Either SomeException a)
harnessSubmission step prepare send = do
    dropSend <- harnessDrops "SINGULAR_HARNESS_DROP_SEND" step
    prepared <- prepare
    sentAnswer <-
        if dropSend
            then pure (Left (toException (ErrorCall "the send was not made")))
            else send prepared
    harnessHoldAt "SINGULAR_HARNESS_HOLD_AFTER_SEND" (Just step)
    dropAnswer <- harnessDrops "SINGULAR_HARNESS_DROP_ANSWER" step
    pure $
        if dropAnswer
            then Left (toException (ErrorCall "the node's answer was lost"))
            else sentAnswer

-- | Pause after the node's answer has been journalled.
holdAfterSubmit :: Text -> IO ()
holdAfterSubmit step = harnessHoldAt "SINGULAR_HARNESS_HOLD_AFTER_SUBMIT" (Just step)

-- | Pause a confirmed fold before its independent public replay.
holdBeforeCommit :: IO ()
holdBeforeCommit = harnessHoldAt "SINGULAR_HARNESS_HOLD_BEFORE_COMMIT" Nothing

-- | Pause after public readback, before recording the observation.
holdBeforeObserved :: IO ()
holdBeforeObserved = harnessHoldAt "SINGULAR_HARNESS_HOLD_BEFORE_OBSERVED" Nothing

harnessDrops :: String -> Text -> IO Bool
harnessDrops var step = (== Just (T.unpack step)) <$> lookupEnv var

waitAt :: FilePath -> IO ()
waitAt path = do
    writeFile (path <> ".waiting") ""
    let waitFor = do
            there <- doesFileExist path
            if there then pure () else threadDelay 100_000 >> waitFor
    waitFor
