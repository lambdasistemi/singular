{- |
Module      : Main
Description : The packaged @singular@ command
License     : Apache-2.0

@singular registry create|insert|terminate|inspect@: one ordinary
process per command over a saved registry directory. See
"Singular.CLI.Command" for the command line and "Singular.CLI" for what
each command does.

This is the composition root of the command's tracing: the only place the
tracing controls are resolved, @SINGULAR_LOG@ is read and a tracer is built
("Singular.CLI.Trace").
-}
module Main (main) where

import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hIsTerminalDevice, hPutStrLn, stderr)

import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( parseInvocation
    , renderCLIError
    , usage
    )
import Singular.CLI.Session (koiosEnv)
import Singular.CLI.Trace (withTracing)

main :: IO ()
main = do
    args <- getArgs
    environment <- getEnvironment
    case parseInvocation environment args of
        Left err -> do
            hPutStrLn stderr ("singular: " <> renderCLIError err)
            hPutStrLn stderr usage
            exitWith (ExitFailure 2)
        Right (command, request) -> do
            terminal <- hIsTerminalDevice stderr
            withTracing
                terminal
                (phaseLog environment)
                request
                (\tracer -> runCommand (koiosEnv tracer) command)
                >>= exitWith
  where
    phaseLog environment = case lookup "SINGULAR_LOG" environment of
        Just path | not (null path) -> Just path
        _ -> Nothing
