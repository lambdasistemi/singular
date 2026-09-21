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
        "A batch must create the right number of tokens for each key, even when the total is correct"
        do
            conjunct "assetKindTotal (claimedMint [b₁, b₂]) k"
            conjunct "assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false"
            conjunct "foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""
        do
            rejects
                "A batch rejection report must explain what differs from the successful comparison"
                "The report must explain why the rejected transaction differs from its successful comparison." $
                    onLeg keyedMint $ distinguisher ""

            rejects
                "A batch rejection report cannot reuse the transaction from the duplicate-registration example"
                "The wrong-allocation example and the duplicate-registration example are different transactions." $
                    onLeg keyedMint $ txid dupTx

            rejects
                "The batch and duplicate-registration examples must each identify their own successful comparison transaction"
                "Each rejection example needs its own successful comparison so the cause of failure can be checked." $
                    onLeg keyedMint $ controlTxid dupControlTx

            rejects
                "A report about a two-key batch is rejected if it lists only one key"
                "This example compares token allocation across two different keys, so both must be identified." $
                    onLeg keyedMint $ keys $ key keyAHex

            rejects
                "A report about a two-key batch is rejected if it lists the same key twice"
                "Listing one key twice does not describe two separate registration requests." $
                    onLeg keyedMint $ keys $ do
                        key keyAHex
                        key keyAHex

            rejects
                "A report about a two-key batch is rejected if it lists three keys"
                "This example processes two keys. A report about three keys does not describe the same batch." $
                    onLeg keyedMint $ keys $ do
                        key keyAHex
                        key keyBHex
                        key keyHex

            rejects
                "A report about a two-key batch is rejected if either key is blank"
                "Both registration keys must be identified; a blank entry does not identify a key." $
                    onLeg keyedMint $ keys $ do
                        key keyAHex
                        key emptyValue

            rejects
                "A batch rejection report cannot borrow a key from the separate single-registration example"
                "The two-key batch is separate from the earlier single registration. Its report must name its own keys." $
                    onLeg keyedMint $ keys $ do
                        key keyHex
                        key keyBHex

            rejects
                "A report claiming the total is correct is rejected if it creates three tokens where two are required"
                "This example is meant to expose a wrong allocation despite a correct total of two tokens. A total of three tests a different mistake." $
                    onLeg keyedMint $ claimedMint $ mint activeHex keyAHex 3

            rejects
                "A report claiming a wrong allocation is rejected if each key actually receives its required token"
                "One token for each key is the correct allocation. It cannot demonstrate rejection for an incorrect allocation." $
                    onLeg keyedMint $ claimedMint $ do
                        mint activeHex keyAHex 1
                        mint activeHex keyBHex 1

            rejects
                "A batch rejection report is rejected if the claimed tokens name a key outside the batch"
                "The claimed tokens must refer to the two registration keys named in this batch." $
                    onLeg keyedMint $ claimedMint $ mint activeHex keyHex 2

            rejects
                "A batch rejection report is rejected if the required tokens name a key outside the batch"
                "The required tokens come from the requests in this batch, not from a registration elsewhere." $
                    onLeg keyedMint $ entailedMint $ do
                        mint activeHex keyHex 1
                        mint activeHex keyBHex 1

            rejects
                "A batch rejection report must say which tokens the rejected transaction tried to create"
                "Without the proposed token allocation, the report cannot show how it differs from the required allocation." $
                    onLeg keyedMint $ claimedMint noMints

            rejects
                "A successful comparison must correct the allocation, not put both tokens at the first key again"
                "The successful comparison must create one token per key. Putting both tokens at the first key repeats the rejected mistake." $
                    onLeg keyedMint $ controlMint $ mint activeHex keyAHex 2

            rejects
                "A successful comparison must allocate its tokens to the two keys in the batch"
                "The successful comparison must create one token for each of the two requested keys." $
                    onLeg keyedMint $ controlMint $ do
                        mint activeHex keyAHex 1
                        mint activeHex keyHex 1

            rejects
                "A registration run report is rejected if the required batch-rejection example is missing"
                "This run report is required to include the batch-rejection example. Leaving it out does not remove the requirement." $
                    dropLeg keyedMint

    unexercised
        "Every successful batch creates exactly the tokens its requests require"
        "Not demonstrated as a separate claim: the reports record successful comparison transactions but do not establish this general rule"


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
