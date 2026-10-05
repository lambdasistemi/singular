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

The node read interface is logged by "Singular.Registry.Node.PhaseLog": each view
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

-- | Where phase lines go, or nowhere.
newtype PhaseLog = PhaseLog (Maybe FilePath)

-- | The environment variable naming the log file.
logEnvVar :: String
logEnvVar = "SINGULAR_LOG"

{- | The log the process's environment asks for: the file @SINGULAR_LOG@
names, or none when it is unset or empty.
-}
phaseLogFromEnv :: IO PhaseLog
phaseLogFromEnv = PhaseLog . named <$> lookupEnv logEnvVar
  where
    named = \case
        Just path | not (null path) -> Just path
        _ -> Nothing

-- | A log appended to this file.
phaseLogAt :: FilePath -> PhaseLog
phaseLogAt = PhaseLog . Just

-- | No log: every operation on it does nothing.
noPhaseLog :: PhaseLog
noPhaseLog = PhaseLog Nothing

-- | Whether lines are being written.
phaseLogEnabled :: PhaseLog -> Bool
phaseLogEnabled (PhaseLog p) = isJust p

{- | Append one line: @ts@, @phase@ and the given fields. The line is
written whole in one append, so lines from concurrent threads or
processes do not interleave. A log that cannot be written never stops
the command it describes.
-}
logPhase :: PhaseLog -> Text -> [(Key, Value)] -> IO ()
logPhase (PhaseLog Nothing) _ _ = pure ()
logPhase (PhaseLog (Just path)) phase fields = do
    stamp <- isoNow
    let line =
            BL.toStrict $
                Aeson.encode
                    ( object $
                        ["ts" .= stamp, "phase" .= phase] <> fields
                    )
                    <> "\n"
    void (try @IOException (appendBytes path line))

appendBytes :: FilePath -> ByteString -> IO ()
appendBytes path bytes = do
    fd <-
        openFd
            path
            WriteOnly
            defaultFileFlags{append = True, creat = Just 0o644}
    writeAll fd bytes `finally` closeFd fd
  where
    writeAll fd b = unless (BS.null b) $ do
        n <- fdWrite fd b
        writeAll fd (BS.drop (fromIntegral n) b)

{- | Run an action and log one line for it: @duration_ms@ and
@outcome@, the given fields before it and, when it returns, those the
result yields (which may replace the outcome). An action that throws
is logged @failed@ with the exception's type and throws again.
-}
timedPhase
    :: PhaseLog
    -> Text
    -> [(Key, Value)]
    -> (a -> [(Key, Value)])
    -> IO a
    -> IO a
timedPhase lg phase before after act
    | not (phaseLogEnabled lg) = act
    | otherwise = do
        elapsed <- startTimer
        try @SomeException act >>= \case
            Right a -> do
                ms <- elapsed
                logPhase lg phase $
                    merge
                        (before <> ["duration_ms" .= ms, "outcome" .= ("ok" :: Text)])
                        (after a)
                pure a
            Left e@(SomeException inner) -> do
                ms <- elapsed
                logPhase lg phase . merge before $
                    [ "duration_ms" .= ms
                    , "outcome" .= ("failed" :: Text)
                    , "error_class" .= show (typeOf inner)
                    ]
                throwIO e
  where
    merge base overriding =
        KeyMap.toList
            (KeyMap.fromList overriding `KeyMap.union` KeyMap.fromList base)

{- | One node or index query, as a line: its name, its duration and the
size of its answer.
-}
queryPhase :: PhaseLog -> Text -> (a -> Int) -> IO a -> IO a
queryPhase lg name size =
    timedPhase
        lg
        "query"
        ["query" .= name]
        (\a -> ["answer_size" .= size a])

{- | Start a monotonic timer; the action it returns reads the
milliseconds elapsed since.
-}
startTimer :: IO (IO Double)
startTimer = do
    t0 <- getMonotonicTimeNSec
    pure $ do
        t1 <- getMonotonicTimeNSec
        pure (fromIntegral ((t1 - t0) `div` 1_000) / 1_000)

{- | The validity interval a transaction carries, as the lines of a
submission name it: the slot each bound is, or null for a bound it does
not have.
-}
validityFields :: ConwayTx -> [(Key, Value)]
validityFields tx =
    [ "validity_lower" .= slot (invalidBefore vldt)
    , "validity_upper" .= slot (invalidHereafter vldt)
    ]
  where
    vldt = tx ^. bodyTxL . vldtTxBodyL
    slot = \case
        SJust (SlotNo s) -> Just s
        SNothing -> Nothing

-- | The current time, ISO-8601 UTC, to the millisecond.
isoNow :: IO Text
isoNow =
    T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%3QZ"
        <$> getCurrentTime
