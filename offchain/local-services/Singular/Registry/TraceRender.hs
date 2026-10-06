{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TraceRender
Description : The phase-log lines the provider-level events stand for, and the file they append to
License     : Apache-2.0

The @SINGULAR_LOG@ phase log is one renderer of the typed events of
"Singular.Registry.Trace": each event that the log has always recorded maps
to one JSON line, with @ts@ (ISO-8601 UTC, to the millisecond), @phase@ and
the fields that phase has always had. The mapping is a pure function; the
file writer appends each line whole in one write, so lines from concurrent
threads or processes do not interleave, and a log that cannot be written
never stops what it describes.

The command's entry point composes these into its tracer; a test composes
them the same way. Nothing here decides whether to log.
-}
module Singular.Registry.TraceRender
    ( -- * Phase-log lines
      readPhase
    , backendPhase
    , queryFields

      -- * The log file
    , appendPhaseLine
    , readPhaseLog
    , backendPhaseLog
    ) where

import Control.Exception (IOException, finally, try)
import Control.Monad (unless, void)
import Control.Tracer (Tracer (..))
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import System.Posix.IO
    ( OpenFileFlags (..)
    , OpenMode (..)
    , closeFd
    , defaultFileFlags
    , openFd
    )
import System.Posix.IO.ByteString (fdWrite)

import Singular.Registry.ProviderTrace (localSource, nodeSource)
import Singular.Registry.Trace
    ( BackendEvent (..)
    , BodyBuild (..)
    , BodyEnd (..)
    , ErrorClass (..)
    , Evaluation (..)
    , HorizonEnd (..)
    , HorizonWait (..)
    , Query (..)
    , QueryEnd (..)
    , ReadEvent (..)
    , ValiditySelection (..)
    , ViewOpening (..)
    , ViewRelease (..)
    , isoNow
    )

{- | The phase-log line of a provider-level event: its phase and fields. A
read at a provider boundary other than the node's view is not a phase-log
line: the log has always named a backend's own exchanges instead.
-}
readPhase :: ReadEvent -> Maybe (Text, [(Key, Value)])
readPhase = \case
    Queried q
        | querySource q `elem` [nodeSource, localSource] ->
            Just ("query", queryFields q)
        | otherwise -> Nothing
    ViewOpened opening -> Just ("view", openingFields opening)
    ViewReleased release -> Just ("view-release", releaseFields release)
    Evaluated e ->
        Just
            ( "eval"
            ,
                [ "redeemers" .= evalRedeemers e
                , "failed" .= evalFailed e
                , "mem" .= evalMemory e
                , "steps" .= evalSteps e
                ]
            )
    SessionOpened ms -> Just ("session-open", ["duration_ms" .= ms])
    HorizonWaited w ->
        Just
            ( "horizon-wait"
            , [ "tip" .= waitTip w
              , "horizon" .= waitHorizon w
              , "lower" .= waitLower w
              , "windowUpper" .= waitWindowUpper w
              , "minimumSlots" .= waitMinimumSlots w
              , "slotLimit" .= waitSlotLimit w
              , "wallLimitMs" .= waitWallLimitMs w
              , "duration_ms" .= waitElapsed w
              ]
                <> case waitEnd w of
                    HorizonMoved tip horizon ->
                        [ "outcome" .= ("ok" :: Text)
                        , "observedTip" .= tip
                        , "observedHorizon" .= horizon
                        ]
                    HorizonFailed c -> failed c
            )
    ValiditySelected v ->
        Just
            ( "validityUpper"
            ,
                [ "tip" .= selectedTip v
                , "horizon" .= selectedHorizon v
                , "lower" .= selectedLower v
                , "effectiveLower" .= selectedEffectiveLower v
                , "windowUpper" .= selectedWindowUpper v
                , "upper" .= selectedUpper v
                , "minimumSlots" .= selectedMinimumSlots v
                ]
            )
    BodyBuilt b ->
        Just
            ( "build-body"
            , [ "builder" .= bodyBuilder b
              , "duration_ms" .= bodyElapsed b
              ]
                <> case bodyEnd b of
                    BodyReady -> ["outcome" .= ("ok" :: Text)]
                    BodyRefused -> ["outcome" .= ("refused" :: Text)]
                    BodyFailed c -> failed c
            )

-- | The phase-log line of a backend's own mechanic.
backendPhase :: BackendEvent -> Maybe (Text, [(Key, Value)])
backendPhase = \case
    Exchanged q -> Just ("query", queryFields q)
    BackendViewOpened opening -> Just ("view", openingFields opening)
    BackendViewReleased release -> Just ("view-release", releaseFields release)

-- | The fields of a @query@ line.
queryFields :: Query -> [(Key, Value)]
queryFields q =
    ["query" .= queryName q]
        <> maybe [] (\s -> ["session" .= s]) (querySession q)
        <> ["duration_ms" .= queryElapsed q]
        <> case queryEnd q of
            Answered size ->
                ("outcome" .= ("ok" :: Text))
                    : maybe [] (\n -> ["answer_size" .= n]) size
            Lagged -> ["outcome" .= ("lag" :: Text), "answer_size" .= (1 :: Int)]
            QueryFailed c -> failed c

openingFields :: ViewOpening -> [(Key, Value)]
openingFields = \case
    NodeViewOpened ms slot hash era ->
        [ "duration_ms" .= ms
        , "outcome" .= ("ok" :: Text)
        , "slot" .= slot
        , "hash" .= hash
        , "era" .= era
        ]
    NodeViewFailed ms c -> ("duration_ms" .= ms) : failed c
    SessionViewOpened session binding -> ["session" .= session, "binding" .= binding]

releaseFields :: ViewRelease -> [(Key, Value)]
releaseFields = \case
    NodeViewHeld ms -> ["held_ms" .= ms]
    SessionViewClosed session -> ["session" .= session]

failed :: ErrorClass -> [(Key, Value)]
failed (ErrorClass c) = ["outcome" .= ("failed" :: Text), "error_class" .= c]

{- | Append one line: @ts@, @phase@ and the given fields, written whole in one
append. A file that cannot be opened or written is skipped.
-}
appendPhaseLine :: FilePath -> Text -> [(Key, Value)] -> IO ()
appendPhaseLine path phase fields = do
    stamp <- isoNow
    let line =
            BL.toStrict $
                Aeson.encode (object (["ts" .= stamp, "phase" .= phase] <> fields))
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

-- | The phase log of provider-level events, appended to a file.
readPhaseLog :: FilePath -> Tracer IO ReadEvent
readPhaseLog path =
    Tracer (maybe (pure ()) (uncurry (appendPhaseLine path)) . readPhase)

-- | The phase log of a backend's mechanics, appended to a file.
backendPhaseLog :: FilePath -> Tracer IO BackendEvent
backendPhaseLog path =
    Tracer
        (maybe (pure ()) (uncurry (appendPhaseLine path)) . backendPhase)
