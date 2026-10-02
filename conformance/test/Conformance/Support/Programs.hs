{- |
Module      : Conformance.Support.Programs
Description : Every registry row is a program or is named outside the model
License     : Apache-2.0
-}
module Conformance.Support.Programs (spec) where

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
import Conformance.Story.Live (validateLive)
import Data.Either (isLeft, isRight)
import Data.Foldable (forM_)
import Data.List (isInfixOf, isPrefixOf, tails)
import Data.Text (Text)
import Data.Text qualified as T
import Paths_conformance (getDataFileName)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

spec :: Spec
spec = describe
    "Appendix: every registry row is a program or is named outside the model" $ do
    it
        "Classifies every registry row of the inventory exactly once, and refuses a group it cannot account for"
        $ do
            group <- registryRows
            group `shouldSatisfy` (not . null)
            fmap length (classifyGroup group) `shouldBe` Right (length group)
            -- The quantifier's controls: nothing to classify, a row nothing
            -- classifies, and a classification for a row the group lacks.
            classifyGroup [] `shouldSatisfy` isLeft
            classifyGroup (group <> ["CG99"]) `shouldSatisfy` isLeft
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
        $ forM_ ["CG14", "CG15"]
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
            forM_ ["CG16", "CG18"] $ \row ->
                case [r | r <- rows, rowId r == row] of
                    [r] -> do
                        rowEvidence r `shouldBe` Nothing
                        T.unpack (rowExpected r) `shouldSatisfy` isPrefixOf "superseded"
                    _ ->
                        expectationFailure (T.unpack row <> " is not in the inventory once")

    it
        "Publishes each registry row's classification under its requirement in the book" $ do
        rows <- loadCommitted
        let book = renderBook rows []
        forM_ [r | r <- rows, rowGroup r == "CG"] $ \r -> do
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
compositions = ["CG01", "CG02", "CG03", "CG04", "CG05", "CG06", "CG08", "CG11"]

tampers :: [Text]
tampers = ["CG07", "CG09", "CG19", "CG21", "CG22", "CG23", "CG24"]

outside :: [Text]
outside =
    [ "CG10"
    , "CG12"
    , "CG13"
    , "CG14"
    , "CG15"
    , "CG16"
    , "CG17"
    , "CG18"
    , "CG20"
    ]

registryRows :: IO [Text]
registryRows = do
    rows <- loadCommitted
    pure [rowId r | r <- rows, rowGroup r == "CG"]

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
