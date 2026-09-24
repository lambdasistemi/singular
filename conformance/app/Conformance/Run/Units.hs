{- |
Module      : Conformance.Run.Units
Description : Split out of Conformance.Run (#263); see that module's header
License     : Apache-2.0
-}
module Conformance.Run.Units (measureUnits, txSizeBytes, emitMeasure) where

import Conformance.Run.Environment

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
measureUnits :: Env -> ConwayTx -> IO (Integer, Integer)
measureUnits env tx = do
    evalMap <- Cage.evaluateTx (envProv env) tx
    let evalStr = Map.map (either (Left . show) Right) evalMap
    units <- case sequence evalStr of
        Left e ->
            failWith ("measure: node evaluation failed: " <> e)
        Right m -> pure (Map.elems m)
    let mem = sum [m | ExUnits m _ <- units]
        cpu = sum [s | ExUnits _ s <- units]
    pure (fromIntegral mem, fromIntegral cpu)


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
