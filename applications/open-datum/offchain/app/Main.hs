{- |
Module      : Main
Description : The packaged @open-datum@ command
License     : Apache-2.0

@open-datum state@, @open-datum registration@ and @open-datum holding@:
one ordinary process per command over your state directory. See
"Singular.Application.OpenDatum.Command" for the command line and
"Singular.Application.OpenDatum.Run" for what each command does.
-}
module Main (main) where

import System.Environment (getArgs, getEnvironment)
import System.Exit (exitWith)

import Singular.Application.OpenDatum.Root (runPackagedOpenDatum)
import Singular.CLI.Version (builtCommit, stampedEnvironment)

main :: IO ()
main = do
    args <- getArgs
    environment <- stampedEnvironment builtCommit <$> getEnvironment
    runPackagedOpenDatum args environment
        >>= exitWith
