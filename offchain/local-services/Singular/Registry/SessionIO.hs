{- | IO consumers of the generic raw session. These functions acquire no
extra session and choose no provider or evaluator. The bounded pre-signing
horizon wait implements the explicit A024 minimum-window rule.
Failures preserve their original type and payload at the IO boundary.
-}
module Singular.Registry.SessionIO
    ( withLatest
    , outputsAt
    , parameters
    , tip
    , registered
    , evaluateTx
    , floorSlot
    , ceilingSlot
    , slotStart
    , validityUpper
    ) where

import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Plutus (ExUnits (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Either (rights)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (Addr, ConwayEra, PParams)
import Singular.Registry.LedgerProvider
    ( Acquisition (..)
    , LedgerProvider (..)
    , Network
    , OutputQuery (..)
    , Outputs
    , ReadFailure (..)
    , Session (..)
    , TipObservation (..)
    )
import Singular.Registry.LocalEvaluation (EvaluateTxResult)
import Singular.Registry.NetworkTime
    ( NetworkTimeFailure (..)
    , ValidityWindow (..)
    )
import Singular.Registry.PhaseLog
    ( logPhase
    , phaseLogFromEnv
    , queryPhase
    , timedPhase
    )
import Singular.Registry.SessionServices qualified as Services
import System.Timeout (timeout)

-- | Request Latest on the caller's explicit network and preserve acquisition refusal.
withLatest
    :: (Network, LedgerProvider w IO)
    -> (Session w IO -> IO a)
    -> IO a
withLatest (network, provider) action =
    acquire provider (Latest network) action >>= either throwIO pure

requireFact :: IO (Either ReadFailure (Evidenced w a)) -> IO a
requireFact action = action >>= either refused (pure . value)
  where
    refused (NetworkTimeRefusal failure) = throwIO failure
    refused failure = throwIO failure

outputsAt :: Session w IO -> Addr -> IO Outputs
outputsAt session address = requireFact (outputs session (AtAddress address))

parameters :: Session w IO -> IO (PParams ConwayEra)
parameters session = do
    logHandle <- phaseLogFromEnv
    queryPhase logHandle "protocolMajorGuard" (const 1) $
        requireService (Services.parameters session)

tip :: Session w IO -> IO TipObservation
tip = requireFact . tipObservation

registered :: Session w IO -> ScriptHash -> IO Bool
registered session script = requireFact (scriptRegistered session script)

requireService :: IO (Either Services.ServiceFailure a) -> IO a
requireService action = action >>= either refused pure
  where
    refused (Services.ServiceReadFailure (NetworkTimeRefusal failure)) = throwIO failure
    refused (Services.ServiceReadFailure failure) = throwIO failure
    refused (Services.ServiceEvaluationFailure failure) = throwIO failure
    refused (Services.ServiceTimeFailure failure) = throwIO failure

{- | The common evaluator consumes the full normal, collateral and reference
input extent through this same session. Logging reports its actual result.
-}
evaluateTx
    :: Session w IO -> ConwayTx -> IO (EvaluateTxResult ConwayEra)
evaluateTx session tx = do
    logHandle <- phaseLogFromEnv
    result <-
        queryPhase
            logHandle
            "evaluateTx"
            Map.size
            (requireService (Services.evaluateTx session tx))
    let done = rights (Map.elems result)
        total f = sum [toInteger (f units) | units <- done]
    logPhase
        logHandle
        "eval"
        [ "redeemers" .= Map.size result
        , "failed" .= (Map.size result - length done)
        , "mem" .= total (\(ExUnits memory _) -> memory)
        , "steps" .= total (\(ExUnits _ steps) -> steps)
        ]
    pure result

floorSlot :: Session w IO -> Integer -> IO SlotNo
floorSlot session ms = do
    logHandle <- phaseLogFromEnv
    queryPhase
        logHandle
        "posixMsToSlot"
        (const 1)
        (requireService (Services.floorSlot session ms))

ceilingSlot :: Session w IO -> Integer -> IO SlotNo
ceilingSlot session ms = do
    logHandle <- phaseLogFromEnv
    queryPhase
        logHandle
        "posixMsCeilSlot"
        (const 1)
        (requireService (Services.ceilingSlot session ms))

slotStart :: Session w IO -> SlotNo -> IO Integer
slotStart session slot = do
    logHandle <- phaseLogFromEnv
    queryPhase
        logHandle
        "slotStart"
        (const 1)
        (requireService (Services.slotStart session slot))

{- | Select before body construction/evaluation. A024 permits one bounded
wait only for a horizon-limited interval. Every tip remains an Unbound read
through the original session; no additional acquisition or submission occurs.
-}
validityUpper
    :: Session w IO -> SlotNo -> Maybe SlotNo -> SlotNo -> IO SlotNo
validityUpper session observed lower upper = do
    logHandle <- phaseLogFromEnv
    let select at =
            queryPhase logHandle "ledgerHorizon" (const 1) $
                requireService (Services.validityWindow session at lower upper)
    initial <- select observed
    (selectedTip, selected) <-
        if not (validityNeedsHorizonWait initial)
            then pure (observed, initial)
            else do
                let oldHorizon = validityHorizon initial
                    slotLimit = toInteger (unSlotNo observed) + validityMinimumSlots initial
                lastObservation <- newIORef (observed, oldHorizon)
                let wait = do
                        -- A fresh actual observation, without reacquiring or
                        -- retaining a provider response for later reuse.
                        current <- observedSlot <$> tip session
                        horizon <-
                            queryPhase logHandle "ledgerHorizon" (const 1) $
                                requireService (Services.observedHorizon session current)
                        writeIORef lastObservation (current, horizon)
                        if toInteger (unSlotNo current) > slotLimit
                            then throwIO (HorizonWaitTimedOut current horizon)
                            else
                                if horizon > oldHorizon
                                    then do
                                        -- Reselect only at the actual wake point;
                                        -- an intermediate short registry window
                                        -- must not end the horizon observation.
                                        next <- select current
                                        if validityNeedsHorizonWait next
                                            then
                                                throwIO
                                                    ( WindowTooShort
                                                        current
                                                        (validityHorizon next)
                                                        lower
                                                        upper
                                                        (validityMinimumSlots next)
                                                    )
                                            else pure (current, next)
                                    else
                                        if toInteger (unSlotNo current) >= slotLimit
                                            then throwIO (HorizonWaitTimedOut current horizon)
                                            else threadDelay 100_000 >> wait
                    bounded = do
                        result <- timeout 20_000_000 wait
                        case result of
                            Just answer -> pure answer
                            Nothing -> do
                                (lastTip, lastHorizon) <- readIORef lastObservation
                                throwIO (HorizonWaitTimedOut lastTip lastHorizon)
                timedPhase
                    logHandle
                    "horizon-wait"
                    [ "tip" .= observed
                    , "horizon" .= oldHorizon
                    , "lower" .= lower
                    , "windowUpper" .= upper
                    , "minimumSlots" .= validityMinimumSlots initial
                    , "slotLimit" .= slotLimit
                    , "wallLimitMs" .= (20_000 :: Integer)
                    ]
                    ( \(at, window) -> ["observedTip" .= at, "observedHorizon" .= validityHorizon window]
                    )
                    bounded
    logPhase
        logHandle
        "validityUpper"
        [ "tip" .= selectedTip
        , "horizon" .= validityHorizon selected
        , "lower" .= lower
        , "effectiveLower"
            .= max
                (maybe 0 (toInteger . unSlotNo) lower)
                (toInteger (unSlotNo selectedTip) + 1)
        , "windowUpper" .= upper
        , "upper" .= validitySelectedUpper selected
        , "minimumSlots" .= validityMinimumSlots selected
        ]
    pure (validitySelectedUpper selected)
