{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Root
Description : The packaged @singular@ command, composed
License     : Apache-2.0

The composition root of the command: the command line parsed, the tracing
controls resolved against the process's standard error, @SINGULAR_LOG@ read,
the tracer built and the command run. @main@ is this with the process's own
arguments, environment and standard error.

Nothing tracing does here can change the command's receipt, journal, outcome
class or exit status: every setup step runs inside the same containment as
emission. A standard error that cannot be asked whether it is a terminal is
taken as not one; when no standard error is available its sink is dropped;
sinks open nothing until they write and contain what they throw, and a
diagnostic that cannot be written is dropped.
-}
module Singular.CLI.Root
    ( runSingular
    , runPackaged
    , runPackagedWith
    , standardError
    ) where

import Control.Exception
    ( SomeAsyncException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import System.Exit (ExitCode (..))
import System.IO
    ( Handle
    , hIsTerminalDevice
    , hPutStrLn
    , stderr
    )
import System.Posix.Files
    ( getFdStatus
    , isCharacterDevice
    , isNamedPipe
    , isRegularFile
    , isSocket
    )
import System.Posix.Types (Fd (..))

import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( parseInvocation
    , renderCLIError
    , usage
    )
import Singular.CLI.Session (koiosEnv)
import Singular.CLI.Trace (withTracing)

-- | Run one command line, with this environment and standard error.
runSingular :: Maybe Handle -> [(String, String)] -> [String] -> IO ExitCode
runSingular errors environment args =
    case parseInvocation environment args of
        Left err -> do
            case errors of
                Just h -> do
                    quietly (hPutStrLn h ("singular: " <> renderCLIError err))
                    quietly (hPutStrLn h usage)
                Nothing -> pure ()
            pure (ExitFailure 2)
        Right (command, request) -> do
            terminal <- case errors of
                Nothing -> pure False
                Just h ->
                    either (const False) id <$> attempt (hIsTerminalDevice h)
            withTracing
                errors
                terminal
                (phaseLog environment)
                request
                (\tracer -> runCommand (koiosEnv tracer) command)
  where
    phaseLog env = case lookup "SINGULAR_LOG" env of
        Just path | not (null path) -> Just path
        _ -> Nothing
    quietly act = () <$ attempt act

-- | Run an action, its synchronous failure returned; an asynchronous one propagates.
attempt :: IO a -> IO (Either SomeException a)
attempt act =
    try act >>= \case
        Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        other -> pure other

{- | The process's standard error, when descriptor 2 is one: a file, a pipe,
a terminal or a socket. A process started with it closed finds that number
taken by the runtime's own descriptors (a timer, an event queue), and writing
there would corrupt them; standard error is then unavailable and its sink is
dropped. No file is opened here, so this cannot fail synchronously.
-}
standardError :: IO (Maybe Handle)
standardError = do
    usable <-
        either (const False) streamLike <$> attempt (getFdStatus (Fd 2))
    pure (if usable then Just stderr else Nothing)
  where
    streamLike s =
        any ($ s) [isRegularFile, isCharacterDevice, isNamedPipe, isSocket]

{- | The packaged command with its standard error taken inside the same
containment as emission: a synchronous failure taking it leaves no handle
and its sink dropped, never an aborted command. Asynchronous exceptions
propagate.
-}
runPackagedWith :: IO (Maybe Handle) -> [String] -> [(String, String)] -> IO ExitCode
runPackagedWith getErrors args environment = do
    errors <- either (const Nothing) id <$> attempt getErrors
    runSingular errors environment args

-- | The packaged command with the process's own standard error.
runPackaged :: [String] -> [(String, String)] -> IO ExitCode
runPackaged = runPackagedWith standardError
