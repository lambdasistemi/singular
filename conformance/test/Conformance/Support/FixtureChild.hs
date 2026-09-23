{- | The second process used by the temporary-directory checks.

The test executable re-runs itself in this mode. It claims directories through
the same fixture boundary the suite uses, announces them, and holds them until
the parent releases it — so the two processes are inside their scoped lifetimes
at the same time, which is the only moment at which they can collide.
-}
module Conformance.Support.FixtureChild (
    childModeVariable,
    claimedFile,
    releaseFile,
    holdScopedDirectories,
    waitForFile,
) where

import Conformance.Fixture.Receipt (fixtureReceipt, withScopedReceiptDir)
import Control.Concurrent (threadDelay)
import Data.ByteString.Lazy qualified as BSL
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | Set to the rendezvous directory to run as the second process.
childModeVariable :: String
childModeVariable = "CONFORMANCE_FIXTURE_CHILD"

-- | Where the child lists the directories it is holding, one per line.
claimedFile :: FilePath -> FilePath
claimedFile rendezvous = rendezvous </> "claimed"

-- | The parent creates this to let the child go.
releaseFile :: FilePath -> FilePath
releaseFile rendezvous = rendezvous </> "release"

{- | Block until a path exists.

Polling, because the rendezvous has to work between two processes that share
nothing but a filesystem.
-}
waitForFile :: FilePath -> IO ()
waitForFile path = go (0 :: Int)
  where
    go n
        | n > 600 = error ("waited too long for " <> path)
        | otherwise = do
            there <- doesFileExist path
            if there
                then pure ()
                else threadDelay 50000 >> go (n + 1)

{- | Claim @count@ directories through the fixture boundary, each holding a
valid receipt of this process's own, and hold all of them until released.

A range rather than a single directory: a name drawn from a per-process
counter depends on how many times this process has already claimed one, and
the parent's count depends on which examples ran before it. Holding the whole
range means the parent collides wherever its own counter happens to stand.
-}
holdScopedDirectories :: Int -> FilePath -> IO ()
holdScopedDirectories count rendezvous = go count []
  where
    go 0 claimed = do
        writeFile (claimedFile rendezvous) (unlines (reverse claimed))
        waitForFile (releaseFile rendezvous)
    go n claimed = withScopedReceiptDir $ \dir -> do
        receipt <- fixtureReceipt
        BSL.writeFile (dir </> "receipt-CG02.json") receipt
        go (n - 1) (dir : claimed)
