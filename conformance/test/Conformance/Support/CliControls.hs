{-# LANGUAGE GADTs #-}
{-# LANGUAGE NumericUnderscores #-}

-- | The refusal controls are judged from receipts, and only from receipts.
module Conformance.Support.CliControls (spec) where

import Conformance.Cli.Admission (sha256Hex)
import Conformance.Cli.Controls
    ( Account (..)
    , ClauseResult (..)
    , ClauseStatus (..)
    , CliI (..)
    , Command (..)
    , Crafted (..)
    , Indexer (..)
    , IndexerRead (..)
    , Observation (..)
    , ProcessEvidence (..)
    , Provocation (..)
    , Receipt (..)
    , Stated (..)
    , Story
    , Submission (..)
    , Target (..)
    , actionsOf
    , attribution
    , commandName
    , controlsStory
    , craftedName
    , duplicateRefused
    , duplicateStory
    , emptyReceipt
    , forbiddenInPermanent
    , held
    , indexerName
    , judge
    , obligationBindings
    , outline
    , permanentStory
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
import Data.List (isInfixOf, nub)
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
                        , rcObservation =
                            Just
                                ( Observation
                                    (if "process:killed" `elem` before then "r2" else "r1")
                                    Nothing
                                    Nothing
                                    []
                                    0
                                    100
                                    (Just (if "process:killed" `elem` before then "terminal" else "active"))
                                )
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
            when again $ modifyIORef' inserted ((t <> ":partial") :)
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
        ReadIndexer ix (Target t) k inspected ->
            emit ("read-indexer " <> T.pack (indexerName ix)) t k $ \r ->
                r
                    { rcOutcome = "success"
                    , rcReadbackFile = Just "evidence/readback.json"
                    , rcReadbackSha256 = Just "00"
                    , rcIndexer = Just (honestRead ix k inspected)
                    , rcMaxLag = Just 600
                    }
        Reclaim (Target t) k _ _ -> do
            modifyIORef' inserted ((t <> ":reclaim") :)
            emit "reclaim" t k $ \r ->
                r
                    { rcOutcome = "accepted"
                    , rcTxId = Just "e1"
                    , rcPendingRequest = Just "b0#0"
                    , rcEvidence = ["evidence/step-e1.cbor.hex"]
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
                in  if t `notElem` ["duplicate", "resurrection", "permanent"]
                        then base{rcOutcome = "accepted"}
                        else
                            (rejected ["PlutusFailure", "CekError"] base)
                                { rcRefusingScripts = [stateHash]
                                }
        Observe (Target t) k -> do
            before <- readIORef inserted
            let partials = length [() | m <- before, m == t <> ":partial"]
                reclaims = length [() | m <- before, m == t <> ":reclaim"]
                pendingNow = t /= "permanent" || partials > reclaims
                released = if t == "permanent" then 2_800_000 * toInteger reclaims else 0
            emit "observe" t k $ \r ->
                r
                    { rcOutcome = "observed"
                    , rcObservation =
                        Just
                            ( Observation
                                "00"
                                (Just "h#1")
                                (Just 4_000_000)
                                ["b0#0" | pendingNow]
                                (if pendingNow then 3_000_000 else 0)
                                (100 + released)
                                (Just "active")
                            )
                    }
      where
        emit name t k fill = do
            n <- readIORef step
            modifyIORef' step (+ 1)
            let r =
                    bounded
                        (fill (emptyReceipt n name (T.pack t) (T.pack k)))
                            { rcAdmission = Just []
                            }
                bounded x
                    | t == "permanent"
                    , name `elem` ["reclaim", "fold-unevaluated"]
                        || "craft " `T.isPrefixOf` name =
                        x
                            { rcAllowance = Just 5_000_000
                            , rcAccount =
                                Just
                                    ( Account
                                        200_000
                                        ["w#0"]
                                        (Just 300_000)
                                        (Just 9_000_000)
                                        ["b0#0", "w#1"]
                                    )
                            }
                    | otherwise = x
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

clauseStatuses :: String -> [ClauseResult] -> [ClauseStatus]
clauseStatuses phrase results = [crStatus r | r <- results, phrase `isInfixOf` crTitle r]

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
    it
        "publishes the missing-proof control uncovered when its receipt records no reachable witness"
        $ do
            rs <- honestReceipts controlsStory
            let unavailable =
                    alter
                        "provoke inspect-without-proof"
                        "process"
                        ( \r ->
                            r
                                { rcOutcome = "client-error"
                                , rcCommand = Nothing
                                , rcProcess = Nothing
                                , rcReason = Just "no saved proof file is reachable"
                                }
                        )
                        rs
                results = judge unavailable controlsStory
            clauseStatuses "proof material moved aside" (judge rs controlsStory)
                `shouldBe` [Held]
            putStrLn
                ( "Harness receipt-computed missing-proof states: "
                    <> show
                        ( clauseStatuses "proof material moved aside" (judge rs controlsStory)
                        , clauseStatuses "proof material moved aside" results
                        )
                )
            clauseStatuses "proof material moved aside" results
                `shouldSatisfy` (\ss -> length ss == 1 && all isUncovered ss)
            clauseStatuses "root does not move" results
                `shouldSatisfy` all (== Held)
            show results
                `shouldSatisfy` isInfixOf "no saved proof file is reachable"
    it
        "refuses interrupted-fold recovery with another root or a repeated submission"
        $ do
            rs <- honestReceipts controlsStory
            let wrongRoot =
                    alter
                        "run inspect"
                        "process"
                        (\r -> r{rcCommand = setRoot "other" <$> rcCommand r})
                        rs
                resubmitted =
                    alter
                        "provoke update-after-kill"
                        "process"
                        ( \r ->
                            r{rcProcess = fmap (\p -> p{peSubmitted = ["f9"]}) (rcProcess r)}
                        )
                        rs
            clauseStatuses
                "inspect reads the key Terminal"
                (judge wrongRoot controlsStory)
                `shouldSatisfy` (\ss -> not (null ss) && any isNotHeld ss)
            clauseStatuses
                "inspect reads the key Terminal"
                (judge resubmitted controlsStory)
                `shouldSatisfy` (\ss -> not (null ss) && any isNotHeld ss)
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
            `shouldSatisfy` isInfixOf "30 of 32 approved cases are covered live; 2 are not."
        -- the indexer read belongs to a take on an existing registry: the
        -- development controls do not reach it, and say so
        full
            `shouldSatisfy` isInfixOf
                "| the Active key read from two public indexers before its termination | client obligation `INV300-INDEXER`, no model statement | uncovered"
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

    describe "one take on a registry that already exists" $ do
        let key = "demo1-take"
            story = permanentStory key
            titled s results = [crStatus r | r <- results, s `isInfixOf` crTitle r]
        it
            "states every clause once, each refusal beside an accepting control"
            $ do
                validateControls story `shouldBe` Right ()
                length (outline story) `shouldBe` 29
                length (nub (map fst (outline story))) `shouldBe` 5
        it "holds every clause on an honest take" $ do
            rs <- honestReceipts story
            let results = judge rs story
            statuses results `shouldBe` replicate 29 Held
            held results `shouldBe` True
        it
            "never creates a registry or provokes a command, and the instrument can tell"
            $ do
                actionsOf story `shouldSatisfy` all (`notElem` forbiddenInPermanent)
                actionsOf story `shouldSatisfy` elem "reclaim"
                -- the same quantifier finds them in the story that does both
                filter (`elem` forbiddenInPermanent) (actionsOf controlsStory)
                    `shouldSatisfy` ( \found -> "run create" `elem` found && any (T.isPrefixOf "provoke ") found
                                    )
                -- and covers every provocation this domain defines
                length (filter (T.isPrefixOf "provoke ") forbiddenInPermanent)
                    `shouldBe` length [minBound .. maxBound :: Provocation]
        it
            "does not hold a retraction that left a request behind, took another, or moved the wallet"
            $ do
                rs <- honestReceipts story
                let reclaimClauses = titled "retraction of that request"
                    after = [r | r <- rs, rcAction r == "observe", rcTarget r == "permanent"]
                    swapLast f = case reverse after of
                        (lastObserve : _) -> map (\r -> if r == lastObserve then f r else r) rs
                        [] -> rs
                    stillPending =
                        swapLast
                            ( \r ->
                                r
                                    { rcObservation = fmap (\o -> o{obPending = ["b0#0"]}) (rcObservation r)
                                    }
                            )
                    wallet =
                        swapLast
                            ( \r ->
                                r
                                    { rcObservation =
                                        fmap
                                            (\o -> o{obWalletLovelace = obWalletLovelace o + 1})
                                            (rcObservation r)
                                    }
                            )
                    refused =
                        alter "reclaim" "permanent" (\r -> r{rcOutcome = "ledger-refused"}) rs
                    noFee = alter "reclaim" "permanent" (\r -> r{rcAccount = Nothing}) rs
                length (filter (/= Held) (reclaimClauses (judge rs story)))
                    `shouldBe` 0
                mapM_
                    ( \mutated -> reclaimClauses (judge mutated story) `shouldSatisfy` any isNotHeld
                    )
                    [stillPending, wallet, refused, noFee]
        it
            "does not hold a refusal whose collateral is unbounded, unstated or unreturned"
            $ do
                rs <- honestReceipts story
                let account f r = r{rcAccount = fmap f (rcAccount r)}
                    over =
                        alter
                            "fold-unevaluated"
                            "permanent"
                            (account (\a -> a{acCollateralTotal = Just 9_000_000}))
                            rs
                    none =
                        alter
                            "fold-unevaluated"
                            "permanent"
                            (account (\a -> a{acCollateralTotal = Nothing}))
                            rs
                    kept =
                        alter
                            "craft update-by-stranger"
                            "permanent"
                            (account (\a -> a{acCollateralReturn = Nothing}))
                            rs
                    unread =
                        alter
                            "craft early-withdrawal"
                            "permanent"
                            (\r -> r{rcAccount = Nothing})
                            rs
                    failsWith mutated needle =
                        show (judge mutated story) `shouldSatisfy` isInfixOf needle
                failsWith over "over the bound of 5000000"
                failsWith none "states no total collateral"
                failsWith kept "returns no part of its collateral input"
                failsWith unread "collateral the transaction states is not recorded"
                statuses (judge rs story) `shouldSatisfy` all (== Held)
        it
            "does not hold any node-judged transaction of a take that set no collateral allowance"
            $ do
                rs <- honestReceipts story
                let unbounded act =
                        alter act "permanent" (\r -> r{rcAllowance = Nothing}) rs
                    exposure = titled "within the operator's explicit allowance"
                    clauseOf act
                        | act == "reclaim" = titled "retraction of that request"
                        | otherwise = exposure
                length (exposure (judge rs story)) `shouldBe` 4
                -- one mutation per node-judged action of the take: each is
                -- caught by the clause that bounds that refusal, not by luck
                mapM_
                    ( \act -> do
                        let results = judge (unbounded act) story
                        clauseOf act results `shouldSatisfy` any isNotHeld
                        show results
                            `shouldSatisfy` isInfixOf "no collateral allowance was set"
                    )
                    [ "craft update-by-stranger"
                    , "craft early-withdrawal"
                    , "fold-unevaluated"
                    , "reclaim"
                    ]
        it
            "does not hold an indexer's read that is missing, unavailable, stale or in disagreement with the node"
            $ do
                rs <- honestReceipts story
                let indexerClauses = titled "finds exactly one output"
                    koios = alterRead "read-indexer koios"
                    alterRead act f =
                        alter act "permanent" f rs
                    withRead f r = r{rcIndexer = fmap f (rcIndexer r)}
                    mutations :: [(String, [Receipt], String)]
                    mutations =
                        [
                            ( "unavailable"
                            , koios (\r -> r{rcOutcome = "provider-unavailable"})
                            , "not success"
                            )
                        ,
                            ( "mismatch outcome"
                            , koios (\r -> r{rcOutcome = "provider-mismatch"})
                            , "not success"
                            )
                        ,
                            ( "record unread"
                            , koios (\r -> r{rcIndexer = Nothing})
                            , "was not read back"
                            )
                        ,
                            ( "record not admitted"
                            , koios
                                ( \r -> r{rcAdmission = Just ["the retained readback record is missing"]}
                                )
                            , "the retained readback record is missing"
                            )
                        ,
                            ( "no configured lag"
                            , koios (\r -> r{rcMaxLag = Nothing})
                            , "no maximum lag the take was configured with"
                            )
                        , -- the raw facts change while every stated flag stays true

                            ( "two holders"
                            , koios
                                (withRead (\i -> i{irHolders = (<> [("x#1", 1)]) <$> irHolders i}))
                            , "counts 2 outputs holding the token"
                            )
                        ,
                            ( "two of the token"
                            , koios
                                ( withRead
                                    (\i -> i{irHolders = map (\(o, _) -> (o, 2)) <$> irHolders i})
                                )
                            , "holds 2 of the token"
                            )
                        ,
                            ( "no holder"
                            , koios (withRead (\i -> i{irHolders = Just []}))
                            , "counts 0 outputs holding the token"
                            )
                        ,
                            ( "no answer kept"
                            , koios (withRead (\i -> i{irHolders = Nothing}))
                            , "keeps no provider answer"
                            )
                        ,
                            ( "answer names another output"
                            , koios (withRead (\i -> i{irHolders = Just [("x#9", 1)]}))
                            , "not the output the record reports"
                            )
                        ,
                            ( "two addresses"
                            , alterRead
                                "read-indexer blockfrost"
                                (withRead (\i -> i{irHolderAddresses = Just 2}))
                            , "counts 2 addresses holding the token"
                            )
                        ,
                            ( "other output"
                            , koios
                                ( withRead
                                    (\i -> i{irIndexerOutput = "x#9", irHolders = Just [("x#9", 1)]})
                                )
                            , "is not the node's"
                            )
                        ,
                            ( "record datum not the answer's"
                            , koios (withRead (\i -> i{irAnswerDatum = Just "d87a80"}))
                            , "does not carry"
                            )
                        ,
                            ( "record tip not the answer's"
                            , koios (withRead (\i -> i{irAnswerTip = Just 50}))
                            , "but the provider's answer says 50"
                            )
                        ,
                            ( "other datum bytes"
                            , koios (withRead (\i -> i{irIndexerDatumCbor = "d87a80"}))
                            , "datum bytes are not the node's"
                            )
                        ,
                            ( "other datum hash"
                            , koios
                                ( withRead
                                    ( \i ->
                                        i
                                            { irIndexerDatumHashComputed = Just "ee"
                                            , irIndexerDatumHashRecorded = "ee"
                                            }
                                    )
                                )
                            , "is not the node's datum hash"
                            )
                        ,
                            ( "recorded hash not the bytes' hash"
                            , koios (withRead (\i -> i{irIndexerDatumHashRecorded = "ee"}))
                            , "not the hash of its own datum bytes"
                            )
                        ,
                            ( "hash never computed"
                            , koios (withRead (\i -> i{irIndexerDatumHashComputed = Nothing}))
                            , "computed no hash"
                            )
                        ,
                            ( "behind"
                            , koios
                                ( withRead
                                    (\i -> i{irIndexerTipSlot = subtract 700 <$> irIndexerTipSlot i})
                                )
                            , "slots behind the node, beyond the 600 allowed"
                            )
                        ,
                            ( "a malformed whole number kept"
                            , koios
                                ( withRead
                                    ( \i ->
                                        i{irMalformed = ["the koios answer's quantity of the token is 1.4"]}
                                    )
                                )
                            , "keeps a malformed fact: the koios answer's quantity of the token is 1.4"
                            )
                        ,
                            ( "no tip"
                            , koios (withRead (\i -> i{irIndexerTipSlot = Nothing}))
                            , "keeps no indexer tip"
                            )
                        ,
                            ( "run under another lag"
                            , koios (withRead (\i -> i{irMaxLagSlots = Just 100_000}))
                            , "not the 600 the take configured"
                            )
                        , -- a stated summary its facts contradict

                            ( "states not holding"
                            , koios (withRead (\i -> i{irStated = (irStated i){stHolds = False}}))
                            , "states holds False, but its facts say True"
                            )
                        ,
                            ( "states another lag"
                            , koios
                                (withRead (\i -> i{irStated = (irStated i){stLagSlots = Just 5}}))
                            , "states a lag of 5 slots"
                            )
                        , -- identities

                            ( "another policy"
                            , koios (withRead (\i -> i{irPolicy = "ee"}))
                            , "the policy the indexer was asked about"
                            )
                        ,
                            ( "another asset name"
                            , koios (withRead (\i -> i{irAssetName = "00"}))
                            , "the asset name the indexer was asked about"
                            )
                        ,
                            ( "node side not the inspect's"
                            , koios (withRead (\i -> i{irNodeDatumHash = "ff"}))
                            , "the record's node datum hash is not the inspect's"
                            )
                        ,
                            ( "another provider's record"
                            , koios (withRead (\i -> i{irProvider = "blockfrost"}))
                            , "not of the indexer asked"
                            )
                        ]
                length (indexerClauses (judge rs story)) `shouldBe` 2
                indexerClauses (judge rs story) `shouldSatisfy` all (== Held)
                mapM_
                    ( \(_, mutated, needle) -> do
                        let results = judge mutated story
                        indexerClauses results `shouldSatisfy` any isNotHeld
                        show results `shouldSatisfy` isInfixOf needle
                    )
                    mutations
        it
            "does not hold a retraction of any request but the one the insertion's receipt names"
            $ do
                rs <- honestReceipts story
                let reclaimClauses = titled "retraction of that request"
                    other =
                        alter
                            "reclaim"
                            "permanent"
                            (\r -> r{rcPendingRequest = Just "zz#9"})
                            rs
                    otherBody =
                        alter
                            "reclaim"
                            "permanent"
                            ( \r ->
                                r
                                    { rcAccount =
                                        fmap (\a -> a{acSpends = ["w#1"]}) (rcAccount r)
                                    }
                            )
                            rs
                    unnamed =
                        alter
                            "run insert"
                            "permanent"
                            ( \r ->
                                if rcOutcome r == "partial" then r{rcPendingRequest = Nothing} else r
                            )
                            rs
                mapM_
                    ( \mutated ->
                        reclaimClauses (judge mutated story) `shouldSatisfy` any isNotHeld
                    )
                    [other, otherBody, unnamed]
                reclaimClauses (judge rs story) `shouldSatisfy` all (== Held)

-- | What an indexer's record keeps when it agrees with the inspect it was asked about.
honestRead :: Indexer -> String -> Receipt -> IndexerRead
honestRead ix k inspected =
    IndexerRead
        { irProvider = T.pack (indexerName ix)
        , irPolicy = "cc"
        , irAssetName = T.pack (hexOf k)
        , irHolders = Just [(out, 1)]
        , irHolderAddresses = if ix == Blockfrost then Just 1 else Nothing
        , irAnswerDatum = Just "d87980"
        , irAnswerTip = Just 100
        , irIndexerOutput = out
        , irIndexerDatumCbor = "d87980"
        , irIndexerDatumHashRecorded = "dd"
        , irIndexerDatumHashComputed = Just "dd"
        , irIndexerTipSlot = Just 100
        , irMaxLagSlots = Just 600
        , irNodeOutput = out
        , irNodeDatumCbor = "d87980"
        , irNodeDatumHash = "dd"
        , irNodeChainPoint = "100.aa"
        , irStated =
            Stated
                { stHolds = True
                , stSameOutput = True
                , stSameDatumBytes = True
                , stSameDatumHash = True
                , stWithinLag = True
                , stLagSlots = Just 0
                }
        , irMalformed = []
        }
  where
    out = case rcCommand inspected of
        Just (Object o)
            | Just (Object a) <- KeyMap.lookup "applicationOutput" o
            , Just (String s) <- KeyMap.lookup "output" a ->
                s
        _ -> ""

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
    Update _ ->
        object
            [ "outcome" .= ("success" :: String)
            , "liveOutput" .= ("u" <> show (updates + 1) <> "#0")
            , "payload" .= payload ("p" <> show (updates + 1))
            , "root" .= ("r1" :: String)
            ]
    Terminate ->
        object
            [ "outcome" .= ("success" :: String)
            , "deposit" .= (2_000_000 :: Int)
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
                    , "observedTip" .= ("100.aa" :: String)
                    , "applicationOutput"
                        .= object
                            [ "output"
                                .= (if updates == 0 then "i#1" else "u" <> show updates <> "#0")
                            , "datumHash" .= ("dd" :: String)
                            , "datumCbor" .= ("d87980" :: String)
                            , "envelope" .= envelope p
                            , "payload" .= payload p
                            , "controller" .= ("c0" :: String)
                            , "deposit" .= (2_000_000 :: Int)
                            , "lovelace" .= (2_000_000 :: Int)
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

-- | A terminal inspect that observed the killed fold from public history.
withObserved :: Bool -> Value -> Value
withObserved killed v = case v of
    Object o
        | killed ->
            Object
                (KeyMap.insert "observed" (toJSON ["f9" :: String]) o)
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
            TerminateKilled ->
                (killed "fold" "f9")
                    { rcObservation =
                        Just (Observation "r2" Nothing Nothing [] 0 100 (Just "terminal"))
                    }
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
