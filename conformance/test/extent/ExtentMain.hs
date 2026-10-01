{- |
Module      : Main
Description : The extent check over the receipts of every run a workflow made
License     : Apache-2.0

@conformance-extent EXTENT.md DIR...@ reads the committed table of the extent
document, then, for each receipts directory, its receipts and its replay
index, and prints each run's refusals by class. It exits non-zero naming every
problem: a run with no refusal, a refusal the index does not name exactly
once, a class-A refusal that differs or is uncompared without a cause, a
refusal the table does not list, or a refusing script role without an
accepting control.
-}
module Main (main) where

import Conformance.Extent
    ( ExtentClass (..)
    , ExtentCount (..)
    , committedClasses
    , extentCount
    , extentProblems
    )
import Conformance.Receipt (loadReceipts)
import Control.Monad (unless)
import Data.Aeson (Value, eitherDecodeFileStrict)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))

main :: IO ()
main = do
    args <- getArgs
    case args of
        document : dirs@(_ : _) -> do
            table <-
                either (failWith . ("extent table: " <>)) pure
                    . committedClasses
                    =<< TIO.readFile document
            problems <- concat <$> mapM (checkRun table) dirs
            mapM_ (TIO.putStrLn . ("FAIL: " <>)) problems
            unless (null problems) exitFailure
            putStrLn ("extent: " <> show (length dirs) <> " runs, no problem")
        _ -> failWith "usage: conformance-extent EXTENT.md RECEIPTS-DIR..."
  where
    checkRun table dir = do
        receipts <-
            either (failWith . ("receipts: " <>)) pure =<< loadReceipts dir
        let indexPath = dir </> "replay" </> "index.json"
        present <- doesFileExist indexPath
        entries <-
            if present
                then
                    either (failWith . ((indexPath <> ": ") <>)) pure
                        =<< (eitherDecodeFileStrict indexPath :: IO (Either String [Value]))
                else pure []
        let count = extentCount table entries
        putStrLn
            ( dir
                <> ": "
                <> show (length receipts)
                <> " receipts; refusals A "
                <> show (countA count)
                <> concat
                    [ ", "
                        <> name
                        <> " "
                        <> show (Map.findWithDefault 0 cls (countTable count))
                    | (name, cls) <- [("B", ClassB), ("C", ClassC), ("D", ClassD)]
                    ]
            )
        pure
            [ T.pack dir <> ": " <> problem
            | problem <- extentProblems table entries receipts
            ]
    failWith message = putStrLn ("FAIL: " <> message) >> exitFailure
