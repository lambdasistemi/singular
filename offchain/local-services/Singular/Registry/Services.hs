{- | Common local computations over an acquired view's raw facts.
Adapters supply immutable time context, parameters and exact resolved outputs.
The evaluator and conversions are fixed here; the provider selects neither.
-}
module Singular.Registry.Services
    ( evaluateTx
    , floorSlot
    , ceilingSlot
    , slotStart
    ) where

import Cardano.Ledger.Plutus (ExUnits (..))
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson ((.=))
import Data.Either (rights)
import Data.Map.Strict qualified as Map
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.LocalEvaluation
    ( EvaluateTxResult
    , EvaluationContext (..)
    , localEvaluation
    )
import Singular.Registry.NetworkTime
    ( NetworkTime
    , NetworkTimeFailure (..)
    , networkMagic
    , posixMsCeilingSlot
    , posixMsFloorSlot
    , slotStartMs
    )
import Singular.Registry.PhaseLog (logPhase, queryPhase)
import Singular.Registry.Provider (ChainPoint (..), View (..))

-- | Validate the binding to this view's network before deriving any answer.
timeOf :: View IO -> IO NetworkTime
timeOf view = do
    time <- viewTimeContext view
    let requested = cpNetwork (viewPoint view)
    unless (requested == networkMagic time) $
        throwIO (WrongTimeNetwork requested (networkMagic time))
    pure time

evaluateTx :: View IO -> ConwayTx -> IO (EvaluateTxResult ConwayEra)
evaluateTx view tx = do
    let lg = viewPhaseLog view
    result <- queryPhase lg "evaluateTx" Map.size $ do
        time <- timeOf view
        localEvaluation
            (EvaluationContext (viewProtocolParams view) time)
            (viewResolvedOutputs view)
            tx
            >>= either throwIO pure
    let done = rights (Map.elems result)
        total f = sum [toInteger (f units) | units <- done]
    logPhase
        lg
        "eval"
        [ "redeemers" .= Map.size result
        , "failed" .= (Map.size result - length done)
        , "mem" .= total (\(ExUnits memory _) -> memory)
        , "steps" .= total (\(ExUnits _ steps) -> steps)
        ]
    pure result

floorSlot :: View IO -> Integer -> IO SlotNo
floorSlot view ms =
    queryPhase (viewPhaseLog view) "posixMsToSlot" (const 1) $ do
        time <- timeOf view
        either throwIO pure (posixMsFloorSlot time ms)

ceilingSlot :: View IO -> Integer -> IO SlotNo
ceilingSlot view ms =
    queryPhase (viewPhaseLog view) "posixMsCeilSlot" (const 1) $ do
        time <- timeOf view
        either throwIO pure (posixMsCeilingSlot time ms)

slotStart :: View IO -> SlotNo -> IO Integer
slotStart view slot =
    queryPhase (viewPhaseLog view) "slotStart" (const 1) $ do
        time <- timeOf view
        either throwIO pure (slotStartMs time slot)
