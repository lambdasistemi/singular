{-# LANGUAGE LambdaCase #-}

{- |
Module      : Main
Description : The packaged @singular-negative@ command
License     : Apache-2.0

@singular-negative registry insert|update|terminate|withdraw|fold|inspect@:
the same flags as @singular@, but the forbidden shapes are built for any
signer, submitted with no local evaluation, and judged from the node's
own verdict. Ordinary spellings run through the shared command; unknown
spellings are refused as the shared parser refuses them.
-}
module Main (main) where

import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn)

import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( Command (..)
    , EntryArgs (..)
    , FoldArgs (..)
    , parseInvocation
    , renderCLIError
    , usage
    )
import Singular.CLI.Finish (finish)
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Root (standardError)
import Singular.CLI.Session (Env (..), failWith, koiosEnv)
import Singular.CLI.Trace (TraceRequest, noTraceRequest, withTracing)

import Negative.Parse
    ( NegativeInvocation (..)
    , parseNegativeInvocation
    )
import Negative.Run
    ( runNegativeFold
    , runNegativeInsert
    , runNegativeTerminate
    , runNegativeUpdate
    , runNegativeWithdraw
    )

main :: IO ()
main = do
    args <- getArgs
    environment <- getEnvironment
    case parseNegativeInvocation environment args of
        Left err -> do
            errors <- standardError
            case errors of
                Just h -> do
                    hPutStrLn h ("singular-negative: " <> renderCLIError err)
                    hPutStrLn h usage
                Nothing -> pure ()
            exitWith (ExitFailure 2)
        Right invocation -> do
            errors <- standardError
            let request = requestOf environment args
                phaseLog = case lookup "SINGULAR_LOG" environment of
                    Just path | not (null path) -> Just path
                    _ -> Nothing
            withTracing errors False phaseLog request $ \tracer ->
                runNegative (koiosEnv tracer) invocation >>= exitWith

{- | Run one negative invocation in the composed environment. The three
negative forms run through the host handlers; ordinary insert and
terminate stop as not in this slice; inspect and help run through the
shared command; create, reject and reclaim are not host commands.
-}
runNegative :: Env -> NegativeInvocation -> IO ExitCode
runNegative env = \case
    Ordinary (Insert args) ->
        finish
            (envTracer env)
            "insert"
            (entryReceipt args)
            (runNegativeInsert env args)
    Ordinary (Terminate args) ->
        finish
            (envTracer env)
            "terminate"
            (entryReceipt args)
            (runNegativeTerminate env args)
    Ordinary cmd@(Inspect _) -> runCommand env cmd
    Ordinary Help -> runCommand env Help
    Ordinary _ ->
        failWith
            ClientRefusal
            "not a host command: create, reject and reclaim run with singular"
    NegativeWithdraw args ->
        finish
            (envTracer env)
            "withdraw"
            (entryReceipt args)
            (runNegativeWithdraw env args)
    NegativeUpdate args tamper ->
        finish
            (envTracer env)
            "update"
            (entryReceipt args)
            (runNegativeUpdate env args tamper)
    NegativeFold args short ->
        finish
            (envTracer env)
            "fold"
            (foldReceipt args)
            (runNegativeFold env args short)

{- | The trace request for one host invocation: the shared tracing
flags of the same spelling, or none when they do not parse.
-}
requestOf :: [(String, String)] -> [String] -> TraceRequest
requestOf env args = case parseInvocation env args of
    Right (_, request) -> request
    Left _ -> noTraceRequest
