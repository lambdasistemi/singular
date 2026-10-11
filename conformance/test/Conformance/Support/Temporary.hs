{- | Appendix controls for the actual conformance temporary-root lifetime.
These are harness checks, not registry or ledger evidence.
-}
module Conformance.Support.Temporary (spec) where

import Conformance.Run.Temporary
    ( TmpDirCleanupFailure (..)
    , TmpDirOwner
    , newTmpDirOwner
    , withTmpDir
    )
import Control.Concurrent.Async
    ( AsyncCancelled
    , cancel
    , waitCatch
    , withAsync
    )
import Control.Concurrent.MVar
    ( newEmptyMVar
    , putMVar
    , readMVar
    , takeMVar
    )
import Control.Exception
    ( ErrorCall (..)
    , IOException
    , SomeException
    , bracket
    , finally
    , fromException
    , throwIO
    , try
    )
import Control.Monad (replicateM, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, nub)
import Data.Maybe (isJust)
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , getTemporaryDirectory
    )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    , shouldSatisfy
    , shouldThrow
    )

spec :: Spec
spec =
    describe "A conformance session owns its temporary root" $ do
        mapM_ environmentCases [False, True]
        mapM_ cleanupFailureCase [False, True]
  where
    environmentCases originallySet =
        describe
            ( if originallySet
                then "TMPDIR originally set"
                else "TMPDIR originally absent"
            )
            $ do
                it "restores the environment and cleans only its own files on success" $
                    withEnvironment originallySet $ \owner original other -> do
                        dir <- withTmpDir owner $ \root -> do
                            getTemporaryDirectory `shouldReturn` root
                            lookupEnv "TMPDIR" `shouldReturn` Just root
                            doesDirectoryExist root `shouldReturn` True
                            writeFile (root </> "owned") "this run"
                            pure root
                        doesDirectoryExist dir `shouldReturn` False
                        readFile (other </> "sentinel") `shouldReturn` "another run"
                        lookupEnv "TMPDIR" `shouldReturn` original

                it "preserves the action's exception, environment and sibling files" $
                    withEnvironment originallySet $ \owner original other -> do
                        seen <- newIORef Nothing
                        result <- try @ErrorCall $ withTmpDir owner $ \root -> do
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
                        next <- withTmpDir owner pure
                        doesDirectoryExist next `shouldReturn` False
                        lookupEnv "TMPDIR" `shouldReturn` original

                it "releases the owner when temporary-root acquisition fails" $
                    withEnvironment originallySet $ \owner original other -> do
                        let missing = other </> "missing-parent"
                        setEnv "TMPDIR" missing
                        withTmpDir
                            owner
                            (const (fail "an invalid parent admitted the action"))
                            `shouldThrow` isDoesNotExistError
                        lookupEnv "TMPDIR" `shouldReturn` Just missing
                        maybe (unsetEnv "TMPDIR") (setEnv "TMPDIR") original
                        dir <- withTmpDir owner pure
                        doesDirectoryExist dir `shouldReturn` False
                        lookupEnv "TMPDIR" `shouldReturn` original
                        readFile (other </> "sentinel") `shouldReturn` "another run"

                it
                    "joins cancellation, restores the environment and releases the owner"
                    $ withEnvironment originallySet
                    $ \owner original other ->
                        bounded $ do
                            entered <- newEmptyMVar
                            blocked <- newEmptyMVar
                            dir <- withAsync
                                ( withTmpDir owner $ \root -> do
                                    writeFile (root </> "owned") "this run"
                                    putMVar entered root
                                    readMVar blocked
                                )
                                $ \worker -> do
                                    root <- takeMVar entered
                                    cancel worker
                                    result <- waitCatch worker
                                    case result :: Either SomeException () of
                                        Left err ->
                                            (fromException err :: Maybe AsyncCancelled)
                                                `shouldSatisfy` isJust
                                        Right () -> fail "cancellation was lost"
                                    pure root
                            doesDirectoryExist dir `shouldReturn` False
                            readFile (other </> "sentinel") `shouldReturn` "another run"
                            lookupEnv "TMPDIR" `shouldReturn` original
                            next <- withTmpDir owner pure
                            next `shouldSatisfy` (/= dir)
                            doesDirectoryExist next `shouldReturn` False
                            lookupEnv "TMPDIR" `shouldReturn` original

                it
                    "refuses nesting before entering the second action or changing the root"
                    $ withEnvironment originallySet
                    $ \owner original other ->
                        bounded $ do
                            ran <- newIORef False
                            dir <- withTmpDir owner $ \root -> do
                                withTmpDir owner (\_ -> writeIORef ran True)
                                    `shouldThrow` alreadyActive
                                readIORef ran `shouldReturn` False
                                lookupEnv "TMPDIR" `shouldReturn` Just root
                                doesDirectoryExist root `shouldReturn` True
                                pure root
                            doesDirectoryExist dir `shouldReturn` False
                            readFile (other </> "sentinel") `shouldReturn` "another run"
                            lookupEnv "TMPDIR" `shouldReturn` original

                it "refuses overlap while the first action is held, then admits reuse" $
                    withEnvironment originallySet $ \owner original other ->
                        bounded $ do
                            entered <- newEmptyMVar
                            release <- newEmptyMVar
                            ran <- newIORef False
                            dir <- withAsync
                                ( withTmpDir owner $ \root -> do
                                    putMVar entered root
                                    takeMVar release
                                )
                                $ \worker -> do
                                    root <- takeMVar entered
                                    withTmpDir owner (\_ -> writeIORef ran True)
                                        `shouldThrow` alreadyActive
                                    readIORef ran `shouldReturn` False
                                    lookupEnv "TMPDIR" `shouldReturn` Just root
                                    doesDirectoryExist root `shouldReturn` True
                                    putMVar release ()
                                    result <- waitCatch worker
                                    either throwIO pure result
                                    pure root
                            doesDirectoryExist dir `shouldReturn` False
                            readFile (other </> "sentinel") `shouldReturn` "another run"
                            lookupEnv "TMPDIR" `shouldReturn` original
                            next <- withTmpDir owner pure
                            next `shouldSatisfy` (/= dir)
                            doesDirectoryExist next `shouldReturn` False
                            lookupEnv "TMPDIR" `shouldReturn` original

                it
                    "allocates distinct roots on repeated use and restores after every call"
                    $ withEnvironment originallySet
                    $ \owner original other -> do
                        roots <- replicateM 32 $ do
                            dir <- withTmpDir owner pure
                            doesDirectoryExist dir `shouldReturn` False
                            lookupEnv "TMPDIR" `shouldReturn` original
                            pure dir
                        length (nub roots) `shouldBe` length roots
                        readFile (other </> "sentinel") `shouldReturn` "another run"

cleanupFailureCase :: Bool -> Spec
cleanupFailureCase actionFails =
    it
        ( if actionFails
            then "retains the action and cleanup failures together"
            else "refuses success when its root could not be removed"
        )
        $ withEnvironment True
        $ \owner original other -> do
            let parent = takeDirectory other
            seen <- newIORef Nothing
            result <-
                ( try @SomeException $ withTmpDir owner $ \root -> do
                    writeIORef seen (Just root)
                    writeFile (root </> "owned") "this run"
                    setFileMode parent 0o500
                    when actionFails $ throwIO (ErrorCall "original action failed")
                )
                    `finally` setFileMode parent 0o700
            root <-
                readIORef seen
                    >>= maybe (fail "the helper never admitted its action") pure
            doesDirectoryExist root `shouldReturn` True
            lookupEnv "TMPDIR" `shouldReturn` original
            readFile (other </> "sentinel") `shouldReturn` "another run"
            case result of
                Right () -> fail "cleanup failed but the helper returned success"
                Left err -> case fromException err of
                    Nothing -> fail ("cleanup failure was not retained: " <> show err)
                    Just failure -> do
                        tmpDirRoot failure `shouldBe` root
                        case fromException (tmpDirCleanupException failure) :: Maybe IOException of
                            Nothing -> fail "the underlying filesystem exception was lost"
                            Just cause -> cause `shouldSatisfy` isPermissionError
                        case tmpDirActionFailure failure of
                            Nothing -> actionFails `shouldBe` False
                            Just cause -> do
                                actionFails `shouldBe` True
                                (show <$> (fromException cause :: Maybe ErrorCall))
                                    `shouldBe` Just "original action failed"
            next <- withTmpDir owner pure
            next `shouldSatisfy` (/= root)
            doesDirectoryExist next `shouldReturn` False
            lookupEnv "TMPDIR" `shouldReturn` original

alreadyActive :: ErrorCall -> Bool
alreadyActive (ErrorCall message) = "TMPDIR owner already active" `isInfixOf` message

bounded :: IO () -> IO ()
bounded action = do
    result <- timeout 10000000 action
    result `shouldBe` Just ()

withEnvironment
    :: Bool -> (TmpDirOwner -> Maybe String -> FilePath -> IO a) -> IO a
withEnvironment originallySet action =
    withSystemTempDirectory "conformance-tmpdir-control" $ \root ->
        bracket (lookupEnv "TMPDIR") restore $ \_ -> do
            let original = if originallySet then Just root else Nothing
                other = root </> "cardano-e2e"
            createDirectory other
            writeFile (other </> "sentinel") "another run"
            restore original
            owner <- newTmpDirOwner
            action owner original other
  where
    restore = maybe (unsetEnv "TMPDIR") (setEnv "TMPDIR")
