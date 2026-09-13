{- | Unit tests for node-failure attribution (NOTE-023 item 2).

The journey's @requireRefusal@ matches the node's NAMED failed-witness
field (@The script hash is:ScriptHash \"HEX\"@), never a substring
anywhere in the context. These tests pin that matcher against compacted
excerpts of REAL ledger refusal reasons (register exhibit, order and
format preserved; 4KB script bodies elided):

- @consumerBudget@: the hook-crosswired refusal — consumer hash named,
  budget exhausted, state hash present later in context;
- @stateSemantic@: the hook-omitted refusal — state hash named, plain
  predicate error, no budget language;
- @extraneousWitness@: a ledger-level refusal naming a hash WITHOUT
  the named field (must not match anything).
-}
module Cardano.MPFS.Cage.FailureMatchSpec (spec) where

import Cardano.MPFS.Cage.TxBuilder.Internal (
    evalScriptHash,
    failedWitnessHash,
    isBudgetFailure,
 )
import Test.Hspec (Spec, describe, it, shouldBe)

consumerHash :: String
consumerHash = "e61455043f0ba3177e9fd8d4b873b7b59fdea15de167ea29a0097b26"

stateHash :: String
stateHash = "82e9a9bdd2a65d73f9f3f60e54fd03f57f5b472fa641bf1b1a8c8619"

consumerBudget :: String
consumerBudget =
    "(FailedUnexpectedly (PlutusFailure \"\\nThe PlutusV3 script failed.\"\n"
        <> "The script hash is:ScriptHash \""
        <> consumerHash
        <> "\"\n"
        <> "The machine terminated part way through evaluation due to overspending the budget.\n"
        <> "ScriptCredential: "
        <> stateHash
        <> " (no staking credential)"

stateSemantic :: String
stateSemantic =
    "(FailedUnexpectedly (PlutusFailure \"\\nThe PlutusV3 script failed.\"\n"
        <> "The script hash is:ScriptHash \""
        <> stateHash
        <> "\"\n"
        <> "The plutus evaluation error is: CekError An error has occurred:\n"
        <> "The machine terminated because of an error, either from a built-in function or from an explicit use of 'error'.\n"
        <> "Caused by: error"

extraneousWitness :: String
extraneousWitness =
    "ConwayUtxowFailure (ExtraneousScriptWitnessesUTXOW (NonEmptySet (fromList [ScriptHash \""
        <> consumerHash
        <> "\"])))"

-- Compacted excerpt of the fork-81 retained builder-evaluation refusal
-- (ticket-81 evidence, order and format preserved): the occupied-key
-- EvalFailure names its purpose, the CekError body, and the failed
-- witness's script hash field.
forkEvalHash :: String
forkEvalHash = "fa90391a470d726da369275cc1ae1be9c35a6d1f3885107e4227794d"

forkEvalRefusal :: String
forkEvalRefusal =
    "EvalFailure (ConwaySpending (AsIx {unAsIx = 2})) \"ValidationFailure (CekError "
        <> "PlutusWithContext {pwcProtocolVersion = Version 10, pwcScriptHash = ScriptHash \""
        <> forkEvalHash
        <> "\"}"

spec :: Spec
spec = describe "node-failure attribution" $ do
    it "parses the consumer hash from a budget refusal" $
        failedWitnessHash consumerBudget `shouldBe` Just consumerHash
    it "parses the state hash from a semantic refusal" $
        failedWitnessHash stateSemantic `shouldBe` Just stateHash
    it "does not attribute a consumer failure to state (negative control)" $
        (failedWitnessHash consumerBudget == Just stateHash)
            `shouldBe` False
    it "does not attribute a state failure to the consumer (reverse)" $
        (failedWitnessHash stateSemantic == Just consumerHash)
            `shouldBe` False
    it "matches the state expectation on its own failure" $
        (failedWitnessHash stateSemantic == Just stateHash)
            `shouldBe` True
    it "detects budget exhaustion" $
        isBudgetFailure consumerBudget `shouldBe` True
    it "does not mistake a semantic failure for budget" $
        isBudgetFailure stateSemantic `shouldBe` False
    it "matches nothing without the named field" $
        failedWitnessHash extraneousWitness `shouldBe` Nothing
    it "parses the eval failure's named script field (NOTE-018)" $
        evalScriptHash forkEvalRefusal `shouldBe` Just forkEvalHash
    it "does not match node-refusal text as an eval field" $
        evalScriptHash consumerBudget `shouldBe` Nothing
    it "does not match eval text as a node-refusal field" $
        failedWitnessHash forkEvalRefusal `shouldBe` Nothing
