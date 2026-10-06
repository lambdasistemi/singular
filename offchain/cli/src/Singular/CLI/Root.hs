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
class or exit status: a standard error that cannot be asked whether it is a
terminal is taken as not one, sinks open nothing until they write and contain
what they throw, and a diagnostic that cannot be written is dropped.
-}
module Singular.CLI.Root
    ( runSingular
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
    , IOMode (WriteMode)
    , hClose
    , hIsTerminalDevice
    , hPutStrLn
    , openFile
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
runSingular :: Handle -> [(String, String)] -> [String] -> IO ExitCode
runSingular errors environment args =
    case parseInvocation environment args of
        Left err -> do
            quietly (hPutStrLn errors ("singular: " <> renderCLIError err))
            quietly (hPutStrLn errors usage)
            pure (ExitFailure 2)
        Right (command, request) -> do
            terminal <-
                either (const False) id <$> attempt (hIsTerminalDevice errors)
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
there would corrupt them; standard error is then a closed handle, which every
write treats as a sink that fails.
-}
standardError :: IO Handle
standardError = do
    usable <-
        either (const False) streamLike <$> attempt (getFdStatus (Fd 2))
    if usable
        then pure stderr
        else do
            closed <- openFile "/dev/null" WriteMode
            hClose closed
            pure closed
  where
    streamLike s =
        any ($ s) [isRegularFile, isCharacterDevice, isNamedPipe, isSocket]
