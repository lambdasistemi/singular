{-# LANGUAGE LambdaCase #-}

{- | The two checks a replay makes before it evaluates anything: the capture
resolves every output the transaction names, and the traced code gets the
deployed application's parameters — shown by the untraced code under them
hashing to the failing hash.
-}
module Conformance.Support.RunReplay (spec) where

import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore qualified as PLC
import PlutusCore.Data qualified as PLC (Data (..))
import PlutusCore.Evaluation.Error qualified as PLC
    ( EvaluationError (..)
    )
import PlutusCore.Evaluation.ErrorWithCause (ErrorWithCause (..))
import PlutusCore.Evaluation.Machine.ExBudget
    ( ExBudget (..)
    , ExRestrictingBudget (..)
    )
import PlutusCore.Evaluation.Machine.Exception (MachineError (..))
import PlutusLedgerApi.Common (serialiseUPLC)
import PlutusLedgerApi.Common qualified as P
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.Evaluation.Machine.Cek (CekUserError (..))

import Singular.Registry.Blueprint (applyBytesParam, applyDataParam)
import Singular.Registry.Ledger (AssetName (..), TokenId (..))
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.Trie qualified as CageTrie
import Singular.Registry.Trie.PureManager (mkPureTrieManager)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , leafTerminal
    )

import Conformance.Replay (RunOutcome (..), UnobservedCause (..))
import Conformance.Run.Book (keyProof)
import Conformance.Run.Replay

-- | A distinct output reference, named by the ledger's own transaction id.
named :: Integer -> TxIn
named n =
    TxIn
        (txIdTx (mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin n) :: ConwayTx))
        (TxIx 0)

output :: TxOut ConwayEra
output =
    mkBasicTxOut
        (addrFromKeyHashBytes Testnet (mconcat (replicate 28 "\x21")))
        (MaryValue (Coin 2_000_000) mempty)

spent, referenced, collateral :: TxIn
spent = named 1
referenced = named 2
collateral = named 3

rejected :: ConwayTx
rejected =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList [spent]
            & referenceInputsTxBodyL .~ Set.fromList [referenced]
            & collateralInputsTxBodyL .~ Set.fromList [collateral]
        )

resolvedAt :: [TxIn] -> Map.Map TxIn (TxOut ConwayEra)
resolvedAt ins = Map.fromList [(i, output) | i <- ins]

-- | A one-parameter validator: @\\p -> body@, flat-encoded.
program
    :: UPLC.Term UPLC.DeBruijn PLC.DefaultUni PLC.DefaultFun ()
    -> ShortByteString
program body =
    serialiseUPLC
        ( UPLC.Program
            ()
            PLC.latestVersion
            (UPLC.LamAbs () (UPLC.DeBruijn 0) body)
        )

untraced, traced :: ShortByteString
untraced = program (UPLC.Var () (UPLC.DeBruijn 1))
traced =
    program
        ( UPLC.Apply
            ()
            (UPLC.LamAbs () (UPLC.DeBruijn 0) (UPLC.Var () (UPLC.DeBruijn 1)))
            (UPLC.Var () (UPLC.DeBruijn 1))
        )

codes :: Map.Map Text (ShortByteString, ShortByteString)
codes = Map.singleton "request.request" (untraced, traced)

application :: String -> DeployedApplication
application token =
    DeployedApplication
        { daTitle = "request.request"
        , daParameters = T.pack token
        , daApply = applyBytesParam (BSC.pack token)
        }

spec :: Spec
spec = describe "before a replay evaluates" $ do
    describe "the capture" $ do
        it "resolving every input, reference input and collateral is complete" $
            checkResolved rejected (resolvedAt [spent, referenced, collateral])
                `shouldBe` Right (resolvedAt [spent, referenced, collateral])
        it "an unresolved reference input makes it capture-incomplete" $
            checkResolved rejected (resolvedAt [spent, collateral])
                `shouldBe` Left CaptureIncomplete
        it "an unresolved spent input makes it capture-incomplete" $
            checkResolved rejected (resolvedAt [referenced, collateral])
                `shouldBe` Left CaptureIncomplete
        it "an unresolved collateral input makes it capture-incomplete" $
            checkResolved rejected (resolvedAt [spent, referenced])
                `shouldBe` Left CaptureIncomplete
    describe "the parameters" $ do
        let failing = computeScriptHash (applyBytesParam "cage-b" untraced)
        it
            "the application reproducing the failing hash gives the traced code"
            $ applyDeployedParameters
                codes
                [application "cage-a", application "cage-b"]
                failing
                `shouldBe` Right
                    AppliedTraced
                        { atTitle = "request.request"
                        , atParameters = "cage-b"
                        , atBytes = applyBytesParam "cage-b" traced
                        , atHash = computeScriptHash (applyBytesParam "cage-b" traced)
                        }
        it "a wrong parameter value is parameters-mismatch" $
            applyDeployedParameters codes [application "cage-a"] failing
                `shouldBe` Left ParametersMismatch
        it "a parameter of the wrong kind is parameters-mismatch" $
            applyDeployedParameters
                codes
                [ DeployedApplication
                    "request.request"
                    "0"
                    (applyDataParam (PLC.I 0))
                ]
                failing
                `shouldBe` Left ParametersMismatch
        it "the traced hash is not the failing hash" $
            fmap
                atHash
                (applyDeployedParameters codes [application "cage-b"] failing)
                `shouldSatisfy` (/= Right failing)
    describe "the proof a fold carries for a key" $ do
        let tid = TokenId (AssetName (SBS.toShort "registry"))
            withControl action = do
                manager <- mkPureTrieManager
                createTrie manager tid
                _ <- withTrie manager tid $ \trie -> CageTrie.insert trie "control" leafTerminal
                action manager
        it "a key the trie does not hold gets a non-empty exclusion proof, the trie untouched" $
            withControl $ \manager -> do
                before <- withTrie manager tid CageTrie.getRoot
                proof <- withSpeculativeTrie manager tid (\trie -> keyProof trie "never-registered")
                after <- withTrie manager tid CageTrie.getRoot
                proof `shouldSatisfy` (not . null)
                after `shouldBe` before
        it "a key the trie holds gets its inclusion proof" $
            withControl $ \manager -> do
                inclusion <- withTrie manager tid (\trie -> CageTrie.getProofSteps trie "control")
                proof <- withSpeculativeTrie manager tid (\trie -> keyProof trie "control")
                Just proof `shouldBe` inclusion
    describe "how an evaluation that did not finish ended" $ do
        let cek e = P.CekError (ErrorWithCause e Nothing)
        it "running out of the budget is budget-exhausted" $
            classify
                ( cek
                    ( PLC.OperationalError
                        (CekOutOfExError (ExRestrictingBudget (ExBudget (-1) (-1))))
                    )
                )
                `shouldBe` BudgetExhausted
        it "a script's error call is a validator failure" $
            classify (cek (PLC.OperationalError CekEvaluationFailure))
                `shouldBe` ValidatorFailure
        it "a failed case over a builtin is a validator failure" $
            classify (cek (PLC.OperationalError (CekCaseBuiltinError "case")))
                `shouldBe` ValidatorFailure
        it "a non-unit result is a validator failure" $
            classify P.InvalidReturnValue `shouldBe` ValidatorFailure
        it "a malformed program is the evaluator's error, not the validator's" $
            classify (cek (PLC.StructuralError OpenTermEvaluatedMachineError))
                `shouldSatisfy` isEvaluationError
        it "a cost model the evaluator cannot use is the evaluator's error" $
            classify P.CostModelParameterMismatch
                `shouldSatisfy` isEvaluationError
  where
    isEvaluationError = \case
        EvaluationError _ -> True
        _ -> False
