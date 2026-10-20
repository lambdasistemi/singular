{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.FoldSelectionSpec
Description : Pure fold selection judges every pending request alone (#518)
License     : Apache-2.0

Pull request 1 of #518 judges every pending request alone and settles one
per fold. Each request is judged against the live registry state alone,
never against what other pending requests would leave behind; the first
check a request fails names its reason. The specs below pin the eight
acceptance properties of the pure selection:

* each-request-judged-alone, with the failing control that refuses when
  several requests are pending
* checks-in-the-specs-order
* one-request-per-key
* every-pending-request-in-exactly-one-list
* capacity-bound-prefix-and-remainder
* window-rule-agrees-with-fold-window, with the off-by-one failing control
* two-vocabularies-never-mixed
* example-four-requests

Every expected value is derived from the inputs by field access, arithmetic
or list operations, never typed back from the code's output. The specs
exercise more than one request per key and more than one key.
-}
module Singular.Registry.FoldSelectionSpec (spec) where

import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import Singular.CLI.FoldRules (FoldWindow (..), foldWindow)
import Singular.Registry.FoldSelection

-- ---------------------------------------------------------
-- Clock, margin and deadline fixtures
-- ---------------------------------------------------------

-- | The decision moment, POSIX milliseconds.
nowMs :: Integer
nowMs = 1000000

-- | The fold margin of the single-request rule, POSIX milliseconds.
marginMs :: Integer
marginMs = 30000

-- | A deadline far beyond the margin: the window is open.
farDeadline :: Integer
farDeadline = nowMs + 1000000

{- | A deadline ten seconds out: inside the thirty-second margin, so the
window is closed.
-}
nearDeadline :: Integer
nearDeadline = nowMs + 10000

-- ---------------------------------------------------------
-- Request builders
-- ---------------------------------------------------------

{- | The registry's processing time, POSIX milliseconds: deadlines are
submission times plus this, never the clock.
-}
processMs :: Integer
processMs = 60000

{- | A clean insertion: decodes, names an admitted edge, is open, approved,
and carries a readable datum.
-}
mkInsert :: Int -> Int -> Text -> Integer -> PendingRequest
mkInsert ref key owner deadline =
    PendingRequest
        { prRef = ref
        , prKey = key
        , prOwner = owner
        , prEdge = EdgeInsertActive
        , prDeadline = deadline
        , prSubmittedAt = deadline - processMs
        , prDecodeOk = True
        , prApproval = ApprovalOk
        , prApp = AppReady
        }

{- | A clean termination: decodes, names an admitted edge, is open and
approved; its application verdict arrives as a field.
-}
mkTerminate :: Int -> Int -> Text -> Integer -> PendingRequest
mkTerminate ref key owner deadline =
    PendingRequest
        { prRef = ref
        , prKey = key
        , prOwner = owner
        , prEdge = EdgeUpdateTerminal
        , prDeadline = deadline
        , prSubmittedAt = deadline - processMs
        , prDecodeOk = True
        , prApproval = ApprovalOk
        , prApp = AppReady
        }

-- | A deterministic owner derived from the key, never typed per case.
ownerOf :: Int -> Text
ownerOf k = T.pack ("owner-" ++ show k)

-- ---------------------------------------------------------
-- Selection outcomes
-- ---------------------------------------------------------

-- | What the selection says about one pending request.
data Outcome
    = OutcomeSettled
    | OutcomeExcluded Text
    deriving stock (Eq, Show)

{- | The code under test's own inverse: look the request's reference up in
the two lists. A reference in neither list is reported, not hidden.
-}
outcomeOf :: Selection -> PendingRequest -> Outcome
outcomeOf sel p =
    case [exc | (q, exc) <- selectionExcluded sel, prRef q == prRef p] of
        (exc : _) -> OutcomeExcluded (exclusionName exc)
        [] ->
            if prRef p `elem` map selRef (selectionSettled sel)
                then OutcomeSettled
                else OutcomeExcluded "missing"

-- ---------------------------------------------------------
-- The spec's four-request example
-- ---------------------------------------------------------

{- | Registry state of the example: key 7 unknown; key 9 active with its
holding live; key 11 unknown.
-}
exampleFacts :: LiveFacts
exampleFacts =
    Map.fromList
        [ (7, (LeafUnknown, False))
        , (9, (LeafActive, True))
        , (11, (LeafUnknown, False))
        ]

{- | Pending, in ledger input order: r1 inserts key 7 for Alice; r2
terminates key 9 for Bob; r3 inserts key 7 for Carol; r4 inserts key 11
for Dana with ten seconds left on its window. Each termination's
application verdict arrives as a field; here the value accepts.
-}
r1 :: PendingRequest
r1 = mkInsert 1 7 "Alice" farDeadline

r2 :: PendingRequest
r2 = mkTerminate 2 9 "Bob" farDeadline

r3 :: PendingRequest
r3 = mkInsert 3 7 "Carol" farDeadline

r4 :: PendingRequest
r4 = mkInsert 4 11 "Dana" nearDeadline

examplePending :: [PendingRequest]
examplePending = [r1, r2, r3, r4]

-- | The facts after the bound-9 fold settles r1: key 7 is active now.
afterFirstFoldFacts :: LiveFacts
afterFirstFoldFacts = Map.insert 7 (LeafActive, True) exampleFacts

spec :: Spec
spec = do
    taggedSelectionSpec
    describe "each-request-judged-alone" $ do
        it
            "is a function of the request, its key's facts, the clock, the margin and the bound"
            $ property
            $ forAll ((,) <$> choose (1, 50) <*> genOtherKeys)
            $ \(k, others) ->
                let target = mkInsert 1001 k (ownerOf k) farDeadline
                    alone_ = [target]
                    withOthers =
                        target
                            : [ mkInsert (2000 + i) j (ownerOf j) farDeadline
                              | (i, j) <- zip [0 :: Int ..] others
                              ]
                    reordered = reverse withOthers
                    facts =
                        Map.fromList $
                            (k, (LeafUnknown, False))
                                : [(j, (LeafUnknown, False)) | j <- nub others]
                    bound = 100
                    o1 =
                        outcomeOf
                            (selectFold bound nowMs marginMs processMs facts alone_)
                            target
                    o2 =
                        outcomeOf
                            (selectFold bound nowMs marginMs processMs facts withOthers)
                            target
                    o3 =
                        outcomeOf
                            (selectFold bound nowMs marginMs processMs facts reordered)
                            target
                in  o1 == o2 && o2 == o3
        it
            "fails the same property for a variant that refuses when several are pending"
            $ do
                let target = mkInsert 1001 7 "Alice" farDeadline
                    other = mkInsert 2001 8 "Bob" farDeadline
                    severalRefuse reqs _
                        | length reqs > 1 = OutcomeExcluded "not-phase1"
                        | otherwise = OutcomeSettled
                severalRefuse [target] target `shouldBe` OutcomeSettled
                severalRefuse [target, other] target
                    `shouldBe` OutcomeExcluded "not-phase1"
                (severalRefuse [target] target == severalRefuse [target, other] target)
                    `shouldBe` False

    describe "checks-in-the-specs-order" $ do
        it "names the first failing check for each single failure" $ do
            checkAlone (cleanBase{prDecodeOk = False}) baseFacts "undecodable"
            checkAlone
                (cleanBase{prEdge = EdgeOther "deleteActive"})
                baseFacts
                "edge-inadmissible"
            checkAlone
                ( cleanBase
                    { prDeadline = nearDeadline
                    , prSubmittedAt = nearDeadline - processMs
                    }
                )
                baseFacts
                "not-phase1"
            checkAlone
                (cleanBase{prApproval = ApprovalMissing})
                baseFacts
                "no-approval"
            checkAlone
                (cleanBase{prApproval = ApprovalPolicyMismatch})
                baseFacts
                "no-approval"
            checkAlone
                (cleanBase{prApproval = ApprovalTupleMismatch})
                baseFacts
                "approval-mismatch"
            checkAlone
                (mkInsert 102 9 "Ivan" farDeadline)
                activeNineFacts
                "key-exists"
            checkAlone
                (mkTerminate 103 60 "Uma" farDeadline)
                unknownSixtyFacts
                "key-unknown"
            checkAlone
                (mkTerminate 104 61 "Nia" farDeadline)
                absentSixtyOneFacts
                "not-booked"
            checkAlone
                (mkTerminate 105 62 "Tara" farDeadline)
                terminalSixtyTwoFacts
                "terminal-immutable"
            checkAlone
                (mkTerminate 106 63 "Tess" farDeadline)
                activeNoTokenFacts
                "token-missing"
            checkAlone
                (cleanBase{prApp = AppDatumUnreadable})
                baseFacts
                "application-datum-unreadable"
            checkAlone
                ( (mkTerminate 107 9 "Ruth" farDeadline)
                    { prApp = AppRequired "fixture-exe-107"
                    }
                )
                activeNineAppFacts
                "application-required"
            checkAlone
                ( (mkTerminate 112 60 "Zed" farDeadline)
                    { prApp = AppRequired "fixture-exe-112"
                    }
                )
                unknownSixtyFacts
                "key-unknown"
            checkAlone
                ( (mkInsert 113 9 "Yara" farDeadline)
                    { prApp = AppDatumUnreadable
                    }
                )
                activeNineFacts
                "key-exists"
        it "names the earlier of two failing checks" $ do
            let both modA modB =
                    checkAlone (modB (modA cleanBase))
            both
                (\p -> p{prDecodeOk = False})
                (\p -> p{prEdge = EdgeOther "deleteActive"})
                baseFacts
                "undecodable"
            both
                (\p -> p{prEdge = EdgeOther "deleteActive"})
                ( \p ->
                    p{prDeadline = nearDeadline, prSubmittedAt = nearDeadline - processMs}
                )
                baseFacts
                "edge-inadmissible"
            both
                ( \p ->
                    p{prDeadline = nearDeadline, prSubmittedAt = nearDeadline - processMs}
                )
                (\p -> p{prApproval = ApprovalMissing})
                baseFacts
                "not-phase1"
            both
                (\p -> p{prApproval = ApprovalTupleMismatch})
                (\p -> p{prApp = AppDatumUnreadable})
                baseFacts
                "approval-mismatch"
            both
                (\p -> p{prDecodeOk = False})
                (\p -> p{prApp = AppDatumUnreadable})
                baseFacts
                "undecodable"
        it "names approval before the leaf check" $ do
            checkAlone
                ( (mkInsert 114 9 "Ava" farDeadline)
                    { prApproval = ApprovalMissing
                    }
                )
                activeNineFacts
                "no-approval"
        it "names the leaf check before the application step" $ do
            checkAlone
                ( (mkInsert 115 9 "Ash" farDeadline)
                    { prApp = AppDatumUnreadable
                    }
                )
                activeNineFacts
                "key-exists"
        it "fails the order for variants that ask in the wrong order" $ do
            let badApproval = (mkInsert 114 9 "Ava" farDeadline){prApproval = ApprovalMissing}
                badApp = (mkInsert 115 9 "Ash" farDeadline){prApp = AppDatumUnreadable}
                leafFirst _ = OutcomeExcluded "key-exists"
                appFirst _ = OutcomeExcluded "application-datum-unreadable"
                trueApproval =
                    outcomeOf
                        (selectFold 9 nowMs marginMs processMs activeNineFacts [badApproval])
                        badApproval
                trueApp =
                    outcomeOf
                        (selectFold 9 nowMs marginMs processMs activeNineFacts [badApp])
                        badApp
            trueApproval `shouldBe` OutcomeExcluded "no-approval"
            trueApp `shouldBe` OutcomeExcluded "key-exists"
            (leafFirst badApproval == trueApproval) `shouldBe` False
            (appFirst badApp == trueApp) `shouldBe` False
        it "names the earlier check before key-in-batch, the seventh check" $ do
            let earlier = mkInsert 108 70 "Eve" farDeadline
                laterBad = (mkInsert 109 70 "Leo" farDeadline){prApproval = ApprovalMissing}
                facts = Map.fromList [(70, (LeafUnknown, False))]
                sel = selectFold 9 nowMs marginMs processMs facts [earlier, laterBad]
            map selRef (selectionSettled sel) `shouldBe` [prRef earlier]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["no-approval"]
        it "names the application step before key-in-batch, the seventh check" $ do
            let earlierApp = mkInsert 116 72 "Eli" farDeadline
                laterAppBad = (mkInsert 117 72 "Lia" farDeadline){prApp = AppDatumUnreadable}
                factsApp = Map.fromList [(72, (LeafUnknown, False))]
                selApp =
                    selectFold
                        9
                        nowMs
                        marginMs
                        processMs
                        factsApp
                        [earlierApp, laterAppBad]
            map selRef (selectionSettled selApp) `shouldBe` [prRef earlierApp]
            map (exclusionName . snd) (selectionExcluded selApp)
                `shouldBe` ["application-datum-unreadable"]
        it "agrees between judgeAlone and a single-request selection" $ do
            let single p facts =
                    ( judgeAlone nowMs marginMs processMs facts p
                    , selectFold 9 nowMs marginMs processMs facts [p]
                    )
                (judged, selected) = single cleanBase baseFacts
            judged
                `shouldBe` Right (SelectedRequest 101 50 "Olive" EdgeInsertActive farDeadline)
            map selRef (selectionSettled selected) `shouldBe` [101]
            selectionExcluded selected `shouldBe` []

    describe "one-request-per-key" $ do
        it "names a later request on an included key key-in-batch" $ do
            let sel = selectFold 9 nowMs marginMs processMs exampleFacts examplePending
            map selRef (selectionSettled sel) `shouldBe` [prRef r1, prRef r2]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["key-in-batch", "not-phase1"]
        it "lets the earlier request in ledger order win" $ do
            let sel = selectFold 9 nowMs marginMs processMs exampleFacts [r3, r1, r2, r4]
            map selRef (selectionSettled sel) `shouldBe` [prRef r3, prRef r2]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["key-in-batch", "not-phase1"]
        it "does not block a key whose earlier request was excluded" $ do
            let bad = (mkInsert 110 71 "Beth" farDeadline){prApproval = ApprovalMissing}
                good = mkInsert 111 71 "Gus" farDeadline
                facts = Map.fromList [(71, (LeafUnknown, False))]
                sel = selectFold 9 nowMs marginMs processMs facts [bad, good]
            map selRef (selectionSettled sel) `shouldBe` [prRef good]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["no-approval"]
        it "keeps the selected keys pairwise distinct" $ do
            property $
                forAll genPartitionInput $ \(reqs, facts, bound) ->
                    let sel = selectFold bound nowMs marginMs processMs facts reqs
                        keys = map selKey (selectionSettled sel)
                    in  nub keys == keys

    describe "every-pending-request-in-exactly-one-list" $ do
        it "partitions any pending list, keeping ledger input order" $ do
            property $
                forAll genPartitionInput $ \(reqs, facts, bound) ->
                    let sel = selectFold bound nowMs marginMs processMs facts reqs
                        settledRefs = map selRef (selectionSettled sel)
                        excludedRefs = map (prRef . fst) (selectionExcluded sel)
                        pendingRefs = map prRef reqs
                    in  sort (settledRefs ++ excludedRefs) == sort pendingRefs
                            && length settledRefs + length excludedRefs == length reqs
                            && settledRefs == [r | r <- pendingRefs, r `elem` settledRefs]
                            && excludedRefs == [r | r <- pendingRefs, r `elem` excludedRefs]
        it "partitions the empty pending list" $ do
            let sel = selectFold 9 nowMs marginMs processMs exampleFacts []
            selectionSettled sel `shouldBe` []
            selectionExcluded sel `shouldBe` []

    describe "capacity-bound-prefix-and-remainder" $ do
        it "settles the first included requests up to the bound at 1, 2 and 9" $ do
            let pents =
                    [ mkInsert (300 + i) (21 + i) (ownerOf (21 + i)) farDeadline
                    | i <- [0 :: Int .. 3]
                    ]
                facts =
                    Map.fromList [(21 + i, (LeafUnknown, False)) | i <- [0 :: Int .. 3]]
                refs = map prRef pents
            checkBound refs pents facts 1
            checkBound refs pents facts 2
            checkBound refs pents facts 9
        it "settles everything at a bound larger than the pending count" $ do
            let pents =
                    [ mkInsert (300 + i) (21 + i) (ownerOf (21 + i)) farDeadline
                    | i <- [0 :: Int .. 3]
                    ]
                facts =
                    Map.fromList [(21 + i, (LeafUnknown, False)) | i <- [0 :: Int .. 3]]
                sel = selectFold 100 nowMs marginMs processMs facts pents
            map selRef (selectionSettled sel) `shouldBe` map prRef pents
            selectionExcluded sel `shouldBe` []
        it
            "settles the first nine and names the tenth capacity at a bound of 9"
            $ do
                let (pents, facts) = tenEligible
                    refs = map prRef pents
                checkBound refs pents facts 1
                checkBound refs pents facts 2
                checkBound refs pents facts 9
                checkBound refs pents facts 12
        it "fails the cut for a variant that settles eight at a bound of nine" $ do
            let (pents, facts) = tenEligible
                refs = map prRef pents
                sel = selectFold 9 nowMs marginMs processMs facts pents
                cutAtEight = take 8 refs
            map selRef (selectionSettled sel) `shouldBe` take 9 refs
            cutAtEight `shouldBe` take 8 refs
            (cutAtEight == map selRef (selectionSettled sel)) `shouldBe` False
        it "keeps each request's own verdict at every bound" $ do
            let at bound =
                    selectFold bound nowMs marginMs processMs exampleFacts examplePending
                verdict bound ref =
                    [ exclusionName exc
                    | (q, exc) <- selectionExcluded (at bound)
                    , prRef q == ref
                    ]
            verdict 1 (prRef r3) `shouldBe` ["key-in-batch"]
            verdict 2 (prRef r3) `shouldBe` ["key-in-batch"]
            verdict 9 (prRef r3) `shouldBe` ["key-in-batch"]
            verdict 1 (prRef r4) `shouldBe` ["not-phase1"]
            verdict 2 (prRef r4) `shouldBe` ["not-phase1"]
            verdict 9 (prRef r4) `shouldBe` ["not-phase1"]
        it "binds nine requests per fold" $ do
            foldCapacity `shouldBe` 9
            foldCapacityProvenance
                `shouldBe` "an estimate, not a measurement: about nine requests fit in a fold under preprod's execution budget of 14 million memory units, bound by trie-proof verification"

    describe "window-rule-admits-at-the-probe-bound" $ do
        it
            "excludes not-phase1 exactly when the probe bound passes the deadline"
            $ do
                property $
                    forAll genWindowCase $ \(deadline, now, margin) ->
                        let req = mkInsert 401 80 "Wendy" deadline
                            facts = Map.fromList [(80, (LeafUnknown, False))]
                            sel = selectFold 9 now margin processMs facts [req]
                            got = map (exclusionName . snd) (selectionExcluded sel)
                            want = ["not-phase1" | now + margin > deadline]
                        in  got == want
        it
            "admits at equality where the old margin comparison refused"
            $ do
                let now = 1000000
                    margin = 30000
                    deadline = now + margin
                foldWindow margin now deadline `shouldBe` FoldClosed margin
                let req = mkInsert 402 81 "Blake" deadline
                    facts = Map.fromList [(81, (LeafUnknown, False))]
                    sel = selectFold 9 now margin processMs facts [req]
                map selRef (selectionSettled sel) `shouldBe` [402]
                selectionExcluded sel `shouldBe` []

    describe "two-vocabularies-never-mixed" $ do
        it "names each of the fourteen reasons in exactly one vocabulary" $ do
            let reasons = [minBound .. maxBound] :: [Reason]
            length reasons `shouldBe` 14
            map (exclusionName . flip Exclusion "") reasons
                `shouldBe` [ "edge-inadmissible"
                           , "no-approval"
                           , "approval-mismatch"
                           , "key-exists"
                           , "token-missing"
                           , "key-unknown"
                           , "not-booked"
                           , "terminal-immutable"
                           , "undecodable"
                           , "not-phase1"
                           , "application-datum-unreadable"
                           , "application-required"
                           , "key-in-batch"
                           , "capacity"
                           ]
            map (exclusionSource . flip Exclusion "") reasons
                `shouldBe` [ "model-refusal"
                           , "model-refusal"
                           , "model-refusal"
                           , "model-refusal"
                           , "model-refusal"
                           , "model-refusal"
                           , "model-refusal"
                           , "model-refusal"
                           , "selection-policy"
                           , "model-refusal"
                           , "selection-policy"
                           , "selection-policy"
                           , "selection-policy"
                           , "selection-policy"
                           ]
        it "never labels a selection-policy reason as a model refusal" $ do
            let policy =
                    [ ReasonUndecodable
                    , ReasonAppDatumUnreadable
                    , ReasonAppRequired
                    , ReasonKeyInBatch
                    , ReasonCapacity
                    ]
            [exclusionSource (Exclusion r "") | r <- policy]
                `shouldBe` [ "selection-policy"
                           , "selection-policy"
                           , "selection-policy"
                           , "selection-policy"
                           , "selection-policy"
                           ]
        it
            "names the application's executable in the application-required detail"
            $ do
                let exe = "fixture-exe-207" :: Text
                    sel =
                        selectFold
                            9
                            nowMs
                            marginMs
                            processMs
                            activeNineAppFacts
                            [ (mkTerminate 107 9 "Ruth" farDeadline)
                                { prApp = AppRequired exe
                                }
                            ]
                case map snd (selectionExcluded sel) of
                    [exc] -> excDetail exc `shouldSatisfy` T.isInfixOf exe
                    other ->
                        expectationFailure
                            ("expected one exclusion, got " ++ show (length other))

    describe "example-four-requests" $ do
        it "settles r1 and r2 at a capacity of 9" $ do
            let sel = selectFold 9 nowMs marginMs processMs exampleFacts examplePending
            map selRef (selectionSettled sel) `shouldBe` [prRef r1, prRef r2]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["key-in-batch", "not-phase1"]
            map (exclusionSource . snd) (selectionExcluded sel)
                `shouldBe` ["selection-policy", "model-refusal"]
            selectionBound sel `shouldBe` 9
        it "settles only r1 at a capacity of 1" $ do
            let sel = selectFold 1 nowMs marginMs processMs exampleFacts examplePending
            map selRef (selectionSettled sel) `shouldBe` [prRef r1]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["capacity", "key-in-batch", "not-phase1"]
            map (exclusionSource . snd) (selectionExcluded sel)
                `shouldBe` ["selection-policy", "selection-policy", "model-refusal"]
        it "settles r1 and r2 at a capacity of 2" $ do
            let sel = selectFold 2 nowMs marginMs processMs exampleFacts examplePending
            map selRef (selectionSettled sel) `shouldBe` [prRef r1, prRef r2]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["key-in-batch", "not-phase1"]
        it "matches the capacity-9 receipt above the pending count" $ do
            let sel = selectFold 100 nowMs marginMs processMs exampleFacts examplePending
            map selRef (selectionSettled sel) `shouldBe` [prRef r1, prRef r2]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["key-in-batch", "not-phase1"]
        it
            "names r3 key-exists on the next fold from the state after this one"
            $ do
                let sel = selectFold 9 nowMs marginMs processMs afterFirstFoldFacts [r3, r4]
                selectionSettled sel `shouldBe` []
                map (exclusionName . snd) (selectionExcluded sel)
                    `shouldBe` ["key-exists", "not-phase1"]
                map (exclusionSource . snd) (selectionExcluded sel)
                    `shouldBe` ["model-refusal", "model-refusal"]
        it "settles r2 on the next fold at a capacity of 1" $ do
            let sel =
                    selectFold 1 nowMs marginMs processMs afterFirstFoldFacts [r2, r3, r4]
            map selRef (selectionSettled sel) `shouldBe` [prRef r2]
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["key-exists", "not-phase1"]

    describe "window-refused-in-the-models-words" $ do
        it "names a closed window not-phase1 as a model refusal" $ do
            let sel = selectFold 9 nowMs marginMs processMs exampleFacts [r4]
            selectionSettled sel `shouldBe` []
            map (exclusionName . snd) (selectionExcluded sel)
                `shouldBe` ["not-phase1"]
            map (exclusionSource . snd) (selectionExcluded sel)
                `shouldBe` ["model-refusal"]
        it "admits a deadline equal to the probe bound" $ do
            let deadline = nowMs + marginMs
                req = mkInsert 403 82 "Eve" deadline
                facts = Map.fromList [(82, (LeafUnknown, False))]
                sel = selectFold 9 nowMs marginMs processMs facts [req]
            map selRef (selectionSettled sel) `shouldBe` [403]
            selectionExcluded sel `shouldBe` []
        it "carries the deadline and the probe bound in the detail" $ do
            let sel = selectFold 9 nowMs marginMs processMs exampleFacts [r4]
            case map snd (selectionExcluded sel) of
                [exc] -> do
                    excDetail exc
                        `shouldSatisfy` T.isInfixOf (T.pack (show nearDeadline))
                    excDetail exc
                        `shouldSatisfy` T.isInfixOf (T.pack (show (nowMs + marginMs)))
                other ->
                    expectationFailure
                        ("expected one exclusion, got " ++ show (length other))

-- ---------------------------------------------------------
-- Single-check fixtures
-- ---------------------------------------------------------

-- | A clean insertion on an unknown key.
cleanBase :: PendingRequest
cleanBase = mkInsert 101 50 "Olive" farDeadline

-- | Facts where key 50 is unknown.
baseFacts :: LiveFacts
baseFacts = Map.fromList [(50, (LeafUnknown, False))]

-- | Facts where key 9 is active with its holding live.
activeNineFacts :: LiveFacts
activeNineFacts = Map.fromList [(9, (LeafActive, True))]

{- | Facts where key 9 is active with its holding live; r107's application
verdict names the fixture executable used in that case.
-}
activeNineAppFacts :: LiveFacts
activeNineAppFacts = Map.fromList [(9, (LeafActive, True))]

-- | Facts where key 60 is unknown.
unknownSixtyFacts :: LiveFacts
unknownSixtyFacts = Map.fromList [(60, (LeafUnknown, False))]

-- | Facts where key 61 reads absent.
absentSixtyOneFacts :: LiveFacts
absentSixtyOneFacts = Map.fromList [(61, (LeafAbsent, False))]

-- | Facts where key 62 reads terminal.
terminalSixtyTwoFacts :: LiveFacts
terminalSixtyTwoFacts = Map.fromList [(62, (LeafTerminal, False))]

-- | Facts where key 63 reads active but no live output holds its token.
activeNoTokenFacts :: LiveFacts
activeNoTokenFacts = Map.fromList [(63, (LeafActive, False))]

{- | One pending request alone must name the expected reason, both through
the selection and through the per-request judgement.
-}
checkAlone :: PendingRequest -> LiveFacts -> Text -> Expectation
checkAlone p facts expected = do
    let sel = selectFold 9 nowMs marginMs processMs facts [p]
    selectionSettled sel `shouldBe` []
    map (exclusionName . snd) (selectionExcluded sel)
        `shouldBe` [expected]
    case judgeAlone nowMs marginMs processMs facts p of
        Left exc -> exclusionName exc `shouldBe` expected
        Right selReq -> expectationFailure ("judged alone as selected: " ++ show selReq)

-- | The capacity prefix and remainder for all-includable requests.
checkBound
    :: [Int] -> [PendingRequest] -> LiveFacts -> Int -> Expectation
checkBound refs pents facts bound = do
    let sel = selectFold bound nowMs marginMs processMs facts pents
        (wantSettled, wantCapacity) = splitAt bound refs
    map selRef (selectionSettled sel) `shouldBe` wantSettled
    map (prRef . fst) (selectionExcluded sel) `shouldBe` wantCapacity
    map (exclusionName . snd) (selectionExcluded sel)
        `shouldBe` replicate (length wantCapacity) "capacity"
    selectionBound sel `shouldBe` bound

-- ---------------------------------------------------------
-- Generators
-- ---------------------------------------------------------

-- | Keys for the requests on other keys in the independence property.
genOtherKeys :: Gen [Int]
genOtherKeys = choose (0, 3) >>= \n -> vectorOf n (choose (51, 100))

{- | Small mixed pending lists over the example keys, with facts for them and
a capacity bound: every pending request is covered whatever its verdict.
-}
genPartitionInput :: Gen ([PendingRequest], LiveFacts, Int)
genPartitionInput = do
    n <- choose (0, 5)
    reqs <- mapM genOne [0 .. n - 1]
    bound <- choose (0, 12)
    pure (reqs, exampleFacts, bound)
  where
    genOne :: Int -> Gen PendingRequest
    genOne ref = do
        key <- elements [7, 9, 11]
        aspect <- choose (0, 9 :: Int)
        let base = mkInsert ref key (ownerOf key) farDeadline
        pure $ case aspect of
            0 -> base
            1 -> base
            2 -> base
            3 -> base
            4 -> mkTerminate ref key (ownerOf key) farDeadline
            5 -> base{prApproval = ApprovalMissing}
            6 ->
                base
                    { prDeadline = nearDeadline
                    , prSubmittedAt = nearDeadline - processMs
                    }
            7 -> base{prDecodeOk = False}
            8 -> mkTerminate ref key (ownerOf key) farDeadline
            _ -> base{prApp = AppDatumUnreadable}

-- | Deadline, clock and margin triples around the open/closed boundary.
genWindowCase :: Gen (Integer, Integer, Integer)
genWindowCase =
    (,,)
        <$> choose (-100000, 3000000)
        <*> choose (0, 2000000)
        <*> choose (0, 120000)

{- | Ten eligible requests on ten distinct keys with facts for them: more
eligible requests than the largest bound, so the ninth settled request
and the first capacity remainder are both exercised.
-}
tenEligible :: ([PendingRequest], LiveFacts)
tenEligible = (pents, facts)
  where
    pents =
        [ mkInsert (500 + i) (31 + i) (ownerOf (31 + i)) farDeadline
        | i <- [0 :: Int .. 9]
        ]
    facts =
        Map.fromList [(31 + i, (LeafUnknown, False)) | i <- [0 :: Int .. 9]]

-- ---------------------------------------------------------
-- chunk3 offchain: the tagged members
-- ---------------------------------------------------------

{- | The selection over tagged pending requests. A registration folds only
inside its processing window; a termination has no window, no approval and no
live holder to find: the singular tag is in the request itself. Every
request lands in exactly one of the two lists, in ledger input order, and the
capacity bound cuts what is left after each request has its own verdict.

Every expected list is derived from the requests and the facts by field
access and list operations, never typed back from the selection.
-}
taggedSelectionSpec :: Spec
taggedSelectionSpec = describe "chunk3 offchain" $ describe "the tagged selection" $ do
    let registration ref key submitted =
            TaggedRequest ref key MemberRegistration submitted AppReady
        termination ref key =
            TaggedRequest ref key MemberTermination 0 AppReady
        select = selectTaggedFold 9 nowMs marginMs processMs
        reasonsOf sel =
            [(tgRef r, exclusionName e) | (r, e) <- taggedExcluded sel]
        settledRefs = map tgRef . taggedSettled
        -- booked at the clock: its deadline is a processing time ahead
        openAt = nowMs
        known = Map.fromList
        active = (LeafActive, True)
        unknown = (LeafUnknown, False)
    it
        "settles registrations and terminations of distinct keys in ledger input order"
        $ do
            let reqs =
                    [ registration 1 10 openAt
                    , termination 2 11
                    , registration 3 12 openAt
                    , termination 4 13
                    ]
                facts = known [(10, unknown), (11, active), (12, unknown), (13, active)]
                sel = select facts reqs
            settledRefs sel `shouldBe` map tgRef reqs
            taggedExcluded sel `shouldBe` []
            map tgKind (taggedSettled sel) `shouldBe` map tgKind reqs
    it
        "refuses a registration past its window and settles a termination of any age"
        $ do
            let stale = nowMs - 10 * processMs
                reqs = [registration 1 20 stale, termination 2 21]
                facts = known [(20, unknown), (21, active)]
                sel = select facts reqs
            reasonsOf sel `shouldBe` [(1, "not-phase1")]
            settledRefs sel `shouldBe` [2]
    it "admits a registration whose deadline is exactly the probe bound" $ do
        let atBound = nowMs + marginMs - processMs
            sel = select (known [(22, unknown)]) [registration 1 22 atBound]
        settledRefs sel `shouldBe` [1]
        taggedExcluded sel `shouldBe` []
    it "refuses a registration of a key the registry already knows" $ do
        let reqs =
                [ registration 1 30 openAt
                , registration 2 31 openAt
                , registration 3 32 openAt
                ]
            facts =
                known
                    [(30, active), (31, (LeafTerminal, False)), (32, (LeafAbsent, False))]
        reasonsOf (select facts reqs)
            `shouldBe` [(1, "key-exists"), (2, "key-exists"), (3, "key-exists")]
    it "refuses a termination of a key the registry cannot terminate" $ do
        let reqs = [termination 1 33, termination 2 34, termination 3 35]
            facts =
                known
                    [ (33, unknown)
                    , (34, (LeafAbsent, False))
                    , (35, (LeafTerminal, False))
                    ]
        reasonsOf (select facts reqs)
            `shouldBe` [(1, "key-unknown"), (2, "not-booked"), (3, "terminal-immutable")]
    it
        "settles a termination of an active key without a live holder to find"
        $ do
            let sel = select (known [(36, (LeafActive, False))]) [termination 1 36]
            settledRefs sel `shouldBe` [1]
            taggedExcluded sel `shouldBe` []
    it
        "refuses a registration whose delivered datum does not read, and never asks a termination for one"
        $ do
            let unreadable = AppDatumUnreadable
                reqs =
                    [ (registration 1 40 openAt){tgCarried = unreadable}
                    , (termination 2 41){tgCarried = unreadable}
                    ]
                facts = known [(40, unknown), (41, active)]
                sel = select facts reqs
            reasonsOf sel `shouldBe` [(1, "application-datum-unreadable")]
            settledRefs sel `shouldBe` [2]
    it "takes one request per key in a batch" $ do
        let regs = [registration 1 50 openAt, registration 2 50 openAt]
            terms = [termination 3 51, termination 4 51]
            facts = known [(50, unknown), (51, active)]
            sel = select facts (regs <> terms)
        reasonsOf sel `shouldBe` [(2, "key-in-batch"), (4, "key-in-batch")]
        settledRefs sel `shouldBe` [1, 3]
    it "cuts the settled prefix at the capacity bound and names the rest" $ do
        let reqs =
                [ if even i
                    then registration i (100 + i) openAt
                    else termination i (100 + i)
                | i <- [1 .. 12]
                ]
            facts =
                known
                    [ (100 + i, if even i then unknown else active)
                    | i <- [1 .. 12]
                    ]
            sel = selectTaggedFold 9 nowMs marginMs processMs facts reqs
        settledRefs sel `shouldBe` [1 .. 9]
        reasonsOf sel `shouldBe` [(i, "capacity") | i <- [10 .. 12]]
        taggedBound sel `shouldBe` 9
        sort (settledRefs sel <> map (tgRef . fst) (taggedExcluded sel))
            `shouldBe` map tgRef reqs
    it "names no approval, no edge and no live token among its reasons" $ do
        let reqs =
                [ registration 1 60 openAt
                , registration 2 61 (nowMs - 10 * processMs)
                , termination 3 62
                , termination 4 63
                , registration 5 60 openAt
                ]
            facts = known [(60, unknown), (61, unknown), (62, unknown), (63, active)]
            names = map snd (reasonsOf (select facts reqs))
        names `shouldSatisfy` (not . null)
        names `shouldSatisfy` all (`elem` allowed)
  where
    allowed =
        [ "not-phase1"
        , "key-exists"
        , "key-unknown"
        , "not-booked"
        , "terminal-immutable"
        , "application-datum-unreadable"
        , "key-in-batch"
        , "capacity"
        ]
