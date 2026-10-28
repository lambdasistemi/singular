{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.Run
Description : Run one parsed @open-datum@ command
License     : Apache-2.0

'runOpenDatum' dispatches the open-datum commands and help. Each
write prints one receipt as JSON on standard output (and to
@--receipt FILE@ when given) and ends with the exit status of its
outcome class ("Singular.CLI.Finish"). The state, registration and holding
commands use the request contract and open their explicit signer before running.
Inspection uses no signer and prints human text by default or one JSON answer
when requested, with its reader-specific exit statuses.
-}
module Singular.Application.OpenDatum.Run
    ( runOpenDatum
    ) where

import Singular.Application.OpenDatum.Command
    ( BookArgs (..)
    , HoldingArgs (..)
    , OpenDatumCommand (..)
    , PendingArgs (..)
    , StateCreateArgs (..)
    , StateFoldArgs (..)
    )
import Singular.Application.OpenDatum.Inspect (openDatumInspection)
import Singular.Application.OpenDatum.Registration
    ( openDatumHost
    , runBook
    , runCleanup
    , runHoldingTerminate
    , runHoldingUpdate
    , runReclaim
    )
import Singular.Application.OpenDatum.Requests.Records
    ( RequestParameters (..)
    )
import Singular.CLI.Finish (finish)
import Singular.CLI.Inspect (runReader)
import Singular.CLI.Receipt (OutcomeClass (ClientRefusal))
import Singular.CLI.Session (Env (..), failWith, openWriteSigner)
import Singular.CLI.State (runStateCreate, runStateFold)
import System.Exit (ExitCode (..))

-- | Run one open-datum command in the environment the entry point composed.
runOpenDatum :: Env -> OpenDatumCommand -> IO ExitCode
runOpenDatum env = \case
    OpenInspect a -> runReader env a openDatumInspection
    OpenHelp text -> putStr text >> pure ExitSuccess
    OpenInsert _ ->
        failWith
            ClientRefusal
            "this internal preparation value is not a public command"
    OpenUpdate _ ->
        failWith
            ClientRefusal
            "this internal preparation value is not a public command"
    OpenTerminate _ ->
        failWith
            ClientRefusal
            "this internal preparation value is not a public command"
    OpenStateCreate a parameters ->
        finish
            (envTracer env)
            "create"
            (stateCreateReceipt a)
            ( openWriteSigner (stateCreateWrite a)
                >>= \ws ->
                    runStateCreate
                        "create"
                        env
                        (openDatumHost parameters)
                        a{stateCreateWrite = ws}
            )
    OpenStateFold a ->
        finish
            (envTracer env)
            "fold"
            (stateFoldReceipt a)
            ( openWriteSigner (stateFoldWrite a)
                >>= \ws ->
                    runStateFold env (openDatumHost noParameters) a{stateFoldWrite = ws}
            )
    OpenHoldingUpdate a path schema ->
        finish
            (envTracer env)
            "update"
            (holdingArgsReceipt a)
            ( openWriteSigner (holdingArgsWrite a) >>= \ws -> runHoldingUpdate env a{holdingArgsWrite = ws} path schema
            )
    OpenHoldingTerminate a ->
        finish
            (envTracer env)
            "terminate"
            (holdingArgsReceipt a)
            ( openWriteSigner (holdingArgsWrite a) >>= \ws -> runHoldingTerminate env a{holdingArgsWrite = ws}
            )
    OpenRegistrationBook a ->
        finish
            (envTracer env)
            "insert"
            (bookArgsReceipt a)
            ( openWriteSigner (bookArgsWrite a)
                >>= \ws -> runBook env a{bookArgsWrite = ws}
            )
    OpenRegistrationReclaim a ->
        finish
            (envTracer env)
            "reclaim"
            (pendingArgsReceipt a)
            ( openWriteSigner (pendingArgsWrite a)
                >>= \ws -> runReclaim env a{pendingArgsWrite = ws}
            )
    OpenRegistrationCleanup a ->
        finish
            (envTracer env)
            "cleanup"
            (pendingArgsReceipt a)
            ( openWriteSigner (pendingArgsWrite a)
                >>= \ws -> runCleanup env a{pendingArgsWrite = ws}
            )

{- | The parameters of a registry's configuration, none of which a fold reads: the
fold creates nothing.
-}
noParameters :: RequestParameters
noParameters =
    RequestParameters
        { rpRegistrationCost = 0
        , rpMinimumTip = 0
        , rpProcessTime = 0
        , rpRetractTime = 0
        , rpBookingWidth = 0
        }
