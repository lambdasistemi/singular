{- |
Module      : Singular.Registry.Candidate
Description : Which revision a run's evidence claims to replay
License     : Apache-2.0

Resolves the candidate revision for the row runners (#91): the
@CANDIDATE_SHA@ override wins for smoke runs, else the invocation
repository's @git rev-parse HEAD@, else the @RELEASE-COMMIT@ file a
published release archive carries at its root — the archive is not a
git checkout, so the file is found by walking up from the working
directory (the runners execute from @offchain/@ inside the extracted
archive). A revision that cannot be established fails closed, never
"unknown".
-}
module Singular.Registry.Candidate (
    CandidateSource (..),
    resolveCandidate,
    sourceName,
) where

import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.Char (isSpace)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory (doesFileExist, getCurrentDirectory)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.Process (readProcess)

-- | Where a resolved candidate revision came from.
data CandidateSource
    = -- | The @CANDIDATE_SHA@ environment override.
      CandidateFromEnv
    | -- | The invocation repository's @git rev-parse HEAD@.
      CandidateFromGitHead
    | -- | The @RELEASE-COMMIT@ file of a published release archive.
      CandidateFromReleaseCommit
    deriving (Eq, Show)

-- | Stable name for the source, as recorded in a run's @meta.json@.
sourceName :: CandidateSource -> String
sourceName CandidateFromEnv = "env"
sourceName CandidateFromGitHead = "git"
sourceName CandidateFromReleaseCommit = "release-commit"

{- | Candidate revision, derived not told: an explicit override wins for
smoke runs, else the invocation repository's HEAD, else the
RELEASE-COMMIT file of the release archive the working directory sits
in. A revision that cannot be established fails closed — never
"unknown". Worktree cleanliness rides along as before: a @git status@
that cannot be read counts as dirty.
-}
resolveCandidate :: IO (Either String (String, Bool, CandidateSource))
resolveCandidate = do
    override <- lookupEnv "CANDIDATE_SHA"
    headOut <- try (readProcess "git" ["rev-parse", "HEAD"] "") :: IO (Either SomeException String)
    statusOut <- try (readProcess "git" ["status", "--porcelain"] "") :: IO (Either SomeException String)
    let dirty = case statusOut of
            Right status -> any (/= '\n') status
            Left _ -> True
    case (override, headOut) of
        (Just sha, _) -> pure (Right (sha, dirty, CandidateFromEnv))
        (Nothing, Right sha) -> pure (Right (trim sha, dirty, CandidateFromGitHead))
        (Nothing, Left _) -> do
            fromArchive <- releaseCommitAbove
            pure $ case fromArchive of
                Just sha -> Right (sha, dirty, CandidateFromReleaseCommit)
                Nothing ->
                    Left
                        "candidate: cannot establish repository revision: \
                        \no CANDIDATE_SHA, no git HEAD, and no RELEASE-COMMIT \
                        \in any parent directory"

{- | The RELEASE-COMMIT file of a release archive above the working
directory (#91): runners execute from @offchain/@ inside the
extracted archive, so the file sits in a parent directory. Empty
entries do not shadow: the walk continues.
-}
releaseCommitAbove :: IO (Maybe String)
releaseCommitAbove = do
    cwd <- getCurrentDirectory
    go (ancestors cwd)
  where
    ancestors dir =
        dir
            : case takeDirectory dir of
                parent
                    | parent == dir -> []
                    | otherwise -> ancestors parent
    go [] = pure Nothing
    go (dir : rest) = do
        let path = dir </> "RELEASE-COMMIT"
        exists <- doesFileExist path
        if not exists
            then go rest
            else do
                bytes <- BS.readFile path
                case trim (T.unpack (TE.decodeUtf8Lenient bytes)) of
                    [] -> go rest
                    sha -> pure (Just sha)

-- | Whitespace, including the trailing newline, off both ends.
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
