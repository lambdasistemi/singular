module Main (main) where

import Conformance.Run (runRows)
import Control.Exception (SomeException, displayException, try)
import System.Environment (getArgs)
import System.Exit (exitFailure)

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["--receipts-dir", dir] -> do
            outcome <- try (runRows ["CG21"] dir) :: IO (Either SomeException ())
            case outcome of
                Left err -> do
                    putStrLn ("fold-budget regression: " <> displayException err)
                    exitFailure
                Right () -> putStrLn "fold-budget regression: fixed fallback refused; evaluated interpreter accepted"
        _ -> fail "usage: fold-budget-regression --receipts-dir DIR"
