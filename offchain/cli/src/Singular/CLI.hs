{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI
Description : Run one parsed @singular@ command
License     : Apache-2.0

'runCommand' dispatches the registry commands and help. Each
write prints one receipt as JSON on standard output (and to
@--receipt FILE@ when given) and ends with the exit status of its
outcome class ("Singular.CLI.Finish"). A command that stops early
prints a receipt naming its outcome class and why; no secret is ever
printed. Read-only inspection prints human text by default or one JSON answer
when requested, with its reader-specific exit statuses.
-}
module Singular.CLI
    ( runCommand
    , runRegistryCommand
    ) where

import Singular.CLI.Command
    ( Command (..)
    , StateCreateArgs (..)
    , SubmitArgs (..)
    , walletAddressCommand
    , walletCreateCommand
    , walletSignCommand
    )
import Singular.CLI.Finish (finish)
import Singular.CLI.Inspect (neutralInspection, runReader)
import Singular.CLI.Session (Env (..), openWriteSigner)
import Singular.CLI.State (neutralHost, runStateCreate)
import Singular.CLI.Submit (submitBundle)
import Singular.Registry.Application (Application)
import System.Exit (ExitCode (..))

-- | Run one command in the environment the entry point composed; the exit status names its outcome class.
runCommand :: Application -> Env -> Command -> IO ExitCode
runCommand = runRegistryCommand

-- | Run one registry command (was runCommand): registry create, wallet, submit and help.
runRegistryCommand :: Application -> Env -> Command -> IO ExitCode
runRegistryCommand _app env = \case
    Help text -> putStr text >> pure ExitSuccess
    Fold _ -> pure (ExitFailure 2)
    RegistryInspect a -> runReader "registry inspect" env a neutralInspection
    StateCreate a ->
        finish
            (envTracer env)
            "registry create"
            (stateCreateReceipt a)
            ( openWriteSigner (stateCreateWrite a) >>= \ws ->
                runStateCreate
                    "registry create"
                    env
                    neutralHost
                    a{stateCreateWrite = ws}
            )
    WalletCreate a -> walletCreateCommand a
    WalletAddress a -> walletAddressCommand a
    WalletSign a -> walletSignCommand a
    SubmitBundle a ->
        submitBundle
            env
            (submitProvider a)
            (submitBundlePath a)
            (submitWitnessPaths a)
            (submitReceipt a)
