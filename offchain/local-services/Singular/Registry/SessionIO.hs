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
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Tracer (traceWith)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
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
import Singular.Registry.ProviderTrace (localSource)
import Singular.Registry.SessionServices qualified as Services
import Singular.Registry.Trace
    ( HorizonEnd (..)
    , HorizonWait (..)
    , ReadEvent (..)
    , ValiditySelection (..)
    , evaluationOf
    , startTimer
    , timedTrace
    , tracedQuery
    )
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
parameters session =
    local session "protocolMajorGuard" $
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
    elapsed <- startTimer
    result <-
        tracedQuery
            (sessionTracer session)
            localSource
            Nothing
            "evaluateTx"
            (Just . Map.size)
            (requireService (Services.evaluateTx session tx))
    ms <- elapsed
    traceWith (sessionTracer session) (Evaluated (evaluationOf ms result))
    pure result

floorSlot :: Session w IO -> Integer -> IO SlotNo
floorSlot session ms =
    local
        session
        "posixMsToSlot"
        (requireService (Services.floorSlot session ms))

ceilingSlot :: Session w IO -> Integer -> IO SlotNo
ceilingSlot session ms =
    local
        session
        "posixMsCeilSlot"
        (requireService (Services.ceilingSlot session ms))

slotStart :: Session w IO -> SlotNo -> IO Integer
slotStart session slot =
    local
        session
        "slotStart"
        (requireService (Services.slotStart session slot))

{- | Select before body construction/evaluation. A024 permits one bounded
wait only for a horizon-limited interval. Every tip remains an Unbound read
through the original session; no additional acquisition or submission occurs.
-}
validityUpper
    :: Session w IO -> SlotNo -> Maybe SlotNo -> SlotNo -> IO SlotNo
validityUpper session observed lower upper = do
    let tracer = sessionTracer session
        slot = unSlotNo
        select at =
            local session "ledgerHorizon" $
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
                            local session "ledgerHorizon" $
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
                timedTrace
                    tracer
                    ( \ms end ->
                        HorizonWaited
                            HorizonWait
                                { waitTip = slot observed
                                , waitHorizon = slot oldHorizon
                                , waitLower = slot <$> lower
                                , waitWindowUpper = slot upper
                                , waitMinimumSlots = validityMinimumSlots initial
                                , waitSlotLimit = slotLimit
                                , waitWallLimitMs = 20_000
                                , waitElapsed = ms
                                , waitEnd =
                                    either
                                        HorizonFailed
                                        ( \(at, window) ->
                                            HorizonMoved (slot at) (slot (validityHorizon window))
                                        )
                                        end
                                }
                    )
                    bounded
    traceWith tracer . ValiditySelected $
        ValiditySelection
            { selectedTip = slot selectedTip
            , selectedHorizon = slot (validityHorizon selected)
            , selectedLower = slot <$> lower
            , selectedEffectiveLower =
                max
                    (maybe 0 (toInteger . unSlotNo) lower)
                    (toInteger (unSlotNo selectedTip) + 1)
            , selectedWindowUpper = slot upper
            , selectedUpper = slot (validitySelectedUpper selected)
            , selectedMinimumSlots = validityMinimumSlots selected
            }
    pure (validitySelectedUpper selected)

-- | One local computation over the session, traced into the session's scope.
local :: Session w IO -> Text -> IO a -> IO a
local session name =
    tracedQuery
        (sessionTracer session)
        localSource
        Nothing
        name
        (const (Just 1))
