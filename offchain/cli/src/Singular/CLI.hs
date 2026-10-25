{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI
Description : Run one parsed @singular@ command
License     : Apache-2.0

'runCommand' dispatches the registry commands and help. Each
command prints one receipt as JSON on standard output (and to
@--receipt FILE@ when given) and ends with the exit status of its
outcome class ("Singular.CLI.Finish"). A command that stops early
prints a receipt naming its outcome class and why; no secret is ever
printed.
-}
module Singular.CLI
    ( runCommand
    , runRegistryCommand
    ) where

import System.Exit (ExitCode (..))

import Data.Aeson (Value, toJSON)
import Singular.CLI.Command
    ( AddressArgs (..)
    , Command (..)
    , CreateArgs (..)
    , EntryMode (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , ReclaimArgs (..)
    , RejectArgs (..)
    , StateCreateArgs (..)
    , SubmitArgs (..)
    , walletAddressCommand
    , walletCreateCommand
    , walletSignCommand
    )
import Singular.CLI.Create
    ( announceCreated
    , createApplication
    , runCreate
    )
import Singular.CLI.Describe (runDescribeCommand)
import Singular.CLI.Finish (finish)
import Singular.CLI.Fold (runFold)
import Singular.CLI.Inspect (runInspect)
import Singular.CLI.Live (receipt)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Reclaim (runReclaim)
import Singular.CLI.Registry (registryFields)
import Singular.CLI.Reject (runReject)
import Singular.CLI.Session (Env (..), openWriteSigner)
import Singular.CLI.SettingsFile (keepStateToken)
import Singular.CLI.State (neutralHost, runStateCreate)
import Singular.CLI.Submit (submitBundle)
import Singular.Registry.Application (Application)
import Singular.Registry.StateToken (renderStateToken)

-- | Run one command in the environment the entry point composed; the exit status names its outcome class.
runCommand :: Application -> Env -> Command -> IO ExitCode
runCommand = runRegistryCommand

-- | Run one registry command (was runCommand): create, fold, reject, reclaim, inspect, help; no insert, update or terminate.
runRegistryCommand :: Application -> Env -> Command -> IO ExitCode
runRegistryCommand app env = \case
    Help text -> putStr text >> pure ExitSuccess
    Create a policy ->
        finish
            (envTracer env)
            "create"
            (createReceipt a)
            ( keepStateToken "singular" (createSaveStateTokenTo a) $
                openCreate a >>= \opened ->
                    createApplication app policy >>= \effective ->
                        runCreate effective env opened >>= announceCreated a
            )
    Fold a ->
        finish
            (envTracer env)
            "fold"
            (foldReceipt a)
            ( openWriteSigner (foldWrite a) >>= \ws -> runFold app env a{foldWrite = ws}
            )
    Reject a ->
        finish
            (envTracer env)
            "reject"
            (rejectReceipt a)
            ( openWriteSigner (rejectWrite a) >>= \ws -> runReject env a{rejectWrite = ws}
            )
    Reclaim a ->
        finish
            (envTracer env)
            "reclaim"
            (reclaimReceipt a)
            ( openWriteSigner (reclaimWrite a) >>= \ws -> runReclaim env a{reclaimWrite = ws}
            )
    StateCreate a ->
        finish
            (envTracer env)
            "state create"
            (stateCreateReceipt a)
            ( openWriteSigner (stateCreateWrite a) >>= \ws -> runStateCreate env neutralHost a{stateCreateWrite = ws}
            )
    Inspect a ->
        finish
            (envTracer env)
            "inspect"
            (inspectReceipt a)
            (runInspect app env a)
    Describe a -> runDescribeCommand app env a
    RegistryAddress a ->
        finish
            (envTracer env)
            "address"
            Nothing
            (pure (registryAddressReceipt a))
    WalletCreate a -> walletCreateCommand a
    WalletAddress a -> walletAddressCommand a
    WalletSign a -> walletSignCommand a
    SubmitBundle a ->
        submitBundle
            env
            app
            (submitProvider a)
            (submitBlueprint a)
            (submitBundlePath a)
            (submitWitnessPaths a)
            (submitReceipt a)

{- | The receipt of @registry address@: the registry's address (null on a
network with no prefix), its state token, its fingerprint and its network magic.
-}
registryAddressReceipt :: AddressArgs -> Value
registryAddressReceipt a =
    receipt
        "address"
        Success
        ( registryFields (addressMagic a) (addressToken a)
            <> [ ("stateToken", toJSON (renderStateToken (addressToken a)))
               , ("networkMagic", toJSON (addressMagic a))
               ]
        )

{- | A create's arguments with the vault its write names opened, before
anything else of the run; a preview names no signer to open.
-}
openCreate :: CreateArgs -> IO CreateArgs
openCreate a = case createMode a of
    Submit ws -> (\opened -> a{createMode = Submit opened}) <$> openWriteSigner ws
    Preview{} -> pure a
