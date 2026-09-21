{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.EdgeSpec
Description : The receipt checks read as theorem clauses
License     : Apache-2.0

The CG21 receipt-validation examples, expressed through the
theorem-clause DSL. A reader follows a bound Lean obligation to the
clauses it exercises and the executable cases under each: every case
names its condition and outcome, runs the real loader through
'Conformance.Receipt.loadReceipts', and records why it distinguishes
its defect. The stable row identity survives beside the cases as
compatibility metadata, never in a name.

What is not a clause stays visibly supporting evidence with no theorem
binding: the artifact-derived quantifier guards and their extent
assertion, the schema gates, and the landed-fold chaining that guards
the Given rather than a Then conjunct. Do not invent bindings for them.
-}
module Conformance.EdgeSpec (spec) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Either (isLeft)
import Test.Hspec (Spec, describe, it, shouldBe)

import Conformance.EdgeFixtures (
    activeHex,
    bootRoot,
    claimedMint,
    completeReceipt,
    dupControlTx,
    dupTx,
    edgeDrop,
    edgeKeys,
    edgeSet,
    entailedMint,
    foldStep,
    foldTx,
    keyAHex,
    keyBHex,
    keyHex,
    legDrop,
    legKeysOf,
    legSet,
    loadOne,
    mintControlTx,
    mintOf,
    openHex,
    optionalLegKeys,
    receiptSet,
    root1,
    root2,
    root3,
    walletAddr,
    withEdge,
 )
import Conformance.Story (
    TheoremGroup,
    accepts,
    acceptsBecause,
    compatRow,
    groupNames,
    mkClause,
    nameViolation,
    receiptClause,
    rejects,
    runTheorem,
    theorem,
    unexercised,
 )
import Conformance.StoryBindings (insertActiveRow, keyedMintFold)

-- | The active-registration obligation read through its receipt checks.
insertActiveGroup :: TheoremGroup
insertActiveGroup =
    theorem
        insertActiveRow
        [ receiptClause
            ( mkClause
                "the destination holds exactly one active token at the requested address"
                [ "address := some r.output"
                , "assets := [((.active, r.key), 1)]"
                , "kindCount t.state .active r.key = 1"
                ]
            )
            [ accepts
                "one active token at the key, at the address the request named"
                (loadOne completeReceipt)
            , rejects
                "no token delivered"
                (loadOne (edgeSet "delivered" (toJSON ([] :: [Value]))))
                "the conclusion is exactly one, so zero is a distinct defect from a wrong one"
            , rejects
                "two tokens delivered at the key"
                ( loadOne
                    ( edgeSet
                        "delivered"
                        ( toJSON
                            [ object
                                [ "policy" .= activeHex
                                , "name" .= keyHex
                                , "quantity" .= (2 :: Int)
                                ]
                            ]
                        )
                    )
                )
                "a per-kind total cannot see a quantity right in kind and wrong in count"
            , rejects
                "a token delivered under the open policy instead of the active one"
                ( loadOne
                    ( edgeSet
                        "delivered"
                        ( toJSON
                            [ object
                                [ "policy" .= openHex
                                , "name" .= keyHex
                                , "quantity" .= (1 :: Int)
                                ]
                            ]
                        )
                    )
                )
                "the policy is half the token identity; an open-policy token is never the active witness"
            , rejects
                "a token whose asset name is not the key"
                ( loadOne
                    ( edgeSet
                        "delivered"
                        ( toJSON
                            [ object
                                [ "policy" .= activeHex
                                , "name" .= String "6f74686572"
                                , "quantity" .= (1 :: Int)
                                ]
                            ]
                        )
                    )
                )
                "the asset name is the key; a token under another name is a different holding"
            , rejects
                "a token observed at an address the request did not name"
                ( loadOne
                    ( edgeSet
                        "observedAddress"
                        (String "60ffffffffffffffffffffffffffffffffffffffffffffffffffffff")
                    )
                )
                "the destination is the address the request named; the same token elsewhere misses it"
            ]
            [ unexercised
                "the signature-set invariance conjunct"
                "no receipt field carries the approval's signature set"
            ]
            (compatRow "CG21")
        , receiptClause
            ( mkClause
                "the fold mints exactly one active token at the key"
                ["mint := [((.active, r.key), 1)]"]
            )
            [ rejects
                "a mint that is not exactly one token at the key"
                (loadOne (edgeSet "minted" (toJSON ([] :: [Value]))))
                "the fold must mint what the destination holds; an empty mint funds nothing"
            ]
            []
            (compatRow "CG21")
        , receiptClause
            ( mkClause
                "the open application declares no parameter"
                ["openPolicyParameters = []"]
            )
            [ rejects
                "an open application that declares a parameter"
                (loadOne (edgeSet "openParameters" (Number 1)))
                "the open policy is parameterless; a declared parameter names a different application"
            ]
            []
            (compatRow "CG21")
        , receiptClause
            (mkClause "the fold pays no refund" ["refunds := []"])
            [ rejects
                "a fold that paid a refund"
                (loadOne (edgeSet "refunds" (toJSON [1_000_000 :: Int])))
                "the concluded transaction refunds nothing; a paid refund moves value the rule never sends"
            ]
            []
            (compatRow "CG21")
        , receiptClause
            (mkClause "the fold requires no signer" ["signers := []"])
            [ rejects
                "a fold that required a signer"
                (loadOne (edgeSet "signers" (toJSON [walletAddr])))
                "the concluded transaction is unsigned; a required signer adds an authorization the rule never grants"
            ]
            []
            (compatRow "CG21")
        , receiptClause
            ( mkClause
                "the request lovelace covers the tip"
                ["lovelaceCoversTip s.config lovelace = true"]
            )
            [ rejects
                "a request whose lovelace does not cover the tip"
                (loadOne (edgeSet "requestLovelace" (Number 999_999)))
                "the hypothesis needs the tip on hand; below it the rule does not apply"
            ]
            []
            (compatRow "CG21")
        , receiptClause
            ( mkClause
                "the destination is bound by the approval"
                ["destinationDatumBinds r = true"]
            )
            [ rejects
                "a destination binding the approval does not carry"
                ( loadOne
                    ( edgeSet
                        "approvalRecomputed"
                        (String "00112233445566778899001122334455667788990011223344556677")
                    )
                )
                "equality of the carried and recomputed approval name is the binding; a mismatch delivers where nothing authorized"
            ]
            []
            (compatRow "CG21")
        , receiptClause
            ( mkClause
                "only the root pin moves"
                ["onlyRootChanged s.config t.state.config = true"]
            )
            [ rejects
                "a fold that moved a non-root configuration pin"
                ( loadOne
                    ( edgeSet
                        "configAfter"
                        ( toJSON
                            [ String "2000000"
                            , String "30000"
                            , String "30000"
                            , openHex
                            , activeHex
                            , String "5c1e7ab390d24f6817be05c3a9f2d148e6730bc5924af18de036b7a1"
                            , String "3b8d02f7561ec49a0d73b15fa28c6e904715d3ba6cf28017e94db5c6"
                            ]
                        )
                    )
                )
                "only the root may move; any other difference is a configuration change the fold must not make"
            , rejects
                "a configuration observation that lost a pin"
                (loadOne (edgeSet "configBefore" (toJSON ([] :: [Value]))))
                "the pin comparison needs both sides; a lost pin is an unobserved configuration, not an unchanged one"
            ]
            []
            (compatRow "CG21")
        , receiptClause
            ( mkClause
                "a second insert at the same key is refused"
                ["txOf t.state r₂ lovelace = .error \"key-exists\""]
            )
            [ acceptsBecause
                "a leg whose trace the ledger did not surface is accepted"
                (loadOne (legDrop "duplicate" "trace"))
                "a script-execution failure carries an empty log list, so absence is the normal case, not an incomplete leg"
            , rejects
                "a leg whose control is the transaction it refused"
                (loadOne (legSet "duplicate" "controlTxid" dupTx))
                "the control must be an accepted transaction; a leg that controls for itself proves the builder can build nothing"
            , rejects
                "a leg naming no failing script"
                (loadOne (legSet "duplicate" "hashes" (toJSON ([] :: [Value]))))
                "attribution needs the failing script; without it the refusal blames nothing"
            , rejects
                "a leg naming an empty failing script"
                (loadOne (legSet "duplicate" "hashes" (toJSON [String ""])))
                "an empty hash attributes to nothing"
            , rejects
                "a duplicate leg naming two keys"
                (loadOne (legSet "duplicate" "keys" (toJSON [keyHex, keyBHex])))
                "the duplicate names the one occupied key; a second key belongs to the other fixture"
            , rejects
                "a duplicate leg naming a key the fold did not insert"
                (loadOne (legSet "duplicate" "keys" (toJSON [keyAHex])))
                "the refusal is key-exists on the inserted key; a key the fold never inserted cannot exist yet"
            , rejects
                "a duplicate leg carrying mint arithmetic"
                (loadOne (legSet "duplicate" "claimedMint" claimedMint))
                "the duplicate is refused before any mint runs; arithmetic on it claims to be the keyed-mint witness"
            , rejects
                "a refused transaction that also landed as a fold"
                (loadOne (legSet "duplicate" "txid" mintControlTx))
                "a refused transaction never lands; a landed txid identifies an acceptance, not a refusal"
            , rejects
                "a control that never landed a fold"
                ( loadOne
                    ( legSet
                        "duplicate"
                        "controlTxid"
                        (String "ff66666666666666666666666666666666666666666666666666666666666666")
                    )
                )
                "the control must be a landed accepting fold; a transaction the run never landed accepts nothing"
            ]
            []
            (compatRow "CG21")
        ]

-- | The batch-allocation obligation read through its keyed-mint witness.
keyedMintGroup :: TheoremGroup
keyedMintGroup =
    theorem
        keyedMintFold
        [ receiptClause
            ( mkClause
                "a two-key batch agreeing per kind but not per key is refused"
                [ "assetKindTotal (claimedMint [b₁, b₂]) k"
                , "assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false"
                , "foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""
                ]
            )
            [ rejects
                "a leg whose distinguisher is empty"
                (loadOne (legSet "keyedMint" "distinguisher" (String "")))
                "the pair's value is exactly one differing thing; an empty distinguisher states none"
            , rejects
                "a keyed-mint leg reusing the duplicate's transaction"
                (loadOne (legSet "keyedMint" "txid" dupTx))
                "each refusal names its own transaction; a shared txid merges two distinct facts"
            , rejects
                "two legs sharing one accepting control"
                (loadOne (legSet "keyedMint" "controlTxid" dupControlTx))
                "each refusal carries its own accepting control; one control for both proves neither pair"
            , rejects
                "a keyed-mint leg naming one key"
                (loadOne (legSet "keyedMint" "keys" (toJSON [keyAHex])))
                "the witness names two distinct keys; one key cannot disagree with itself"
            , rejects
                "a keyed-mint leg naming the same key twice"
                (loadOne (legSet "keyedMint" "keys" (toJSON [keyAHex, keyAHex])))
                "two entries for one key are one key; the batch must name two distinct ones"
            , rejects
                "a keyed-mint leg naming three keys"
                (loadOne (legSet "keyedMint" "keys" (toJSON [keyAHex, keyBHex, keyHex])))
                "the witness is a two-key batch; a third key is a different batch"
            , rejects
                "a keyed-mint leg naming an empty key"
                (loadOne (legSet "keyedMint" "keys" (toJSON [keyAHex, String ""])))
                "an empty key is not a key the batch consumed"
            , rejects
                "a keyed-mint leg reusing the fold's own key"
                (loadOne (legSet "keyedMint" "keys" (toJSON [keyHex, keyBHex])))
                "the witness is a batch of its own; the fold's key belongs to the other observation"
            , rejects
                "a keyed-mint leg whose claim also disagrees per kind"
                (loadOne (legSet "keyedMint" "claimedMint" (toJSON [mintOf keyAHex 3])))
                "a claim that also disagrees per kind is a net mismatch, not the keyed fault this witness exhibits"
            , rejects
                "a keyed-mint leg whose claim agrees per key as well"
                (loadOne (legSet "keyedMint" "claimedMint" entailedMint))
                "a claim matching the entailment per key agrees everywhere; nothing distinguishes it from its control"
            , rejects
                "a keyed-mint leg claiming a mint at neither named key"
                (loadOne (legSet "keyedMint" "claimedMint" (toJSON [mintOf keyHex 2])))
                "the claim must sit at a named key; a mint elsewhere is unobserved arithmetic"
            , rejects
                "a keyed-mint leg entailing a mint at neither named key"
                ( loadOne
                    ( legSet
                        "keyedMint"
                        "entailedMint"
                        (toJSON [mintOf keyHex 1, mintOf keyBHex 1])
                    )
                )
                "the entailment is read off the batch's own edges; an edge elsewhere entails nothing here"
            , rejects
                "a keyed-mint leg with no claimed mint at all"
                (loadOne (legSet "keyedMint" "claimedMint" (toJSON ([] :: [Value]))))
                "a claim with nothing to compare is not an observation; the pair comes whole or not at all"
            , rejects
                "a keyed-mint control that minted the refused claim"
                (loadOne (legSet "keyedMint" "controlMint" claimedMint))
                "the control is the same batch with the right distribution; minting the refused claim repeats the defect"
            , rejects
                "a keyed-mint control that minted at another key"
                ( loadOne
                    ( legSet
                        "keyedMint"
                        "controlMint"
                        (toJSON [mintOf keyAHex 1, mintOf keyHex 1])
                    )
                )
                "the control must mint exactly what the batch entails; another key is another distribution"
            , rejects
                "an absent keyed-mint leg is refused"
                (loadOne (edgeSet "keyedMint" Null))
                "an absent leg is an incomplete row, never an absent requirement"
            ]
            [ unexercised
                "the accepted-fold agreement conjunct"
                "agreement on an accepted fold as a standalone conclusion; the controls witness landings, not the asset-same equation"
            ]
            (compatRow "CG21")
        ]

spec :: Spec
spec = do
    runTheorem insertActiveGroup
    runTheorem keyedMintGroup
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

        it "names every clause and example without a row ID or ticket number" $
            [n | g <- [insertActiveGroup, keyedMintGroup], n <- groupNames g, nameViolation n]
                `shouldBe` []
