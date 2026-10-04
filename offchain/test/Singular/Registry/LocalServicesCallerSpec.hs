-- | A real existing balancer must declare units sufficient for its final body.
module Singular.Registry.LocalServicesCallerSpec (spec) where

import Cardano.Ledger.Alonzo.Plutus.Evaluate (evalTxExUnits)
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.Plutus (ExUnits (..))
import Cardano.Ledger.State (UTxO (..))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import Singular.Registry.LocalEvaluation
    ( EvaluationContext (..)
    , evaluateResolved
    )
import Singular.Registry.LocalEvaluationSpec (fixture)
import Singular.Registry.NetworkTime
    ( networkEpochInfo
    , networkSystemStart
    )
import Singular.Registry.Provider (View (..))
import Singular.Registry.StubView (stubView)
import Singular.Registry.TxBuilder.Internal
    ( evaluateAndBalanceReferencing
    )
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "Common services through the existing transaction balancer" $
    it
        "declares sufficient units for exactly the actual final-body purposes" $ do
        (ctx, inputs, tx, _, _, _) <- fixture
        fault <- (== Just "1") <$> lookupEnv "LOCAL_SERVICES_CALLER_FAULT"
        calls <- newIORef (0 :: Int)
        let pp = evaluationParameters ctx
            time = evaluationNetworkTime ctx
            view =
                stubView
                    { viewProtocolParams = pp
                    , viewEvaluateTx = \candidate -> do
                        modifyIORef' calls (+ 1)
                        actual <-
                            either (fail . show) pure (evaluateResolved ctx candidate inputs)
                        pure $
                            if fault
                                then Map.map (const (Right (ExUnits 1 1))) actual
                                else actual
                    }
        case inputs of
            funding : collateral : reference : [] -> do
                balanced <-
                    evaluateAndBalanceReferencing
                        view
                        pp
                        [funding, collateral]
                        [reference]
                        (snd funding ^. addrTxOutL)
                        tx
                count <- readIORef calls
                count `shouldSatisfy` (> 1)
                -- This expected answer calls the imported ledger directly,
                -- outside both the builder loop and the new common evaluator.
                let measured =
                        evalTxExUnits
                            pp
                            balanced
                            (UTxO (Map.fromList inputs))
                            (networkEpochInfo time)
                            (networkSystemStart time)
                    Redeemers witnesses = balanced ^. witsTxL . rdmrsTxWitsL
                    declared = Map.map snd witnesses
                    failures = [purpose | (purpose, Left _) <- Map.toList measured]
                    units = Map.mapMaybe (either (const Nothing) Just) measured
                    fits (ExUnits memory steps) (ExUnits statedMemory statedSteps) =
                        memory <= statedMemory && steps <= statedSteps
                Map.size measured `shouldSatisfy` (> 0)
                failures `shouldBe` []
                Map.keysSet units `shouldBe` Map.keysSet declared
                Map.isSubmapOfBy fits units declared `shouldBe` True
            _ -> fail "UnexpectedRecordedInputExtent"
