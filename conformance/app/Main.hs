{- |
Module      : Main
Description : Singular consumer conformance row runner (issue #63)
License     : Apache-2.0

@conformance -- list@ prints the complete 41-row inventory from
@rows.json@: id, group, requirement, source, expected outcome and
state. A row prints as @executed@ only when a run receipt for it
exists and matches the current base (@--receipts DIR@ or
@CONFORMANCE_RECEIPTS@, defaulting to none); otherwise @list@
prints the declared plan. @conformance -- run ROW...@ executes rows
against a real devnet.
-}
module Main (main) where

import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import Conformance.Receipt (
    Receipt,
    currentBase,
    loadReceipts,
    receiptRow,
 )
import Conformance.Rows (
    loadRows,
    renderInventory,
    rowId,
 )
import Paths_conformance (getDataFileName)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["list"] -> runList Nothing
        ["list", "--receipts", dir] -> runList (Just dir)
        _ -> do
            hPutStrLn stderr "usage: conformance -- list [--receipts DIR]"
            hPutStrLn stderr "       conformance -- run ROW..."
            hPutStrLn
                stderr
                "env:   CONFORMANCE_RECEIPTS=DIR (when --receipts is absent)"
            exitFailure

runList :: Maybe FilePath -> IO ()
runList flagDir = do
    path <- getDataFileName "rows.json"
    result <- loadRows path
    case result of
        Left err -> do
            hPutStrLn stderr ("conformance list: FAILED: " <> err)
            exitFailure
        Right rows -> do
            receipts <- resolveReceipts flagDir
            case receipts of
                Left err -> do
                    hPutStrLn stderr ("conformance list: FAILED: " <> err)
                    exitFailure
                Right rs -> case
                    [ receiptRow r
                    | r <- rs
                    , receiptRow r `notElem` map rowId rows
                    ] of
                    (bad : _) -> do
                        hPutStrLn
                            stderr
                            ( "conformance list: FAILED: receipt for unknown row "
                                <> T.unpack bad
                            )
                        exitFailure
                    [] -> do
                        base <- currentBase
                        case base of
                            Nothing ->
                                TIO.putStr (renderInventory "" rs rows)
                            Just b ->
                                TIO.putStr (renderInventory b rs rows)

-- | The receipt directory: @--receipts@, else @CONFORMANCE_RECEIPTS@,
-- else none (the declared plan prints, honestly uncovered).
resolveReceipts :: Maybe FilePath -> IO (Either String [Receipt])
resolveReceipts (Just dir) = loadReceipts dir
resolveReceipts Nothing = do
    env <- lookupEnv "CONFORMANCE_RECEIPTS"
    case env of
        Just dir -> loadReceipts dir
        Nothing -> pure (Right [])
