{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Apply two requests at distinct keys: each entails one active token.
-- The refused claim allocates both tokens to the first key; its total is
-- right, its distribution is wrong. The accepting control allocates one to
-- each key. The single registered key belongs to a different observation.
-- This checks receipt evidence. No dedicated keyed-mint journey step exists;
-- the real producer is conformance/app/Conformance/Run.hs.
module Conformance.Fold.KeyedMint (spec, story, keyedMintFold, conjuncts) where

import Control.Monad.Operational (Program)
import Test.Hspec (Spec)
import Conformance.Story
import Conformance.Fixture.ActiveRegistration (activeHex, keyHex, keyAHex, keyBHex, dupTx, dupControlTx, emptyValue)

spec :: Spec
spec = runStory story

story :: Program StoryI ()
story = theorem keyedMintFold $ do
    clause
        "a two-key batch agreeing per kind but not per key is refused"
        do
            conjunct "assetKindTotal (claimedMint [b₁, b₂]) k"
            conjunct "assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false"
            conjunct "foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""
        do
            rejects
                "a leg whose distinguisher is empty"
                "the pair's value is exactly one differing thing; an empty distinguisher states none" $
                    onLeg keyedMint $ distinguisher ""

            rejects
                "a keyed-mint leg reusing the duplicate's transaction"
                "each refusal names its own transaction; a shared txid merges two distinct facts" $
                    onLeg keyedMint $ txid dupTx

            rejects
                "two legs sharing one accepting control"
                "each refusal carries its own accepting control; one control for both proves neither pair" $
                    onLeg keyedMint $ controlTxid dupControlTx

            rejects
                "a keyed-mint leg naming one key"
                "the witness names two distinct keys; one key cannot disagree with itself" $
                    onLeg keyedMint $ keys $ key keyAHex

            rejects
                "a keyed-mint leg naming the same key twice"
                "two entries for one key are one key; the batch must name two distinct ones" $
                    onLeg keyedMint $ keys $ do
                        key keyAHex
                        key keyAHex

            rejects
                "a keyed-mint leg naming three keys"
                "the witness is a two-key batch; a third key is a different batch" $
                    onLeg keyedMint $ keys $ do
                        key keyAHex
                        key keyBHex
                        key keyHex

            rejects
                "a keyed-mint leg naming an empty key"
                "an empty key is not a key the batch consumed" $
                    onLeg keyedMint $ keys $ do
                        key keyAHex
                        key emptyValue

            rejects
                "a keyed-mint leg reusing the fold's own key"
                "the witness is a batch of its own; the fold's key belongs to the other observation" $
                    onLeg keyedMint $ keys $ do
                        key keyHex
                        key keyBHex

            rejects
                "a keyed-mint leg whose claim also disagrees per kind"
                "a claim that also disagrees per kind is a net mismatch, not the keyed fault this witness exhibits" $
                    onLeg keyedMint $ claimedMint $ mint activeHex keyAHex 3

            rejects
                "a keyed-mint leg whose claim agrees per key as well"
                "a claim matching the entailment per key agrees everywhere; nothing distinguishes it from its control" $
                    onLeg keyedMint $ claimedMint $ do
                        mint activeHex keyAHex 1
                        mint activeHex keyBHex 1

            rejects
                "a keyed-mint leg claiming a mint at neither named key"
                "the claim must sit at a named key; a mint elsewhere is unobserved arithmetic" $
                    onLeg keyedMint $ claimedMint $ mint activeHex keyHex 2

            rejects
                "a keyed-mint leg entailing a mint at neither named key"
                "the entailment is read off the batch's own edges; an edge elsewhere entails nothing here" $
                    onLeg keyedMint $ entailedMint $ do
                        mint activeHex keyHex 1
                        mint activeHex keyBHex 1

            rejects
                "a keyed-mint leg with no claimed mint at all"
                "a claim with nothing to compare is not an observation; the pair comes whole or not at all" $
                    onLeg keyedMint $ claimedMint noMints

            rejects
                "a keyed-mint control that minted the refused claim"
                "the control is the same batch with the right distribution; minting the refused claim repeats the defect" $
                    onLeg keyedMint $ controlMint $ mint activeHex keyAHex 2

            rejects
                "a keyed-mint control that minted at another key"
                "the control must mint exactly what the batch entails; another key is another distribution" $
                    onLeg keyedMint $ controlMint $ do
                        mint activeHex keyAHex 1
                        mint activeHex keyHex 1

            rejects
                "an absent keyed-mint leg is refused"
                "an absent leg is an incomplete row, never an absent requirement" $
                    dropLeg keyedMint

    unexercised
        "the accepted-fold agreement conjunct"
        "agreement on an accepted fold as a standalone conclusion; the controls witness landings, not the asset-same equation"


-- | The batch-allocation obligation.
keyedMintFold :: Binding
keyedMintFold =
    mkBoundObligation
        "Singular.Statements.fold_batch_claimed_mint_by_kind_key"
        "9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988"
        "265c595"

-- | Verbatim Lean anchors used by this subject.
conjuncts :: [String]
conjuncts = [ "assetKindTotal (claimedMint [b₁, b₂]) k"
          , "assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false"
          , "foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""
    ]
