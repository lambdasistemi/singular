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
    ) where

import System.Exit (ExitCode (..))

import Singular.CLI.Command
    ( Command (..)
    , CreateArgs (..)
    , EntryArgs (..)
    , FoldArgs (..)
    , InspectArgs (..)
    , ReclaimArgs (..)
    , RejectArgs (..)
    , usage
    )
import Singular.CLI.Create (runCreate)
import Singular.CLI.Entry (runInsert, runTerminate, runUpdate)
import Singular.CLI.Finish (finish)
import Singular.CLI.Fold (runFold)
import Singular.CLI.Inspect (runInspect)
import Singular.CLI.Reclaim (runReclaim)
import Singular.CLI.Reject (runReject)
import Singular.CLI.Session (Env (..))
import Singular.Registry.Application (Application)

-- | Run one command in the environment the entry point composed; the exit status names its outcome class.
runCommand :: Application -> Env -> Command -> IO ExitCode
runCommand app env = \case
    Help -> putStr usage >> pure ExitSuccess
    Create a ->
        finish
            (envTracer env)
            "create"
            (createReceipt a)
            (runCreate app env a)
    Insert a -> finish (envTracer env) "insert" (entryReceipt a) (runInsert env a)
    Update a -> finish (envTracer env) "update" (entryReceipt a) (runUpdate env a)
    Terminate a ->
        finish
            (envTracer env)
            "terminate"
            (entryReceipt a)
            (runTerminate env a)
    Fold a -> finish (envTracer env) "fold" (foldReceipt a) (runFold app env a)
    Reject a ->
        finish (envTracer env) "reject" (rejectReceipt a) (runReject env a)
    Reclaim a ->
        finish (envTracer env) "reclaim" (reclaimReceipt a) (runReclaim env a)
    Inspect a ->
        finish
            (envTracer env)
            "inspect"
            (inspectReceipt a)
            (runInspect app env a)
