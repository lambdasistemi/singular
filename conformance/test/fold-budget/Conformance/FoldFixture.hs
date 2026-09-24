-- | Permanent live regression: refuse an honest fold with a measured,
-- insufficient per-purpose budget, then give that same initial budget to
-- the interpreter. Evaluation-derived declarations must make it accepted.
-- This module is compiled only by the fold-budget-regression target.
module Conformance.FoldFixture (Fixture, newFixture, prepare) where

import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL)
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Node.Client.Submitter (SubmitResult (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad (unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import Singular.Registry.Ledger (ExUnits (..))
import Singular.Registry.Provider qualified as Cage

newtype Fixture = Fixture (IORef Bool)

newFixture :: IO Fixture
newFixture = Fixture <$> newIORef False

prepare :: Fixture -> Cage.Provider IO -> (ExUnits -> IO ConwayTx)
    -> (ConwayTx -> IO SubmitResult) -> ExUnits -> IO ExUnits
prepare (Fixture used) provider assemble submit declared = do
    alreadyUsed <- atomicModifyIORef' used (\old -> (True, old))
    if alreadyUsed then pure declared else do
        template <- assemble declared
        let Redeemers redeemers = template ^. witsTxL . rdmrsTxWitsL
            purposes = Map.keys redeemers
        unless (not (null purposes)) $ fail "A1 fold has no redeemer purposes"
        pp <- Cage.queryProtocolParams provider
        let ExUnits maxMem maxCpu = pp ^. ppMaxTxExUnitsL
            count = fromIntegral (length purposes)
        trial <- assemble (ExUnits (maxMem `div` count) (maxCpu `div` count))
        measurements <- Cage.evaluateTx provider trial
        unless (sort (Map.keys measurements) == sort purposes) $
            fail "A1 node evaluation map omits a redeemer purpose"
        measured <- traverse (either (fail . show) pure) measurements
        let pairs = [(mem, cpu) | ExUnits mem cpu <- Map.elems measured]
            (peakMem, peakCpu) = foldr (\(m,c) (a,b) -> (max m a, max c b)) (0,0) pairs
        unless (peakMem > 0 && peakCpu > 0) $ fail "A1 evaluation is empty or zero"
        let fallback = ExUnits (peakMem - 1) (peakCpu - 1)
            overBudget = [purpose | (purpose, ExUnits mem cpu) <- Map.toList measured,
                mem > peakMem - 1 || cpu > peakCpu - 1]
        unless (not (null overBudget)) $ fail "A1 fallback did not underbudget a purpose"
        putStrLn ("A1 node evaluation map: " <> show measured)
        putStrLn ("A1 test-only fallback: " <> show fallback <> " budgetPurposes=" <> show overBudget)
        fixed <- assemble fallback
        result <- submit fixed
        case result of
            Submitted _ -> fail "A1 fixed fallback unexpectedly accepted"
            Rejected reason -> putStrLn
                ("A1 fixed fallback refused: purposes=" <> show overBudget
                    <> " reason=" <> show (TE.decodeUtf8Lenient reason))
        pure fallback
