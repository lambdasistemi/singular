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
    , runPackagedVia
    , standardError
    , containFailure
    , failureSentence
    ) where

import Control.Exception
    ( IOException
    , SomeAsyncException
    , SomeException
    , catch
    , displayException
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
    , stderr
    )
import System.IO.Error (ioeGetFileName)
import System.Posix.Files
    ( getFdStatus
    , isCharacterDevice
    , isNamedPipe
    , isRegularFile
    , isSocket
    )
import System.Posix.Types (Fd (..))

import Control.Tracer (Tracer)

import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( loadInvocationSources
    , parseInvocationFrom
    , refusalHint
    , renderCLIError
    , singularHint
    , singularVersion
    )
import Singular.CLI.Help (singularProgram)
import Singular.CLI.Options (builtinCommand)
import Singular.CLI.Session (Env, koiosEnv)
import Singular.CLI.Trace (Trace, withTracing)
import Singular.CLI.Vault (ioReason)
import Singular.Registry.Application (Application)

-- | Run one command line, with this environment and standard error.
runSingular
    :: Application
    -> Maybe Handle
    -> [(String, String)]
    -> [String]
    -> IO ExitCode
runSingular = runSingularVia koiosEnv

-- | The same, over the chain provider built from the composed tracer.
runSingularVia
    :: (Tracer IO Trace -> Env)
    -> Application
    -> Maybe Handle
    -> [(String, String)]
    -> [String]
    -> IO ExitCode
runSingularVia provider app errors environment args =
    builtinCommand (singularProgram singularVersion) args >>= \case
        Just code -> pure code
        Nothing ->
            loadInvocationSources environment args >>= \sources -> case parseInvocationFrom sources args of
                Left err -> do
                    case errors of
                        Just h -> do
                            quietly (hPutStrLn h ("singular: " <> renderCLIError err))
                            mapM_ (quietly . hPutStrLn h) (refusalHint err <> singularHint args)
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
                        (\tracer -> runCommand app (provider tracer) command)
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
runPackagedWith
    :: Application
    -> IO (Maybe Handle)
    -> [String]
    -> [(String, String)]
    -> IO ExitCode
runPackagedWith = runPackagedVia koiosEnv

{- | The packaged command over the chain provider built from the composed
tracer: every step of the packaged composition, its standard error taken,
its command line parsed, its tracing resolved and contained, and the command
run with that provider. The packaged binary is this with Koios.
-}
runPackagedVia
    :: (Tracer IO Trace -> Env)
    -> Application
    -> IO (Maybe Handle)
    -> [String]
    -> [(String, String)]
    -> IO ExitCode
runPackagedVia provider app getErrors args environment =
    containFailure "singular" $ do
        errors <- fromRight Nothing <$> attempt getErrors
        runSingularVia provider app errors environment args

-- | The packaged command with the process's own standard error.
runPackaged
    :: Application -> [String] -> [(String, String)] -> IO ExitCode
runPackaged app = runPackagedWith app standardError

{- | The last resort for a failure no command reported: one line on standard
error saying what failed, and status 1, in place of the runtime's own report of
an uncaught exception. A command that stops on purpose says so itself and never
comes here. An asynchronous exception, the interrupt that ends a run, goes on
through, and so does an exit.
-}
containFailure :: String -> IO ExitCode -> IO ExitCode
containFailure program act =
    act `catch` \e -> case fromException e of
        Just (async :: SomeAsyncException) -> throwIO async
        Nothing -> case fromException e of
            Just (code :: ExitCode) -> pure code
            Nothing -> do
                void
                    (attempt (hPutStrLn stderr (program <> ": " <> failureSentence e)))
                pure (ExitFailure 1)

{- | What failed in a sentence: a file that could not be used says which and
why, anything else its first line.
-}
failureSentence :: SomeException -> String
failureSentence e = unwords (words (takeWhile (/= '\n') said))
  where
    said = case fromException e of
        Just (io :: IOException) ->
            maybe "" (<> ": ") (ioeGetFileName io) <> ioReason io
        Nothing -> displayException e
