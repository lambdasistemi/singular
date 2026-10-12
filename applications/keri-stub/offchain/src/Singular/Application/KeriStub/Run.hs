{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.Run
Description : Run one parsed @keri-stub@ command
License     : Apache-2.0

'runKeriStub' dispatches the keri-stub commands and help. Each
command prints one receipt as JSON on standard output (and to
@--receipt FILE@ when given) and ends with the exit status of its
outcome class ("Singular.CLI.Finish"). Create, fold and status are thin
calls to the library with the keri-stub value; register is the entry
command this package owns.
-}
module Singular.Application.KeriStub.Run
    ( runKeriStub
    ) where

import System.Exit (ExitCode (..))

import Singular.Application.KeriStub.Command
    ( KeriStubCommand (..)
    , keriStubUsage
    )
import Singular.Application.KeriStub.Register (runRegister)
import Singular.Application.KeriStub.Value (keriStubApplication)
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

-- | Run one keri-stub command in the environment the entry point composed.
runKeriStub :: Env -> KeriStubCommand -> IO ExitCode
runKeriStub env = \case
    KeriHelp -> putStr keriStubUsage >> pure ExitSuccess
    KeriCreate a ->
        finish
            (envTracer env)
            "create"
            (createReceipt a)
            (runCreate keriStubApplication env a)
    KeriRegister a ->
        finish
            (envTracer env)
            "register"
            (entryReceipt a)
            (runRegister env a)
    KeriFold a ->
        finish
            (envTracer env)
            "fold"
            (foldReceipt a)
            (runFold keriStubApplication env a)
    KeriStatus a ->
        finish
            (envTracer env)
            "status"
            (inspectReceipt a)
            (runInspect keriStubApplication env a)
