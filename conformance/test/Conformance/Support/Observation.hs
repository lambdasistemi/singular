{-# LANGUAGE OverloadedStrings #-}

-- | Appendix: completeness of receipt observations; no theorem claim.
module Conformance.Support.Observation (spec) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Either (isLeft)
import Test.Hspec (Spec, describe, it, shouldBe)

import Conformance.Fixture.ActiveRegistration (
    bootRoot,
    dupControlTx,
    edgeDrop,
    edgeKeys,
    edgeSet,
    foldStep,
    foldTx,
    legDrop,
    legKeysOf,
    loadOne,
    mintControlTx,
    optionalLegKeys,
    receiptSet,
    root1,
    root2,
    root3,
    withEdge,
 )

spec :: Spec
spec = do
    describe "Appendix: checking that a registration report is complete and consistent" $ do
        -- The extent is read out of the artifact, not listed here; these
        -- sizes are what stop the quantifiers ranging over nothing.
        it "Checks that the example report contains all the fields used by the missing-data tests" $ do
            length edgeKeys `shouldBe` 20
            legKeysOf "duplicate"
                `shouldBe` ["controlTxid", "distinguisher", "hashes", "keys", "trace", "txid"]
            legKeysOf "keyedMint"
                `shouldBe` [ "claimedMint"
                           , "controlMint"
                           , "controlTxid"
                           , "distinguisher"
                           , "entailedMint"
                           , "hashes"
                           , "keys"
                           , "trace"
                           , "txid"
                           ]

        it "Rejects a report with no registration evidence" $ do
            r <- loadOne (withEdge Null)
            (isLeft r) `shouldBe` True

        it "Rejects a registration report whenever any required top-level field is missing" $
            mapM_
                ( \k -> do
                    r <- loadOne (edgeDrop k)
                    (k, isLeft r) `shouldBe` (k, True)
                )
                edgeKeys

        it "Rejects either rejection example whenever any required detail is missing" $
            mapM_
                ( \(leg, k) -> do
                    r <- loadOne (legDrop leg k)
                    ((leg, k), isLeft r) `shouldBe` ((leg, k), True)
                )
                [ (leg, k)
                | leg <- ["duplicate", "keyedMint"]
                , k <- legKeysOf leg
                , k `notElem` optionalLegKeys
                ]

        -- Each landed fold advances the committed trie before the next
        -- proof is built. These guard the Given — that every fold in
        -- the observation genuinely landed — rather than a Then
        -- conjunct, so they stay supporting instead of borrowing a
        -- clause they do not read.
        it "Rejects a report saying a successful registration left the registry contents unchanged" $ do
            r <-
                loadOne
                    ( edgeSet
                        "sequence"
                        ( toJSON
                            [ foldStep foldTx bootRoot bootRoot
                            , foldStep dupControlTx bootRoot root2
                            , foldStep mintControlTx root2 root3
                            ]
                        )
                    )
            (isLeft r) `shouldBe` True

        it "Rejects a report whose second transaction starts from the initial registry instead of the first transaction's result" $ do
            r <-
                loadOne
                    ( edgeSet
                        "sequence"
                        ( toJSON
                            [ foldStep foldTx bootRoot root1
                            , foldStep dupControlTx bootRoot root2
                            , foldStep mintControlTx root2 root3
                            ]
                        )
                    )
            (isLeft r) `shouldBe` True

        it "Rejects a report whose recorded registry state disagrees with its reported transaction result" $ do
            r <-
                loadOne
                    ( edgeSet
                        "sequence"
                        ( toJSON
                            [ object
                                [ "txid" .= foldTx
                                , "rootBefore" .= bootRoot
                                , "rootAfter" .= root1
                                , "committed" .= root2
                                ]
                            , foldStep dupControlTx root1 root2
                            , foldStep mintControlTx root2 root3
                            ]
                        )
                    )
            (isLeft r) `shouldBe` True

        it "Rejects a report that lists no successful request-processing transactions" $ do
            r <- loadOne (edgeSet "sequence" (toJSON ([] :: [Value])))
            (isLeft r) `shouldBe` True

        it "Rejects a report whose registration transaction is missing from its list of successful transactions" $ do
            r <-
                loadOne
                    ( edgeSet
                        "sequence"
                        ( toJSON
                            [ foldStep dupControlTx bootRoot root1
                            , foldStep mintControlTx root1 root2
                            ]
                        )
                    )
            (isLeft r) `shouldBe` True

        it "Rejects registration evidence submitted under a different requirement" $ do
            r <- loadOne (receiptSet "row" (String "CG02"))
            (isLeft r) `shouldBe` True

