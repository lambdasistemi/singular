{-# LANGUAGE GADTs #-}

-- | The refusal controls are judged from receipts, and only from receipts.
module Conformance.Support.CliControls (spec) where

import Conformance.Cli.Admission (sha256Hex)
import Conformance.Cli.Controls
    ( ClauseResult (..)
    , ClauseStatus (..)
    , CliI (..)
    , Command (..)
    , Crafted (..)
    , Observation (..)
    , ProcessEvidence (..)
    , Provocation (..)
    , Receipt (..)
    , Story
    , Submission (..)
    , Target (..)
    , attribution
    , commandName
    , controlsStory
    , craftedName
    , duplicateRefused
    , duplicateStory
    , emptyReceipt
    , held
    , judge
    , obligationBindings
    , outline
    , provocationName
    , rejectionEvidence
    , renderControls
    , resolveObligation
    , resolveStatement
    , statementBindings
    , validateControls
    )
import Conformance.Story.Binding (BoundObligation (..), firstExisting)
import Conformance.Story.Specification
    ( Clause (..)
    , Step (..)
    , action
    , bindCheck
    , checkAction
    , clause
    , clauses
    , theorem
    )
import Control.Monad (when)
import Control.Monad.Operational
    ( Program
    , ProgramViewT (Return, (:>>=))
    , view
    )
import Data.Aeson
    ( Value (..)
    , eitherDecodeFileStrict'
    , object
    , toJSON
    , (.=)
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Char (ord)
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec
    ( Spec
    , describe
    , it
    , pendingWith
    , shouldBe
    , shouldSatisfy
    )
import Text.Printf (printf)

stateHash :: T.Text
stateHash = "5ca1ab1e"

-- | What a correct run leaves: every step answered, every refusal the node's.
honestReceipts :: Story () -> IO [Receipt]
honestReceipts story = do
    step <- newIORef (0 :: Int)
    inserted <- newIORef ([] :: [String])
    out <- newIORef []
    run step inserted out story
    reverse <$> readIORef out
  where
    run
        :: IORef Int -> IORef [String] -> IORef [Receipt] -> Story a -> IO a
    run step inserted out program = case view program of
        Return a -> pure a
        Action i :>>= next -> act step inserted out i >>= run step inserted out . next
        Theorem _ body :>>= next ->
            runClauses step inserted out (clauses body)
                >>= run step inserted out . next

    runClauses
        :: IORef Int
        -> IORef [String]
        -> IORef [Receipt]
        -> Program (Clause thm CliI) b
        -> IO b
    runClauses step inserted out p = case view p of
        Return b -> pure b
        Clause _ c body :>>= next -> do
            obs <- run step inserted out body
            run step inserted out (checkAction c obs)
            runClauses step inserted out (next obs)

    act
        :: IORef Int -> IORef [String] -> IORef [Receipt] -> CliI a -> IO a
    act step inserted out i = case i of
        Require _ _ -> pure ()
        Run Inspect (Target "interrupted") k ->
            emit "run inspect" "interrupted" k $ \r ->
                r
                    { rcOutcome = "partial"
                    , rcCommand =
                        Just
                            ( object
                                [ "outcome" .= ("partial" :: String)
                                , "incompleteCreate" .= object ["seed" .= ("s#0" :: String)]
                                , "leaf" .= Null
                                , "observed" .= ["b9" :: String]
                                ]
                            )
                    }
        Run Inspect (Target t) k
            | t == "process" && k == "held" -> do
                before <- readIORef inserted
                emit "run inspect" t k $ \r ->
                    r
                        { rcOutcome = "success"
                        , rcCommand =
                            Just
                                ( withObserved
                                    ("process:killed" `elem` before)
                                    ( commandReceipt
                                        Inspect
                                        k
                                        0
                                        ("process:killed" `elem` before)
                                    )
                                )
                        }
        Provoke p (Target t) k -> do
            modifyIORef' inserted ((t <> ":" <> provocationName p) :)
            when (p == TerminateKilled) $
                modifyIORef' inserted ("process:killed" :)
            emit ("provoke " <> T.pack (provocationName p)) t k $ \r ->
                provoked p r
        Run c (Target t) k -> do
            before <- readIORef inserted
            let again = c == Insert && (t <> "/" <> k) `elem` before
                updates = length [() | u <- before, u == t <> ":update"]
                terminal = (t <> ":terminate") `elem` before
            modifyIORef' inserted (commandMark c t k :)
            emit ("run " <> T.pack (commandName c)) t k $ \r ->
                if again
                    then r{rcOutcome = "partial", rcPendingRequest = Just "b0#0"}
                    else
                        r
                            { rcOutcome = "success"
                            , rcCommand = Just (commandReceipt c k updates terminal)
                            }
        Craft cr (Target t) k ->
            emit ("craft " <> T.pack (craftedName cr)) t k $ \r ->
                let base =
                        r
                            { rcEvaluation = Just "skipped"
                            , rcApplication = Just appHash
                            , rcTxId = Just "c1"
                            , rcEvidence = ["evidence/step-c1.cbor.hex"]
                            }
                in  if cr
                        `elem` [ HonestUpdate
                               , TerminateBooking
                               , FoldPaysInFull
                               , FoldTwoReleasesInFull
                               , FoldMixedInFull
                               ]
                        then base{rcOutcome = "accepted"}
                        else
                            ( rejected
                                ["PlutusFailure" | cr /= UpdateWithoutScript]
                                base
                            )
                                { rcRefusingScripts = [appHash]
                                }
        Book (Target t) k ->
            emit "book" t k $ \r -> r{rcOutcome = "accepted", rcTxId = Just "b1"}
        FoldUnevaluated (Target t) k ->
            emit "fold-unevaluated" t k $ \r ->
                let base =
                        r
                            { rcEvaluation = Just "skipped"
                            , rcStateValidator = Just stateHash
                            , rcTxId = Just "f1"
                            , rcEvidence = ["evidence/step-f1.cbor.hex"]
                            }
                in  if t `notElem` ["duplicate", "resurrection"]
                        then base{rcOutcome = "accepted"}
                        else
                            (rejected ["PlutusFailure", "CekError"] base)
                                { rcRefusingScripts = [stateHash]
                                }
        Observe (Target t) k ->
            emit "observe" t k $ \r ->
                r
                    { rcOutcome = "observed"
                    , rcObservation =
                        Just
                            ( Observation
                                "00"
                                (Just "h#1")
                                (Just 4000000)
                                ["b0#0"]
                                3000000
                                100
                                (Just "active")
                            )
                    }
      where
        emit name t k fill = do
            n <- readIORef step
            modifyIORef' step (+ 1)
            let r =
                    (fill (emptyReceipt n name (T.pack t) (T.pack k)))
                        { rcAdmission = Just []
                        }
            modifyIORef' out (r :)
            pure r

statuses :: [ClauseResult] -> [ClauseStatus]
statuses = map crStatus

isUncovered, isNotHeld :: ClauseStatus -> Bool
isUncovered s = case s of Uncovered _ -> True; _ -> False
isNotHeld s = case s of NotHeld _ -> True; _ -> False

-- | Change the one receipt whose action and target match.
alter
    :: T.Text -> T.Text -> (Receipt -> Receipt) -> [Receipt] -> [Receipt]
alter act target f =
    map
        (\r -> if rcAction r == act && rcTarget r == target then f r else r)

spec :: Spec
spec = describe "The ordinary CLI's story and boundary, judged from receipts" $ do
    it
        "binds each application statement it tells, as the statement ledger records them"
        $ do
            map boName statementBindings
                `shouldBe` map
                    ("OpenDatumApplication.Statements." <>)
                    [ "duplicate_refused_by_registry"
                    , "resurrection_refused_by_registry"
                    , "insertion_holding_inline"
                    , "update_keeps_registry"
                    , "update_payload_free"
                    , "release_burns_atomically"
                    , "update_requires_controller"
                    , "update_preserves_custody"
                    , "only_fold_releases"
                    , "bookInsert_inversion"
                    , "insertion_requires_registry_identity"
                    , "bookTerminate_inversion"
                    , "fold_settles_additively"
                    , "fold_inversion"
                    ]
            found <-
                firstExisting
                    [ "../applications/open-datum/ledgers.json"
                    , "applications/open-datum/ledgers.json"
                    ]
            case found of
                Nothing ->
                    pendingWith
                        "the application's statement ledger is not beside this build; cli-controls run resolves it before any step"
                Just path -> do
                    ledger <-
                        eitherDecodeFileStrict' path >>= either fail pure :: IO Value
                    mapM_
                        (\b -> resolveStatement ledger b `shouldBe` Right ())
                        statementBindings
                    case statementBindings of
                        (b : _) ->
                            resolveStatement ledger b{boDigest = replicate 64 '0'}
                                `shouldSatisfy` isLeft
                        [] -> fail "no statement is bound"
    it
        "states every clause once and refuses a refusal without an accepting control"
        $ do
            length (outline controlsStory) `shouldBe` 98
            validateControls controlsStory `shouldBe` Right ()
            let refusedOnly =
                    theorem duplicateRefused $
                        clause
                            "its fold is refused"
                            (bindCheck duplicateRefused (\_ -> pure ()))
                            (pure ())
            validateControls refusedOnly `shouldSatisfy` isLeft
            validateControls (duplicateStory >> refusedOnly)
                `shouldSatisfy` isLeft
    it "holds every clause on an honest run" $ do
        rs <- honestReceipts controlsStory
        let results = judge rs controlsStory
        statuses results `shouldBe` replicate 98 Held
        held results `shouldBe` True
    it
        "leaves every clause from a missing receipt on uncovered, naming the step"
        $ do
            rs <- honestReceipts controlsStory
            let dropped =
                    filter
                        ( \r ->
                            not (rcAction r == "fold-unevaluated" && rcTarget r == "duplicate")
                        )
                        rs
                results = judge dropped controlsStory
            length results `shouldBe` 98
            take 3 (statuses results) `shouldBe` [Held, Held, Held]
            drop 3 (statuses results) `shouldSatisfy` all isUncovered
            held results `shouldBe` False
    it "does not accept a receipt answering another registry's action" $ do
        rs <- honestReceipts controlsStory
        let aliased =
                alter
                    "fold-unevaluated"
                    "duplicate"
                    (\r -> r{rcTarget = "duplicate-control"})
                    rs
            results = judge aliased controlsStory
        statuses results !! 3 `shouldSatisfy` isUncovered
        show (statuses results !! 3)
            `shouldSatisfy` isInfixOf "answers fold-unevaluated in duplicate-control"
    it
        "does not hold a refusal the node accepted, or one naming another script"
        $ do
            rs <- honestReceipts controlsStory
            let accepted =
                    alter
                        "fold-unevaluated"
                        "duplicate"
                        (\r -> r{rcOutcome = "accepted", rcRefusingScripts = []})
                        rs
                otherScript =
                    alter
                        "fold-unevaluated"
                        "resurrection"
                        (\r -> r{rcRefusingScripts = ["0ther"]})
                        rs
                evaluated =
                    alter
                        "fold-unevaluated"
                        "duplicate"
                        (\r -> r{rcEvaluation = Nothing})
                        rs
            statuses (judge accepted controlsStory) !! 3 `shouldSatisfy` isNotHeld
            statuses (judge otherScript controlsStory) !! 8
                `shouldSatisfy` isNotHeld
            statuses (judge evaluated controlsStory) !! 3
                `shouldSatisfy` isNotHeld
    it
        "does not hold an insert reported as anything but partial with its pending request"
        $ do
            rs <- honestReceipts controlsStory
            let second =
                    [r | r <- rs, rcAction r == "run insert", rcTarget r == "duplicate"]
                        !! 1
                refusedInstead =
                    map
                        ( \r ->
                            if r == second
                                then r{rcOutcome = "client-refusal", rcPendingRequest = Nothing}
                                else r
                        )
                        rs
            rcOutcome second `shouldBe` "partial"
            statuses (judge refusedInstead controlsStory) !! 2
                `shouldSatisfy` isNotHeld
    it "does not hold a readback that moved, or one with nothing pending" $ do
        rs <- honestReceipts controlsStory
        let observes = [r | r <- rs, rcAction r == "observe", rcTarget r == "duplicate"]
            lastObserve = last observes
            moved =
                map
                    ( \r ->
                        if r == lastObserve
                            then
                                r{rcObservation = fmap (\o -> o{obRoot = "11"}) (rcObservation r)}
                            else r
                    )
                    rs
        statuses (judge moved controlsStory) !! 4 `shouldSatisfy` isNotHeld
    it "renders uncovered clauses beside held ones, with the count" $ do
        rs <- honestReceipts controlsStory
        let rendered = renderControls (judge (take 3 rs) controlsStory) controlsStory
        rendered `shouldSatisfy` isInfixOf "uncovered: no receipt for step 3"
        rendered
            `shouldSatisfy` isInfixOf "0 of 98 clauses hold; 0 do not; 98 are uncovered."
        rendered
            `shouldSatisfy` isInfixOf
                "`OpenDatumApplication.Statements.duplicate_refused_by_registry`"
        rendered
            `shouldSatisfy` (\t -> not (any (\d -> ('#' : [d]) `isInfixOf` t) ['0' .. '9']))
    it
        "does not hold a tampered update the node accepted, or a refusal naming another script"
        $ do
            rs <- honestReceipts controlsStory
            let tamper =
                    alter
                        "craft update-escaped"
                        "boundary"
                        (\r -> r{rcOutcome = "accepted", rcRefusingScripts = []})
                        rs
                otherScript =
                    alter
                        "craft early-withdrawal"
                        "boundary"
                        (\r -> r{rcRefusingScripts = [stateHash]})
                        rs
                byTitle s results = [crStatus r | r <- results, s `isInfixOf` crTitle r]
            byTitle
                "goes to the controller's own address"
                (judge tamper controlsStory)
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            byTitle
                "outside any fold is refused"
                (judge otherScript controlsStory)
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
    it
        "does not hold a lifecycle whose receipts disagree with one another"
        $ do
            rs <- honestReceipts controlsStory
            let moved =
                    alter
                        "run update"
                        "lifecycle"
                        (\r -> r{rcCommand = fmap (setRoot "r9") (rcCommand r)})
                        rs
                kept =
                    alter
                        "run terminate"
                        "lifecycle"
                        (\r -> r{rcOutcome = "client-refusal"})
                        rs
                titled s results = [crStatus r | r <- results, s `isInfixOf` crTitle r]
            titled "root does not move" (judge moved controlsStory)
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            titled "releases its protected deposit" (judge kept controlsStory)
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
    it
        "does not hold a client obligation its process evidence contradicts"
        $ do
            rs <- honestReceipts controlsStory
            let titled s results = [crStatus r | r <- results, s `isInfixOf` crTitle r]
                process f r = r{rcProcess = f <$> rcProcess r}
                judged act f title =
                    titled title (judge (alter act "process" f rs) controlsStory)
                lateJudged f title =
                    titled
                        title
                        (judge (alter "provoke create-late" "raced" f rs) controlsStory)
            titled "lock is released" (judge rs controlsStory)
                `shouldSatisfy` all (== Held)
            judged
                "provoke insert-while-locked"
                (process (\p -> p{peJournalAfter = peJournalAfter p + 2}))
                "while another process holds the registry's lock"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            judged
                "provoke insert-while-locked"
                (\r -> r{rcOutcome = "success"})
                "while another process holds the registry's lock"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            judged
                "provoke terminate-killed"
                (process (\p -> p{peLastEvent = "fold/confirmed"}))
                "killed once the node accepted its fold"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            judged
                "provoke terminate-killed"
                (process (\p -> p{peExit = 0}))
                "killed once the node accepted its fold"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            judged
                "provoke update-node-lost"
                (process (\p -> p{peWaited = Just 121}))
                "with the node stopped"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            judged
                "provoke inspect-without-proof"
                ( \r ->
                    r
                        { rcCommand =
                            Just
                                ( object
                                    [ "outcome" .= ("proof-missing" :: String)
                                    , "leaf" .= ("active" :: String)
                                    ]
                                )
                        }
                )
                "proof material moved aside"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            lateJudged
                ( process
                    (\p -> p{peFilesAfter = [("targets/raced/registry.json", "02")]})
                )
                "is refused because the registry exists"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            lateJudged
                (\r -> r{rcReason = Just "the wallet does not hold the seed"})
                "is refused because the registry exists"
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
    it
        "binds each client obligation to its row of the CLI's specification"
        $ do
            found <-
                firstExisting
                    [ "../specs/299-singular-cli/spec.md"
                    , "specs/299-singular-cli/spec.md"
                    ]
            case found of
                Nothing -> pendingWith "the CLI's specification is not in this checkout"
                Just path -> do
                    rows <- TE.decodeUtf8 <$> BS.readFile path
                    let digest = sha256Hex . TE.encodeUtf8
                    mapM_
                        (\b -> resolveObligation digest rows b `shouldBe` Right ())
                        obligationBindings
                    case obligationBindings of
                        (b : _) -> do
                            resolveObligation digest rows b{boDigest = replicate 64 '0'}
                                `shouldSatisfy` isLeft
                            resolveObligation digest (T.replace "R299-05" "R299-5" rows) b
                                `shouldSatisfy` isLeft
                        [] -> fail "no client obligation is bound"
    it "computes each approved case's coverage from the clause verdicts" $ do
        rs <- honestReceipts controlsStory
        let full = renderControls (judge rs controlsStory) controlsStory
            withoutWithdrawal = filter (\r -> rcAction r /= "craft early-withdrawal") rs
            partial =
                renderControls (judge withoutWithdrawal controlsStory) controlsStory
        full
            `shouldSatisfy` isInfixOf "30 of 31 approved cases are covered live; 1 are not."
        -- the ruled-out case stays visible and uncovered, citing its ruling
        full
            `shouldSatisfy` isInfixOf
                "| an update whose continuation duplicates the token's carrier | `update_preserves_custody` | uncovered: the live suite runs no transaction for it"
        full
            `shouldSatisfy` isInfixOf "specs/299-singular-cli/ruling-duplicate-carrier.md"
        partial
            `shouldSatisfy` isInfixOf
                "| a release of the live holding outside any fold | `only_fold_releases` | uncovered"
    it "uncovers every claim of a telling whose termination prefix failed" $ do
        rs <- honestReceipts controlsStory
        let failedTermination =
                alter
                    "run terminate"
                    "resurrection"
                    (\r -> r{rcOutcome = "client-refusal"})
                    rs
            results = judge failedTermination controlsStory
            resurrection =
                [ crStatus r
                | r <- results
                , crStatement r
                    == "OpenDatumApplication.Statements.resurrection_refused_by_registry"
                ]
        take 1 resurrection `shouldSatisfy` all isNotHeld
        drop 1 resurrection
            `shouldSatisfy` (\ss -> length ss == 4 && all isUncovered ss)
        show (drop 1 resurrection)
            `shouldSatisfy` isInfixOf "its premise does not hold"
        -- each names the cause, not only the premise
        drop 1 resurrection
            `shouldSatisfy` all (isInfixOf "client-refusal" . show)
        held results `shouldBe` False
    it
        "does not accept a prefix whose inspect reads the key Active where Terminal is claimed"
        $ do
            rs <- honestReceipts controlsStory
            let wrongLeaf =
                    alter
                        "run inspect"
                        "resurrection"
                        (\r -> r{rcCommand = fmap (setField "leaf" "active") (rcCommand r)})
                        rs
                premise =
                    [ crStatus r
                    | r <- judge wrongLeaf controlsStory
                    , crStatement r
                        == "OpenDatumApplication.Statements.resurrection_refused_by_registry"
                    ]
            take 1 premise `shouldSatisfy` all isNotHeld
            case take 1 premise of
                [NotHeld why] ->
                    why
                        `shouldSatisfy` any (isInfixOf "leaf is \"active\", not \"terminal\"")
                other -> fail ("the premise is " <> show other)
    it
        "does not hold an ordinary command's claim, or its premise, when its journalled bodies were not admitted"
        $ do
            rs <- honestReceipts controlsStory
            let insertBroken =
                    alter
                        "run insert"
                        "lifecycle"
                        (\r -> r{rcAdmission = Just ["the journalled body b is missing"]})
                        rs
                titled s results = [crStatus r | r <- results, s `isInfixOf` crTitle r]
            titled
                "delivers the key's one token"
                (judge insertBroken controlsStory)
                `shouldSatisfy` (\ss -> not (null ss) && all isNotHeld ss)
            show
                ( titled
                    "delivers the key's one token"
                    (judge insertBroken controlsStory)
                )
                `shouldSatisfy` isInfixOf "the journalled body b is missing"
            let createBroken =
                    alter
                        "run create"
                        "resurrection"
                        (\r -> r{rcAdmission = Nothing})
                        rs
                resurrection =
                    [ crStatus r
                    | r <- judge createBroken controlsStory
                    , crStatement r
                        == "OpenDatumApplication.Statements.resurrection_refused_by_registry"
                    ]
            take 1 resurrection `shouldSatisfy` all isNotHeld
            drop 1 resurrection
                `shouldSatisfy` (\ss -> not (null ss) && all isUncovered ss)
    it "does not hold a refusal whose retained evidence was not admitted" $ do
        rs <- honestReceipts controlsStory
        let unread =
                alter
                    "fold-unevaluated"
                    "duplicate"
                    (\r -> r{rcAdmission = Nothing})
                    rs
            broken =
                alter
                    "fold-unevaluated"
                    "duplicate"
                    (\r -> r{rcAdmission = Just ["the retained rejection is missing"]})
                    rs
        statuses (judge unread controlsStory) !! 3 `shouldSatisfy` isNotHeld
        show (statuses (judge broken controlsStory) !! 3)
            `shouldSatisfy` isInfixOf "the retained rejection is missing"
    it
        "does not count a rejection before any script ran as the validator's refusal, even naming its hash"
        $ do
            rs <- honestReceipts controlsStory
            let phaseOne =
                    alter "fold-unevaluated" "duplicate" (\r -> r{rcPhaseWords = []}) rs
                refusal = statuses (judge phaseOne controlsStory) !! 3
            refusal `shouldSatisfy` isNotHeld
            show refusal `shouldSatisfy` isInfixOf "before any script ran"
    it
        "does not count a script that ran out of its stated budget as the validator's refusal"
        $ do
            rs <- honestReceipts controlsStory
            budget <- readFile "test/fixtures/node-refusals/budget.txt"
            fst (rejectionEvidence budget) `shouldSatisfy` elem "OverBudget"
            let exhausted =
                    alter
                        "fold-unevaluated"
                        "duplicate"
                        (\r -> r{rcPhaseWords = rcPhaseWords r <> ["OverBudget"]})
                        rs
                refusal = statuses (judge exhausted controlsStory) !! 3
            statuses (judge rs controlsStory) !! 3
                `shouldSatisfy` (not . isNotHeld)
            refusal `shouldSatisfy` isNotHeld
            show refusal `shouldSatisfy` isInfixOf "ran out of the budget"
    it
        "reads the node's own phase-2 and phase-1 rejections as the suite's refusal discipline does"
        $ do
            budget <- readFile "test/fixtures/node-refusals/budget.txt"
            let (words2, hashes2) = rejectionEvidence budget
                phase1Text =
                    "ConwayUtxowFailure (MissingScriptWitnessesUTXOW (fromList [ScriptHash \""
                        <> T.unpack appHash
                        <> "\"]))"
                (words1, hashes1) = rejectionEvidence phase1Text
                as ws hs =
                    (emptyReceipt 0 "" "" ""){rcPhaseWords = ws, rcRefusingScripts = hs}
            words2 `shouldSatisfy` elem "PlutusFailure"
            case hashes2 of
                (h : _) -> attribution h (as words2 hashes2) `shouldBe` Right ()
                [] -> fail "the phase-2 fixture names no failed script"
            (words1, hashes1) `shouldBe` ([], [appHash])
            attribution appHash (as words1 hashes1) `shouldSatisfy` isLeft
    it
        "refuses a story that runs an action outside a clause, or a refusal telling without its premise"
        $ do
            validateControls
                (action (Run Create (Target "loose") "") >> controlsStory)
                `shouldSatisfy` isLeft
            let unfounded =
                    theorem duplicateRefused $ do
                        _ <-
                            clause
                                "an absent key is accepted"
                                (bindCheck duplicateRefused (\_ -> pure ()))
                                (pure ())
                        clause
                            "the fold is refused"
                            (bindCheck duplicateRefused (\_ -> pure ()))
                            (pure ())
            validateControls unfounded `shouldSatisfy` isLeft

appHash :: T.Text
appHash = "a99"

commandMark :: Command -> String -> String -> String
commandMark c t k = case c of
    Insert -> t <> "/" <> k
    _ -> t <> ":" <> commandName c

-- | The receipts the ordinary commands print, consistent with one another.
commandReceipt :: Command -> String -> Int -> Bool -> Value
commandReceipt c k updates terminal = case c of
    Create ->
        object
            [ "outcome" .= ("success" :: String)
            , "pins"
                .= object
                    ["pinState" .= ("aa" :: String), "pinActive" .= ("cc" :: String)]
            , "token" .= ("bb" :: String)
            ]
    Insert ->
        object
            [ "outcome" .= ("success" :: String)
            , "liveOutput" .= ("i#1" :: String)
            , "envelope" .= envelope "p0"
            ]
    Update n ->
        object
            [ "outcome" .= ("success" :: String)
            , "liveOutput" .= ("u" <> show n <> "#0")
            , "payload" .= payload ("p" <> show n)
            , "root" .= ("r1" :: String)
            ]
    Terminate ->
        object
            [ "outcome" .= ("success" :: String)
            , "deposit" .= (2000000 :: Int)
            , "released" .= ("t#1" :: String)
            ]
    Inspect
        | terminal ->
            object
                [ "outcome" .= ("success" :: String)
                , "leaf" .= ("terminal" :: String)
                , "key" .= hexOf k
                , "root" .= ("r2" :: String)
                , "applicationOutput" .= object ["holdings" .= ([] :: [Value])]
                ]
        | otherwise ->
            let p = if updates == 0 then "p0" else "p" <> show updates
            in  object
                    [ "outcome" .= ("success" :: String)
                    , "leaf" .= ("active" :: String)
                    , "key" .= hexOf k
                    , "root" .= ("r1" :: String)
                    , "applicationOutput"
                        .= object
                            [ "output"
                                .= (if updates == 0 then "i#1" else "u" <> show updates <> "#0")
                            , "envelope" .= envelope p
                            , "payload" .= payload p
                            , "controller" .= ("c0" :: String)
                            , "deposit" .= (2000000 :: Int)
                            , "lovelace" .= (2000000 :: Int)
                            ]
                    ]
  where
    payload :: String -> Value
    payload p = object ["bytes" .= p]
    envelope :: String -> Value
    envelope p =
        object
            [ "fields"
                .= [ object
                        [ "fields"
                            .= [ object ["int" .= (1 :: Int)]
                               , object
                                    [ "fields"
                                        .= [ object ["bytes" .= ("aa" :: String)]
                                           , object ["bytes" .= ("bb" :: String)]
                                           ]
                                    ]
                               , object ["bytes" .= ("cc" :: String)]
                               ]
                        ]
                   , payload p
                   ]
            ]

-- | Replace a command receipt's root.
setRoot :: T.Text -> Value -> Value
setRoot root v = case v of
    Object o -> Object (KeyMap.insert "root" (String root) o)
    _ -> v

-- | A node rejection as the backend records it: its words, file and digest.
rejected :: [T.Text] -> Receipt -> Receipt
rejected phaseWords r =
    r
        { rcOutcome = "ledger-refused"
        , rcPhaseWords = phaseWords
        , rcRejectionFile = Just "evidence/rejection.txt"
        , rcRejectionSha256 = Just "00"
        }

-- | A key label as the commands print keys: lowercase hex of its bytes.
hexOf :: String -> String
hexOf = concatMap (printf "%02x" . ord)

-- | Replace one field of a command receipt.
setField :: T.Text -> T.Text -> Value -> Value
setField name value v = case v of
    Object o -> Object (KeyMap.insert (Key.fromText name) (String value) o)
    _ -> v

-- | A terminal inspect that applied and observed the killed fold from the chain.
withObserved :: Bool -> Value -> Value
withObserved killed v = case v of
    Object o
        | killed ->
            Object
                ( KeyMap.insert
                    "mirrorAdvanced"
                    (toJSON ["f9" :: String])
                    (KeyMap.insert "observed" (toJSON ["f9" :: String]) o)
                )
    _ -> v

-- | What each provoked command leaves when the client keeps its obligations.
provoked :: Provocation -> Receipt -> Receipt
provoked p r =
    let still =
            ProcessEvidence
                { peJournal = "targets/process/journal.jsonl"
                , peJournalBefore = 5
                , peJournalAfter = 5
                , peLastEvent = "insert/observed"
                , peSubmitted = []
                , peExit = 1
                , peWaited = Nothing
                , peFilesBefore = []
                , peFilesAfter = []
                , peSeedProbe = Nothing
                }
        killed step tx =
            r
                { rcOutcome = "no-receipt"
                , rcSubmissions = [Submission step tx "b" "d"]
                , rcProcess =
                    Just
                        still
                            { peJournalAfter = 7
                            , peLastEvent = step <> "/submitted"
                            , peSubmitted = [tx]
                            , peExit = -9
                            }
                }
        noLeaf outcome =
            r
                { rcOutcome = outcome
                , rcCommand = Just (object ["outcome" .= outcome, "leaf" .= Null])
                , rcProcess = Just still
                }
    in  case p of
            WhileLocked -> r{rcOutcome = "concurrent-writer", rcProcess = Just still}
            SelectorChanged -> r{rcOutcome = "client-refusal", rcProcess = Just still}
            WithoutProof -> noLeaf "proof-missing"
            WithoutNode -> noLeaf "node-unavailable"
            TerminateKilled -> killed "fold" "f9"
            UpdateAfterKill ->
                r
                    { rcOutcome = "partial"
                    , rcCommand =
                        Just
                            ( object
                                [ "outcome" .= ("partial" :: String)
                                , "unresolved"
                                    .= object
                                        [ "tx" .= ("f9" :: String)
                                        , "case" .= ("acknowledged" :: String)
                                        ]
                                ]
                            )
                    , rcProcess = Just still
                    }
            CreateKilled -> killed "boot" "b9"
            CreateAgain -> r{rcOutcome = "client-refusal", rcProcess = Just still}
            LateCreate ->
                r
                    { rcOutcome = "client-refusal"
                    , rcReason =
                        Just
                            "targets/raced already holds a registry or its journal; create never overwrites one"
                    , rcProcess =
                        Just
                            still
                                { peFilesBefore = [("evidence/before/registry.json", "01")]
                                , peFilesAfter = [("targets/raced/registry.json", "01")]
                                , peSeedProbe = Just "evidence/probe.json"
                                }
                    }
            NodeLost ->
                r
                    { rcOutcome = "partial"
                    , rcReason = Just "the update u9 was submitted; its confirmation failed"
                    , rcProcess =
                        Just
                            still
                                { peJournalAfter = 8
                                , peLastEvent = "update/unconfirmed"
                                , peSubmitted = ["u9"]
                                , peWaited = Just 31
                                }
                    }
