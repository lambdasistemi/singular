{-# LANGUAGE OverloadedStrings #-}

-- | Issue #80 bounded feasibility evaluation of paolino/tasty-bdd
-- (revision f55494c9b917ec12b4d01e506694b1a5c3b41b56).
--
-- One real Lean obligation, one real implementation boundary:
--
--  * Obligation (pinned in conformance/coverage/evaluation/):
--    Singular.NamingStatements.naming_occupied_key_refuses_duplicate — "a
--    competing certified Insert for the now-occupied key is refused with the
--    named registry reason"; the refusal the Lean model pins at
--    Singular/Model.lean:175 (occupied-key).
--
--  * Implementation execution: the packaged conformance runner over a real
--    devnet and the real blueprint (row CG05), with its executing negative
--    control proving the refusal discriminates.
--
-- Modes:
--   spike positive  — the honest story, must pass
--   spike negative  — the same story asserting a deliberate lie, must fail
--                     with a failing process status
--
-- Run with `-j1` so the teardown-observation test runs after the story.
module Main (main) where

import qualified Control.Monad as CM
import Data.Char (isDigit)
import Data.List (isInfixOf)
import System.Directory (doesDirectoryExist, doesFileExist, removeDirectoryRecursive)
import System.Environment (getArgs, lookupEnv, withArgs)
import System.Exit (ExitCode (..), die)
import System.FilePath ((</>))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode, readProcessWithExitCode)

import Test.BDD.Language
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.Bdd

receiptsDir :: FilePath
receiptsDir = "/tmp/t80-tasty-bdd-spike-receipts"

-- cardano-node process ids, read from /proc (no pgrep assumption)
nodePids :: IO [String]
nodePids = do
  (_c, out, _e) <- readProcessWithExitCode "ls" ["/proc"] ""
  let entries = filter (all isDigit) (words out)
  mapM pidOf entries >>= return . concat
  where
    pidOf p = do
      ok <- doesFileExist ("/proc" </> p </> "cmdline")
      if not ok then return [] else do
        (_c, out, _e) <- readProcessWithExitCode "cat" ["/proc" </> p </> "cmdline"] ""
        return [p | "cardano-node" `isInfixOf` out]

blueprintPath :: IO FilePath
blueprintPath = lookupEnv "MPFS_BLUEPRINT" >>= maybe (die "MPFS_BLUEPRINT unset") return

runStory :: IO (ExitCode, String, String)
runStory = do
  confDir <- lookupEnv "CONFORMANCE_DIR" >>= maybe (return "/code/singular-e18-ratchet/conformance") return
  readCreateProcessWithExitCode
    (proc "nix" ["run", "--quiet", confDir ++ "#conformance", "--", "run", "CG05",
                 "--receipts-dir", receiptsDir]) { cwd = Just (confDir ++ "/..") }
    ""
main :: IO ()
main = do
  (mode0, rest) <- getArgs >>= \case
    ("positive":r) -> return (False, r)
    ("negative":r) -> return (True, r)
    _ -> die "usage: spike positive|negative  (tasty flags after the mode, e.g. -j1)"
  _ <- blueprintPath
  baseline <- nodePids
  let lie = mode0
  withArgs rest $ defaultMain $ testGroup "tasty-bdd evaluation: CG05 occupied-key refusal"
    [ testBehavior
        "real boundary: occupied insert refused, script-attributed, control discriminates"
        $ Given (do
            bp <- blueprintPath
            ok <- doesFileExist bp
            CM.unless ok (die "blueprint missing")
            return ())
        $ GivenAndAfter (do
            exists <- doesDirectoryExist receiptsDir
            CM.when exists (removeDirectoryRecursive receiptsDir)
            return receiptsDir)
            (\d -> do
                still <- doesDirectoryExist d
                CM.when still (removeDirectoryRecursive d))

        $ When runStory
        $ Then (\(code, out, err) ->
            if lie
              then fail ("deliberate lie: the refusal must not have happened, but the story ran: "
                         ++ show (code == ExitSuccess))
              else expectExitSuccess code)
        $ Then (\(_code, out, _err) -> assertTrue ("1/1 rows ok" `isInfixOf` out) "runner reports 1/1 rows ok")
        $ Then (\(_code, out, _err) -> assertTrue ("REFUSED at submit" `isInfixOf` out) "occupied insert refused at submit")
        $ Then (\(_code, out, _err) -> assertTrue ("the refusal discriminates" `isInfixOf` out) "executing negative control passed")
        $ Then (\(_code, _out, _err) -> do
            ok <- doesFileExist (receiptsDir </> "receipt-CG05.json")
            assertTrue ok "CG05 receipt artifact exists")
        $ End
    , testBehavior
        "teardown: real resources released — receipts dir gone, no leaked cardano-node"

        $ When (do
            left <- doesDirectoryExist receiptsDir
            pids <- nodePids
            return (left, filter (`notElem` baseline) pids))
        $ Then (\(left, _new) -> assertTrue (not left) "the story's receipts dir was removed by teardown")
        $ Then (\(_left, new) -> assertTrue (null new) "no cardano-node process leaked past the run")
        $ End
    ]
  where
    expectExitSuccess ExitSuccess = return ()
    expectExitSuccess c = fail ("expected exit success, got " ++ show c)
    assertTrue b m = CM.unless b (fail ("assertion failed: " ++ m))
