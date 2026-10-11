{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Run
Description : Run one parsed @open-datum@ command
License     : Apache-2.0

'runOpenDatum' dispatches the open-datum commands and help. Each
command prints one receipt as JSON on standard output (and to
@--receipt FILE@ when given) and ends with the exit status of its
outcome class ("Singular.CLI.Finish"). Create, fold and inspect are thin
calls to the library with the open-datum value; insert, update and
terminate are the entry commands this package owns.
-}
module Singular.Application.OpenDatum.Run
    ( runOpenDatum
    ) where

import System.Exit (ExitCode (..))

import Singular.Application.OpenDatum.Command
    ( OpenDatumCommand (..)
    , openDatumUsage
    )
import Singular.Application.OpenDatum.Entry
    ( runInsert
    , runTerminate
    , runUpdate
    )
import Singular.Application.OpenDatum.Value (openDatumApplication)
import Singular.CLI.Command
    ( CreateArgs (..)
    , EntryArgs (..)
    , FoldArgs (..)
    , InspectArgs (..)
    )
import Singular.CLI.Create (runCreate)
import Singular.CLI.Finish (finish)
import Singular.CLI.Fold (runFold)
import Singular.CLI.Inspect (runInspect)
import Singular.CLI.Session (Env (..))

-- | Run one open-datum command in the environment the entry point composed.
runOpenDatum :: Env -> OpenDatumCommand -> IO ExitCode
runOpenDatum env = \case
    OpenHelp -> putStr openDatumUsage >> pure ExitSuccess
    OpenCreate a ->
        finish
            (envTracer env)
            "create"
            (createReceipt a)
            (runCreate openDatumApplication env a)
    OpenInsert a ->
        finish
            (envTracer env)
            "insert"
            (entryReceipt a)
            (runInsert env a)
    OpenUpdate a ->
        finish
            (envTracer env)
            "update"
            (entryReceipt a)
            (runUpdate env a)
    OpenTerminate a ->
        finish
            (envTracer env)
            "terminate"
            (entryReceipt a)
            (runTerminate env a)
    OpenFold a ->
        finish
            (envTracer env)
            "fold"
            (foldReceipt a)
            (runFold openDatumApplication env a)
    OpenInspect a ->
        finish
            (envTracer env)
            "inspect"
            (inspectReceipt a)
            (runInspect openDatumApplication env a)
