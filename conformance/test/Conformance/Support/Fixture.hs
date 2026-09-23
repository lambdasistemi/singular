{- | How an example owns the temporary directory it works in.

Appendix material: evidence about our own harness, not about the registry.
It is here because an example that shares a directory with a concurrent run
is an example whose result was decided by something other than the registry.
-}
module Conformance.Support.Fixture (spec) where

import Conformance.Fixture.Receipt (
    loadOne,
    withScopedReceiptDir,
 )
import Conformance.Support.FixtureChild (
    childModeVariable,
    claimedFile,
    releaseFile,
    waitForFile,
 )
import Control.Exception (ErrorCall (..), throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (
    CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    waitForProcess,
 )
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

{- | How many directories the second process holds.

Above the number of times any one example run claims one, so wherever the
parent's own counter stands it falls inside the range the child is holding.
-}
heldByTheOtherProcess :: Int
heldByTheOtherProcess = 256

spec :: Spec
spec = describe "How an example owns its temporary files" $ do
    it "does not share its directory with a second process running the same example" $
        withSystemTempDirectory "conformance-fixture-rendezvous" $ \rendezvous -> do
            self <- getExecutablePath
            environment <- getEnvironment
            (_, _, _, child) <-
                createProcess
                    (proc self [])
                        { env = Just ((childModeVariable, rendezvous) : environment)
                        , std_out = NoStream
                        , std_err = NoStream
                        }
            -- The child is now inside its scoped lifetimes and stays there:
            -- whatever happens next happens while it holds those directories.
            waitForFile (claimedFile rendezvous)
            held <- lines <$> readFile (claimedFile rendezvous)

            result <- loadOne
            survived <- mapM (\dir -> doesFileExist (dir </> "receipt-CG02.json")) held

            writeFile (releaseFile rendezvous) ""
            exit <- waitForProcess child

            length held `shouldBe` heldByTheOtherProcess
            -- Its own receipt and only its own: a directory another process is
            -- holding is not this example's to read from.
            result `shouldBe` Right 1
            -- Nor to delete.
            survived `shouldBe` map (const True) held
            -- Last, because a child that cannot release the directories it is
            -- holding is a consequence of the two assertions above, not the
            -- finding itself.
            exit `shouldBe` ExitSuccess

    it "removes its directory when the work inside it throws" $ do
        -- An IORef created inside this example is ordinary local state; it
        -- carries the path out so the directory can be looked for once the
        -- exception has propagated.
        seen <- newIORef ""
        outcome <-
            try . withScopedReceiptDir $ \dir -> do
                writeIORef seen dir
                throwIO (ErrorCall "the work inside the directory failed")
        case outcome :: Either ErrorCall () of
            Right () -> error "the action was expected to throw"
            Left _ -> pure ()
        dir <- readIORef seen
        doesDirectoryExist dir `shouldReturn` False

    it "gives two examples different directories" $ do
        first <- withScopedReceiptDir pure
        second <- withScopedReceiptDir pure
        (first == second) `shouldBe` False
