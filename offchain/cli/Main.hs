{- |
Module      : Main
Description : The packaged @singular@ command
License     : Apache-2.0

@singular registry create|insert|update|terminate|fold|reject|reclaim|inspect@:
one ordinary process per command over your state directory. See
"Singular.CLI.Command" for the command line, "Singular.CLI" for what each
command does and "Singular.CLI.Root" for the composition this runs.
-}
module Main (main) where

import System.Environment (getArgs, getEnvironment)
import System.Exit (exitWith)

import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Root (runPackaged)

main :: IO ()
main = do
    args <- getArgs
    environment <- getEnvironment
    runPackaged openDatumApplication args environment >>= exitWith
