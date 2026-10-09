{- | IO lifecycle effects for the same constructor used in pure State.
Each raw read is timed where it happens and traced as one of the backend's
own exchanges; opening and closing a session are traced too. The sink keeps
the raw evidence a receipt records, which no trace carries.
-}
module Singular.Provider.Koios.Runtime (newIORuntime, koiosSource) where

import Control.Exception (finally, mask)
import Control.Tracer (Tracer, traceWith)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Singular.Provider.Koios.Provider
    ( ProviderEvent (..)
    , ProviderRuntime (..)
    )
import Singular.Registry.Evidence (SessionId (..))
import Singular.Registry.Trace
    ( BackendEvent (..)
    , Query (..)
    , QueryEnd (..)
    , ViewOpening (..)
    , ViewRelease (..)
    , isoNow
    , timedTrace
    )

-- | The source Koios's exchanges and reads report as.
koiosSource :: Text.Text
koiosSource = "Koios"

{- | The sink retains raw evidence for receipts. The tracer records names,
identities, durations and failure classes, without raw bodies, error text
or keys.
-}
newIORuntime
    :: Tracer IO BackendEvent
    -> (ProviderEvent -> IO ())
    -> IO (ProviderRuntime IO)
newIORuntime tracer sink = do
    prefix <- isoNow
    state <- newIORef (0 :: Integer, Set.empty)
    let identityText (SessionId identity) = identity
        observe event = do
            sink event
            case event of
                SessionOpened identity _ ->
                    traceWith tracer . BackendViewOpened $
                        SessionViewOpened (identityText identity) "Unbound"
                SessionClosed identity ->
                    traceWith tracer . BackendViewReleased $
                        SessionViewClosed (identityText identity)
                _ -> pure ()
    pure
        ProviderRuntime
            { scopedSession = \action release -> mask $ \restore -> do
                identity <- atomicModifyIORef' state $ \(number, open) ->
                    let allocated = SessionId ("koios-" <> prefix <> "-" <> Text.pack (show number))
                    in  ((number + 1, Set.insert allocated open), allocated)
                restore (action identity)
                    `finally` ( release identity
                                    `finally` atomicModifyIORef'
                                        state
                                        (\(number, open) -> ((number, Set.delete identity open), ()))
                              )
            , sessionOpen = \identity -> Set.member identity . snd <$> readIORef state
            , recordEvent = observe
            , measureRead = \identity name event action ->
                timedTrace
                    tracer
                    ( \ms end ->
                        Exchanged
                            Query
                                { queryName = name
                                , querySource = koiosSource
                                , querySession = Just (identityText identity)
                                , queryElapsed = ms
                                , queryEnd = either QueryFailed (const (Answered Nothing)) end
                                }
                    )
                    (do result <- action; sink (event result); pure result)
            }
