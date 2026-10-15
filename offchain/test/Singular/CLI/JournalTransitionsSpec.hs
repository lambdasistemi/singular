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
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import Test.Hspec

import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )

import Singular.CLI.Receipt
    ( FoldTransition (..)
    , JournalEntry (..)
    , chainTransitions
    , foldScalarsAgree
    , foldTransitions
    )
import Singular.CLI.Reconcile (observeVerdicts)
import Singular.CLI.Session
    ( Expectation (..)
    , expectationJournalFields
    , foldExpectationScalars
    )
import Singular.Registry.TxBuilder.BookingFixture
    ( applicationPolicy
    , applicationScript
    , payer
    )
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)
import Singular.Registry.Wallet (bech32Address)

spec :: Spec
spec = transitionRows >> fundingHolds

transitionRows :: Spec
transitionRows =
    describe "the fold's journal line lists its transitions" $
        do
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
            it "reads the entry's list when it has one" $ do
                let ts =
                        toList
                            ( chainTransitions
                                "rb0"
                                ( ("req1", "key1", 3, "active:aa", "ra1")
                                    :| [("req2", "key2", 4, "terminal", "ra2")]
                                )
                            )
                foldTransitions baseEntry{journalTransitions = Just ts} `shouldBe` ts
                foldTransitions baseEntry{journalTransitions = Just []} `shouldBe` []
            it
                "reads a scalar-only line as its one transition with an empty request"
                $ do
                    foldTransitions
                        baseEntry
                            { journalKey = Just "key1"
                            , journalExpect = Just "active:aa"
                            , journalEdge = Just 3
                            , journalRootBefore = Just "rb0"
                            , journalRootAfter = Just "ra1"
                            }
                        `shouldBe` [FoldTransition "" "key1" 3 "active:aa" "rb0" "ra1"]
            it "reads a line carrying neither as empty" $ do
                foldTransitions baseEntry `shouldBe` []
                foldTransitions
                    baseEntry
                        { journalKey = Just "key1"
                        , journalExpect = Just "active:aa"
                        , journalRootBefore = Just "rb0"
                        , journalRootAfter = Just "ra1"
                        }
                    `shouldBe` []
            it "is true for a line without a list" $ do
                foldScalarsAgree baseEntry `shouldBe` True
                foldScalarsAgree baseEntry{journalKey = Just "key1"} `shouldBe` True
            it "agrees with the scalars the writer derives from the list" $ do
                let ts =
                        chainTransitions
                            "rb0"
                            ( ("req1", "key1", 3, "active:aa", "ra1")
                                :| [ ("req2", "key2", 4, "terminal", "ra2")
                                   , ("req3", "key3", 3, "active:bb", "ra3")
                                   ]
                            )
                    (key, expect, edge, rootBefore, rootAfter) =
                        foldExpectationScalars ts
                    entry =
                        baseEntry
                            { journalKey = Just key
                            , journalExpect = Just expect
                            , journalEdge = Just edge
                            , journalRootBefore = Just rootBefore
                            , journalRootAfter = Just rootAfter
                            , journalTransitions = Just (toList ts)
                            }
                foldScalarsAgree entry `shouldBe` True
            it "disagrees when any scalar is altered against its list" $ do
                let ts =
                        chainTransitions
                            "rb0"
                            ( ("req1", "key1", 3, "active:aa", "ra1")
                                :| [("req2", "key2", 4, "terminal", "ra2")]
                            )
                    (key, expect, edge, rootBefore, rootAfter) =
                        foldExpectationScalars ts
                    healthy =
                        baseEntry
                            { journalKey = Just key
                            , journalExpect = Just expect
                            , journalEdge = Just edge
                            , journalRootBefore = Just rootBefore
                            , journalRootAfter = Just rootAfter
                            , journalTransitions = Just (toList ts)
                            }
                foldScalarsAgree healthy{journalKey = Just "other"} `shouldBe` False
                foldScalarsAgree healthy{journalExpect = Just "terminal"}
                    `shouldBe` False
                foldScalarsAgree healthy{journalEdge = Just 9} `shouldBe` False
                foldScalarsAgree healthy{journalRootBefore = Just "other"}
                    `shouldBe` False
                foldScalarsAgree healthy{journalRootAfter = Just "other"}
                    `shouldBe` False
                foldScalarsAgree healthy{journalTransitions = Just []}
                    `shouldBe` False

baseEntry :: JournalEntry
baseEntry =
    JournalEntry
        { journalCommand = "insert"
        , journalStep = "fold"
        , journalTxId = "tx"
        , journalEvent = "prepared"
        , journalDetail = Nothing
        , journalInputs = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalChainPoint = Nothing
        , journalSession = Nothing
        , journalObservedTip = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        , journalTransitions = Nothing
        , journalTime = Nothing
        }

-- ---------------------------------------------------------
-- The funding expectation (#491 remainder, pull request 1)
-- ---------------------------------------------------------

{- | A preparation is observed when the transaction's first output is
live, ada only, at the payer's address: the @funding@ expectation names
the payer, and the read-back output is checked against it.
-}
fundingHolds :: Spec
fundingHolds = describe "the funding expectation" $ do
    it "observes a live ada-only output at the named payer" $ do
        verdicts <-
            observeVerdicts
                "fold"
                baseEntry
                    { journalExpect = Just ("funding:" <> T.pack (bech32Address payer))
                    }
                (mkBasicTxOut payer (MaryValue (Coin 5_000_000) mempty))
                Nothing
        verdicts
            `shouldBe` [ Right
                            "fold: the funding output is live, ada only, at the payer's address"
                       ]
    it "leaves an output at another address unread" $ do
        verdicts <-
            observeVerdicts
                "fold"
                baseEntry
                    { journalExpect = Just ("funding:" <> T.pack (bech32Address payer))
                    }
                (mkBasicTxOut stranger (MaryValue (Coin 5_000_000) mempty))
                Nothing
        verdicts `shouldBe` [Left "fold: its after-state is not read back"]
    it "leaves a token-carrying output unread" $ do
        verdicts <-
            observeVerdicts
                "fold"
                baseEntry
                    { journalExpect = Just ("funding:" <> T.pack (bech32Address payer))
                    }
                ( mkBasicTxOut
                    payer
                    ( MaryValue
                        (Coin 5_000_000)
                        ( MultiAsset
                            (Map.singleton applicationPolicy (Map.singleton (AssetName "t") 1))
                        )
                    )
                )
                Nothing
        verdicts `shouldBe` [Left "fold: its after-state is not read back"]
    it "leaves a reference-script output unread" $ do
        verdicts <-
            observeVerdicts
                "fold"
                baseEntry
                    { journalExpect = Just ("funding:" <> T.pack (bech32Address payer))
                    }
                ( mkBasicTxOut payer (MaryValue (Coin 5_000_000) mempty)
                    & referenceScriptTxOutL .~ SJust applicationScript
                )
                Nothing
        verdicts `shouldBe` [Left "fold: its after-state is not read back"]
  where
    stranger = addrFromKeyHashBytes Testnet (BS.replicate 28 0x11)
