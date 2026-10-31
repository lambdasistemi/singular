{- |
Module      : Singular.CLI.Plan
Description : Reading a JSON document a command names
License     : Apache-2.0

The one check a command makes of a caller's input before it builds anything:
the document it names is read, or the command is refused with the reason.
Entry-specific planning lives in the application, which depends on this
library; this module names no application.
-}
module Singular.CLI.Plan
    ( readJson
    ) where

import Data.Aeson qualified as Aeson

import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.CLI.Session (failWith)

-- | A JSON document the caller named, or a client refusal saying why not.
readJson :: FilePath -> IO Aeson.Value
readJson path =
    Aeson.eitherDecodeFileStrict' path
        >>= either (failWith ClientRefusal . ((path <> ": ") <>)) pure
