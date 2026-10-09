{- | IO consumers of the generic raw session. These functions acquire no
extra session and choose no provider or evaluator. The bounded pre-signing
horizon wait implements the explicit A024 minimum-window rule.
Failures preserve their original type and payload at the IO boundary.
-}
module Singular.Registry.SessionIO
    ( withLatest
    , outputsAt
    , outputsAtAddress
    , outputsAtTxIn
    , outputsHolding
    , outputsCarrying
    , mintRecordOf
    , readOutputsAt
    , fundableOutputsAt
    , fundedView
    , sessionScope
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
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Tracer (traceWith)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.Ledger (Addr, ConwayEra, PParams)
import Singular.Registry.LedgerProvider
    ( Acquisition (..)
    , Asset
    , LedgerProvider (..)
    , MintRecord (..)
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
import Singular.Registry.WalletOutputs (fundable, selectFunding)
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

{- | Named reads (A-001 §2): fixed-query runners over the abstract
session. Builders and commands name one of these, never the generic
'OutputQuery' mechanism. Each preserves the underlying read's evidence
and failure semantics exactly.
-}

-- | The outputs at one address, with their evidence.
outputsAtAddress
    :: Session w m -> Addr -> m (Either ReadFailure (Evidenced w Outputs))
outputsAtAddress session address = outputs session (AtAddress address)

-- | The output at one exact reference, with its evidence.
outputsAtTxIn
    :: Session w m -> TxIn -> m (Either ReadFailure (Evidenced w Outputs))
outputsAtTxIn session ref = outputs session (AtTxIn ref)

-- | The outputs holding any quantity of this asset.
outputsHolding
    :: Session w m -> Asset -> m (Either ReadFailure (Evidenced w Outputs))
outputsHolding session asset = outputs session (HoldingAsset asset)

-- | The outputs carrying a reference script with this hash.
outputsCarrying
    :: Session w m
    -> ScriptHash
    -> m (Either ReadFailure (Evidenced w Outputs))
outputsCarrying session hash = outputs session (CarryingReferenceScript hash)

-- | The mint record for this asset, when the provider knows one.
mintRecordOf
    :: Session w m
    -> Asset
    -> m (Either ReadFailure (Evidenced w (Maybe MintRecord)))
mintRecordOf session asset = mintRecord session asset

-- | The outputs at one address, read failure thrown as 'outputsAt' throws it.
readOutputsAt :: Session w IO -> Addr -> IO Outputs
readOutputsAt session address = requireFact (outputsAtAddress session address)

{- | The fundable outputs at one address (ordering is the caller's):
ada-only with no reference script. Identical to reading through
'fundingView' with no reservation.
-}
fundableOutputsAt :: Session w IO -> Addr -> IO Outputs
fundableOutputsAt session address =
    filter (fundable . snd) <$> readOutputsAt session address

-- | The session's own identity and binding, as its receipts name them.
sessionScope :: Session w m -> (SessionId, SessionBinding)
sessionScope session = (sessionId session, sessionBinding session)

{- | A view in which the wallet's own address holds only the output the caller
named to fund the fold: the production fold funds and collateralises from
the largest ada-only output of the wallet it reads, and takes no funding
argument. The named output must be an ada-only output of that wallet. With
none named the view is the fold's own.
-}
fundedView
    :: Maybe TxIn
    -> Addr
    -> Session NoWitness IO
    -> IO (Either String (Session NoWitness IO))
fundedView Nothing _ v = pure (Right v)
fundedView chosen addr v = do
    wallet <- readOutputsAt v addr
    pure $ case selectFunding chosen wallet of
        Left why -> Left why
        Right one ->
            Right
                v
                    { outputs = \query ->
                        fmap (fmap (select query one)) (outputs v query)
                    }
  where
    select (AtAddress address) one fact
        | address == addr =
            fact{value = filter ((== fst one) . fst) (value fact)}
    select _ _ fact = fact

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
    let evaluation = evaluationOf ms result
    sessionEvaluated session evaluation
    traceWith (sessionTracer session) (Evaluated evaluation)
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
