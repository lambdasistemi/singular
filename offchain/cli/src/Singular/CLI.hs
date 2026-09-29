{- |
Module      : Singular.CLI
Description : Run one parsed @singular@ command
License     : Apache-2.0

'runCommand' dispatches the four registry commands and help. Each
command prints one receipt as JSON on standard output and ends with the
exit status of its outcome class ("Singular.CLI.Receipt").
-}
module Singular.CLI
    ( runCommand
    ) where

import System.Exit (ExitCode (..))

import Singular.CLI.Command (Command)

-- | Run one command; the exit status names its outcome class.
runCommand :: Command -> IO ExitCode
runCommand _ = do
    putStrLn "singular: not implemented"
    pure (ExitFailure 1)
