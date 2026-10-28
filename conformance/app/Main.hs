-- | Read the published inventory or regenerate its receipt-derived evidence page.
module Main (main) where

import Control.Monad ((>=>))
import Data.Maybe (fromMaybe)

import Conformance.EvidencePage (runEvidencePage)
import Conformance.Receipt (Receipt (..), currentBase, loadReceipts)
import Conformance.Rows (Row (..), loadRows, renderInventory)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Paths_conformance (getDataFileName)
import System.Environment (getArgs, lookupEnv)
import System.Exit (die)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["list"] -> lookupEnv "CONFORMANCE_RECEIPTS" >>= runList
        ["list", "--receipts", dir] -> runList (Just dir)
        ["evidence-page", "--root", root] -> runEvidencePage root False
        ["evidence-page", "--root", root, "--write"] -> runEvidencePage root True
        _ ->
            die
                "usage: conformance list [--receipts DIR] | evidence-page --root ROOT [--write]"

runList :: Maybe FilePath -> IO ()
runList dir = do
    path <- getDataFileName "rows.json"
    rows <- loadRows path >>= either die pure
    receipts <-
        maybe (pure []) (loadReceipts >=> either die pure) dir
    case [ receiptRow report
         | report <- receipts
         , receiptRow report `notElem` map rowId rows
         ] of
        bad : _ -> die ("receipt for unknown requirement " <> T.unpack bad)
        [] -> do
            base <- currentBase
            TIO.putStr (renderInventory (fromMaybe "" base) receipts rows)
