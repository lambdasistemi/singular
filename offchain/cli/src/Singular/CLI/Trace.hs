{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Trace
Description : One typed event stream per command, and its renderers
License     : Apache-2.0

Every @singular@ command reports what it does as one stream of typed events:
the protocol actions and verdicts ('What') and the mechanics under each
('How'). Each event carries its scope path, outermost first: the registry,
the key or request, the edge action, the transaction. An inner layer traces
its own small event type; the enclosing scope adds the context it knows by
'within', so no inner function passes identifiers it does not use.

Only the entry point builds a tracer. The outputs are renderers of the same
events: indented text, JSON lines, the @SINGULAR_LOG@ phase log and the test
collector.
-}
module Singular.CLI.Trace
    ( -- * Events
      Trace (..)
    , Scope (..)
    , Event (..)
    , What (..)
    , How (..)
    , Fetch (..)
    , EdgeAction (..)
    , RefusalKind (..)
    , TxEvent (..)
    , Ended (..)
    , TipAt (..)
    , SubmitVerdict (..)
    , ConfirmVerdict (..)

      -- * Scoping
    , within
    , report
    , what
    , how
    , readsUnder
    , backendUnder
    , txUnder
    , ended

      -- * Controls
    , TraceLevel (..)
    , TraceFormat (..)
    , TraceSink (..)
    , TraceRequest (..)
    , Output (..)
    , noTraceRequest
    , resolveOutputs
    , atLevel
    , levelOf

      -- * Renderers
    , renderText
    , renderJsonLine
    , decodeJsonLine
    , renderPhaseLog

      -- * Sinks
    , fanOut
    , withTracing
    , outputSink
    , phaseLogSink
    ) where

import Control.Applicative ((<|>))
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , catch
    , fromException
    , throwIO
    )
import Control.Monad (forM_)
import Control.Tracer
    ( Tracer (..)
    , condTracing
    , contramap
    , nullTracer
    , traceWith
    )
import Data.Aeson (Value (..), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.Types (Pair, Parser, parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BL
import Data.Char (isPrint)
import Data.Data (Data)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Tracer.ThreadSafe (newThreadSafeTracer)
import Data.Word (Word64)
import System.IO (Handle, hFlush)
import Text.Printf (printf)

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
    )
import Singular.Registry.TraceRender
    ( appendPhaseLine
    , backendPhase
    , readPhase
    )

-- ---------------------------------------------------------
-- Events
-- ---------------------------------------------------------

-- | One event of a command, with the scopes it happened in, outermost first.
data Trace = Trace
    { traceScope :: [Scope]
    , traceEvent :: Event
    }
    deriving stock (Eq, Show, Data)

-- | A protocol scope an event happens in.
data Scope
    = -- | The registry, by its state token (base16)
      InRegistry Text
    | -- | A registry key
      InKey ByteString
    | -- | A request, by its output reference
      InRequest Text
    | -- | The action taken on an edge
      InEdge EdgeAction
    | -- | One transaction, by its journal step
      InTransaction Text
    deriving stock (Eq, Show, Data)

-- | A protocol action or verdict, or a mechanic under one.
data Event
    = What What
    | How How
    deriving stock (Eq, Show, Data)

-- | The actions taken on the registry's edges.
data EdgeAction
    = -- | Booking a request for this edge (insert, terminate)
      Booking Text
    | -- | Folding a request on this edge
      Folding Text
    | Updating
    | Rejecting
    | -- | Taking back a request on this edge
      Reclaiming Text
    | Booting
    | Inspecting
    deriving stock (Eq, Show, Data)

-- | Where a failure happened, disjointly.
data RefusalKind
    = -- | The client refused before anything was submitted
      ClientRefused
    | -- | A script failed the client's local evaluation
      EvaluationRefused
    | -- | The ledger rejected the submitted transaction
      LedgerRejected
    | -- | The provider's transport failed: no ledger judged anything
      TransportFailed
    deriving stock (Eq, Show, Data, Enum, Bounded)

-- | The protocol actions and verdicts.
data What
    = CommandStarted Text
    | -- | The command, its outcome class and its elapsed milliseconds
      CommandEnded Text Text Double
    | -- | The state output, the root (base16) and the pending requests, when counted
      RegistrySeen
        { seenState :: Text
        , seenRoot :: Text
        , seenPending :: Maybe Int
        }
    | -- | A key, its leaf and the output holding it
      KeySeen
        { seenKey :: ByteString
        , seenLeaf :: Text
        , seenHolding :: Maybe Text
        }
    | -- | A request: its key, its edge and its processing deadline
      RequestSeen
        { seenRequest :: Text
        , seenEdge :: Text
        , seenRequestKey :: ByteString
        , seenDeadlineMs :: Maybe Integer
        , seenDeadlineSlot :: Maybe Word64
        }
    | EdgeStarted EdgeAction
    | -- | The request a booking left pending, and its deadline
      Booked Text (Maybe Integer)
    | -- | A fold's edge at its key, and the output it delivered or released
      Folded Text ByteString Text
    | -- | An update's key and the output now holding it
      Updated ByteString Text
    | -- | The requests a reject turned away
      Rejected [Text]
    | -- | The request taken back and the lovelace returned
      Reclaimed Text Integer
    | -- | The registry's token and state output after its boot
      Created Text Text
    | -- | The root before and after (base16)
      RootSeen Text Text
    | -- | A refusal, where it happened and the type or tag it carries
      Refused RefusalKind (Maybe ErrorClass)
    deriving stock (Eq, Show, Data)

-- | A mechanic under a protocol action.
data How
    = -- | One read step of the command: what it read, from which source
      Fetched Fetch
    | -- | One call at the provider boundary
      Read ReadEvent
    | -- | A backend's own mechanics
      Backend BackendEvent
    | Tx TxEvent
    deriving stock (Eq, Show, Data)

-- | A read step a command opens and closes around its queries.
data Fetch = Fetch
    { fetchWhat :: [Text]
    , fetchSource :: Text
    , fetchElapsed :: Double
    , fetchEnd :: Ended
    }
    deriving stock (Eq, Show, Data)

-- | How a timed step ended.
data Ended
    = Done
    | FailedWith ErrorClass
    deriving stock (Eq, Show, Data)

-- | The tip a submission met.
data TipAt
    = TipSlot Word64
    | TipUnreadable
    deriving stock (Eq, Show, Data)

-- | What the provider answered a submission.
data SubmitVerdict
    = Accepted
    | LedgerRefusedIt
    | ProviderFailed
    | WrongNetwork
    | SubmitThrew ErrorClass
    deriving stock (Eq, Show, Data)

-- | How a confirmation wait ended.
data ConfirmVerdict
    = Confirmed
    | ConfirmTimedOut
    | -- | The wait ended in a failure of this type
      ConfirmFailed ErrorClass
    | -- | The wait itself threw this type
      ConfirmThrew ErrorClass
    deriving stock (Eq, Show, Data)

-- | The transaction mechanics of a write, each under its journal step.
data TxEvent
    = TxBuilt Text Double Ended
    | -- | Step, transaction id, fee in lovelace, milliseconds, end
      TxSigned Text Text (Maybe Integer) Double Ended
    | TxSubmitted
        { submitStep :: Text
        , submitTx :: Text
        , submitLower :: Maybe Word64
        , submitUpper :: Maybe Word64
        , submitTip :: TipAt
        , submitElapsed :: Double
        , submitVerdict :: SubmitVerdict
        }
    | TxConfirmed Text Text Double ConfirmVerdict
    | -- | Step, transaction id, and the milliseconds from its confirmation to its readback
      TxObserved Text Text Double
    deriving stock (Eq, Show, Data)

-- ---------------------------------------------------------
-- Scoping
-- ---------------------------------------------------------

-- | Trace inside one more scope: the enclosing scope adds what it knows.
within :: Scope -> Tracer m Trace -> Tracer m Trace
within s = contramap (\(Trace path e) -> Trace (s : path) e)

-- | Report one protocol action or verdict inside these scopes, outermost first.
report :: Tracer m Trace -> [Scope] -> What -> m ()
report tracer scopes = traceWith tracer . Trace scopes . What

-- | Trace protocol actions.
what :: Tracer m Trace -> Tracer m What
what = contramap (Trace [] . What)

-- | Trace mechanics.
how :: Tracer m Trace -> Tracer m How
how = contramap (Trace [] . How)

-- | Trace a provider's reads.
readsUnder :: Tracer m Trace -> Tracer m ReadEvent
readsUnder = contramap (Trace [] . How . Read)

-- | Trace a backend's own mechanics.
backendUnder :: Tracer m Trace -> Tracer m BackendEvent
backendUnder = contramap (Trace [] . How . Backend)

-- | Trace a write's transaction mechanics.
txUnder :: Tracer m Trace -> Tracer m TxEvent
txUnder = contramap (Trace [] . How . Tx)

-- | How a timed step ended, from what it returned or the type of what it threw.
ended :: Either ErrorClass a -> Ended
ended = either FailedWith (const Done)

-- ---------------------------------------------------------
-- Controls
-- ---------------------------------------------------------

-- | How much a command narrates: nothing, its protocol actions, or also how.
data TraceLevel = TraceOff | TraceWhat | TraceHow
    deriving stock (Eq, Show, Ord, Enum, Bounded)

data TraceFormat = TextFormat | JsonFormat
    deriving stock (Eq, Show)

-- | Where a trace goes.
data TraceSink = ToStderr | ToFile FilePath
    deriving stock (Eq, Show)

-- | What the command line asked for; unset fields take their defaults.
data TraceRequest = TraceRequest
    { requestLevel :: Maybe TraceLevel
    , requestSinks :: [TraceSink]
    , requestFormat :: Maybe TraceFormat
    }
    deriving stock (Eq, Show)

-- | A command line naming no tracing control.
noTraceRequest :: TraceRequest
noTraceRequest = TraceRequest Nothing [] Nothing

-- | One sink with its format.
data Output = Output TraceSink TraceFormat
    deriving stock (Eq, Show)

{- | The level and outputs a request resolves to, given whether standard
error is a terminal. With no level named, a terminal narrates @what@ and
anything else narrates nothing; with no sink named, the narration goes to
standard error. Standard error takes text and a file takes JSON lines, unless
a format is named. At @off@ nothing is opened.
-}
resolveOutputs :: Bool -> TraceRequest -> (TraceLevel, [Output])
resolveOutputs terminal TraceRequest{..} = case level of
    TraceOff -> (TraceOff, [])
    _ ->
        ( level
        , [ Output sink (fromMaybe (formatOf sink) requestFormat) | sink <- sinks
          ]
        )
  where
    level =
        fromMaybe (if terminal then TraceWhat else TraceOff) requestLevel
    sinks = if null requestSinks then [ToStderr] else requestSinks
    formatOf = \case
        ToStderr -> TextFormat
        ToFile _ -> JsonFormat

-- | Whether an event is a protocol action (@what@) or a mechanic (@how@).
levelOf :: Trace -> TraceLevel
levelOf (Trace _ event) = case event of
    What _ -> TraceWhat
    How _ -> TraceHow

-- | Whether an event is shown at a level.
atLevel :: TraceLevel -> Trace -> Bool
atLevel level t = level /= TraceOff && levelOf t <= level

-- ---------------------------------------------------------
-- Renderers
-- ---------------------------------------------------------

{- | One event as an indented line of narration, or none. The indentation is
read from the event's own scope path: registry, then key or request, then
edge; a transaction adds none, so its mechanics sit under their edge. The
line that opens a scope (a registry, key or request seen, an edge started)
and an edge's result sit at that scope's own depth. A timed line ends in its
seconds, aligned at column 78. Provider calls, views and backend mechanics
are left to the JSON lines.
-}
renderText :: Trace -> Maybe Text
renderText (Trace scope event) = place <$> line
  where
    place (label, time) =
        let prefix = T.replicate (2 * depth) " " <> label
        in  case time of
                Nothing -> prefix
                Just ms ->
                    let s = seconds ms
                        n = max 3 (76 - T.length prefix - T.length s)
                    in  prefix <> " " <> T.replicate n "." <> " " <> s
    depth = max 0 (length [() | s <- scope, not (isTransaction s)] - lifted)
    lifted = case event of
        What w | opensScope w -> 1
        _ -> 0
    registry = listToMaybe (reverse [t | InRegistry t <- scope])
    line = case event of
        What w -> whatLine registry w
        How h -> (\(l, t) -> ("how  " <> l, t)) <$> howLine h

isTransaction :: Scope -> Bool
isTransaction = \case
    InTransaction _ -> True
    _ -> False

-- | Whether a protocol line opens its scope or closes its edge.
opensScope :: What -> Bool
opensScope = \case
    RegistrySeen{} -> True
    KeySeen{} -> True
    RequestSeen{} -> True
    EdgeStarted _ -> True
    Booked{} -> True
    Folded{} -> True
    Updated{} -> True
    Rejected _ -> True
    Reclaimed{} -> True
    Created{} -> True
    _ -> False

whatLine :: Maybe Text -> What -> Maybe (Text, Maybe Double)
whatLine registry = \case
    CommandStarted _ -> Nothing
    CommandEnded command outcome ms -> Just (command <> " " <> outcome, Just ms)
    RegistrySeen _ root pending ->
        untimed $
            "registry "
                <> maybe "" ((<> " ") . short) registry
                <> "(root "
                <> short root
                <> maybe "" (\n -> ", " <> tshow n <> " pending") pending
                <> ")"
    KeySeen key leaf holding ->
        untimed $
            "key "
                <> keyText key
                <> " "
                <> leaf
                <> maybe "" ((", held at " <>) . shortRef) holding
    RequestSeen request edge key deadline slot ->
        untimed $
            "request "
                <> shortRef request
                <> " "
                <> edge
                <> " "
                <> keyText key
                <> case (deadline, slot) of
                    (Just ms, Just s) -> " (deadline " <> utcText ms <> ", slot " <> tshow s <> ")"
                    (Just ms, Nothing) -> " (deadline " <> utcText ms <> ")"
                    (Nothing, Just s) -> " (slot " <> tshow s <> ")"
                    (Nothing, Nothing) -> ""
    EdgeStarted action -> untimed (actionText action)
    Booked request deadline ->
        untimed $
            "result request "
                <> shortRef request
                <> " booked"
                <> maybe "" ((", fold before " <>) . utcText) deadline
    Folded edge key output ->
        untimed $
            "result "
                <> keyText key
                <> " "
                <> edge
                <> " folded, output "
                <> shortRef output
    Updated key output ->
        untimed
            ("result " <> keyText key <> " updated, output " <> shortRef output)
    Rejected requests ->
        untimed $
            "result "
                <> tshow (length requests)
                <> " rejected: "
                <> T.intercalate ", " (map shortRef requests)
    Reclaimed request returned ->
        untimed $
            "result request "
                <> shortRef request
                <> " reclaimed, "
                <> ada returned
                <> " returned"
    Created tokenName stateOut ->
        untimed $
            "result registry "
                <> short tokenName
                <> " created, state "
                <> shortRef stateOut
    RootSeen before after -> untimed ("root " <> short before <> " → " <> short after)
    Refused kind cls ->
        untimed $
            ( case kind of
                ClientRefused -> "refused by the client: nothing was submitted"
                EvaluationRefused -> "refused by local script evaluation: nothing was submitted"
                LedgerRejected -> "rejected by the ledger"
                TransportFailed -> "refused by the provider, not the ledger: no ledger judged it"
            )
                <> maybe "" (\(ErrorClass c) -> " (" <> c <> ")") cls
  where
    untimed l = Just (l, Nothing)

howLine :: How -> Maybe (Text, Maybe Double)
howLine = \case
    Fetched (Fetch items source ms end) ->
        timed
            ( "read "
                <> T.intercalate ", " items
                <> " via "
                <> source
                <> endText end
            )
            ms
    Read r -> case r of
        Evaluated Evaluation{..} ->
            timed
                ( "evaluate "
                    <> tshow evalRedeemers
                    <> (if evalRedeemers == 1 then " script " else " scripts ")
                    <> (if evalFailed == 0 then "✓" else "✗ " <> tshow evalFailed <> " failed")
                    <> " (mem "
                    <> compact evalMemory
                    <> ", steps "
                    <> compact evalSteps
                    <> ")"
                )
                evalElapsed
        HorizonWaited HorizonWait{..} ->
            timed
                ( "wait for the conversion horizon past slot "
                    <> tshow waitWindowUpper
                    <> case waitEnd of
                        HorizonMoved _ horizon -> ", now at slot " <> tshow horizon
                        HorizonFailed (ErrorClass c) -> ": failed (" <> c <> ")"
                )
                waitElapsed
        _ -> Nothing
    Backend _ -> Nothing
    Tx t -> case t of
        TxBuilt step ms end -> timed ("build " <> step <> endText end) ms
        TxSigned _ tx fee ms end ->
            timed
                ( "sign "
                    <> short tx
                    <> maybe "" ((", fee " <>) . ada) fee
                    <> endText end
                )
                ms
        TxSubmitted{..} ->
            timed
                ( "submit tx "
                    <> short submitTx
                    <> " at "
                    <> ( case submitTip of
                            TipSlot s -> "tip slot " <> tshow s
                            TipUnreadable -> "an unreadable tip"
                       )
                    <> case submitVerdict of
                        Accepted -> ""
                        LedgerRefusedIt -> ": the ledger refused it"
                        ProviderFailed -> ": the provider failed"
                        WrongNetwork -> ": another network"
                        SubmitThrew (ErrorClass c) -> ": threw " <> c
                )
                submitElapsed
        TxConfirmed _ tx ms verdict ->
            timed
                ( "confirm tx "
                    <> short tx
                    <> case verdict of
                        Confirmed -> ""
                        ConfirmTimedOut -> ": timed out"
                        ConfirmFailed (ErrorClass c) -> ": failed (" <> c <> ")"
                        ConfirmThrew (ErrorClass c) -> ": threw " <> c
                )
                ms
        TxObserved _ tx ms -> timed ("observe tx " <> short tx) ms
  where
    timed l ms = Just (l, Just ms)
    endText = \case
        Done -> ""
        FailedWith (ErrorClass c) -> ": failed (" <> c <> ")"

actionText :: EdgeAction -> Text
actionText = \case
    Booking edge -> "book " <> edge
    Folding edge -> "fold " <> edge
    Updating -> "update"
    Rejecting -> "reject"
    Reclaiming edge -> "reclaim " <> edge
    Booting -> "boot"
    Inspecting -> "inspect"

-- | An identifier, shortened to its first eight characters.
short :: Text -> Text
short t
    | T.length t > 8 = T.take 8 t <> "…"
    | otherwise = t

-- | An output reference, its transaction id shortened.
shortRef :: Text -> Text
shortRef t = case T.breakOn "#" t of
    (txid, ix) -> short txid <> ix

-- | A key, quoted when its bytes are printable text, else base16.
keyText :: ByteString -> Text
keyText key = case TE.decodeUtf8' key of
    Right t | not (T.null t), T.all isPrint t -> "\"" <> t <> "\""
    _ -> "0x" <> short (hexText key)

-- | Lovelace as tADA, six decimals.
ada :: Integer -> Text
ada lovelace =
    (if lovelace < 0 then "-" else "")
        <> tshow whole
        <> "."
        <> T.justifyRight 6 '0' (tshow part)
        <> " tADA"
  where
    (whole, part) = abs lovelace `divMod` 1_000_000

-- | A count, to three significant digits with its magnitude.
compact :: Integer -> Text
compact n
    | n >= 1_000_000_000 = scaled 1e9 "G"
    | n >= 1_000_000 = scaled 1e6 "M"
    | n >= 1_000 = scaled 1e3 "K"
    | otherwise = tshow n
  where
    scaled :: Double -> Text -> Text
    scaled unit suffix = digits (fromIntegral n / unit) <> suffix
    digits x
        | x >= 100 = tshow (round x :: Integer)
        | x >= 10 = trimmed (T.pack (printf "%.1f" x))
        | otherwise = trimmed (T.pack (printf "%.2f" x))
    trimmed = T.dropWhileEnd (== '.') . T.dropWhileEnd (== '0')

-- | Milliseconds as seconds, one decimal.
seconds :: Double -> Text
seconds ms = T.pack (printf "%.1f" (ms / 1000)) <> "s"

-- | POSIX milliseconds as a UTC time.
utcText :: Integer -> Text
utcText ms =
    T.pack
        ( formatTime
            defaultTimeLocale
            "%Y-%m-%d %H:%M:%SZ"
            (posixSecondsToUTCTime (fromIntegral ms / 1000))
        )

tshow :: (Show a) => a -> Text
tshow = T.pack . show

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode

{- | One event as one JSON object on one line, newline-terminated: its level,
its scope path and its event's fields. Keys are base16; nothing else is
transformed, so the line decodes back to the event ('decodeJsonLine').
-}
renderJsonLine :: Trace -> ByteString
renderJsonLine (Trace scope event) =
    BL.toStrict (Aeson.encode (Aeson.object fields)) <> "\n"
  where
    fields =
        [ "level" .= (case event of What _ -> "what"; How _ -> "how" :: Text)
        , "scope" .= map scopeJson scope
        ]
            <> case event of
                What w -> whatJson w
                How h -> howJson h

-- | Read one JSON line back to its event.
decodeJsonLine :: ByteString -> Maybe Trace
decodeJsonLine line =
    Aeson.decodeStrict (fromMaybe line (BS.stripSuffix "\n" line))
        >>= parseMaybe traceParser

scopeJson :: Scope -> Value
scopeJson = \case
    InRegistry t -> Aeson.object ["registry" .= t]
    InKey k -> Aeson.object ["key" .= hexText k]
    InRequest r -> Aeson.object ["request" .= r]
    InEdge a -> Aeson.object (actionJson a)
    InTransaction s -> Aeson.object ["transaction" .= s]

actionJson :: EdgeAction -> [Pair]
actionJson a =
    ("edge" .= name) : maybe [] (\e -> ["on" .= e]) on
  where
    (name, on) = case a of
        Booking e -> ("book" :: Text, Just e)
        Folding e -> ("fold", Just e)
        Updating -> ("update", Nothing)
        Rejecting -> ("reject", Nothing)
        Reclaiming e -> ("reclaim", Just e)
        Booting -> ("boot", Nothing)
        Inspecting -> ("inspect", Nothing)

named :: Text -> [Pair] -> [Pair]
named name = (("event" .= name) :)

failure :: ErrorClass -> [Pair]
failure (ErrorClass c) = ["errorClass" .= c]

kindName :: RefusalKind -> Text
kindName = \case
    ClientRefused -> "client"
    EvaluationRefused -> "evaluation"
    LedgerRejected -> "ledger"
    TransportFailed -> "transport"

whatJson :: What -> [Pair]
whatJson = \case
    CommandStarted c -> named "command-started" ["command" .= c]
    CommandEnded c o ms ->
        named
            "command-ended"
            ["command" .= c, "outcome" .= o, "elapsedMs" .= ms]
    RegistrySeen s r p -> named "registry" ["state" .= s, "root" .= r, "pending" .= p]
    KeySeen k l h -> named "key" ["key" .= hexText k, "leaf" .= l, "holding" .= h]
    RequestSeen r e k d s ->
        named
            "request"
            [ "request" .= r
            , "edge" .= e
            , "key" .= hexText k
            , "deadlineMs" .= d
            , "deadlineSlot" .= s
            ]
    EdgeStarted a -> named "edge-started" (actionJson a)
    Booked r d -> named "booked" ["request" .= r, "deadlineMs" .= d]
    Folded e k o -> named "folded" ["edge" .= e, "key" .= hexText k, "output" .= o]
    Updated k o -> named "updated" ["key" .= hexText k, "output" .= o]
    Rejected rs -> named "rejected" ["requests" .= rs]
    Reclaimed r v -> named "reclaimed" ["request" .= r, "returned" .= v]
    Created t s -> named "created" ["token" .= t, "state" .= s]
    RootSeen b a -> named "root" ["before" .= b, "after" .= a]
    Refused k c ->
        named
            "refused"
            ["kind" .= kindName k, "errorClass" .= fmap (\(ErrorClass x) -> x) c]

howJson :: How -> [Pair]
howJson = \case
    Fetched (Fetch items source ms end) ->
        named
            "fetched"
            ( ["reads" .= items, "source" .= source, "elapsedMs" .= ms]
                <> endJson end
            )
    Read r -> case r of
        Queried q -> named "query" (queryJson q)
        ViewOpened o -> named "view-opened" (openingJson o)
        ViewReleased o -> named "view-released" (releaseJson o)
        Evaluated Evaluation{..} ->
            named
                "evaluated"
                [ "elapsedMs" .= evalElapsed
                , "redeemers" .= evalRedeemers
                , "failed" .= evalFailed
                , "memory" .= evalMemory
                , "steps" .= evalSteps
                ]
        SessionOpened ms -> named "session-opened" ["elapsedMs" .= ms]
        HorizonWaited HorizonWait{..} ->
            named "horizon-waited" $
                [ "tip" .= waitTip
                , "horizon" .= waitHorizon
                , "lower" .= waitLower
                , "windowUpper" .= waitWindowUpper
                , "minimumSlots" .= waitMinimumSlots
                , "slotLimit" .= waitSlotLimit
                , "wallLimitMs" .= waitWallLimitMs
                , "elapsedMs" .= waitElapsed
                ]
                    <> case waitEnd of
                        HorizonMoved t h ->
                            [ "outcome" .= ("moved" :: Text)
                            , "observedTip" .= t
                            , "observedHorizon" .= h
                            ]
                        HorizonFailed c -> ("outcome" .= ("failed" :: Text)) : failure c
        ValiditySelected ValiditySelection{..} ->
            named
                "validity-selected"
                [ "tip" .= selectedTip
                , "horizon" .= selectedHorizon
                , "lower" .= selectedLower
                , "effectiveLower" .= selectedEffectiveLower
                , "windowUpper" .= selectedWindowUpper
                , "upper" .= selectedUpper
                , "minimumSlots" .= selectedMinimumSlots
                ]
        BodyBuilt (BodyBuild builder ms end) ->
            named "body-built" $
                ["builder" .= builder, "elapsedMs" .= ms]
                    <> case end of
                        BodyReady -> ["outcome" .= ("ready" :: Text)]
                        BodyRefused -> ["outcome" .= ("refused" :: Text)]
                        BodyFailed c -> ("outcome" .= ("failed" :: Text)) : failure c
    Backend b -> case b of
        Exchanged q -> named "exchange" (queryJson q)
        BackendViewOpened o -> named "backend-view-opened" (openingJson o)
        BackendViewReleased o -> named "backend-view-released" (releaseJson o)
    Tx t -> case t of
        TxBuilt step ms end ->
            named "tx-built" (["step" .= step, "elapsedMs" .= ms] <> endJson end)
        TxSigned step tx fee ms end ->
            named
                "tx-signed"
                ( ["step" .= step, "tx" .= tx, "fee" .= fee, "elapsedMs" .= ms]
                    <> endJson end
                )
        TxSubmitted{..} ->
            named "tx-submitted" $
                [ "step" .= submitStep
                , "tx" .= submitTx
                , "validityLower" .= submitLower
                , "validityUpper" .= submitUpper
                , "tipSlot" .= tipSlot submitTip
                , "elapsedMs" .= submitElapsed
                ]
                    <> case submitVerdict of
                        Accepted -> verdict "accepted"
                        LedgerRefusedIt -> verdict "ledger-refused"
                        ProviderFailed -> verdict "provider-failed"
                        WrongNetwork -> verdict "wrong-network"
                        SubmitThrew c -> verdict "threw" <> failure c
        TxConfirmed step tx ms v ->
            named "tx-confirmed" $
                ["step" .= step, "tx" .= tx, "elapsedMs" .= ms]
                    <> case v of
                        Confirmed -> verdict "confirmed"
                        ConfirmTimedOut -> verdict "timed-out"
                        ConfirmFailed c -> verdict "failed" <> failure c
                        ConfirmThrew c -> verdict "threw" <> failure c
        TxObserved step tx ms ->
            named
                "tx-observed"
                ["step" .= step, "tx" .= tx, "sinceConfirmedMs" .= ms]
  where
    verdict v = ["verdict" .= (v :: Text)]
    tipSlot = \case
        TipSlot s -> Just s
        TipUnreadable -> Nothing

endJson :: Ended -> [Pair]
endJson = \case
    Done -> ["outcome" .= ("done" :: Text)]
    FailedWith c -> ("outcome" .= ("failed" :: Text)) : failure c

queryJson :: Query -> [Pair]
queryJson Query{..} =
    [ "name" .= queryName
    , "source" .= querySource
    , "session" .= querySession
    , "elapsedMs" .= queryElapsed
    ]
        <> case queryEnd of
            Answered size -> ["outcome" .= ("answered" :: Text), "size" .= size]
            Lagged -> ["outcome" .= ("lagged" :: Text)]
            QueryFailed c -> ("outcome" .= ("failed" :: Text)) : failure c

openingJson :: ViewOpening -> [Pair]
openingJson = \case
    NodeViewOpened{..} ->
        [ "view" .= ("node" :: Text)
        , "elapsedMs" .= openedElapsed
        , "slot" .= openedSlot
        , "hash" .= openedHash
        , "era" .= openedEra
        ]
    NodeViewFailed ms c ->
        ["view" .= ("node-failed" :: Text), "elapsedMs" .= ms] <> failure c
    SessionViewOpened{..} ->
        [ "view" .= ("session" :: Text)
        , "session" .= openedSession
        , "binding" .= openedBinding
        ]

releaseJson :: ViewRelease -> [Pair]
releaseJson = \case
    NodeViewHeld ms -> ["view" .= ("node" :: Text), "heldMs" .= ms]
    SessionViewClosed s -> ["view" .= ("session" :: Text), "session" .= s]

traceParser :: Value -> Parser Trace
traceParser = Aeson.withObject "trace" $ \o -> do
    scope <- o .: "scope" >>= mapM scopeParser
    level <- o .: "level"
    name <- o .: "event"
    Trace scope <$> case level :: Text of
        "what" -> What <$> whatParser name o
        "how" -> How <$> howParser name o
        _ -> fail "a level is what or how"

scopeParser :: Value -> Parser Scope
scopeParser = Aeson.withObject "scope" $ \o ->
    (InRegistry <$> o .: "registry")
        <|> (InKey <$> (o .: "key" >>= unhex))
        <|> (InRequest <$> o .: "request")
        <|> (InEdge <$> actionParser o)
        <|> (InTransaction <$> o .: "transaction")

actionParser :: Aeson.Object -> Parser EdgeAction
actionParser o = do
    name <- o .: "edge"
    on <- o .:? "on"
    case (name :: Text, on) of
        ("book", Just e) -> pure (Booking e)
        ("fold", Just e) -> pure (Folding e)
        ("update", Nothing) -> pure Updating
        ("reject", Nothing) -> pure Rejecting
        ("reclaim", Just e) -> pure (Reclaiming e)
        ("boot", Nothing) -> pure Booting
        ("inspect", Nothing) -> pure Inspecting
        _ -> fail "not an edge action"

unhex :: Text -> Parser ByteString
unhex = either fail pure . B16.decode . TE.encodeUtf8

classParser :: Aeson.Object -> Parser ErrorClass
classParser o = ErrorClass <$> o .: "errorClass"

whatParser :: Text -> Aeson.Object -> Parser What
whatParser name o = case name of
    "command-started" -> CommandStarted <$> o .: "command"
    "command-ended" ->
        CommandEnded
            <$> o .: "command"
            <*> o .: "outcome"
            <*> o .: "elapsedMs"
    "registry" -> RegistrySeen <$> o .: "state" <*> o .: "root" <*> o .:? "pending"
    "key" ->
        KeySeen <$> (o .: "key" >>= unhex) <*> o .: "leaf" <*> o .:? "holding"
    "request" ->
        RequestSeen
            <$> o .: "request"
            <*> o .: "edge"
            <*> (o .: "key" >>= unhex)
            <*> o .:? "deadlineMs"
            <*> o .:? "deadlineSlot"
    "edge-started" -> EdgeStarted <$> actionParser o
    "booked" -> Booked <$> o .: "request" <*> o .:? "deadlineMs"
    "folded" ->
        Folded <$> o .: "edge" <*> (o .: "key" >>= unhex) <*> o .: "output"
    "updated" -> Updated <$> (o .: "key" >>= unhex) <*> o .: "output"
    "rejected" -> Rejected <$> o .: "requests"
    "reclaimed" -> Reclaimed <$> o .: "request" <*> o .: "returned"
    "created" -> Created <$> o .: "token" <*> o .: "state"
    "root" -> RootSeen <$> o .: "before" <*> o .: "after"
    "refused" -> do
        kind <- o .: "kind"
        k <- case kind :: Text of
            "client" -> pure ClientRefused
            "evaluation" -> pure EvaluationRefused
            "ledger" -> pure LedgerRejected
            "transport" -> pure TransportFailed
            _ -> fail "not a refusal kind"
        Refused k . fmap ErrorClass <$> o .:? "errorClass"
    _ -> fail "not a protocol event"

howParser :: Text -> Aeson.Object -> Parser How
howParser name o = case name of
    "fetched" ->
        fmap Fetched $
            Fetch
                <$> o .: "reads"
                <*> o .: "source"
                <*> o .: "elapsedMs"
                <*> endParser
    "query" -> Read . Queried <$> queryParser
    "view-opened" -> Read . ViewOpened <$> openingParser
    "view-released" -> Read . ViewReleased <$> releaseParser
    "evaluated" ->
        fmap (Read . Evaluated) $
            Evaluation
                <$> o .: "elapsedMs"
                <*> o .: "redeemers"
                <*> o .: "failed"
                <*> o .: "memory"
                <*> o .: "steps"
    "session-opened" -> Read . SessionOpened <$> o .: "elapsedMs"
    "horizon-waited" -> do
        outcome <- o .: "outcome"
        end <- case outcome :: Text of
            "moved" -> HorizonMoved <$> o .: "observedTip" <*> o .: "observedHorizon"
            "failed" -> HorizonFailed <$> classParser o
            _ -> fail "not a horizon outcome"
        fmap (Read . HorizonWaited) $
            HorizonWait
                <$> o .: "tip"
                <*> o .: "horizon"
                <*> o .:? "lower"
                <*> o .: "windowUpper"
                <*> o .: "minimumSlots"
                <*> o .: "slotLimit"
                <*> o .: "wallLimitMs"
                <*> o .: "elapsedMs"
                <*> pure end
    "validity-selected" ->
        fmap (Read . ValiditySelected) $
            ValiditySelection
                <$> o .: "tip"
                <*> o .: "horizon"
                <*> o .:? "lower"
                <*> o .: "effectiveLower"
                <*> o .: "windowUpper"
                <*> o .: "upper"
                <*> o .: "minimumSlots"
    "body-built" -> do
        outcome <- o .: "outcome"
        end <- case outcome :: Text of
            "ready" -> pure BodyReady
            "refused" -> pure BodyRefused
            "failed" -> BodyFailed <$> classParser o
            _ -> fail "not a body outcome"
        fmap (Read . BodyBuilt) $
            BodyBuild <$> o .: "builder" <*> o .: "elapsedMs" <*> pure end
    "exchange" -> Backend . Exchanged <$> queryParser
    "backend-view-opened" -> Backend . BackendViewOpened <$> openingParser
    "backend-view-released" -> Backend . BackendViewReleased <$> releaseParser
    "tx-built" ->
        fmap Tx $ TxBuilt <$> o .: "step" <*> o .: "elapsedMs" <*> endParser
    "tx-signed" ->
        fmap Tx $
            TxSigned
                <$> o .: "step"
                <*> o .: "tx"
                <*> o .:? "fee"
                <*> o .: "elapsedMs"
                <*> endParser
    "tx-submitted" -> do
        v <- o .: "verdict"
        submitted <- case v :: Text of
            "accepted" -> pure Accepted
            "ledger-refused" -> pure LedgerRefusedIt
            "provider-failed" -> pure ProviderFailed
            "wrong-network" -> pure WrongNetwork
            "threw" -> SubmitThrew <$> classParser o
            _ -> fail "not a submission verdict"
        fmap Tx $
            TxSubmitted
                <$> o .: "step"
                <*> o .: "tx"
                <*> o .:? "validityLower"
                <*> o .:? "validityUpper"
                <*> (maybe TipUnreadable TipSlot <$> o .:? "tipSlot")
                <*> o .: "elapsedMs"
                <*> pure submitted
    "tx-confirmed" -> do
        v <- o .: "verdict"
        confirmed <- case v :: Text of
            "confirmed" -> pure Confirmed
            "timed-out" -> pure ConfirmTimedOut
            "failed" -> ConfirmFailed <$> classParser o
            "threw" -> ConfirmThrew <$> classParser o
            _ -> fail "not a confirmation verdict"
        fmap Tx $
            TxConfirmed
                <$> o .: "step"
                <*> o .: "tx"
                <*> o .: "elapsedMs"
                <*> pure confirmed
    "tx-observed" ->
        fmap Tx $
            TxObserved <$> o .: "step" <*> o .: "tx" <*> o .: "sinceConfirmedMs"
    _ -> fail "not a mechanic"
  where
    endParser = do
        outcome <- o .: "outcome"
        case outcome :: Text of
            "done" -> pure Done
            "failed" -> FailedWith <$> classParser o
            _ -> fail "not an end"
    queryParser = do
        outcome <- o .: "outcome"
        end <- case outcome :: Text of
            "answered" -> Answered <$> o .:? "size"
            "lagged" -> pure Lagged
            "failed" -> QueryFailed <$> classParser o
            _ -> fail "not a query outcome"
        Query
            <$> o .: "name"
            <*> o .: "source"
            <*> o .:? "session"
            <*> o .: "elapsedMs"
            <*> pure end
    openingParser = do
        view <- o .: "view"
        case view :: Text of
            "node" ->
                NodeViewOpened
                    <$> o .: "elapsedMs"
                    <*> o .: "slot"
                    <*> o .: "hash"
                    <*> o .: "era"
            "node-failed" -> NodeViewFailed <$> o .: "elapsedMs" <*> classParser o
            "session" -> SessionViewOpened <$> o .: "session" <*> o .: "binding"
            _ -> fail "not a view"
    releaseParser = do
        view <- o .: "view"
        case view :: Text of
            "node" -> NodeViewHeld <$> o .: "heldMs"
            "session" -> SessionViewClosed <$> o .: "session"
            _ -> fail "not a view"

{- | The @SINGULAR_LOG@ line an event stands for: its phase and its fields,
without the time stamp the sink adds.
-}
renderPhaseLog :: Trace -> Maybe (Text, [(Key, Value)])
renderPhaseLog (Trace _ event) = case event of
    How (Read e) -> readPhase e
    How (Backend e) -> backendPhase e
    How (Tx e) -> txPhase e
    _ -> Nothing

-- | The phase-log line of a transaction mechanic.
txPhase :: TxEvent -> Maybe (Text, [(Key, Value)])
txPhase = \case
    TxBuilt step ms end -> Just ("build", ["step" .= step] <> timed ms end)
    TxSigned step tx _ ms end -> Just ("sign", ["step" .= step, "tx" .= tx] <> timed ms end)
    TxSubmitted{..} ->
        Just
            ( "submit"
            , [ "step" .= submitStep
              , "tx" .= submitTx
              , "validity_lower" .= submitLower
              , "validity_upper" .= submitUpper
              , "duration_ms" .= submitElapsed
              ]
                <> case submitTip of
                    TipSlot s -> ["tip_slot" .= s]
                    TipUnreadable -> ["tip_slot" .= Null]
                <> case submitVerdict of
                    Accepted -> outcome "submitted"
                    LedgerRefusedIt -> outcome "rejected"
                    ProviderFailed -> outcome "failed"
                    WrongNetwork -> outcome "wrong-network"
                    SubmitThrew c -> failedWith c
            )
    TxConfirmed step tx ms verdict ->
        Just
            ( "confirm"
            , [ "step" .= step
              , "tx" .= tx
              , "duration_ms" .= ms
              ]
                <> case verdict of
                    Confirmed -> outcome "confirmed"
                    ConfirmTimedOut -> outcome "timeout"
                    -- the wait's own failure was always written without its class
                    ConfirmFailed _ -> outcome "failed"
                    ConfirmThrew c -> failedWith c
            )
    TxObserved{} -> Nothing
  where
    outcome o = ["outcome" .= (o :: Text)]
    timed ms = \case
        Done -> ["duration_ms" .= ms] <> outcome "ok"
        FailedWith c -> ("duration_ms" .= ms) : failedWith c
    failedWith (ErrorClass c) = outcome "failed" <> ["error_class" .= c]

-- ---------------------------------------------------------
-- Sinks
-- ---------------------------------------------------------

{- | One tracer feeding every sink, serialised: every sink sees the same order
of events and no line interleaves with another.
-}
fanOut :: [Tracer IO Trace] -> IO (Tracer IO Trace)
fanOut sinks = newThreadSafeTracer (foldMap contained sinks)

{- | A sink whose failure stays its own: whatever it throws (a closed handle, an
unwritable file, a full disk, a fault of its own) reaches neither the other
sinks nor the command. An asynchronous exception still propagates.
-}
contained :: Tracer IO Trace -> Tracer IO Trace
contained sink = Tracer $ \event ->
    traceWith sink event `catch` \(e :: SomeException) ->
        case fromException e of
            Just (_ :: SomeAsyncException) -> throwIO e
            Nothing -> pure ()

{- | Run the command with the tracer the entry point composes: every output
the request resolves to, given the process's standard error and whether it is
a terminal, and the @SINGULAR_LOG@ phase log when a path is given. Nothing is
opened here: a file sink opens per line, inside its containment.
-}
withTracing
    :: Maybe Handle
    -> Bool
    -> Maybe FilePath
    -> TraceRequest
    -> (Tracer IO Trace -> IO a)
    -> IO a
withTracing errors terminal phaseLog request body = case sinks of
    [] -> body nullTracer
    _ -> fanOut sinks >>= body
  where
    (level, outputs) = resolveOutputs terminal request
    sinks =
        map (outputSink errors level) outputs
            <> maybe [] (pure . phaseLogSink) phaseLog

{- | The tracer writing one output at a level: only the events shown at that
level, each written whole as it happens (standard error, the handle given, is flushed after
each line; a file is opened, appended and closed per line). A line of text
is written as UTF-8 whatever the locale.
-}
outputSink :: Maybe Handle -> TraceLevel -> Output -> Tracer IO Trace
outputSink errors level (Output sink format) = case (sink, errors) of
    (ToStderr, Nothing) -> nullTracer
    (ToStderr, Just h) ->
        condTracing (atLevel level) $
            Tracer $ \t -> forM_ (rendered t) $ \bytes ->
                BS.hPut h bytes >> hFlush h
    (ToFile path, _) ->
        condTracing (atLevel level) $
            Tracer $ \t -> forM_ (rendered t) $ \bytes ->
                BS.appendFile path bytes
  where
    rendered t = case format of
        TextFormat -> (\l -> TE.encodeUtf8 (l <> "\n")) <$> renderText t
        JsonFormat -> Just (renderJsonLine t)

-- | The tracer appending the @SINGULAR_LOG@ phase log to a file.
phaseLogSink :: FilePath -> Tracer IO Trace
phaseLogSink path =
    Tracer
        (maybe (pure ()) (uncurry (appendPhaseLine path)) . renderPhaseLog)
