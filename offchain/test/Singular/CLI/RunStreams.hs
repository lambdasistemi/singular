{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.RunStreams
Description : Run the packaged command and read what it wrote
License     : Apache-2.0

One packaged run of @singular@ ('runSingular') with the process's standard
output and standard error redirected to files, so a case can read the exit
status, what was printed and what was said, as a person at a terminal would.
-}
module Singular.CLI.RunStreams
    ( Ran
    , ran
    , ranWith
    , captured
    , said
    ) where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO (hFlush, stderr, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , dup
    , dupTo
    , openFd
    , stdError
    , stdOutput
    )
import System.Posix.Types (Fd)

import Singular.CLI.Root (runSingular)
import Singular.Registry.Application (Application, neutralApplication)

-- | What one packaged run returned and wrote: status, standard output, standard error.
type Ran = (ExitCode, ByteString, ByteString)

-- | The packaged command with this environment and these arguments.
ran :: [(String, String)] -> [String] -> IO Ran
ran = ranWith neutralApplication

-- | The same over an application.
ranWith :: Application -> [(String, String)] -> [String] -> IO Ran
ranWith app environment args =
    captured (runSingular app (Just stderr) environment args)

-- | An action's result with what it wrote to standard output and standard error.
captured :: IO a -> IO (a, ByteString, ByteString)
captured act = withSystemTempDirectory "run-streams" $ \dir -> do
    let outPath = dir </> "stdout"
        errPath = dir </> "stderr"
    a <- redirecting stdOutput outPath (redirecting stdError errPath act)
    (,,) a <$> BS.readFile outPath <*> BS.readFile errPath

redirecting :: Fd -> FilePath -> IO a -> IO a
redirecting target path act =
    bracket
        ( do
            hFlush stdout >> hFlush stderr
            saved <- dup target
            f <-
                openFd
                    path
                    WriteOnly
                    defaultFileFlags{creat = Just 0o644, trunc = True}
            _ <- dupTo f target
            closeFd f
            pure saved
        )
        ( \saved -> do
            hFlush stdout >> hFlush stderr
            _ <- dupTo saved target
            closeFd saved
        )
        (const act)

-- | The text of what was written.
said :: ByteString -> String
said = T.unpack . TE.decodeUtf8
