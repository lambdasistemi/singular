{- | Appendix controls for the actual conformance temporary-root lifetime.
These are harness checks, not registry or ledger evidence.
-}
module Conformance.Support.Temporary (spec) where

import Conformance.Run.Environment (bracketTmpDir)
import Control.Exception (ErrorCall (..), bracket, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , getTemporaryDirectory
    )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

spec :: Spec
spec =
    describe "A conformance session owns its temporary root" $
        mapM_ environmentCases [False, True]
  where
    environmentCases originallySet =
        describe
            ( if originallySet
                then "TMPDIR originally set"
                else "TMPDIR originally absent"
            ) $ do
            it "restores the environment and cleans only its own files on success" $
                withEnvironment originallySet $ \original other -> do
                    dir <- bracketTmpDir $ do
                        root <- getTemporaryDirectory
                        lookupEnv "TMPDIR" `shouldReturn` Just root
                        doesDirectoryExist root `shouldReturn` True
                        writeFile (root </> "owned") "this run"
                        pure root
                    doesDirectoryExist dir `shouldReturn` False
                    readFile (other </> "sentinel") `shouldReturn` "another run"
                    lookupEnv "TMPDIR" `shouldReturn` original

            it "preserves the action's exception, environment and sibling files" $
                withEnvironment originallySet $ \original other -> do
                    seen <- newIORef Nothing
                    result <- try @ErrorCall $ bracketTmpDir $ do
                        root <- getTemporaryDirectory
                        writeIORef seen (Just root)
                        writeFile (root </> "owned") "this run"
                        throwIO (ErrorCall "temporary action failed")
                    case result :: Either ErrorCall () of
                        Left err -> show err `shouldBe` "temporary action failed"
                        Right () -> fail "the action's exception was lost"
                    path <- readIORef seen
                    case path of
                        Nothing -> fail "the actual helper never ran its action"
                        Just dir -> doesDirectoryExist dir `shouldReturn` False
                    readFile (other </> "sentinel") `shouldReturn` "another run"
                    lookupEnv "TMPDIR" `shouldReturn` original

withEnvironment :: Bool -> (Maybe String -> FilePath -> IO a) -> IO a
withEnvironment originallySet action =
    withSystemTempDirectory "conformance-tmpdir-control" $ \root ->
        bracket (lookupEnv "TMPDIR") restore $ \_ -> do
            let original = if originallySet then Just root else Nothing
                other = root </> "cardano-e2e"
            createDirectory other
            writeFile (other </> "sentinel") "another run"
            restore original
            action original other
  where
    restore = maybe (unsetEnv "TMPDIR") (setEnv "TMPDIR")
