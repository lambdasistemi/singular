{- |
Module      : Conformance.Support.Vocabularies
Description : Every authentication and wire-format requirement is classified and said in its vocabulary
License     : Apache-2.0
-}
module Conformance.Support.Vocabularies (spec) where

import Conformance.Authentication.Programs qualified as Authentication
import Conformance.Book (renderBook)
import Conformance.Classification
    ( Class (..)
    , Classified (..)
    , Vocabulary (..)
    , armsRow
    , classifyInventory
    , classifyRow
    )
import Conformance.Rows (Row (..), loadRows)
import Conformance.Wire.Programs qualified as Wire
import Data.Either (isLeft)
import Data.Foldable (forM_)
import Data.List (isInfixOf, isPrefixOf, nub, sort, tails)
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
    "Appendix: every authentication and wire-format requirement is classified and said in its vocabulary"
    $ do
        it
            "Classifies each requirement of the model-facing groups once, and refuses an extent it cannot account for"
            $ do
                rows <- loadCommitted
                let classified = [r | r <- rows, rowGroup r `elem` groups]
                length classified `shouldSatisfy` (> 0)
                fmap length (classifyInventory rows)
                    `shouldBe` Right (length classified)
                -- The quantifier's controls: nothing to classify, a requirement
                -- listed twice, and a program or reason for a requirement the
                -- inventory does not hold.
                classifyInventory [] `shouldSatisfy` isLeft
                classifyInventory (rows <> take 1 (identity rows))
                    `shouldSatisfy` isLeft
                forM_ (identity rows <> serialization rows) $ \r ->
                    classifyInventory (filter (/= r) rows) `shouldSatisfy` isLeft

        it
            "Places all five authentication and eight wire-format requirements outside the model, each with its own reason"
            $ do
                rows <- loadCommitted
                length (identity rows) `shouldBe` 5
                length (serialization rows) `shouldBe` 8
                forM_ (identity rows <> serialization rows) $ \r -> case classifyRow r of
                    Right (Classified _ (OutsideModel reason) _) ->
                        T.length reason `shouldSatisfy` (> 40)
                    other ->
                        expectationFailure
                            (T.unpack (rowId r) <> " is not outside the model: " <> show other)
                let reasons =
                        [ reason
                        | r <- identity rows <> serialization rows
                        , Right (Classified _ (OutsideModel reason) _) <- [classifyRow r]
                        ]
                length (nub reasons) `shouldBe` length reasons

        it
            "Runs each authentication requirement in the authentication vocabulary and each wire-format requirement in the wire round trip"
            $ do
                rows <- loadCommitted
                forM_ (identity rows) $ \r ->
                    fmap classifiedVocabulary (classifyRow r)
                        `shouldBe` Right (Just AuthenticationVocabulary)
                forM_ (serialization rows) $ \r ->
                    fmap classifiedVocabulary (classifyRow r)
                        `shouldBe` Right (Just WireRoundTrip)

        it
            "Publishes each requirement's classification and its program, instruction by instruction, under the requirement in the book"
            $ do
                rows <- loadCommitted
                let book = renderBook rows []
                forM_ (identity rows <> serialization rows) $ \r -> do
                    let name = T.unpack (rowId r)
                        section = requirementSection (T.unpack (rowRequirement r)) book
                        readings =
                            maybe
                                ( map
                                    Wire.instructionReading
                                    (maybe [] Wire.programInstructions (Wire.programFor name))
                                )
                                ( map Authentication.instructionReading
                                    . Authentication.programInstructions
                                )
                                (Authentication.programFor name)
                    case (classifyRow r, section) of
                        (Right (Classified _ (OutsideModel reason) _), Right text) -> do
                            text
                                `shouldSatisfy` isInfixOf
                                    ("Outside the model's vocabulary: " <> T.unpack reason)
                            readings `shouldSatisfy` (not . null)
                            forM_ readings $ \reading ->
                                text `shouldSatisfy` isInfixOf reading
                        other -> expectationFailure (name <> ": " <> show other)

        it
            "Uses every instruction kind of each vocabulary in some program, and reads every instruction as its own sentence"
            $ do
                let authentication =
                        Authentication.sessionPrologue
                            <> concatMap Authentication.programInstructions Authentication.programs
                    wire = concatMap Wire.programInstructions Wire.programs
                sort (nub (map Authentication.instructionKind authentication))
                    `shouldBe` [minBound .. maxBound]
                sort (nub (map Wire.instructionKind wire))
                    `shouldBe` [minBound .. maxBound]
                forM_ authentication $ \i ->
                    Authentication.instructionReading i `shouldSatisfy` (not . null)
                forM_ wire $ \i -> Wire.instructionReading i `shouldSatisfy` (not . null)
                length (nub (map Wire.instructionReading wire))
                    `shouldBe` length (nub wire)

        it
            "Introduces every seed, registry and transaction before an instruction uses it"
            $ do
                Authentication.validateSession `shouldBe` Right ()
                Wire.programs `shouldSatisfy` (not . null)
                forM_ Wire.programs $ \p -> Wire.validateProgram p `shouldBe` Right ()
                -- The validation's controls: a registry read before it boots,
                -- and a citation of a transaction nothing submitted.
                forM_ (take 1 [p | p <- Wire.programs, Wire.needsDevnet p]) $ \p -> do
                    Wire.validateProgram
                        p{Wire.programInstructions = drop 1 (Wire.programInstructions p)}
                        `shouldSatisfy` isLeft
                    Wire.validateProgram
                        p{Wire.programCites = [Wire.RejectionIn "nowhere"]}
                        `shouldSatisfy` isLeft

        it
            "Arms some requirement with every control of each vocabulary, and arms nothing with an unknown control"
            $ do
                rows <- loadCommitted
                let names = map (T.unpack . rowId) (identity rows <> serialization rows)
                forM_ (Authentication.controls <> Wire.controls) $ \control ->
                    any (armsRow control) names `shouldBe` True
                any (armsRow "no-such-control") names `shouldBe` False
                Authentication.controls `shouldSatisfy` (not . null)
                Wire.controls `shouldSatisfy` (not . null)
  where
    groups = ["registry-operations", "registry-identity", "serialization"]

identity :: [Row] -> [Row]
identity rows = [r | r <- rows, rowGroup r == "registry-identity"]

serialization :: [Row] -> [Row]
serialization rows = [r | r <- rows, rowGroup r == "serialization"]

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
                            | (i, rest) <- zip [0 :: Int ..] (tails text)
                            , "\n### " `isPrefixOf` rest || "\n## " `isPrefixOf` rest
                            ] of
        i : _ -> take i text
        [] -> text
