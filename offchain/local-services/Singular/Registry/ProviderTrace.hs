{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.ProviderTrace
Description : The provider boundary, traced: every call a command makes, timed and typed
License     : Apache-2.0

One decorator per read interface, both emitting the same typed events
("Singular.Registry.Trace"): every call through the provider is timed where
it happens and traced as 'Queried', with the call's name, the source that
answered it, the session it ran in, its elapsed time and its end. A failure
carries its type or its constructor, never its text.

The enclosing scope decides where the events go: it wraps the provider with
its own tracer, with its context already added by @contramap@, so the reads
land under the action they serve. Wrapping again in an inner scope is how a
read is placed there; the provider underneath is the same.

The sessions and views a decorated provider hands out carry the same tracer
('sessionTracer', 'viewTracer'), so the local services computed over them
report into the scope too.
-}
module Singular.Registry.ProviderTrace
    ( tracedLedgerProvider
    , tracedProvider
    , localSource
    , nodeSource
    ) where

import Control.Exception (SomeException, finally, throwIO, try)
import Control.Monad (unless)
import Control.Tracer (Tracer, traceWith)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Cardano.Slotting.Slot (SlotNo (..))
import Singular.Registry.Evidence (Evidenced (..), SessionId (..))
import Singular.Registry.LedgerProvider
    ( LedgerProvider (..)
    , Session (..)
    )
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider (..)
    , View (..)
    )
import Singular.Registry.Trace
    ( ErrorClass
    , Query (..)
    , QueryEnd (..)
    , ReadEvent (..)
    , ViewOpening (..)
    , ViewRelease (..)
    , errorClassOf
    , failureTag
    , startTimer
    , timedTrace
    )

-- | The source the node's view interface reports as.
nodeSource :: Text
nodeSource = "node"

-- | The source the local services computed over a view or session report as.
localSource :: Text
localSource = "local"

{- | A ledger provider whose every session read is traced, under the given
source name. The sessions it hands out trace their local services into the
same tracer.
-}
tracedLedgerProvider
    :: Text
    -> Tracer IO ReadEvent
    -> LedgerProvider w IO
    -> LedgerProvider w IO
tracedLedgerProvider source tracer inner =
    inner
        { acquire = \requested action ->
            acquire inner requested (action . traced)
        }
  where
    traced s =
        s
            { sessionTracer = tracer
            , outputs = call s "outputs" (Just . length . value) . outputs s
            , protocolParameters =
                call s "protocolParameters" none (protocolParameters s)
            , tipObservation = call s "tip" none (tipObservation s)
            , networkTime = call s "networkTime" none (networkTime s)
            , scriptRegistered = call s "scriptRegistered" none . scriptRegistered s
            , history = \asset range -> call s "history" none (history s asset range)
            }
    none = const Nothing
    call
        :: (Show f)
        => Session w IO
        -> Text
        -> (b -> Maybe Int)
        -> IO (Either f b)
        -> IO (Either f b)
    call s name size act =
        let SessionId label = sessionId s
        in  timedTrace tracer (queried source (Just label) name size) act
    queried src session name size ms end =
        Queried
            Query
                { queryName = name
                , querySource = src
                , querySession = session
                , queryElapsed = ms
                , queryEnd = ended size end
                }

-- | How a read that answers with a value or a failure ended.
ended
    :: (Show f)
    => (a -> Maybe Int) -> Either ErrorClass (Either f a) -> QueryEnd
ended size = \case
    Right (Right a) -> Answered (size a)
    Right (Left failure) -> QueryFailed (failureTag failure)
    Left thrown -> QueryFailed thrown

{- | The node's view provider, traced: each acquisition with its chain point
and duration, each read through the view, and each release with how long the
view was held.
-}
tracedProvider :: Tracer IO ReadEvent -> Provider IO -> Provider IO
tracedProvider tracer inner = Provider $ \act -> do
    elapsed <- startTimer
    acquired <- newIORef False
    let acquiring v = do
            writeIORef acquired True
            ms <- elapsed
            let point = viewPoint v
            traceWith tracer . ViewOpened $
                NodeViewOpened
                    { openedElapsed = ms
                    , openedSlot = unSlotNo (cpSlot point)
                    , openedHash = hexText (cpBlockHash point)
                    , openedEra = cpEra point
                    }
            held <- startTimer
            act (traced v)
                `finally` (held >>= traceWith tracer . ViewReleased . NodeViewHeld)
    try @SomeException (withView inner acquiring) >>= \case
        Right a -> pure a
        Left e -> do
            got <- readIORef acquired
            unless got $ do
                ms <- elapsed
                traceWith tracer (ViewOpened (NodeViewFailed ms (errorClassOf e)))
            throwIO e
  where
    traced v =
        v
            { viewUTxOsAt = read' "utxosAt" (Just . length) . viewUTxOsAt v
            , viewTimeContext = read' "networkTime" one (viewTimeContext v)
            , viewResolvedOutputs =
                read' "resolvedOutputs" (Just . length) . viewResolvedOutputs v
            , viewTracer = tracer
            , viewScriptRegistered =
                read' "scriptRegistered" one . viewScriptRegistered v
            }
    one = const (Just 1)
    read' :: Text -> (a -> Maybe Int) -> IO a -> IO a
    read' name size =
        timedTrace tracer $ \ms end ->
            Queried
                Query
                    { queryName = name
                    , querySource = nodeSource
                    , querySession = Nothing
                    , queryElapsed = ms
                    , queryEnd = either QueryFailed (Answered . size) end
                    }

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
