{- |
Module      : Conformance.Run.Units
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Units (measureUnits, txSizeBytes, emitMeasure, measurePurposeUnits, successfulPurposeUnits, exceedsDeclaredUnits, declaredPurposeUnits, protocolProbePurposeUnits, aggregatePurposeUnits, redeemerPurposeNames) where

import Conformance.Run.Environment
import Conformance.PurposeUnits
import Data.Text qualified as T
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)

import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Api.PParams (
    ppMaxTxExUnitsL,
    ppMaxTxSizeL,
 )
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Ledger (
    ConwayEra,
    ExUnits (..),
 )
import Singular.Registry.Provider qualified as Cage

import Conformance.Mirror (
    emit,
    failWith,
 )

-- ---------------------------------------------------------
-- Measurements (CL01 for these rows)
-- ---------------------------------------------------------

{- | Measure a fold's execution units: summed over the node's
per-script evaluation of the unsigned transaction, while its
inputs are still unspent. Units come from the running node, never
hardcoded.
-}
measurePurposeUnits :: Env -> ConwayTx -> IO PurposeMeasurements
measurePurposeUnits env tx = do
    evalMap <- Cage.evaluateTx (envProv env) tx
    pure $
        Map.fromList
            [ ( T.pack (show purpose)
              , either
                    (Left . T.pack . show)
                    (\(ExUnits mem cpu) -> Right (fromIntegral mem, fromIntegral cpu))
                    result
              )
            | (purpose, result) <- Map.toList evalMap
            ]

successfulPurposeUnits :: PurposeMeasurements -> PurposeUnits
successfulPurposeUnits = Map.mapMaybe (either (const Nothing) Just)

exceedsDeclaredUnits :: PurposeMeasurements -> PurposeUnits -> [T.Text]
exceedsDeclaredUnits measured declared =
    overBudgetPurposes (successfulPurposeUnits measured) declared

declaredPurposeUnits :: ExUnits -> ExUnits -> PurposeMeasurements -> Either T.Text PurposeUnits
declaredPurposeUnits transactionLimit blockLimit =
    allocatePurposeUnits (unitsPair transactionLimit) (unitsPair blockLimit)

protocolProbePurposeUnits :: ExUnits -> ExUnits -> [T.Text] -> Either T.Text PurposeUnits
protocolProbePurposeUnits transactionLimit blockLimit purposes
    | null purposes = Left "cannot allocate protocol probe units without redeemer purposes"
    | otherwise = Right (Map.fromList [(purpose, perPurpose) | purpose <- purposes])
  where
    (maxMem, maxCpu) = protocolUnitsCeiling (unitsPair transactionLimit) (unitsPair blockLimit)
    count = toInteger (length purposes)
    perPurpose = (maxMem `div` count, maxCpu `div` count)

unitsPair :: ExUnits -> (Integer, Integer)
unitsPair (ExUnits mem cpu) = (fromIntegral mem, fromIntegral cpu)

sumPurposeUnits :: PurposeUnits -> (Integer, Integer)
sumPurposeUnits units =
    ( sum [mem | (mem, _) <- Map.elems units]
    , sum [cpu | (_, cpu) <- Map.elems units]
    )

redeemerPurposeNames :: ConwayTx -> [T.Text]
redeemerPurposeNames tx = case tx ^. witsTxL . rdmrsTxWitsL of
    Redeemers purposes -> map (T.pack . show) (Map.keys purposes)

aggregatePurposeUnits :: PurposeMeasurements -> Either T.Text (Integer, Integer)
aggregatePurposeUnits measured = case [reason | Left reason <- Map.elems measured] of
    reason : _ -> Left ("node evaluation failed: " <> reason)
    [] -> Right (sumPurposeUnits (successfulPurposeUnits measured))

measureUnits :: Env -> ConwayTx -> IO (Integer, Integer)
measureUnits env tx = do
    measurements <- measurePurposeUnits env tx
    either (failWith . T.unpack . ("measure: " <>)) pure
        (aggregatePurposeUnits measurements)


-- | Serialized size of the signed transaction that lands on chain.
txSizeBytes :: ConwayTx -> Integer
txSizeBytes tx =
    fromIntegral (BSL.length (serialize (eraProtVerHigh @ConwayEra) tx))


{- | Print one fold's units and size against the devnet's Conway
maxima, with headroom. Maxima are queried, never hardcoded.
-}
emitMeasure :: Env -> String -> Integer -> Integer -> Integer -> IO ()
emitMeasure env label mem cpu size = do
    pp <- Cage.queryProtocolParams (envProv env)
    let ExUnits maxMem maxSteps = pp ^. ppMaxTxExUnitsL
        maxSize = fromIntegral (pp ^. ppMaxTxSizeL) :: Integer
        pct :: Integer -> Integer -> Double
        pct used maxV =
            (fromIntegral used / fromIntegral maxV * 100) ::
                Double
    emit
        "measure"
        ( label
            <> " fold mem="
            <> show mem
            <> "/"
            <> show maxMem
            <> " ("
            <> show (pct mem (fromIntegral maxMem))
            <> "%, headroom "
            <> show (fromIntegral maxMem - mem)
            <> ") cpu="
            <> show cpu
            <> "/"
            <> show maxSteps
            <> " ("
            <> show (pct cpu (fromIntegral maxSteps))
            <> "%, headroom "
            <> show (fromIntegral maxSteps - cpu)
            <> ") size="
            <> show size
            <> "/"
            <> show maxSize
            <> " ("
            <> show (pct size maxSize)
            <> "%, headroom "
            <> show (maxSize - size)
            <> ")"
        )
