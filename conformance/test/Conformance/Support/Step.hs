{- | Which submitted transaction the model judges.

Appendix material: once the law accepts a step, the driver judges the
transaction the runner submitted, whatever the chain answered to it. A node
rejection the runner cannot attribute to a script still rejected a submitted
transaction, and the model's verdict on it is still owed.
-}
module Conformance.Support.Step (spec) where

import Data.Aeson (Value (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import Test.Hspec (Spec, describe, it, shouldBe)

import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, mkBasicTxBody)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Tx.Ledger (ConwayTx)

import Conformance.Run.Step (
    StepOutcome (..),
    StepRejection (..),
    judgedTransaction,
    refusedOutcome,
 )

-- | A submitted transaction, told apart by its fee.
submitted :: ConwayTx
submitted = mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin 1_180_563)

-- | A node rejection with no budget exceeded, in the node's words.
rejection :: String -> StepRejection
rejection text = StepRejection (T.pack text) Map.empty Map.empty []

-- | The script the step's refusal is attributed to.
marker :: String
marker = "874e476d"

-- | The node's phase-2 refusal naming that script.
scriptRefusal :: String
scriptRefusal = "ConwayUtxowFailure/UtxoFailure/UtxosFailure/ValidationTagMismatch/FailedUnexpectedly/PlutusFailure | CekError: Caused by: error (PlutusWithContext {pwcScriptHash = ScriptHash 874e476d})"

-- | The node's phase-1 refusal of a live retraction in run 36066233387.
collateralRefusal :: String
collateralRefusal = "HardForkApplyTxErrFromEra S (S (S (S (S (S (Z (WrapApplyTxErr {unwrapApplyTxErr = ConwayApplyTxError (ConwayUtxowFailure (UtxoFailure (InsufficientCollateral (DeltaCoin (-29999999081618799)) (Coin 1770845))) :| [ConwayUtxowFailure (UtxoFailure (IncorrectTotalCollateralField (DeltaCoin (-29999999081618799)) (Coin 511035)))])}))))))"

-- | The id of the transaction the model is handed, if any.
judgedId :: Value -> StepOutcome -> Maybe String
judgedId law outcome = show . txIdTx <$> judgedTransaction law outcome

spec :: Spec
spec = describe "Which submitted transaction the model judges" $ do
    let own = Just (show (txIdTx submitted))
    it "judges a transaction the chain accepted" $
        judgedId (String "accepted") (StepAccepted submitted (0, 0, 0)) `shouldBe` own
    it "judges a transaction the chain refused for a script it names" $
        judgedId (String "accepted") (refusedOutcome marker submitted (rejection scriptRefusal))
            `shouldBe` own
    it "judges a transaction the node rejected for a reason it attributes to no script" $
        judgedId (String "accepted") (refusedOutcome marker submitted (rejection collateralRefusal))
            `shouldBe` own
    it "judges nothing the law already refused" $
        judgedId (String "refused") (refusedOutcome marker submitted (rejection collateralRefusal))
            `shouldBe` Nothing
