{- |
Module      : Main
Description : Singular consumer conformance row runner (issue #63)
License     : Apache-2.0

@conformance -- list@ prints the complete 40-row inventory from
@rows.json@. @conformance -- run ROW...@ executes rows against a real
devnet.
-}
module Main (main) where

import Data.Text.IO qualified as TIO
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Conformance.Rows (
    loadRows,
    renderInventory,
 )
import Paths_conformance (getDataFileName)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["list"] -> runList
        _ -> do
            hPutStrLn stderr "usage: conformance -- list"
            hPutStrLn stderr "       conformance -- run ROW..."
            exitFailure

runList :: IO ()
runList = do
    path <- getDataFileName "rows.json"
    result <- loadRows path
    case result of
        Left err -> do
            hPutStrLn stderr ("conformance list: FAILED: " <> err)
            exitFailure
        Right rows -> TIO.putStr (renderInventory rows)
