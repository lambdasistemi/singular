module Singular.Registry.CandidateSpec (spec) where

import Control.Exception (finally)
import Singular.Registry.Candidate (CandidateSource (..), resolveCandidate, sourceName)
import System.Directory (
    createDirectory,
    getCurrentDirectory,
    getTemporaryDirectory,
    removeDirectoryRecursive,
    removeFile,
    setCurrentDirectory,
 )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Test.Hspec

spec :: Spec
spec = describe "Singular.Registry.Candidate" $ do
    it "resolves a release archive's RELEASE-COMMIT walking up from the working directory" $ do
        withSandbox $ \dir -> do
            createDirectory (dir </> "offchain")
            withoutCandidateOverride . within (dir </> "offchain") $ do
                writeFile (dir </> "RELEASE-COMMIT") (candidateSha <> "\n")
                result <- resolveCandidate
                -- The sandbox is no git repository, so a readable
                -- git status is impossible: dirty rides along True.
                result
                    `shouldBe` Right (candidateSha, True, CandidateFromReleaseCommit)
        sourceName CandidateFromReleaseCommit `shouldBe` "release-commit"

    it "fails closed with no override, no repository and no RELEASE-COMMIT" $ do
        withSandbox $ \dir ->
            withoutCandidateOverride . within dir $ do
                result <- resolveCandidate
                case result of
                    Left err -> do
                        err `shouldContain` "candidate: cannot establish repository revision"
                        err `shouldContain` "RELEASE-COMMIT"
                    Right got ->
                        expectationFailure ("expected the fail-closed error, resolved " <> show got)

-- | A fixed sha-shaped revision the specs assert on.
candidateSha :: String
candidateSha = "9f2c6e5b1a0d4f8e3c7b2a6d5e1f0c9b8a7d6e5f"

{- | A unique empty temporary directory, outside any git repository,
removed afterwards.
-}
withSandbox :: (FilePath -> IO a) -> IO a
withSandbox act = do
    root <- getTemporaryDirectory
    (unique, handle) <- openTempFile root "cage-candidate-spec"
    hClose handle
    removeFile unique
    createDirectory unique
    act unique `finally` removeDirectoryRecursive unique

-- | Run with the working directory moved, restoring it afterwards.
within :: FilePath -> IO a -> IO a
within dir act = do
    original <- getCurrentDirectory
    setCurrentDirectory dir
    act `finally` setCurrentDirectory original

{- | Hide the CANDIDATE_SHA override for the duration, restoring it
afterwards.
-}
withoutCandidateOverride :: IO a -> IO a
withoutCandidateOverride act = do
    saved <- lookupEnv "CANDIDATE_SHA"
    unsetEnv "CANDIDATE_SHA"
    act `finally` maybe (pure ()) (setEnv "CANDIDATE_SHA") saved
