{- | What a traced replay admits as a refusal's reason, and how an admitted
reason meets the model's: every cause and every comparison outcome, each
as its own case, and a control that the cases cover every cause there is.
-}
module Conformance.Support.Replay (spec) where

import Data.Aeson (object, (.=))
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
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
                       , "no-replay-route"
                       , "parameters-mismatch"
                       , "unidentified-script"
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
    describe "a refused step against Lean's reason" $ do
        it "every purpose of the judged script admitting Lean's reason agrees" $
            stepComparison "m" "retract-owner" [("m", Admitted "retract-owner")]
                `shouldBe` Agrees
        it "an admitted reason other than Lean's differs, naming both" $
            stepComparison "m" "not-phase2" [("m", Admitted "retract-owner")]
                `shouldBe` Differs "retract-owner" "not-phase2"
        it "an unobserved reason is uncompared, with its cause" $
            stepComparison "m" "key-unknown" [("m", Unobserved NoUserTrace)]
                `shouldBe` Uncompared NoUserTrace
        it "another script's reason does not enter the step's comparison" $
            stepComparison
                "m"
                "retract-state-spent"
                [ ("s", Admitted "missing-action")
                , ("m", Admitted "retract-state-spent")
                ]
                `shouldBe` Agrees
        it "one purpose of the judged script differing makes the step differ" $
            stepComparison
                "m"
                "not-booked"
                [("m", Admitted "not-booked"), ("m", Admitted "root")]
                `shouldBe` Differs "root" "not-booked"
        it "a judged script that did not fail leaves the step uncompared" $
            stepComparison "m" "not-booked" [("s", Admitted "not-booked")]
                `shouldBe` Uncompared ContextUnavailable
        it "each comparison is spelled as the replay index spells it" $
            map
                comparisonName
                [Agrees, Differs "a" "b", Uncompared Timeout]
                `shouldBe` ["agrees", "differs", "uncompared"]
        it "the attributed script's admitted reason is its receipt branch" $ do
            admittedFor "m" [("m", Admitted "key-exists"), ("s", Admitted "x")]
                `shouldBe` Just "key-exists"
            admittedFor
                "m"
                [("m", Admitted "key-exists"), ("m", Unobserved NoUserTrace)]
                `shouldBe` Nothing
            admittedFor "m" [("m", Admitted "a"), ("m", Admitted "b")]
                `shouldBe` Nothing
            admittedFor "m" [("s", Admitted "key-exists")] `shouldBe` Nothing
    describe "the accepting controls the index must carry" $ do
        let refusal role =
                object ["kind" .= ("refusal" :: Text), "role" .= (role :: Text)]
            control role deployed traced =
                object
                    [ "kind" .= ("accepting-control" :: Text)
                    , "controls"
                        .= [ object
                                [ "role" .= (role :: Text)
                                , "deployed" .= object ["outcome" .= (deployed :: Text)]
                                , "traced" .= object ["outcome" .= (traced :: Text)]
                                ]
                           ]
                    ]
            succeeded role = control role "succeeded" "succeeded"
        it "every refusing role with a succeeding control is complete" $
            acceptingControlGaps
                [ refusal "state.state"
                , refusal "request.request+state.state"
                , succeeded "state.state"
                , succeeded "request.request"
                ]
                `shouldBe` []
        it "a refusing role with no control is a gap" $
            acceptingControlGaps
                [ refusal "request.request+state.state"
                , succeeded "state.state"
                ]
                `shouldBe` ["request.request: no accepting control"]
        it "a control whose traced run failed is a gap" $
            acceptingControlGaps
                [ refusal "state.state"
                , control "state.state" "succeeded" "validator-failure"
                ]
                `shouldBe` ["state.state: no accepting control with both runs succeeded"]
        it "a control whose deployed run failed is a gap" $
            acceptingControlGaps
                [ refusal "state.state"
                , control "state.state" "budget-exhausted" "succeeded"
                ]
                `shouldBe` ["state.state: no accepting control with both runs succeeded"]
        it
            "a role that is only a bare hash needs no control, and none is invented"
            $ acceptingControlGaps [refusal "80d434cb", refusal "unattributed"]
                `shouldBe` []
    describe "which script a failing hash is" $ do
        let families =
                [ ScriptFamily "state.state" True ["aa"]
                , ScriptFamily "witness.witness" True ["bb", "cc"]
                , ScriptFamily "open.open" False ["dd"]
                ]
        it "a routed family whose application reproduces the hash is replayed" $
            identifyScript families Nothing "cc"
                `shouldBe` Right "witness.witness"
        it "a reproduced hash is replayed whatever role the capture records" $
            identifyScript families (Just "open.open") "aa"
                `shouldBe` Right "state.state"
        it "a family the replay does not trace is no-replay-route" $
            identifyScript families Nothing "dd" `shouldBe` Left NoReplayRoute
        it
            "a recorded family none of whose applications reproduce the hash is parameters-mismatch"
            $ identifyScript families (Just "witness.witness") "ee"
                `shouldBe` Left ParametersMismatch
        it
            "a hash no family reproduces and no role names is unidentified-script"
            $ identifyScript families Nothing "ee"
                `shouldBe` Left UnidentifiedScript
        it "the classifier alone reaches the three identification causes" $
            [ cause
            | (role, hash) <-
                [(Nothing, "dd"), (Just "witness.witness", "ee"), (Nothing, "ee")]
            , Left cause <- [identifyScript families role hash]
            ]
                `shouldBe` [NoReplayRoute, ParametersMismatch, UnidentifiedScript]
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
            "the deployed blueprint the traced build corresponds to admits replays"
            $ toolchainCause provenance (tpUntracedHashes provenance)
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
    describe "the evidence a receipt carries" $ do
        let purpose hash traced = PurposeReplay "spend" hash traced Nothing Nothing
        it
            "an admitted purpose carries its reason, both hashes and the capture"
            $ rejectionEvidence
                (Just "capture")
                ["dh"]
                [purpose "dh" (Just "th") (Admitted "key-exists")]
                [Admitted "key-exists"]
                `shouldBe` [ ReplayEvidence
                                "dh"
                                (Just "th")
                                (Just "key-exists")
                                Nothing
                                (Just "capture")
                           ]
        it "an unobserved purpose carries its cause by name and no reason" $
            rejectionEvidence
                (Just "capture")
                ["dh"]
                [purpose "dh" Nothing (Unobserved NoReplayRoute)]
                [Unobserved NoReplayRoute]
                `shouldBe` [ ReplayEvidence
                                "dh"
                                Nothing
                                Nothing
                                (Just "no-replay-route")
                                (Just "capture")
                           ]
        it
            "every failing purpose is carried, in the order the replay met them"
            $ map
                replayDeployedHash
                ( rejectionEvidence
                    (Just "capture")
                    ["state", "request"]
                    [ purpose "state" (Just "ts") (Admitted "missing-action")
                    , purpose "request" (Just "tr") (Admitted "retract-state-spent")
                    ]
                    [Admitted "missing-action", Admitted "retract-state-spent"]
                )
                `shouldBe` ["state", "request"]
        it
            "a replay that ended before any purpose gives each failing hash its cause"
            $ rejectionEvidence Nothing ["h1", "h2"] [] [Unobserved Timeout]
                `shouldBe` [ ReplayEvidence hash Nothing Nothing (Just "timeout") Nothing
                           | hash <- ["h1", "h2"]
                           ]
        it
            "the correspondence states the traced build and digests its untraced hashes"
            $ do
                let provenance hashes =
                        TracedProvenance
                            { tpSource = "/nix/store/source"
                            , tpCompiler = "v1.1.21"
                            , tpFlags = "--trace-filter user-defined --trace-level verbose"
                            , tpUntracedHashes = Map.fromList hashes
                            }
                    deployed = [("state.state.spend", "aa"), ("request.request.spend", "bb")]
                    stated = correspondenceOf (provenance deployed)
                ( correspondenceSource stated
                    , correspondenceCompiler stated
                    , correspondenceFlags stated
                    )
                    `shouldBe` ( "/nix/store/source"
                               , "v1.1.21"
                               , "--trace-filter user-defined --trace-level verbose"
                               )
                T.length (correspondenceDigest stated) `shouldBe` 64
                correspondenceDigest
                    (correspondenceOf (provenance (reverse deployed)))
                    `shouldBe` correspondenceDigest stated
                correspondenceDigest
                    ( correspondenceOf
                        ( provenance
                            [("state.state.spend", "aa"), ("request.request.spend", "bc")]
                        )
                    )
                    `shouldNotBe` correspondenceDigest stated
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
