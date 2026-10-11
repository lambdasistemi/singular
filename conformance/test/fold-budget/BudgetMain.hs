module Main (main) where

import Conformance.Run (runRows)
import Conformance.Run.Temporary (newTmpDirOwner)
import Control.Exception (SomeException, displayException, try)
import System.Environment (getArgs)
import System.Exit (exitFailure)

main :: IO ()
main = do
    owner <- newTmpDirOwner
    args <- getArgs
    case args of
        ["--receipts-dir", dir] -> do
            outcome <-
                try (runRows owner ["register-active-key"] dir)
                    :: IO (Either SomeException ())
            case outcome of
                Left err -> do
                    putStrLn ("fold-budget regression: " <> displayException err)
                    exitFailure
                Right () ->
                    putStrLn
                        "fold-budget regression: fixed fallback refused; evaluated interpreter accepted"
        _ -> fail "usage: fold-budget-regression --receipts-dir DIR"
