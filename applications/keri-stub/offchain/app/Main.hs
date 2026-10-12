{- |
Module      : Main
Description : The packaged @keri-stub@ command
License     : Apache-2.0

@keri-stub create|register|convict|fold|status@:
one ordinary process per command over your state directory. See
"Singular.Application.KeriStub.Command" for the command line and
"Singular.Application.KeriStub.Run" for what each command does.
-}
module Main (main) where

import System.Environment (getArgs, getEnvironment)
import System.Exit (exitWith)

import Singular.Application.KeriStub.Root (runPackagedKeriStub)
import Singular.Application.KeriStub.Value (keriStubApplication)

main :: IO ()
main = do
    args <- getArgs
    environment <- getEnvironment
    runPackagedKeriStub keriStubApplication args environment
        >>= exitWith
