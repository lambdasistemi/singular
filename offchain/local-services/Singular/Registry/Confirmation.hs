{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Exact-output confirmation from generic sessions and explicit clock effects.
Confirmation reads have their own acquisitions, after the body is prepared.
-}
module Singular.Registry.Confirmation
    ( ConfirmationRuntime (..)
    , ConfirmationFailure (..)
    , confirmTransaction
    , confirmationWindow
    , newIOConfirmationRuntime
    , awaitTransaction
    ) where

import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx
    ( bodyTxL
    , outputsTxBodyL
    , txIdTx
    , vldtTxBodyL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception (Exception, fromException, throwIO, try)
import Control.Monad qualified
import Data.Foldable (toList)
import Data.Maybe qualified
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Lens.Micro ((^.))
import Singular.Registry.Evidence (value)
import Singular.Registry.LedgerProvider
import Singular.Registry.NetworkTime (NetworkTimeFailure)
import Singular.Registry.SessionServices qualified as Services
import Singular.Registry.Wait
    ( WaitFailure
    , WaitStage (..)
    , boundWaitClosingSince
    , startWaitClock
    , tryOutcome
    )

{- | The consumer supplies clock, sleep and whole-action cancellation effects.
A pure State interpreter supplies the same vocabulary without embedded IO.
-}
data ConfirmationRuntime m = ConfirmationRuntime
    { currentPosixMs :: m Integer
    , pausePolling :: Int -> m ()
    , attemptWindowRead :: forall a. m a -> m (Either ConfirmationFailure a)
    , boundedConfirmation
        :: forall a
         . TxId -> Int -> m (Either Integer a) -> m (Either WaitFailure a)
    }

-- | Raw refusals and infrastructure timeouts remain distinct.
data ConfirmationFailure
    = ConfirmationAcquireFailure AcquireFailure
    | ConfirmationReadFailure ReadFailure
    | ConfirmationTimeFailure NetworkTimeFailure
    | ConfirmationNoOutput TxId
    | ConfirmationWaitFailure WaitFailure
    deriving stock (Show)

instance Exception ConfirmationFailure

data PollObservation = OutputVisible | WindowOpen | WindowClosed

{- | Output zero must be visible under its exact transaction reference.
The finite upper bound is validated before its uncapped two-minute margin;
an unbounded body keeps the existing five-minute wall-clock window.
Retry after one second, then back off to the original five-second interval
so a slow or missing transaction does not multiply provider traffic.
-}
confirmTransaction
    :: forall m w
     . (Monad m)
    => ConfirmationRuntime m
    -> LedgerProvider w m
    -> Network
    -> ConwayTx
    -> m (Either ConfirmationFailure ())
confirmTransaction runtime provider network tx = case toList (tx ^. bodyTxL . outputsTxBodyL) of
    [] -> pure (Left (ConfirmationNoOutput tid))
    _ : _ -> do
        windowResult <- confirmationWindow runtime provider network tx
        case windowResult of
            Left failure -> pure (Left failure)
            Right (deadline, bound) -> do
                result <- boundedConfirmation runtime tid bound (poll deadline 1)
                pure $ case result of
                    Left failure -> Left (ConfirmationWaitFailure failure)
                    Right outcome -> outcome
  where
    tid = txIdTx tx
    wanted = TxIn tid (TxIx 0)
    poll deadline delay = do
        observed <- readScope provider network $ \session -> do
            exact <- outputs session (AtTxIn wanted)
            case exact of
                Right fact | any ((== wanted) . fst) (value fact) -> pure (Right OutputVisible)
                Left (MissingOutput missing)
                    | missing /= wanted ->
                        pure (Left (ConfirmationReadFailure (MissingOutput missing)))
                Left failure@(ConflictingOutput _) -> pure (Left (ConfirmationReadFailure failure))
                Left failure@(ReleasedSession _) -> pure (Left (ConfirmationReadFailure failure))
                Left failure@(BackendReadFailure _) -> pure (Left (ConfirmationReadFailure failure))
                Left failure@(NetworkTimeRefusal _) -> pure (Left (ConfirmationReadFailure failure))
                _ -> do
                    tip <- tipObservation session
                    pure $ case tip of
                        Left failure -> Left (ConfirmationReadFailure failure)
                        Right fact ->
                            Right
                                ( if toInteger (observedBlockTime (value fact)) * 1000 < deadline
                                    then WindowOpen
                                    else WindowClosed
                                )
        case observed of
            Left failure -> pure (Right (Left failure))
            Right WindowClosed -> pure (Left deadline)
            Right WindowOpen ->
                pausePolling runtime delay >> poll deadline (min 5 (delay * 2))
            Right OutputVisible -> pure (Right (Right ()))

{- | Derive the same bounded window used by 'confirmTransaction'. A private
read-only recorder may inspect it without inventing a transaction output or
starting a visibility poll. This performs no submission or confirmation.
-}
confirmationWindow
    :: (Monad m)
    => ConfirmationRuntime m
    -> LedgerProvider w m
    -> Network
    -> ConwayTx
    -> m (Either ConfirmationFailure (Integer, Int))
confirmationWindow runtime provider network tx = do
    result <-
        boundedConfirmation runtime (txIdTx tx) 30 (Right <$> window)
    pure (either (Left . ConfirmationWaitFailure) id result)
  where
    window = do
        attempted <- attemptWindowRead runtime $ readScope provider network $ \session -> case invalidHereafter (tx ^. bodyTxL . vldtTxBodyL) of
            SJust upper -> do
                start <- Services.slotStart session upper
                pure $ case start of
                    Right ms -> Right (Just (ms + 120000))
                    Left (Services.ServiceTimeFailure failure) -> Left (ConfirmationTimeFailure failure)
                    Left (Services.ServiceReadFailure failure) -> Left (ConfirmationReadFailure failure)
                    Left failure ->
                        Left
                            (ConfirmationReadFailure (BackendReadFailure (showService failure)))
            SNothing -> do
                tip <- tipObservation session
                case tip of
                    Left failure -> pure (Left (ConfirmationReadFailure failure))
                    Right fact -> do
                        checked <- Services.slotStart session (observedSlot (value fact))
                        pure $ case checked of
                            Right _ -> Right Nothing
                            Left (Services.ServiceTimeFailure failure) -> Left (ConfirmationTimeFailure failure)
                            Left (Services.ServiceReadFailure failure) -> Left (ConfirmationReadFailure failure)
                            Left failure ->
                                Left
                                    (ConfirmationReadFailure (BackendReadFailure (showService failure)))
        let derived = Control.Monad.join attempted
        selected <- case derived of
            -- Preserve the historical synchronous context-read fallback. Its
            -- independent block-time read is still within the window-read bound.
            Left (ConfirmationReadFailure _) -> do
                fallback <- readScope provider network $ \session ->
                    fmap
                        (either (Left . ConfirmationReadFailure) (const (Right ())))
                        (tipObservation session)
                pure (Nothing <$ fallback)
            other -> pure other
        case selected of
            Left failure -> pure (Left failure)
            Right supplied -> do
                now <- currentPosixMs runtime
                let deadline = Data.Maybe.fromMaybe (now + 300000) supplied
                    seconds = max 0 ((deadline - now + 999) `div` 1000)
                pure (Right (deadline, fromInteger seconds + 10))

readScope
    :: (Monad m)
    => LedgerProvider w m
    -> Network
    -> (Session w m -> m (Either ConfirmationFailure a))
    -> m (Either ConfirmationFailure a)
readScope provider network action = do
    acquired <- acquire provider (Latest network) action
    pure (either (Left . ConfirmationAcquireFailure) id acquired)

-- | IO cancellation preserves the original wait failure and other exceptions.
newIOConfirmationRuntime :: IO (ConfirmationRuntime IO)
newIOConfirmationRuntime = do
    clock <- startWaitClock
    pure
        ConfirmationRuntime
            { currentPosixMs = round . (* 1000) <$> getPOSIXTime
            , pausePolling = \seconds -> threadDelay (seconds * 1000000)
            , attemptWindowRead = \action -> do
                result <- tryOutcome action
                pure $ case result of
                    Right answer -> Right answer
                    Left failure -> case fromException failure of
                        Just timeFailure -> Left (ConfirmationTimeFailure timeFailure)
                        Nothing ->
                            Left
                                ( ConfirmationReadFailure
                                    (BackendReadFailure (Text.pack (show failure)))
                                )
            , boundedConfirmation = \tid bound action ->
                try
                    (boundWaitClosingSince clock SessionConfirmationWait tid bound action)
            }

{- | Production IO callers rethrow wait failures as infrastructure exceptions,
retaining the existing timeout identity instead of publishing a refusal.
-}
awaitTransaction
    :: LedgerProvider w IO -> Network -> ConwayTx -> IO ()
awaitTransaction provider network tx = do
    runtime <- newIOConfirmationRuntime
    result <- confirmTransaction runtime provider network tx
    case result of
        Left (ConfirmationWaitFailure failure) -> throwIO failure
        Left failure -> throwIO failure
        Right () -> pure ()

showService :: Services.ServiceFailure -> Text.Text
showService = Text.pack . show
