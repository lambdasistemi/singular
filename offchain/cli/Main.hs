{- |
Module      : Main
Description : The packaged @singular@ command
License     : Apache-2.0

@singular registry create|insert|terminate|inspect@: one ordinary
process per command over a saved registry directory. See
"Singular.CLI.Command" for the command line and "Singular.CLI" for what
each command does.
-}
module Main (main) where

import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import Singular.CLI (runCommand)
import Singular.CLI.Command (parseCommand, renderCLIError, usage)

main :: IO ()
main = do
    args <- getArgs
    case parseCommand args of
        Left err -> do
            hPutStrLn stderr ("singular: " <> renderCLIError err)
            hPutStrLn stderr usage
            exitWith (ExitFailure 2)
        Right command -> runCommand command >>= exitWith
