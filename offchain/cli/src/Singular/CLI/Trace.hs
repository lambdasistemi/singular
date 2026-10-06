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
    , what
    , how
    , readsUnder

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

import Control.Tracer (Tracer, contramap, nullTracer)
import Data.Aeson (Value)
import Data.Aeson.Key (Key)
import Data.ByteString (ByteString)
import Data.Data (Data)
import Data.Text (Text)
import Data.Word (Word64)

import Singular.Registry.Trace (BackendEvent, ErrorClass, ReadEvent)

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

-- | The tip a submission met, when the trace asked for it.
data TipAt
    = TipNotRead
    | TipSlot Word64
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
    | ConfirmFailed
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
    | TxObserved Text Text
    deriving stock (Eq, Show, Data)

-- ---------------------------------------------------------
-- Scoping
-- ---------------------------------------------------------

-- | Trace inside one more scope: the enclosing scope adds what it knows.
within :: Scope -> Tracer m Trace -> Tracer m Trace
within _ = id

-- | Trace protocol actions.
what :: Tracer m Trace -> Tracer m What
what = contramap (Trace [] . What)

-- | Trace mechanics.
how :: Tracer m Trace -> Tracer m How
how = contramap (Trace [] . How)

-- | Trace a provider's reads.
readsUnder :: Tracer m Trace -> Tracer m ReadEvent
readsUnder = contramap (Trace [] . How . Read)

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
error is a terminal.
-}
resolveOutputs :: Bool -> TraceRequest -> (TraceLevel, [Output])
resolveOutputs _ _ = (TraceOff, [])

-- | Whether an event is a protocol action (@what@) or a mechanic (@how@).
levelOf :: Trace -> TraceLevel
levelOf _ = TraceOff

-- | Whether an event is shown at a level.
atLevel :: TraceLevel -> Trace -> Bool
atLevel _ _ = False

-- ---------------------------------------------------------
-- Renderers
-- ---------------------------------------------------------

-- | One event as an indented line of narration, or none.
renderText :: Trace -> Maybe Text
renderText _ = Nothing

-- | One event as one JSON object on one line, newline-terminated.
renderJsonLine :: Trace -> ByteString
renderJsonLine _ = mempty

-- | Read one JSON line back to its event.
decodeJsonLine :: ByteString -> Maybe Trace
decodeJsonLine _ = Nothing

{- | The @SINGULAR_LOG@ line an event stands for: its phase and its fields,
without the time stamp the sink adds.
-}
renderPhaseLog :: Trace -> Maybe (Text, [(Key, Value)])
renderPhaseLog _ = Nothing

-- ---------------------------------------------------------
-- Sinks
-- ---------------------------------------------------------

{- | One tracer feeding every sink, serialised: every sink sees the same order
of events and no line interleaves with another.
-}
fanOut :: [Tracer IO Trace] -> IO (Tracer IO Trace)
fanOut _ = pure nullTracer

{- | Run the command with the tracer the entry point composes: every output
the request resolves to, given whether standard error is a terminal, and the
@SINGULAR_LOG@ phase log when a path is given.
-}
withTracing
    :: Bool
    -> Maybe FilePath
    -> TraceRequest
    -> (Tracer IO Trace -> IO a)
    -> IO a
withTracing _ _ _ body = body nullTracer

-- | The tracer writing one output at a level.
outputSink :: TraceLevel -> Output -> Tracer IO Trace
outputSink _ _ = nullTracer

-- | The tracer appending the @SINGULAR_LOG@ phase log to a file.
phaseLogSink :: FilePath -> Tracer IO Trace
phaseLogSink _ = nullTracer
