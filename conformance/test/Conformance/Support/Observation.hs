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
    describe "supporting evidence (schema completeness, no theorem binding)" $ do
        -- The extent is read out of the artifact, not listed here; these
        -- sizes are what stop the quantifiers ranging over nothing.
        it "names every field of the observation before mutating one" $ do
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

        it "refuses a receipt that carries no observation at all" $ do
            r <- loadOne (withEdge Null)
            (isLeft r) `shouldBe` True

        it "refuses the observation with any single field absent" $
            mapM_
                ( \k -> do
                    r <- loadOne (edgeDrop k)
                    (k, isLeft r) `shouldBe` (k, True)
                )
                edgeKeys

        it "refuses either refusal leg with any required field absent" $
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
        it "refuses a landed fold whose root did not move" $ do
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

        it "refuses a second fold proved against the boot root" $ do
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

        it "refuses a committed root that disagrees with the chain's" $ do
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

        it "refuses an empty landed-fold sequence" $ do
            r <- loadOne (edgeSet "sequence" (toJSON ([] :: [Value])))
            (isLeft r) `shouldBe` True

        it "refuses a fold transaction absent from the landed sequence" $ do
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

        it "refuses edge evidence on a row carrying another identity" $ do
            r <- loadOne (receiptSet "row" (String "CG02"))
            (isLeft r) `shouldBe` True

