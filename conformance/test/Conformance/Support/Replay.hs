{- | What a traced replay admits as a refusal's reason, and how an admitted
reason meets the model's: every cause and every comparison outcome, each
as its own case, and a control that the cases cover every cause there is.
-}
module Conformance.Support.Replay (spec) where

import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)

import Conformance.Replay

run :: RunOutcome -> [Text] -> ReplayRun
run outcome logs =
    ReplayRun
        { runBytesHash = "bytes"
        , runBudgetLimit = (100, 100)
        , runBudgetUsed = case outcome of
            Succeeded -> Just (10, 10)
            _ -> Nothing
        , runOutcome = outcome
        , runLogs = logs
        }

-- | The deployed bytes carry no trace; the ledger refused them.
refusedDeployed :: ReplayRun
refusedDeployed = run ValidatorFailure []

{- | Each case: its name, the deployed run, the traced run, an earlier cause,
and what the replay must admit.
-}
admissionCases
    :: [(String, ReplayRun, ReplayRun, Maybe UnobservedCause, ReplayClass)]
admissionCases =
    [
        ( "one user trace on a refused traced run is the reason, verbatim"
        , refusedDeployed
        , run ValidatorFailure ["not-phase2"]
        , Nothing
        , Admitted "not-phase2"
        )
    ,
        ( "a blank log line is not a user trace"
        , refusedDeployed
        , run ValidatorFailure ["", "deposit-returned", "  "]
        , Nothing
        , Admitted "deposit-returned"
        )
    ,
        ( "the deployed run succeeding admits nothing"
        , run Succeeded []
        , run ValidatorFailure ["root"]
        , Nothing
        , Unobserved DeployedSucceeds
        )
    ,
        ( "the deployed run out of budget admits nothing"
        , run BudgetExhausted []
        , run ValidatorFailure ["root"]
        , Nothing
        , Unobserved DeployedBudget
        )
    ,
        ( "the traced run succeeding admits nothing"
        , refusedDeployed
        , run Succeeded []
        , Nothing
        , Unobserved TracedSucceeds
        )
    ,
        ( "the traced run out of budget admits nothing"
        , refusedDeployed
        , run BudgetExhausted ["key-exists"]
        , Nothing
        , Unobserved TracedBudget
        )
    ,
        ( "a traced failure with no user trace admits nothing"
        , refusedDeployed
        , run ValidatorFailure []
        , Nothing
        , Unobserved NoUserTrace
        )
    ,
        ( "a traced failure with two user traces admits neither"
        , refusedDeployed
        , run ValidatorFailure ["approval-quantity", "destination"]
        , Nothing
        , Unobserved SeveralUserTraces
        )
    ,
        ( "the evaluator failing on the deployed run admits nothing"
        , run (EvaluationError "codec") []
        , run ValidatorFailure ["root"]
        , Nothing
        , Unobserved EvaluatorFailed
        )
    ,
        ( "the evaluator failing on the traced run admits nothing"
        , refusedDeployed
        , run (EvaluationError "cost model") []
        , Nothing
        , Unobserved EvaluatorFailed
        )
    ]
        <> [ ( "an earlier " <> show cause <> " wins over two refusing runs"
             , refusedDeployed
             , run ValidatorFailure ["not-booked"]
             , Just cause
             , Unobserved cause
             )
           | cause <- [minBound .. maxBound]
           ]

comparisonCases :: [(String, Text, ReplayClass, ReasonComparison)]
comparisonCases =
    [
        ( "an admitted reason equal to Lean's agrees"
        , "retract-owner"
        , Admitted "retract-owner"
        , Agrees
        )
    ,
        ( "an admitted reason other than Lean's differs, naming both"
        , "not-phase2"
        , Admitted "retract-owner"
        , Differs "retract-owner" "not-phase2"
        )
    ]
        <> [ ( "an unobserved " <> show cause <> " is not compared"
             , "deposit-returned"
             , Unobserved cause
             , Uncompared cause
             )
           | cause <- [minBound .. maxBound]
           ]

spec :: Spec
spec = describe "traced replay of a live refusal" $ do
    describe "what a replay admits" $
        mapM_
            ( \(name, deployed, traced, earlier, expected) ->
                it name $ admitReason deployed traced earlier `shouldBe` expected
            )
            admissionCases
    describe "a reason against Lean's" $
        mapM_
            ( \(name, lean, replay, expected) ->
                it name $ compareReason lean replay `shouldBe` expected
            )
            comparisonCases
    it "the cases reach every cause through admitReason itself" $
        sort (nub [cause | Unobserved cause <- admitted])
            `shouldBe` [minBound .. maxBound]
    it "the two runs alone reach exactly the run causes" $
        sort (nub [cause | Unobserved cause <- runAdmitted])
            `shouldBe` [ DeployedSucceeds
                       , DeployedBudget
                       , TracedSucceeds
                       , TracedBudget
                       , NoUserTrace
                       , SeveralUserTraces
                       , EvaluatorFailed
                       ]
    it "every cause is spelled as the replay evidence contract spells it" $
        map causeName [minBound .. maxBound]
            `shouldBe` [ "capture-incomplete"
                       , "context-unavailable"
                       , "toolchain-mismatch"
                       , "parameters-mismatch"
                       , "deployed-succeeds"
                       , "deployed-budget"
                       , "traced-succeeds"
                       , "traced-budget"
                       , "no-user-trace"
                       , "several-user-traces"
                       , "phase-1"
                       , "setup-failure"
                       , "timeout"
                       , "client-exception"
                       , "evaluation-error"
                       ]
    describe "the toolchain" $ do
        let provenance =
                TracedProvenance
                    { tpSource = "/nix/store/source"
                    , tpCompiler = "v1.1.21"
                    , tpFlags = "--trace-filter user-defined --trace-level verbose"
                    , tpUntracedHashes =
                        Map.fromList
                            [("state.state.spend", "aa"), ("request.request.spend", "bb")]
                    }
        it
            "the deployed blueprint the traced build corresponds to admits replays" $
            toolchainCause provenance (tpUntracedHashes provenance)
                `shouldBe` Nothing
        it "a moved deployed hash is toolchain-mismatch" $
            toolchainCause
                provenance
                (Map.insert "request.request.spend" "cc" (tpUntracedHashes provenance))
                `shouldBe` Just ToolchainMismatch
        it "a deployed validator the traced build lacks is toolchain-mismatch" $
            toolchainCause
                provenance
                (Map.insert "witness.witness.mint" "dd" (tpUntracedHashes provenance))
                `shouldBe` Just ToolchainMismatch
    it "a capture's identity ignores file order and follows content" $ do
        let files = [("a.cbor", "one"), ("b.json", "two")]
        captureIdOf files `shouldBe` captureIdOf (reverse files)
        captureIdOf files
            `shouldNotBe` captureIdOf [("a.cbor", "one"), ("b.json", "tw0")]
        captureIdOf files
            `shouldNotBe` captureIdOf [("a.cbor", "two"), ("b.json", "one")]

-- | What 'admitReason' answers for every case, and for the run-only cases.
admitted, runAdmitted :: [ReplayClass]
admitted = [admitReason d t earlier | (_, d, t, earlier, _) <- admissionCases]
runAdmitted =
    [admitReason d t Nothing | (_, d, t, Nothing, _) <- admissionCases]
