{- |
Module      : InsertActive.Narration
Description : The command's two output channels and its identity spelling
License     : Apache-2.0

Everything @insert-active@ prints goes through here: 'say' narrates a step
on standard output, 'die' names a failure on standard error and ends the
run with exit status 1. Both carry the @insert-active: @ prefix operators
and CI logs match on.

'die' ends the run by throwing 'ExitFailure', so inside the command's
outer handler it is reported a second time as
@insert-active: FAILED: ExitFailure 1@. That double line is the command's
existing diagnostic shape and is kept.
-}
module InsertActive.Narration
    ( say
    , die
    , hex
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

-- | Name a failure on standard error and end the run with status 1.
die :: String -> IO a
die msg = do
    hPutStrLn stderr ("insert-active: " <> msg)
    exitWith (ExitFailure 1)

-- | Narrate one step on standard output.
say :: String -> IO ()
say = putStrLn . ("insert-active: " <>)

-- | Lowercase hex, the spelling every identity in the observation uses.
hex :: ByteString -> T.Text
hex = TE.decodeUtf8 . Base16.encode
