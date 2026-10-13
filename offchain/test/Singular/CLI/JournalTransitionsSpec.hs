{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.JournalTransitionsSpec
Description : The fold's journal line lists its transitions
License     : Apache-2.0

A fold's prepared line carries every transition it folds, chained from
the fold's root before to its root after, with the scalar fields
mirroring the first and last transition. A line written before the list
existed decodes with no list.
-}
module Singular.CLI.JournalTransitionsSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Test.Hspec

import Singular.CLI.Receipt
    ( FoldTransition (..)
    , JournalEntry (..)
    , chainTransitions
    )
import Singular.CLI.Session
    ( Expectation (..)
    , expectationJournalFields
    , foldExpectationScalars
    )

spec :: Spec
spec = describe "the fold's journal line lists its transitions" $ do
    it "chains three transitions from the fold's root before" $ do
        let got =
                chainTransitions
                    "rb0"
                    ( ("req1", "key1", 3, "active:aa", "ra1")
                        :| [ ("req2", "key2", 4, "terminal", "ra2")
                           , ("req3", "key3", 3, "active:bb", "ra3")
                           ]
                    )
            listed = toList got
        map transitionRequest listed `shouldBe` ["req1", "req2", "req3"]
        map transitionKey listed `shouldBe` ["key1", "key2", "key3"]
        map transitionEdge listed `shouldBe` [3, 4, 3]
        map transitionExpect listed
            `shouldBe` ["active:aa", "terminal", "active:bb"]
        map transitionRootBefore listed `shouldBe` ["rb0", "ra1", "ra2"]
        map transitionRootAfter listed `shouldBe` ["ra1", "ra2", "ra3"]
    it
        "mirrors the first transition and the last root after in the scalars"
        $ do
            let transitions =
                    chainTransitions
                        "rb0"
                        ( ("req1", "key1", 3, "active:aa", "ra1")
                            :| [ ("req2", "key2", 4, "terminal", "ra2")
                               , ("req3", "key3", 3, "active:bb", "ra3")
                               ]
                        )
                (key, expect, edge, rootBefore, rootAfter) =
                    foldExpectationScalars transitions
            key `shouldBe` "key1"
            expect `shouldBe` "active:aa"
            edge `shouldBe` 3
            rootBefore `shouldBe` "rb0"
            rootAfter `shouldBe` "ra3"
            let (jKey, jExpect, jEdge, jBefore, jAfter, jList) =
                    expectationJournalFields (FoldExpectation transitions)
            jKey `shouldBe` Just "key1"
            jExpect `shouldBe` Just "active:aa"
            jEdge `shouldBe` Just 3
            jBefore `shouldBe` Just "rb0"
            jAfter `shouldBe` Just "ra3"
            jList `shouldBe` Just (toList transitions)
    it "writes the other constructor exactly as before with no list" $ do
        let (jKey, jExpect, jEdge, jBefore, jAfter, jList) =
                expectationJournalFields
                    (Expectation Nothing "state" Nothing Nothing Nothing)
        jKey `shouldBe` Nothing
        jExpect `shouldBe` Just "state"
        jEdge `shouldBe` Nothing
        jBefore `shouldBe` Nothing
        jAfter `shouldBe` Nothing
        jList `shouldBe` Nothing
    it
        "decodes a line written before the list with no list and round-trips"
        $ do
            let oldLine :: BC.ByteString
                oldLine =
                    "{\"journalCommand\":\"insert\",\"journalStep\":\"fold\",\"journalTxId\":\"ab\",\"journalEvent\":\"prepared\",\"journalDetail\":null,\"journalInputs\":[],\"journalTipSlot\":7,\"journalBody\":null,\"journalBodyHash\":null,\"journalChainPoint\":\"7.00\",\"journalKey\":null,\"journalExpect\":\"state\",\"journalEdge\":null,\"journalRootBefore\":null,\"journalRootAfter\":null}"
            entry <- case Aeson.eitherDecodeStrict' oldLine of
                Right e -> pure (e :: JournalEntry)
                Left err ->
                    expectationFailure ("old line does not decode: " <> err)
                        >> pure (error "unreachable")
            journalTransitions entry `shouldBe` Nothing
            journalExpect entry `shouldBe` Just "state"
            let reEncoded = Aeson.encode entry
            case Aeson.eitherDecode' reEncoded of
                Right entry2 -> entry2 `shouldBe` entry
                Left err -> expectationFailure ("re-encoded line does not decode: " <> err)
