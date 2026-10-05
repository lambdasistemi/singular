{- |
Module      : Singular.Registry.LocalEvaluation
Description : Ledger evaluation from complete resolved input facts
License     : Apache-2.0

Evaluation uses only the transaction, protocol parameters, resolved outputs
and validated network time supplied by the caller. The resolver may run in a
pure fixture monad. No node connection or provider evaluation is acquired here.
-}
module Singular.Registry.LocalEvaluation
    ( EvaluateTxResult
    , EvaluationContext (..)
    , EvaluationFailure (..)
    , localEvaluation
    , evaluateResolved
    , evaluationInputs
    ) where

import Control.Exception (Exception)
import Control.Monad (foldM, unless)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Ledger.Alonzo.Plutus.Evaluate
    ( TransactionScriptFailure
    , evalTxExUnits
    )
import Cardano.Ledger.Alonzo.Scripts (AsIx, PlutusPurpose)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, bodyTxL)
import Cardano.Ledger.Plutus (ExUnits)
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.NetworkTime
    ( NetworkTime
    , networkEpochInfo
    , networkSystemStart
    )

-- | Every script purpose's actual ledger answer, including script failures.
type EvaluateTxResult era =
    Map
        (PlutusPurpose AsIx era)
        (Either (TransactionScriptFailure era) ExUnits)

-- | Immutable context supplied by the transaction's one acquired read view.
data EvaluationContext = EvaluationContext
    { evaluationParameters :: PParams ConwayEra
    , evaluationNetworkTime :: NetworkTime
    }

-- | Input-resolution refusals, distinct from the ledger's script failures.
data EvaluationFailure
    = MissingEvaluationInputs (Set TxIn)
    | ConflictingEvaluationInput TxIn
    deriving stock (Eq, Show)

instance Exception EvaluationFailure

-- | The complete spent, collateral and reference-output extent of a body.
evaluationInputs :: ConwayTx -> Set TxIn
evaluationInputs tx =
    let body = tx ^. bodyTxL
    in  Set.unions
            [ body ^. inputsTxBodyL
            , body ^. collateralInputsTxBodyL
            , body ^. referenceInputsTxBodyL
            ]

-- | Resolve raw facts through the supplied effect, then compute locally.
localEvaluation
    :: (Monad m)
    => EvaluationContext
    -> (Set TxIn -> m [(TxIn, TxOut ConwayEra)])
    -> ConwayTx
    -> m (Either EvaluationFailure (EvaluateTxResult ConwayEra))
localEvaluation context resolve tx =
    evaluateResolved context tx <$> resolve (evaluationInputs tx)

{- | Equal duplicate facts are harmless; conflicting duplicates and missing
material refuse before the ledger evaluator runs. Full output equality
includes address, value, datum and reference script.
-}
evaluateResolved
    :: EvaluationContext
    -> ConwayTx
    -> [(TxIn, TxOut ConwayEra)]
    -> Either EvaluationFailure (EvaluateTxResult ConwayEra)
evaluateResolved context tx inputs = do
    outputs <- foldM insert Map.empty inputs
    let missing = evaluationInputs tx `Set.difference` Map.keysSet outputs
    unless (Set.null missing) (Left (MissingEvaluationInputs missing))
    let time = evaluationNetworkTime context
    pure $
        evalTxExUnits
            (evaluationParameters context)
            tx
            (UTxO outputs)
            (networkEpochInfo time)
            (networkSystemStart time)
  where
    insert known (reference, output) = case Map.lookup reference known of
        Just previous | previous /= output -> Left (ConflictingEvaluationInput reference)
        _ -> Right (Map.insert reference output known)
