{-# LANGUAGE FlexibleContexts #-}

{- | Pure lifecycle and observation effects for the shipping Koios provider.
The shared recorded transport can run directly in the same State monad.
-}
module Singular.Provider.Koios.State
    ( ProviderState (..)
    , initialProviderState
    , stateRuntime
    ) where

import Control.Monad.State.Strict (MonadState, gets, modify')
import Data.Set qualified as Set
import Data.Text qualified as Text
import Singular.Provider.Koios.Provider
    ( ProviderEvent
    , ProviderRuntime (..)
    )
import Singular.Registry.Evidence (SessionId (..))

data ProviderState = ProviderState
    { nextSessionNumber :: Integer
    , openSessions :: Set.Set SessionId
    , providerEvents :: [ProviderEvent]
    }

initialProviderState :: ProviderState
initialProviderState = ProviderState 0 Set.empty []

{- | Every acquisition allocates a fresh identity, then releases it before
returning. No IORef, external clock or process state is involved.
-}
stateRuntime :: (MonadState ProviderState m) => ProviderRuntime m
stateRuntime =
    ProviderRuntime
        { scopedSession = \action release -> do
            number <- gets nextSessionNumber
            let identity = SessionId ("koios-" <> Text.pack (show number))
            modify'
                ( \state ->
                    state
                        { nextSessionNumber = number + 1
                        , openSessions = Set.insert identity (openSessions state)
                        }
                )
            result <- action identity
            release identity
            modify'
                ( \state -> state{openSessions = Set.delete identity (openSessions state)}
                )
            pure result
        , sessionOpen = \identity -> gets (Set.member identity . openSessions)
        , recordEvent = \event ->
            modify'
                (\state -> state{providerEvents = providerEvents state <> [event]})
        , measureRead = \_ _ event action -> do
            result <- action
            modify'
                ( \state -> state{providerEvents = providerEvents state <> [event result]}
                )
            pure result
        }
