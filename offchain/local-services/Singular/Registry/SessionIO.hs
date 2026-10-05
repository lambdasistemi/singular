{- | IO consumers of the generic raw session. These functions acquire no
extra session and choose no provider, evaluator or time conversion policy.
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
    ) where

import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Plutus (ExUnits (..))
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (throwIO)
import Data.Aeson ((.=))
import Data.Either (rights)
import Data.Map.Strict qualified as Map
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.Ledger (Addr, ConwayEra, PParams)
import Singular.Registry.LedgerProvider
    ( Acquisition (..)
    , LedgerProvider (..)
    , Network
    , OutputQuery (..)
    , Outputs
    , ReadFailure
    , Session (..)
    , TipObservation
    )
import Singular.Registry.LocalEvaluation (EvaluateTxResult)
import Singular.Registry.PhaseLog
    ( logPhase
    , phaseLogFromEnv
    , queryPhase
    )
import Singular.Registry.SessionServices qualified as Services

-- | Request Latest on the caller's explicit network and preserve acquisition refusal.
withLatest
    :: (Network, LedgerProvider w IO)
    -> (Session w IO -> IO a)
    -> IO a
withLatest (network, provider) action =
    acquire provider (Latest network) action >>= either throwIO pure

requireFact :: IO (Either ReadFailure (Evidenced w a)) -> IO a
requireFact action = action >>= either throwIO (pure . value)

outputsAt :: Session w IO -> Addr -> IO Outputs
outputsAt session address = requireFact (outputs session (AtAddress address))

parameters :: Session w IO -> IO (PParams ConwayEra)
parameters = requireFact . protocolParameters

tip :: Session w IO -> IO TipObservation
tip = requireFact . tipObservation

registered :: Session w IO -> ScriptHash -> IO Bool
registered session script = requireFact (scriptRegistered session script)

requireService :: IO (Either Services.ServiceFailure a) -> IO a
requireService action = action >>= either refused pure
  where
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
