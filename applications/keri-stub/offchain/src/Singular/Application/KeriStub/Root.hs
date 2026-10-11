{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.KeriStub.Root
Description : The packaged @keri-stub@ command, composed
License     : Apache-2.0

The composition root of the command: the command line parsed, the tracing
controls resolved against the process's standard error, @SINGULAR_LOG@ read,
the tracer built and the command run.

Mirrors 'Singular.CLI.Root' for the application's three verbs
(create, fold, status). Nothing tracing does
here can change the command's receipt, journal, outcome class or exit
status: every setup step runs inside the same containment as emission.
-}
module Singular.Application.KeriStub.Root
    ( runKeriStubSingular
    , runPackagedKeriStub
    , runPackagedKeriStubWith
    , runPackagedKeriStubVia
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (void)
import Data.Either (fromRight)
import System.Exit (ExitCode (..))
import System.IO
    ( Handle
    , hIsTerminalDevice
    , hPutStrLn
    )

import Control.Tracer (Tracer)

import Singular.Application.KeriStub.Command
    ( keriStubUsage
    , parseKeriStubInvocation
    , renderCLIError
    )
import Singular.Application.KeriStub.Run (runKeriStub)
import Singular.CLI.Root (standardError)
import Singular.CLI.Session (Env, koiosEnv)
import Singular.CLI.Trace (Trace, withTracing)
import Singular.Registry.Application (Application)

-- | Run one keri-stub command line, with this environment and standard error.
runKeriStubSingular
    :: Application
    -> Maybe Handle
    -> [(String, String)]
    -> [String]
    -> IO ExitCode
runKeriStubSingular = runKeriStubSingularVia koiosEnv

-- | The same, over the chain provider built from the composed tracer.
runKeriStubSingularVia
    :: (Tracer IO Trace -> Env)
    -> Application
    -> Maybe Handle
    -> [(String, String)]
    -> [String]
    -> IO ExitCode
runKeriStubSingularVia provider _app errors environment args =
    case parseKeriStubInvocation environment args of
        Left err -> do
            case errors of
                Just h -> do
                    quietly (hPutStrLn h ("keri-stub: " <> renderCLIError err))
                    quietly (hPutStrLn h keriStubUsage)
                Nothing -> pure ()
            pure (ExitFailure 2)
        Right (command, request) -> do
            terminal <- case errors of
                Nothing -> pure False
                Just h ->
                    fromRight False <$> attempt (hIsTerminalDevice h)
            withTracing
                errors
                terminal
                (phaseLog environment)
                request
                (\tracer -> runKeriStub (provider tracer) command)
  where
    phaseLog env = case lookup "SINGULAR_LOG" env of
        Just path | not (null path) -> Just path
        _ -> Nothing
    quietly act = void (attempt act)

-- | Run an action, its synchronous failure returned; an asynchronous one propagates.
attempt :: IO a -> IO (Either SomeException a)
attempt act =
    try act >>= \case
        Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        other -> pure other

{- | The packaged keri-stub command with its standard error taken inside the same
containment as emission: a synchronous failure taking it leaves no handle
and its sink dropped, never an aborted command. Asynchronous exceptions
propagate.
-}
runPackagedKeriStubWith
    :: Application
    -> IO (Maybe Handle)
    -> [String]
    -> [(String, String)]
    -> IO ExitCode
runPackagedKeriStubWith = runPackagedKeriStubVia koiosEnv

{- | The packaged keri-stub command over the chain provider built from the composed
tracer: every step of the packaged composition, its standard error taken,
its command line parsed, its tracing resolved and contained, and the command
run with that provider. The packaged binary is this with Koios.
-}
runPackagedKeriStubVia
    :: (Tracer IO Trace -> Env)
    -> Application
    -> IO (Maybe Handle)
    -> [String]
    -> [(String, String)]
    -> IO ExitCode
runPackagedKeriStubVia provider app getErrors args environment = do
    errors <- fromRight Nothing <$> attempt getErrors
    runKeriStubSingularVia provider app errors environment args

-- | The packaged keri-stub command with the process's own standard error.
runPackagedKeriStub
    :: Application -> [String] -> [(String, String)] -> IO ExitCode
runPackagedKeriStub app = runPackagedKeriStubWith app standardError
