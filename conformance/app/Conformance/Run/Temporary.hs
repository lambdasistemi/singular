{-# LANGUAGE LambdaCase #-}

{- | Explicit ownership of the devnet's process-wide TMPDIR requirement.

The pinned node helper reads TMPDIR and deletes its cardano-e2e child; it
has no explicit-root API. Allocate one owner at executable startup and pass
it to every session. Other code must not mutate TMPDIR concurrently, and
callbacks must join their workers before leaving this lifetime.
-}
module Conformance.Run.Temporary
    ( TmpDirOwner
    , newTmpDirOwner
    , TmpDirCleanupFailure (..)
    , withTmpDir
    ) where

import Control.Concurrent.MVar (MVar, newMVar, putMVar, tryTakeMVar)
import Control.Exception
    ( ErrorCall (..)
    , Exception (..)
    , SomeException
    , bracket
    , bracket_
    , mask
    , throwIO
    , try
    )
import Control.Monad (unless)
import System.Directory (getTemporaryDirectory, removePathForcibly)
import System.Environment (lookupEnv)
import System.IO.Temp (createTempDirectory)
import System.Posix.Env (setEnv, unsetEnv)

-- | The sole environment owner supplied to all sessions of one executable.
newtype TmpDirOwner = TmpDirOwner (MVar ())

-- | Allocate once at process composition, before starting any sessions.
newTmpDirOwner :: IO TmpDirOwner
newTmpDirOwner = TmpDirOwner <$> newMVar ()

-- | Failed deletion retains its path and both failures when the action also failed.
data TmpDirCleanupFailure = TmpDirCleanupFailure
    { tmpDirRoot :: FilePath
    -- ^ The root whose removal failed, available for diagnosis or recovery.
    , tmpDirActionFailure :: Maybe SomeException
    -- ^ The original action (or environment restoration) exception, if any.
    , tmpDirCleanupException :: SomeException
    -- ^ The exception raised by the cleanup attempt.
    }
    deriving stock (Show)

instance Exception TmpDirCleanupFailure where
    displayException failure =
        "conformance: TMPDIR cleanup failed for "
            <> show (tmpDirRoot failure)
            <> ": "
            <> displayException (tmpDirCleanupException failure)
            <> maybe
                ""
                (\cause -> "; action also failed: " <> displayException cause)
                (tmpDirActionFailure failure)

{- | Run in an exclusively created root, restoring the exact previously set
or absent TMPDIR before attempting to remove that root. Acquisition and
cleanup are masked; the callback is cancellable. Failed deletion throws
'TmpDirCleanupFailure', retaining the action's exception when both fail.

Nested or overlapping use of this owner fails before reading or changing
TMPDIR. It does not wait (nested use would deadlock), and claims no isolation
from independently allocated owners or unrelated environment mutators.
-}
withTmpDir :: TmpDirOwner -> (FilePath -> IO a) -> IO a
withTmpDir (TmpDirOwner occupancy) action =
    bracket_ acquire (putMVar occupancy ()) $ do
        parent <- getTemporaryDirectory
        mask $ \restoreAction -> do
            dir <- createTempDirectory parent "conformance-"
            result <- try @SomeException $
                restoreAction $
                    bracket (lookupEnv "TMPDIR") restoreEnvironment $ \_ -> do
                        setEnv "TMPDIR" dir True
                        observed <- getTemporaryDirectory
                        unless (observed == dir && dir /= parent) $
                            throwIO (ErrorCall "conformance: TMPDIR isolation failed")
                        action dir
            cleanup <- try @SomeException (removePathForcibly dir)
            case cleanup of
                Right () -> either throwIO pure result
                Left err ->
                    throwIO
                        (TmpDirCleanupFailure dir (either Just (const Nothing) result) err)
  where
    acquire =
        tryTakeMVar occupancy >>= \case
            Just () -> pure ()
            Nothing ->
                throwIO
                    ( ErrorCall
                        "conformance: TMPDIR owner already active; nested or overlapping sessions are unsupported"
                    )
    restoreEnvironment = maybe (unsetEnv "TMPDIR") (\value -> setEnv "TMPDIR" value True)
