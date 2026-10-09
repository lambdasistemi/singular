{- |
Module      : Conformance.Support.Programs
Description : Every registry row is a program or is named outside the model
License     : Apache-2.0
-}
module Conformance.Support.Programs (spec) where

import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL)
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Conformance.Book (renderBook)
import Conformance.Edge.Programs
    ( Classification (..)
    , Kind (..)
    , Program (..)
    , Registry (..)
    , classify
    , classifyGroup
    , displayCohort
    , displayStory
    , kindOf
    , programFor
    , programs
    , recordsOf
    )
import Conformance.Rows (Row (..), loadRows)
import Conformance.Run.Live (tamperedRefunds)
import Conformance.Story.Live (validateLive)
import Conformance.Story.Live qualified as Live
import Control.Monad (void)
import Data.Either (isLeft, isRight)
import Data.Foldable (forM_)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))
import Paths_conformance (getDataFileName)
import Singular.Registry.Ledger (Coin (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

spec :: Spec
spec = do
    refundSpec
    programSpec

programSpec :: Spec
programSpec = describe
    "Appendix: every registry row is a program or is named outside the model"
    $ do
        it
            "Classifies every registry row of the inventory exactly once, and refuses a group it cannot account for"
            $ do
                group <- registryRows
                group `shouldSatisfy` (not . null)
                fmap length (classifyGroup group) `shouldBe` Right (length group)
                -- The quantifier's controls: nothing to classify, a row nothing
                -- classifies, and a classification for a row the group lacks.
                classifyGroup [] `shouldSatisfy` isLeft
                classifyGroup (group <> ["unknown-requirement"])
                    `shouldSatisfy` isLeft
                classifyGroup (drop 1 group) `shouldSatisfy` isLeft

        it "Reads each program's kind off its instructions" $ do
            forM_ compositions $ \row ->
                classify row `shouldBe` Right (Composed EdgeComposition)
            forM_ tampers $ \row ->
                classify row `shouldBe` Right (Composed Tamper)
            forM_ programs $ \p ->
                fmap Composed (kindOf p) `shouldBe` classify (T.pack (programRow p))

        it "Names every row the model cannot express with its own reason" $
            forM_ outside $ \row -> case classify row of
                Right (Outside reason) -> T.length reason `shouldSatisfy` (> 40)
                other ->
                    expectationFailure
                        (T.unpack row <> " is not outside the vocabulary: " <> show other)

        it
            "Retires the stake_script hook rows against the registry interface, which has no hook"
            $ forM_
                [ "retired-stake-hook-with-withdrawal"
                , "retired-stake-hook-without-withdrawal"
                ]
            $ \row -> do
                fmap programRow (programFor row) `shouldBe` Nothing
                case classify (T.pack row) of
                    Right (Outside reason) ->
                        T.unpack reason `shouldSatisfy` isInfixOf "no stake_script hook"
                    other -> expectationFailure (row <> ": " <> show other)

        it
            "Validates every program, books its cohort in its own registries and expects one outcome per compared record"
            $ do
                group <- registryRows
                length programs
                    `shouldSatisfy` (>= length compositions + length tampers)
                forM_ programs $ \p -> do
                    case displayStory p of
                        Right story -> validateLive story `shouldBe` Right ()
                        Left problem -> expectationFailure (programRow p <> ": " <> problem)
                    recordsOf p `shouldBe` Right (length (programExpected p))
                    case displayCohort p of
                        Right cohort ->
                            forM_ cohort $ \(registry, _) ->
                                registry `shouldSatisfy` (`elem` readings p)
                        Left problem -> expectationFailure (programRow p <> ": " <> problem)
                    T.pack (programRow p)
                        `shouldSatisfy` (`elem` ("sequence" : group))

        it
            "Cites no end-to-end example the registry's suite no longer has, for the custody rows superseded with the owner role"
            $ do
                rows <- loadCommitted
                forM_
                    ["historical-owner-signed-sweep", "historical-registry-termination"]
                    $ \row ->
                        case [r | r <- rows, rowId r == row] of
                            [r] -> do
                                rowEvidence r `shouldBe` Nothing
                                T.unpack (rowExpected r) `shouldSatisfy` isPrefixOf "superseded"
                            _ ->
                                expectationFailure (T.unpack row <> " is not in the inventory once")

        it
            "Publishes each registry row's classification under its requirement in the book"
            $ do
                rows <- loadCommitted
                let book = renderBook rows []
                forM_ [r | r <- rows, rowGroup r == "registry-operations"] $ \r -> do
                    let section = requirementSection (T.unpack (rowRequirement r)) book
                        expected = case classify (rowId r) of
                            Right (Composed EdgeComposition) ->
                                "Run as an edge composition over the registry's operations"
                            Right (Composed Tamper) ->
                                "Run as a tamper of an edge's transaction"
                            Right (Outside reason) ->
                                "Outside the model's vocabulary: " <> T.unpack reason
                            Left problem -> "unclassified: " <> problem
                    section `shouldSatisfy` isRight
                    fmap (isInfixOf expected) section `shouldBe` Right True
  where
    readings p = map registryReading (programRegistries p)

compositions :: [Text]
compositions =
    [ "insert-key"
    , "insert-occupied-key"
    , "permanent-retire-active-key"
    , "retract-inside-window"
    , "reject-after-window"
    , "empty-fold"
    ]

tampers :: [Text]
tampers =
    [ "retract-outside-window"
    , "reject-before-deadline-consumer-requirement"
    , "request-value-and-refund-routing"
    , "register-active-key"
    , "reject-and-retract-refund-controls"
    , "reject-inside-processing-and-retraction-windows"
    ]

outside :: [Text]
outside =
    [ "update-existing-key"
    , "delete-existing-key"
    , "reinsert-deleted-key"
    , "retire-active-key"
    , "fold-against-superseded-root"
    , "surplus-fold-actions"
    , "historical-owner-change"
    , "retired-stake-hook-with-withdrawal"
    , "retired-stake-hook-without-withdrawal"
    , "historical-owner-signed-sweep"
    , "historical-non-owner-sweep"
    , "historical-registry-termination"
    , "historical-permissionless-fold"
    ]

registryRows :: IO [Text]
registryRows = do
    rows <- loadCommitted
    pure [rowId r | r <- rows, rowGroup r == "registry-operations"]

loadCommitted :: IO [Row]
loadCommitted = do
    path <- getDataFileName "rows.json"
    loadRows path >>= either fail pure

{- | The book's text from a requirement's heading to the next heading, or why
there is none.
-}
requirementSection :: String -> String -> Either String String
requirementSection requirement book =
    case [rest | rest <- tails book, heading `isPrefixOf` rest] of
        [rest] -> Right (takeSection (drop (length heading) rest))
        [] -> Left ("no heading for " <> requirement)
        _ -> Left ("more than one heading for " <> requirement)
  where
    heading = "### " <> requirement <> "\n"
    takeSection text = case [ i
                            | (i, rest) <- zip [0 ..] (tails text)
                            , "\n### " `isPrefixOf` rest || "\n## " `isPrefixOf` rest
                            ] of
        i : _ -> take i text
        [] -> text

-- | The story language's booked reject batches and the refunds they pay.
refundSpec :: Spec
refundSpec = describe "Appendix: a reject batch's bookings and refund tampers" $ do
    it
        "Crosses, shortens and splits a reject batch's refunds in the transaction's input order"
        $ do
            tamperedRefunds
                Live.CrossedRefunds
                [4_000_000, 2_000_000]
                [genesisAddr, genesisAddr]
                `shouldBe` Right ([2_000_000, 4_000_000], [])
            fmap fst (tamperedRefunds Live.CrossedRefunds [1, 2, 3] [])
                `shouldBe` Right [2, 3, 1]
            tamperedRefunds
                (Live.ShortFirstRefund 1_000)
                [4_000_000, 2_000_000]
                []
                `shouldBe` Right ([3_999_000, 2_000_000], [])
            case tamperedRefunds (Live.SplitFirstRefund 1) [3_000_000] [genesisAddr] of
                Right (refunds, [beside]) -> do
                    refunds `shouldBe` [2_999_999]
                    beside ^. addrTxOutL `shouldBe` genesisAddr
                    beside ^. coinTxOutL `shouldBe` Coin 2_000_000
                other -> expectationFailure ("split refund: " <> show (fmap fst other))
            fmap fst (tamperedRefunds Live.CrossedRefunds [3_000_000] [])
                `shouldSatisfy` isLeft
            fmap fst (tamperedRefunds (Live.ShortFirstRefund 1) [] [])
                `shouldSatisfy` isLeft
    it
        "Validates a booked reject batch, renders who booked each request and refuses what cannot be built"
        $ do
            let request = Live.EdgeRequest Live.InsertAbsent "first-key" "first wallet"
                other = Live.EdgeRequest Live.InsertAbsent "second-key" "second wallet"
                booked deposit = [(request, Live.Booking "first owner wallet" deposit)]
                pair =
                    booked 4_000_000
                        <> [(other, Live.Booking "second owner wallet" 2_000_000)]
                batch alteration requests =
                    void
                        ( maybe
                            Live.rejectBookedBatchWithin
                            Live.tamperRejectBookedBatchWithin
                            alteration
                            Live.AfterTheWindows
                            "registry"
                            requests
                        )
            validateLive (batch Nothing pair) `shouldBe` Right ()
            Live.renderLive (batch Nothing pair)
                `shouldSatisfy` isInfixOf
                    "booked **first-key** by the first owner wallet with a deposit of 4000000 lovelace, **second-key** by the second owner wallet with a deposit of 2000000 lovelace"
            forM_
                [
                    ( Live.CrossedRefunds
                    , "with each owner refunded, in its refund's position, what the next request's owner is owed"
                    )
                ,
                    ( Live.ShortFirstRefund 1_000
                    , "with the first request's refund 1000 lovelace short, "
                    )
                ,
                    ( Live.SplitFirstRefund 1
                    , "1 lovelace short in its own position and two ada more in another output at the same owner's key"
                    )
                ]
                $ \(alteration, reading) -> do
                    validateLive (batch (Just alteration) pair) `shouldBe` Right ()
                    Live.renderLive (batch (Just alteration) pair)
                        `shouldSatisfy` isInfixOf reading
            validateLive (batch (Just Live.CrossedRefunds) (booked 4_000_000))
                `shouldSatisfy` isLeft
            validateLive (batch (Just (Live.ShortFirstRefund 0)) pair)
                `shouldSatisfy` isLeft
            validateLive (batch Nothing (booked 0)) `shouldSatisfy` isLeft
    it
        "Reads a refund tamper off the instructions and counts the batch as one compared record"
        $ do
            let program =
                    void
                        ( Live.tamperRejectBookedBatchWithin
                            Live.CrossedRefunds
                            Live.AfterTheWindows
                            "registry"
                            [ (Live.EdgeRequest Live.InsertAbsent "a" "w", Live.Booking "w" 1)
                            , (Live.EdgeRequest Live.InsertAbsent "b" "w", Live.Booking "w" 1)
                            ]
                        )
            Live.liveInstructions program
                `shouldBe` [Live.Instruction Live.BatchInstruction (Just "crossed-refunds")]
