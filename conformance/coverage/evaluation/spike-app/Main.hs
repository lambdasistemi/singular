{-# LANGUAGE OverloadedStrings #-}

-- | Issue #80 adapter: devnet-bound stories with failure-safe session teardown.
--
-- Uses lambdasistemi/tasty-bdd (revision f55494c9b917ec12b4d01e506694b1a5c3b41b56)
-- for story sequencing only. Real resources — the receipts directory and the
-- whole devnet session underneath a per-run marker TMPDIR — are bound through
-- tasty's `withResource`, never through bare `GivenAndAfter`: the library's
-- interpreter composes teardowns before the When action runs, so any exception
-- from When skips them, and Then-failures skip them under the default
-- ingredients. That is F-2, read from source
-- (Test.Tasty.Bdd `run`, `FailFast` branch), and this adapter does not rely on it.
--
-- Session teardown (F-1) lives here rather than in the row runner: whatever the
-- runner cleans itself, the adapter reaps marker-scoped cardano-node processes
-- (SIGTERM, grace, SIGKILL) and removes the marker directory, then writes a
-- release proof file beside it. Marker scoping (a unique per-run path present
-- in the nodes' --database-path) keeps sibling lanes and infra nodes out of
-- reach. A cleanup claim is demonstrated, not asserted: the shell runs a
-- passing story and an intentionally failing story and checks the proof file,
-- the gone directory and the process table after each.
--
-- Modes:
--   spike positive  — the honest story, must pass (exit 0)
--   spike negative  — the same story asserting a deliberate lie, must fail
--                     with a failing process status (exit 1); release still runs
--   spike reap DIR  — standalone reaper for an abandoned marker dir (kill drill,
--                     CI cleanup step); exits 0 iff no marker nodes remain
--
-- Run with `-j1`.
module Main (main) where

import qualified Control.Concurrent as CC
import qualified Control.Monad as CM
import Data.Char (isDigit)
import Data.List (isInfixOf)
import Data.Unique (hashUnique, newUnique)

import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removePathForcibly)
import System.Environment (getArgs, getEnvironment, lookupEnv, withArgs)
import System.Exit (ExitCode (..), die, exitFailure, exitSuccess)
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd, env), proc, readCreateProcessWithExitCode, readProcess, readProcessWithExitCode)

import Test.BDD.Language
import Test.Tasty (defaultMain, testGroup, withResource)
import Test.Tasty.Bdd

-- | Per-run session handle: everything releasable lives under 'sessMarker'.
data Session = Session
    { sessReceipts :: !FilePath
    , sessMarker :: !FilePath
    , sessBaseline :: ![String]
    }

-- | All cardano-node pids visible right now (any lane, any origin).
nodePids :: IO [String]
nodePids = do
  (_c, out, _e) <- readProcessWithExitCode "ls" ["/proc"] ""
  let entries = filter (all isDigit) (words out)
  concat <$> mapM pidOf entries
  where
    pidOf p = do
      ok <- doesFileExist ("/proc" </> p </> "cmdline")
      if not ok
        then return []
        else do
          (_c, out, _e) <- readProcessWithExitCode "cat" ["/proc" </> p </> "cmdline"] ""
          return [p | "cardano-node" `isInfixOf` out]

-- | Our lane's nodes only: cardano-node processes whose command line carries
-- our unique marker path (the runner puts --database-path underneath the
-- TMPDIR we hand it). Infra nodes and sibling lanes never match.
markerNodePids :: FilePath -> IO [String]
markerNodePids marker = do
  (_c, out, _e) <- readProcessWithExitCode "ls" ["/proc"] ""
  let entries = filter (all isDigit) (words out)
  concat <$> mapM pidOf entries
  where
    pidOf p = do
      ok <- doesFileExist ("/proc" </> p </> "cmdline")
      if not ok
        then return []
        else do
          (_c, out, _e) <- readProcessWithExitCode "cat" ["/proc" </> p </> "cmdline"] ""
          return
            [ p
            | "cardano-node" `isInfixOf` out
            , marker `isInfixOf` out
            ]

-- | SIGTERM, grace, SIGKILL survivors. Returns @(found, remaining)@:
-- what was there before reaping and what survived it (want []).
reapMarkerNodes :: FilePath -> IO ([String], [String])
reapMarkerNodes marker = do
  found <- markerNodePids marker
  CM.unless (null found) $ do
    _ <- readProcessWithExitCode "kill" (["-TERM"] <> found) ""
    CC.threadDelay 3_000_000
    still <- markerNodePids marker
    CM.unless (null still) $ do
      _ <- readProcessWithExitCode "kill" (["-KILL"] <> still) ""
      CC.threadDelay 1_000_000
      pure ()
  final <- markerNodePids marker
  pure (found, final)

acquireSession :: String -> IO Session
acquireSession tag = do
  -- Unique across processes sharing /tmp with sibling lanes: wall-clock
  -- nanoseconds (a process-local counter alone collides, as a merged run
  -- once proved) plus the per-process counter for same-instant starts.
  -- Only base/directory/filepath/process are used — no new dependencies.
  stamp <- init . filter (/= '\n') <$> readProcess "date" ["+%s%N"] ""
  n <- abs <$> hashUnique <$> newUnique
  let marker = "/tmp/t80-story-" <> tag <> "-" <> stamp <> "-" <> show n
      receipts = marker </> "receipts"
  createDirectoryIfMissing True marker
  baseline <- nodePids
  return (Session receipts marker baseline)

-- | Unconditional release: reap our nodes, remove the whole marker tree,
-- then record what happened where the shell demonstration can read it.
-- Runs on pass and on failure alike — that is the F-2 repair.
releaseSession :: String -> Session -> IO ()
releaseSession tag sess = do
  (reaped, _) <- reapMarkerNodes (sessMarker sess)
  removePathForcibly (sessMarker sess)
  gone <- doesDirectoryExist (sessMarker sess)
  still <- markerNodePids (sessMarker sess)
  writeFile
    (sessMarker sess <> ".released")
    ( unlines
        [ "mode: " <> tag
        , "receiptsRemoved: " <> show gone
        , "markerNodesReaped: " <> show reaped
        , "markerNodesRemaining: " <> show still
        , "baselineNodeCount: " <> show (length (sessBaseline sess))
        ]
    )

blueprintPath :: IO FilePath
blueprintPath = lookupEnv "MPFS_BLUEPRINT" >>= maybe (die "MPFS_BLUEPRINT unset") return

conformanceDir :: IO FilePath
conformanceDir =
  lookupEnv "CONFORMANCE_DIR"
    >>= maybe (die "CONFORMANCE_DIR unset (path to the conformance package dir)") return

-- | Drive one CG05 row with TMPDIR scoped under our marker, so every
-- session file and node the runner creates is attributable to this run.
runStory :: Session -> IO (ExitCode, String, String)
runStory sess = do
  confDir <- conformanceDir
  baseEnv <- getEnvironment
  let childEnv = ("TMPDIR", sessMarker sess) : filter ((/= "TMPDIR") . fst) baseEnv
  readCreateProcessWithExitCode
    (proc "nix" ["run", "--quiet", confDir ++ "#conformance", "--", "run", "CG05",
                 "--receipts-dir", sessReceipts sess])
      { cwd = Just (confDir ++ "/..")
      , env = Just childEnv
      }
    ""

main :: IO ()
main = do
  (mode, rest) <- getArgs >>= \case
    ("positive" : r) -> return ("positive" :: String, r)
    ("negative" : r) -> return ("negative", r)
    ("reap" : d : _) -> do
      CM.unless ("t80-story-" `isInfixOf` d) (die ("reap refuses path outside t80-story- markers: " <> d))
      (reaped, _) <- reapMarkerNodes d
      removePathForcibly d
      gone <- doesDirectoryExist d
      still <- markerNodePids d
      putStrLn ("reaped: " <> show reaped <> ", remaining: " <> show still <> ", dirGone: " <> show (not gone))
      if null still && not gone then exitSuccess else exitFailure
    _ ->
      die
        "usage: spike positive|negative [-j1 tasty flags] | spike reap MARKERDIR"
  _ <- blueprintPath
  _ <- conformanceDir
  let lie = mode == "negative"
  withArgs rest $
    defaultMain $
      withResource (acquireSession mode) (releaseSession mode) $ \getSess ->
        testGroup "tasty-bdd evaluation: CG05 occupied-key refusal" $
          [ testBehavior
              "real boundary: occupied insert refused, script-attributed, control discriminates"
              $ Given (do
                  bp <- blueprintPath
                  ok <- doesFileExist bp
                  CM.unless ok (die "blueprint missing")
                  return ())
              $ When (getSess >>= runStory)
              $ Then (\(code, _out, _err) ->
                  if lie
                    then fail ("deliberate lie: the refusal must not have happened, but the story ran: "
                               ++ show (code == ExitSuccess))
                    else expectExitSuccess code)
              $ Then (\(_code, out, _err) -> assertTrue ("1/1 rows ok" `isInfixOf` out) "runner reports 1/1 rows ok")
              $ Then (\(_code, out, _err) -> assertTrue ("REFUSED at submit" `isInfixOf` out) "occupied insert refused at submit")
              $ Then (\(_code, out, _err) -> assertTrue ("the refusal discriminates" `isInfixOf` out) "executing negative control passed")
              $ Then (\(_code, _out, _err) -> do
                  sess <- getSess
                  ok <- doesFileExist (sessReceipts sess </> "receipt-CG05.json")
                  assertTrue ok "CG05 receipt artifact exists")
              $ End
          ]
  where
    expectExitSuccess ExitSuccess = return ()
    expectExitSuccess c = fail ("expected exit success, got " <> show c)
    assertTrue b m = CM.unless b (fail ("assertion failed: " <> m))
