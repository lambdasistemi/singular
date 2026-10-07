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

The sessions a decorated provider hands out carry the same tracer
('sessionTracer'), so the local services computed over them
report into the scope too.
-}
module Singular.Registry.ProviderTrace
    ( tracedLedgerProvider
    , localSource
    , nodeSource
    ) where

import Control.Tracer (Tracer)
import Data.Text (Text)

import Singular.Registry.Evidence (Evidenced (..), SessionId (..))
import Singular.Registry.LedgerProvider
    ( LedgerProvider (..)
    , Session (..)
    )
import Singular.Registry.Trace
    ( ErrorClass
    , Query (..)
    , QueryEnd (..)
    , ReadEvent (..)
    , failureTag
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
