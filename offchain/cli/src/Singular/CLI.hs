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

import Control.Tracer (Tracer)
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
import Singular.CLI.Trace (Trace)

-- | Run one command, tracing into the given tracer; the exit status names its outcome class.
runCommand :: Tracer IO Trace -> Command -> IO ExitCode
runCommand tracer = \case
    Help -> putStr usage >> pure ExitSuccess
    Create a -> finish tracer "create" (createReceipt a) (runCreate tracer a)
    Insert a -> finish tracer "insert" (entryReceipt a) (runInsert tracer a)
    Update a -> finish tracer "update" (entryReceipt a) (runUpdate tracer a)
    Terminate a -> finish tracer "terminate" (entryReceipt a) (runTerminate tracer a)
    Fold a -> finish tracer "fold" (foldReceipt a) (runFold tracer a)
    Reject a -> finish tracer "reject" (rejectReceipt a) (runReject tracer a)
    Reclaim a -> finish tracer "reclaim" (reclaimReceipt a) (runReclaim tracer a)
    Inspect a -> finish tracer "inspect" (inspectReceipt a) (runInspect tracer a)
