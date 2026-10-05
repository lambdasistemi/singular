{-# LANGUAGE LambdaCase #-}

{- | Fixed local computations over one generic ledger session's raw facts.
The caller's monad supplies reads; these services acquire no session, perform
no transport operation of their own, and select no evaluation or time policy.
-}
module Singular.Registry.SessionServices
    ( ServiceFailure (..)
    , parameters
    , evaluateTx
    , floorSlot
    , ceilingSlot
    , slotStart
    , validityUpper
    ) where

import Cardano.Ledger.Api.PParams (ppProtocolVersionL)
import Cardano.Ledger.BaseTypes (ProtVer (..))
import Cardano.Ledger.Binary (getVersion)
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (Exception)
import Control.Monad (unless)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Lens.Micro ((^.))
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.LedgerProvider
    ( Network (..)
    , OutputQuery (..)
    , ReadFailure
    , Session (..)
    )
import Singular.Registry.LocalEvaluation
    ( EvaluateTxResult
    , EvaluationContext (..)
    , EvaluationFailure
    , evaluateResolved
    , evaluationInputs
    )
import Singular.Registry.NetworkTime
    ( NetworkTime
    , NetworkTimeFailure (..)
    , capValidityUpper
    , ledgerHorizon
    , networkMagic
    , posixMsCeilingSlot
    , posixMsFloorSlot
    , slotStartMs
    , validateProtocolMajor
    )

-- | Preserve the specific raw-read, evaluation or conversion refusal.
data ServiceFailure
    = ServiceReadFailure ReadFailure
    | ServiceEvaluationFailure EvaluationFailure
    | ServiceTimeFailure NetworkTimeFailure
    deriving stock (Eq, Show)

instance Exception ServiceFailure

rawFact
    :: (Monad m)
    => m (Either ReadFailure (Evidenced w a)) -> ExceptT ServiceFailure m a
rawFact = fmap value . ExceptT . fmap (first ServiceReadFailure)

timeOf
    :: (Monad m) => Session w m -> ExceptT ServiceFailure m NetworkTime
timeOf session = do
    time <- rawFact (networkTime session)
    let Network requested = sessionNetwork session
    unless (requested == networkMagic time) $
        throwE
            (ServiceTimeFailure (WrongTimeNetwork requested (networkMagic time)))
    pure time

guardMajor
    :: (Monad m)
    => NetworkTime -> PParams ConwayEra -> ExceptT ServiceFailure m ()
guardMajor time pp =
    let ProtVer major _ = pp ^. ppProtocolVersionL
    in  ExceptT . pure . first ServiceTimeFailure $
            validateProtocolMajor time (getVersion major)

-- | The common builder parameter boundary refuses before constructing a body.
parameters
    :: (Monad m)
    => Session w m -> m (Either ServiceFailure (PParams ConwayEra))
parameters session = runExceptT $ do
    pp <- rawFact (protocolParameters session)
    time <- timeOf session
    guardMajor time pp
    pure pp

{- | Resolve the body's full spent, collateral and reference-input extent,
then invoke the common ledger evaluator on exactly those facts.
-}
evaluateTx
    :: (Monad m)
    => Session w m
    -> ConwayTx
    -> m (Either ServiceFailure (EvaluateTxResult ConwayEra))
evaluateTx session tx = runExceptT $ do
    pp <- rawFact (protocolParameters session)
    time <- timeOf session
    guardMajor time pp
    resolved <- case NE.nonEmpty (Set.toAscList (evaluationInputs tx)) of
        Nothing -> pure []
        Just references -> rawFact (outputs session (AnyOf (fmap AtTxIn references)))
    ExceptT . pure . first ServiceEvaluationFailure $
        evaluateResolved (EvaluationContext pp time) tx resolved

floorSlot
    :: (Monad m)
    => Session w m -> Integer -> m (Either ServiceFailure SlotNo)
floorSlot session ms = runExceptT $ do
    time <- timeOf session
    ExceptT . pure . first ServiceTimeFailure $ posixMsFloorSlot time ms

ceilingSlot
    :: (Monad m)
    => Session w m -> Integer -> m (Either ServiceFailure SlotNo)
ceilingSlot session ms = runExceptT $ do
    time <- timeOf session
    ExceptT . pure . first ServiceTimeFailure $ posixMsCeilingSlot time ms

slotStart
    :: (Monad m)
    => Session w m -> SlotNo -> m (Either ServiceFailure Integer)
slotStart session slot = runExceptT $ do
    time <- timeOf session
    ExceptT . pure . first ServiceTimeFailure $ slotStartMs time slot

-- | Select inside one build's explicitly observed window, without reacquiring.
validityUpper
    :: (Monad m)
    => Session w m
    -> SlotNo
    -> Maybe SlotNo
    -> SlotNo
    -> m (Either ServiceFailure (SlotNo, SlotNo))
validityUpper session observed lower upper = runExceptT $ do
    time <- timeOf session
    ExceptT . pure . first ServiceTimeFailure $ do
        horizon <- ledgerHorizon time observed
        capped <- capValidityUpper time observed lower upper
        pure (horizon, capped)
