{- |
Module      : Main
Description : The packaged @open-datum@ command
License     : Apache-2.0

@open-datum create|insert|update|terminate|fold|inspect@:
one ordinary process per command over your state directory. See
"Singular.Application.OpenDatum.Command" for the command line and
"Singular.Application.OpenDatum.Run" for what each command does.
-}
module Main (main) where

import System.Environment (getArgs, getEnvironment)
import System.Exit (exitWith)

import Singular.Application.OpenDatum.Root (runPackagedOpenDatum)
import Singular.Application.OpenDatum.Value (openDatumApplication)

main :: IO ()
main = do
    args <- getArgs
    environment <- getEnvironment
    runPackagedOpenDatum openDatumApplication args environment
        >>= exitWith
