{-# LANGUAGE GADTs #-}

-- | The refusal controls are judged from receipts, and only from receipts.
module Conformance.Support.CliControls (spec) where

import Conformance.Cli.Controls
    ( ClauseResult (..)
    , ClauseStatus (..)
    , CliI (..)
    , Command (..)
    , Observation (..)
    , Receipt (..)
    , Story
    , Target (..)
    , commandName
    , controlsStory
    , duplicateRefused
    , duplicateStory
    , emptyReceipt
    , held
    , judge
    , outline
    , renderControls
    , resolveStatement
    , statementBindings
    , validateControls
    )
import Conformance.Story.Binding (BoundObligation (..), firstExisting)
import Conformance.Story.Specification
    ( Clause (..)
    , Step (..)
    , bindCheck
    , checkAction
    , clause
    , clauses
    , theorem
    )
import Control.Monad.Operational
    ( Program
    , ProgramViewT (Return, (:>>=))
    , view
    )
import Data.Aeson (Value, eitherDecodeFileStrict')
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf, isSuffixOf)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , pendingWith
    , shouldBe
    , shouldSatisfy
    )

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
        Run c (Target t) k -> do
            before <- readIORef inserted
            let again = c == Insert && t `elem` before
            modifyIORef' inserted (if c == Insert then (t :) else id)
            emit ("run " <> T.pack (commandName c)) t k $ \r ->
                if again
                    then r{rcOutcome = "partial", rcPendingRequest = Just "b0#0"}
                    else r{rcOutcome = "success"}
        Book (Target t) k ->
            emit "book" t k $ \r -> r{rcOutcome = "accepted", rcTxId = Just "b1"}
        FoldUnevaluated (Target t) k ->
            emit "fold-unevaluated" t k $ \r ->
                let base =
                        r
                            { rcEvaluation = Just "skipped"
                            , rcStateValidator = Just stateHash
                            , rcTxId = Just "f1"
                            }
                in  if "-control" `isSuffixOf` t
                        then base{rcOutcome = "accepted"}
                        else
                            base{rcOutcome = "ledger-refused", rcRefusingScripts = [stateHash]}
        Observe (Target t) k ->
            emit "observe" t k $ \r ->
                r
                    { rcOutcome = "observed"
                    , rcObservation =
                        Just
                            (Observation "00" (Just "h#1") (Just 4000000) ["b0#0"] 3000000 100)
                    }
      where
        emit name t k fill = do
            n <- readIORef step
            modifyIORef' step (+ 1)
            let r = fill (emptyReceipt n name (T.pack t) (T.pack k))
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
spec = describe "The ordinary CLI's refusal controls, judged from receipts" $ do
    it
        "binds exactly the two application statements, as the statement ledger records them"
        $ do
            map boName statementBindings
                `shouldBe` [ "OpenDatumApplication.Statements.duplicate_refused_by_registry"
                           , "OpenDatumApplication.Statements.resurrection_refused_by_registry"
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
        "states four clauses per statement and refuses a refusal without an accepting control"
        $ do
            length (outline controlsStory) `shouldBe` 8
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
        statuses results `shouldBe` replicate 8 Held
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
            length results `shouldBe` 8
            take 2 (statuses results) `shouldBe` [Held, Held]
            drop 2 (statuses results) `shouldSatisfy` all isUncovered
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
        statuses results !! 2 `shouldSatisfy` isUncovered
        show (statuses results !! 2)
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
            statuses (judge accepted controlsStory) !! 2 `shouldSatisfy` isNotHeld
            statuses (judge otherScript controlsStory) !! 6
                `shouldSatisfy` isNotHeld
            statuses (judge evaluated controlsStory) !! 2
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
            statuses (judge refusedInstead controlsStory) !! 1
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
        statuses (judge moved controlsStory) !! 3 `shouldSatisfy` isNotHeld
    it "renders uncovered clauses beside held ones, with the count" $ do
        rs <- honestReceipts controlsStory
        let rendered = renderControls (judge (take 3 rs) controlsStory) controlsStory
        rendered `shouldSatisfy` isInfixOf "uncovered: no receipt for step 3"
        rendered
            `shouldSatisfy` isInfixOf "0 of 8 clauses hold; 0 do not; 8 are uncovered."
        rendered
            `shouldSatisfy` isInfixOf
                "`OpenDatumApplication.Statements.duplicate_refused_by_registry`"
        rendered
            `shouldSatisfy` (\t -> not (any (\d -> ('#' : [d]) `isInfixOf` t) ['0' .. '9']))
