{- | The ordinary CLI's refusal controls, run against a node and judged from
their receipts.

@cli-controls run@ executes "Conformance.Cli.Controls"'s stories: the
ordinary commands through the @singular@ executable, and the two steps no
command takes — an insertion booked but not folded, and a fold submitted
without local evaluation — through the same library builders the commands
use. Every action leaves one receipt under @WORK/receipts@.

@cli-controls render RECEIPTS@ reads those receipts back, judges every
clause from them alone and prints the section a reader sees. @run@ ends by
doing exactly that, so its verdict is the one a later reader recomputes.
-}
module Main (main) where

import Conformance.Cli.Admission (admit)
import Conformance.Cli.Backend (runControls)
import Conformance.Cli.Controls
    ( Receipt (..)
    , controlsStory
    , held
    , judge
    , renderControls
    )
import Data.Aeson (eitherDecodeFileStrict')
import Data.List (sort)
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath
    ( dropTrailingPathSeparator
    , takeDirectory
    , takeExtension
    , (</>)
    )
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["render", dir] -> render dir >>= exitWith
        ("run" : rest) -> runControls rest >>= render >>= exitWith
        _ -> do
            hPutStrLn stderr usage
            exitWith (ExitFailure 2)

usage :: String
usage =
    unlines
        [ "usage:"
        , "  cli-controls run --singular EXE --blueprint PLUTUS_JSON --ledger LEDGERS_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE --work DIR"
        , "  cli-controls render RECEIPTS_DIR"
        ]

-- | Judge the receipts in a directory and print the section they give.
render :: FilePath -> IO ExitCode
render dir = do
    names <-
        sort . filter ((== ".json") . takeExtension) <$> listDirectory dir
    -- Every receipt is admitted from the run's directory, the parent of
    -- its receipts, before any verdict is computed from it.
    let work = takeDirectory (dropTrailingPathSeparator dir)
    receipts <- mapM (\n -> readReceipt (dir </> n) >>= admit work) names
    let results = judge receipts controlsStory
    putStr (renderControls results controlsStory)
    pure (if held results then ExitSuccess else ExitFailure 1)
  where
    readReceipt :: FilePath -> IO Receipt
    readReceipt path =
        eitherDecodeFileStrict' path
            >>= either (\e -> fail ("receipt " <> path <> ": " <> e)) pure
