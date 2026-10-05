{-# LANGUAGE LambdaCase #-}

{- | IO lifecycle effects for the same constructor used in pure State.
Query timing wraps the actual raw read; disabled logging changes no facts.
-}
module Singular.Provider.Koios.Runtime (newIORuntime) where

import Control.Exception (finally, mask)
import Data.Aeson ((.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Singular.Provider.Koios.Provider
    ( ProviderEvent (..)
    , ProviderRuntime (..)
    )
import Singular.Registry.Evidence (SessionId (..))
import Singular.Registry.PhaseLog
    ( PhaseLog
    , isoNow
    , logPhase
    , timedPhase
    )

{- | The sink retains raw evidence for receipts. Phase logging records names,
identities, durations and failure classes without raw error text or keys.
-}
newIORuntime
    :: PhaseLog -> (ProviderEvent -> IO ()) -> IO (ProviderRuntime IO)
newIORuntime logHandle sink = do
    prefix <- isoNow
    state <- newIORef (0 :: Integer, Set.empty)
    let identityText (SessionId identity) = identity
        observe event = do
            sink event
            case event of
                SessionOpened identity _ ->
                    logPhase
                        logHandle
                        "view"
                        [ "session" .= identityText identity
                        , "binding" .= ("Unbound" :: Text.Text)
                        ]
                SessionClosed identity ->
                    logPhase logHandle "view-release" ["session" .= identityText identity]
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
                timedPhase
                    logHandle
                    "query"
                    ["session" .= identityText identity, "query" .= name]
                    (const [])
                    (do result <- action; sink (event result); pure result)
            }
