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
    , withTmpDir
    ) where

import Control.Concurrent.MVar (MVar, newMVar, putMVar, tryTakeMVar)
import Control.Exception (ErrorCall (..), bracket, bracket_, throwIO)
import Control.Monad (unless)
import System.Directory (getTemporaryDirectory)
import System.Environment (lookupEnv)
import System.IO.Temp (withTempDirectory)
import System.Posix.Env (setEnv, unsetEnv)

-- | The sole environment owner supplied to all sessions of one executable.
newtype TmpDirOwner = TmpDirOwner (MVar ())

-- | Allocate once at process composition, before starting any sessions.
newTmpDirOwner :: IO TmpDirOwner
newTmpDirOwner = TmpDirOwner <$> newMVar ()

{- | Run in an exclusively created root, restoring the exact previously set
or absent TMPDIR before removing that root. Brackets cover acquisition,
environment checks, synchronous failure and asynchronous cancellation.

Nested or overlapping use of this owner fails before reading or changing
TMPDIR. It does not wait (nested use would deadlock), and claims no isolation
from independently allocated owners or unrelated environment mutators.
-}
withTmpDir :: TmpDirOwner -> (FilePath -> IO a) -> IO a
withTmpDir (TmpDirOwner occupancy) action =
    bracket_ acquire (putMVar occupancy ()) $ do
        parent <- getTemporaryDirectory
        withTempDirectory parent "conformance-" $ \dir ->
            bracket (lookupEnv "TMPDIR") restore $ \_ -> do
                setEnv "TMPDIR" dir True
                observed <- getTemporaryDirectory
                unless (observed == dir && dir /= parent) $
                    throwIO (ErrorCall "conformance: TMPDIR isolation failed")
                action dir
  where
    acquire =
        tryTakeMVar occupancy >>= \case
            Just () -> pure ()
            Nothing ->
                throwIO
                    ( ErrorCall
                        "conformance: TMPDIR owner already active; nested or overlapping sessions are unsupported"
                    )
    restore = maybe (unsetEnv "TMPDIR") (\value -> setEnv "TMPDIR" value True)
