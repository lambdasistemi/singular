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
import Conformance.Cli.Backend (runAttach, runControls)
import Conformance.Cli.Controls
    ( Receipt (..)
    , Story
    , controlsStory
    , held
    , judge
    , permanentStory
    , renderControls
    )
import Data.Aeson (eitherDecodeFileStrict')
import Data.List (sort)
import Data.Text qualified as T
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
        ["render", dir] -> render controlsStory dir >>= exitWith
        ["render", "--attach-key", key, dir] ->
            render (permanentStory key) dir >>= exitWith
        ("run" : rest) -> runControls rest >>= render controlsStory >>= exitWith
        ("attach" : rest) -> case keyOf rest of
            Just key -> do
                (dir, stopped) <- runAttach rest
                verdict <- render (permanentStory key) dir
                case stopped of
                    Just why -> do
                        hPutStrLn stderr ("cli-controls: the take stopped: " <> T.unpack why)
                        exitWith (ExitFailure 1)
                    Nothing -> exitWith verdict
            Nothing -> do
                hPutStrLn stderr "cli-controls: attach needs --key"
                exitWith (ExitFailure 2)
        _ -> do
            hPutStrLn stderr usage
            exitWith (ExitFailure 2)

usage :: String
usage =
    unlines
        [ "usage:"
        , "  cli-controls run --singular EXE --blueprint PLUTUS_JSON --ledger LEDGERS_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE --work DIR"
        , "  cli-controls attach --singular EXE --blueprint PLUTUS_JSON --ledger LEDGERS_JSON"
        , "      --node-socket PATH --network-magic N --wallet-skey FILE --stranger-skey FILE"
        , "      --registry DIR --key LABEL --work DIR"
        , "      --collateral-allowance LOVELACE [--max-outlay LOVELACE]"
        , "  cli-controls render RECEIPTS_DIR"
        , "  cli-controls render --attach-key LABEL RECEIPTS_DIR"
        ]

-- | The key a take names, from its options.
keyOf :: [String] -> Maybe String
keyOf ("--key" : key : _) = Just key
keyOf (_ : rest) = keyOf rest
keyOf [] = Nothing

-- | Judge the receipts in a directory and print the section they give.
render :: Story () -> FilePath -> IO ExitCode
render story dir = do
    names <-
        sort . filter ((== ".json") . takeExtension) <$> listDirectory dir
    -- Every receipt is admitted from the run's directory, the parent of
    -- its receipts, before any verdict is computed from it.
    let work = takeDirectory (dropTrailingPathSeparator dir)
    receipts <- mapM (\n -> readReceipt (dir </> n) >>= admit work) names
    let results = judge receipts story
    putStr (renderControls results story)
    pure (if held results then ExitSuccess else ExitFailure 1)
  where
    readReceipt :: FilePath -> IO Receipt
    readReceipt path =
        eitherDecodeFileStrict' path
            >>= either (\e -> fail ("receipt " <> path <> ": " <> e)) pure
