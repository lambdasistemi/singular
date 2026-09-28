{- |
Module      : Journey.Narration
Description : How the journey narrates a step and names a failure
License     : Apache-2.0

Every line the journey prints on standard output is one 'emit',
@[journey] <step>: <what was observed>@; CI logs and the README's step
list are read against these step names. 'failWith' aborts with a
@journey: @-prefixed message, which the entry point reports as
@journey: FAILED: journey: ...@ with exit status 1; 'require' is
'failWith' for an observable that did not hold.
-}
module Journey.Narration (
    emit,
    require,
    failWith,
    hex,
    textOf,
) where

import Control.Exception (ErrorCall (..), throwIO)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

{- | One narration line: what the runner did and what it
observed.
-}
emit :: String -> String -> IO ()
emit stepName detail =
    putStrLn ("[journey] " <> stepName <> ": " <> detail)

-- | Fail the journey unless the observable holds.
require :: String -> Bool -> IO ()
require label cond =
    unless cond (failWith ("condition failed: " <> label))

-- | Abort the journey with a diagnosable message.
failWith :: String -> IO a
failWith msg = throwIO (ErrorCall ("journey: " <> msg))

-- | Lowercase hex for narration.
hex :: ByteString -> String
hex = T.unpack . TE.decodeUtf8 . Base16.encode

-- | Render a byte string as text for narration.
textOf :: ByteString -> String
textOf = T.unpack . TE.decodeUtf8
