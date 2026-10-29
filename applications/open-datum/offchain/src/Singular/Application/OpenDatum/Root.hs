{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.Application.OpenDatum.Root
Description : The packaged @open-datum@ command, composed
License     : Apache-2.0

The composition root of the command: the command line parsed, the tracing
controls resolved against the process's standard error, @SINGULAR_LOG@ read,
the tracer built and the command run.

Mirrors 'Singular.CLI.Root' for the application's commands. Nothing tracing does
here can change the command's receipt, journal, outcome class or exit
status: every setup step runs inside the same containment as emission.
-}
module Singular.Application.OpenDatum.Root
    ( runOpenDatumSingular
    , runPackagedOpenDatum
    , runPackagedOpenDatumWith
    , runPackagedOpenDatumVia
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (void)
import Control.Tracer (Tracer)
import Data.Either (fromRight)
import Singular.Application.OpenDatum.Command
    ( loadOpenDatumSources
    , openDatumHint
    , openDatumRefusalHint
    , openDatumVersion
    , parseOpenDatumInvocationFrom
    , renderCLIError
    )
import Singular.Application.OpenDatum.Help (openDatumProgram)
import Singular.Application.OpenDatum.Run (runOpenDatum)
import Singular.CLI.Options (builtinCommand)
import Singular.CLI.Root (containFailure, standardError)
import Singular.CLI.Session (Env, koiosEnv)
import Singular.CLI.Trace (Trace, withTracing)
import Singular.Registry.Application (Application, neutralApplication)
import System.Exit (ExitCode (..))
import System.IO (Handle, hIsTerminalDevice, hPutStrLn)

-- | Run one open-datum command line, with this environment and standard error.
runOpenDatumSingular
    :: Application
    -> Maybe Handle
    -> [(String, String)]
    -> [String]
    -> IO ExitCode
runOpenDatumSingular = runOpenDatumSingularVia koiosEnv

-- | The same, over the chain provider built from the composed tracer.
runOpenDatumSingularVia
    :: (Tracer IO Trace -> Env)
    -> Application
    -> Maybe Handle
    -> [(String, String)]
    -> [String]
    -> IO ExitCode
runOpenDatumSingularVia provider _app errors environment args =
    builtinCommand (openDatumProgram openDatumVersion) args >>= \case
        Just code -> pure code
        Nothing ->
            loadOpenDatumSources environment args >>= \sources -> case parseOpenDatumInvocationFrom sources args of
                Left err -> do
                    case errors of
                        Just h -> do
                            quietly (hPutStrLn h ("open-datum: " <> renderCLIError err))
                            mapM_
                                (quietly . hPutStrLn h)
                                (openDatumRefusalHint err <> openDatumHint args)
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
                        (\tracer -> runOpenDatum (provider tracer) command)
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

{- | The packaged open-datum command with its standard error taken inside the same
containment as emission: a synchronous failure taking it leaves no handle
and its sink dropped, never an aborted command. Asynchronous exceptions
propagate.
-}
runPackagedOpenDatumWith
    :: Application
    -> IO (Maybe Handle)
    -> [String]
    -> [(String, String)]
    -> IO ExitCode
runPackagedOpenDatumWith = runPackagedOpenDatumVia koiosEnv

{- | The packaged open-datum command over the chain provider built from the composed
tracer: every step of the packaged composition, its standard error taken,
its command line parsed, its tracing resolved and contained, and the command
run with that provider. The packaged binary is this with Koios.
-}
runPackagedOpenDatumVia
    :: (Tracer IO Trace -> Env)
    -> Application
    -> IO (Maybe Handle)
    -> [String]
    -> [(String, String)]
    -> IO ExitCode
runPackagedOpenDatumVia provider app getErrors args environment =
    containFailure "open-datum" $ do
        errors <- fromRight Nothing <$> attempt getErrors
        runOpenDatumSingularVia provider app errors environment args

-- | The packaged open-datum command with the process's own standard error.
runPackagedOpenDatum
    :: [String] -> [(String, String)] -> IO ExitCode
runPackagedOpenDatum = runPackagedOpenDatumWith neutralApplication standardError
