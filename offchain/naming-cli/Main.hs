{- |
Module      : Main
Description : Naming registry management executable
License     : Apache-2.0
-}
module Main (main) where

import Control.Exception (SomeException, catch, displayException)
import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL
import Naming.CLI.Change (runChange)
import Naming.CLI.Options (Command (..), Options (..), parserInfo)
import Naming.CLI.Read (runRead)
import Options.Applicative (execParser)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    options <- execParser parserInfo
    let run = case command options of
            ChangeRecord payer name controller change -> runChange (connection options) payer name controller change
            _ -> runRead options
    (run >>= BL.putStrLn . encode) `catch` \(err :: SomeException) -> do
        hPutStrLn stderr ("singular-naming: " <> displayException err)
        exitFailure
