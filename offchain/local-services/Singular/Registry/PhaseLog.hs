{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.PhaseLog
Description : An opt-in, append-only, timestamped log of the phases a command runs
License     : Apache-2.0

When the environment variable @SINGULAR_LOG@ names a file, every phase a
command goes through appends one line to it: a JSON object with @ts@
(ISO-8601 UTC, millisecond precision) and @phase@, and the fields that
phase has. Unset or empty, nothing is created and nothing is written:
the log is neither the registry journal nor standard output.

The node read interface is logged by `Singular.Registry.Node.PhaseLog`: each view
acquisition (@view@, with its chain point and duration), each read
through it (@query@, with its name, duration and answer size), each
script evaluation (@eval@, with the ex-units it measured) and each view
release (@view-release@, with how long it was held). A command that
issues its reads through the provider it was handed cannot bypass it.
The commands' own phases (@build@, @sign@, @submit@, @confirm@) are
logged by "Singular.CLI.Session" through 'timedPhase'.

A line names what happened, never what it was said with: an operation's
failure is recorded as its outcome and the exception's type, never its
text, so that no key, credential or path an error message carries
reaches the file.
-}
module Singular.Registry.PhaseLog
    ( -- * The log
      PhaseLog
    , logEnvVar
    , phaseLogFromEnv
    , phaseLogAt
    , noPhaseLog
    , phaseLogEnabled

      -- * Lines
    , logPhase
    , timedPhase
    , queryPhase
    , startTimer
    , validityFields
    , isoNow
    ) where

import Control.Exception
    ( IOException
    , SomeException (..)
    , finally
    , throwIO
    , try
    )
import Control.Monad (unless, void)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
    ( defaultTimeLocale
    , formatTime
    , getCurrentTime
    )
import Data.Typeable (typeOf)
import GHC.Clock (getMonotonicTimeNSec)
import Lens.Micro ((^.))
import System.Environment (lookupEnv)
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , openFd
    )
import System.Posix.IO.ByteString (fdWrite)

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (vldtTxBodyL)
import Cardano.Ledger.BaseTypes (SlotNo (..), StrictMaybe (..))
import Cardano.Tx.Ledger (ConwayTx)
