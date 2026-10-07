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

import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (throwIO)
import Control.Monad (unless)
import Control.Tracer (traceWith)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
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
import Singular.Registry.Provider (ChainPoint (..), View (..))
import Singular.Registry.ProviderTrace (localSource)
import Singular.Registry.Trace
    ( ReadEvent (..)
    , evaluationOf
    , startTimer
    , tracedQuery
    )

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
    let tracer = viewTracer view
    elapsed <- startTimer
    result <- tracedQuery tracer localSource Nothing "evaluateTx" (Just . Map.size) $ do
        time <- timeOf view
        localEvaluation
            (EvaluationContext (viewProtocolParams view) time)
            (viewResolvedOutputs view)
            tx
            >>= either throwIO pure
    ms <- elapsed
    traceWith tracer (Evaluated (evaluationOf ms result))
    pure result

floorSlot :: View IO -> Integer -> IO SlotNo
floorSlot view ms =
    local view "posixMsToSlot" $ do
        time <- timeOf view
        either throwIO pure (posixMsFloorSlot time ms)

ceilingSlot :: View IO -> Integer -> IO SlotNo
ceilingSlot view ms =
    local view "posixMsCeilSlot" $ do
        time <- timeOf view
        either throwIO pure (posixMsCeilingSlot time ms)

slotStart :: View IO -> SlotNo -> IO Integer
slotStart view slot =
    local view "slotStart" $ do
        time <- timeOf view
        either throwIO pure (slotStartMs time slot)

-- | One local computation over the view, traced into the view's scope.
local :: View IO -> Text -> IO a -> IO a
local view name =
    tracedQuery
        (viewTracer view)
        localSource
        Nothing
        name
        (const (Just 1))
