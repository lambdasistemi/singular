{- | Unit tests for the retirement-binding predicates (NOTE-024 item
3, NOTE-026).

Trust split, stated plainly: the NAME FORMULA is pinned by
@Naming.RegisterSpec@ (fixed vectors) and cross-checked on devnet
(ledger executes both on-chain copies against mirror-computed names);
what is pinned HERE is every predicate the independent reader
applies — key/control/log agreement, policy derivation, custody
triple binding (policy AND name AND quantity), creation-mint
binding, and route signers — using @representativeName@ the same way
production code does. A deviation in any single field must refuse,
and the wrong-policy\/same-name case must refuse (that is the
NOTE-026 defect class: a dropped policy).
-}
module Naming.RetireVerifySpec (spec) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Naming.Register (representativeName)
import Naming.Verify (
    RetireEvidence (..),
    positiveMintPolicy,
    verifyRetireEvidence,
 )

keyA, keyB, policyS, policyR, policyX, tokenT :: ByteString
keyA = BS.replicate 28 0xaa
keyB = BS.replicate 28 0xbb
policyS = BS.replicate 28 0x53
policyR = BS.replicate 28 0x52
policyX = BS.replicate 28 0x58
tokenT = "cage-token-name"

repA, repB :: ByteString
repA = representativeName keyA policyS tokenT 0
repB = representativeName keyB policyS tokenT 0

quorum12 :: [ByteString]
quorum12 = [BS.replicate 28 0x11, BS.replicate 28 0x12]

-- | A valid controller-route bundle over an unrotated record.
validLT :: RetireEvidence
validLT =
    RetireEvidence
        { reRecord = "TxA#1"
        , reRetireTx = "TxR"
        , reKeyHash = keyA
        , reCreationHash = keyA
        , reCreationHashLog = keyA
        , reCurrentControl = keyA
        , reQuorum = quorum12
        , rePolicy = policyS
        , reToken = tokenT
        , reIncarnation = 0
        , reCreationMint = [("app-policy", "approval", -1), (policyR, repA, 1)]
        , reCustodyPolicy = policyR
        , reCustodyName = repA
        , reCustodyQty = 1
        , reRepLog = repA
        , reSigners = [keyA]
        , reWitnesses = [keyA, "folder-funds-key"]
        }

-- | A valid quorum-route bundle over a ROTATED record (control is
-- keyB, creation hash stays keyA).
validRR :: RetireEvidence
validRR =
    validLT
        { reRecord = "TxRec#0"
        , reCurrentControl = keyB
        , reSigners = quorum12
        , reWitnesses = quorum12 <> ["folder-funds-key"]
        }

spec :: Spec
spec = describe "retirement binding predicates" $ do
    it "accepts a valid controller-route bundle" $
        verifyRetireEvidence validLT `shouldBe` Right ()
    it "accepts a valid rotated quorum-route bundle" $
        verifyRetireEvidence validRR `shouldBe` Right ()
    it "refuses a same-name token under the wrong policy (NOTE-026)" $
        verifyRetireEvidence validLT{reCustodyPolicy = policyX}
            `shouldSatisfy` isLeft
    it "refuses a wrong custody name" $
        verifyRetireEvidence validLT{reCustodyName = repB}
            `shouldSatisfy` isLeft
    it "refuses a wrong custody quantity" $
        verifyRetireEvidence validLT{reCustodyQty = 2}
            `shouldSatisfy` isLeft
    it "refuses a wrong retire key" $
        verifyRetireEvidence validLT{reKeyHash = keyB}
            `shouldSatisfy` isLeft
    it "refuses a log mismatch on creation hash" $
        verifyRetireEvidence validLT{reCreationHashLog = keyB}
            `shouldSatisfy` isLeft
    it "refuses a log mismatch on rep" $
        verifyRetireEvidence validLT{reRepLog = repB}
            `shouldSatisfy` isLeft
    it "refuses a controller route signed by another key" $
        verifyRetireEvidence validLT{reSigners = [keyB]}
            `shouldSatisfy` isLeft
    it "refuses a controller route whose signer never witnessed" $
        verifyRetireEvidence validLT{reWitnesses = ["folder-funds-key"]}
            `shouldSatisfy` isLeft
    it "refuses a quorum route signed by the controller" $
        verifyRetireEvidence validRR{reSigners = quorum12 <> [keyB]}
            `shouldSatisfy` isLeft
    it "refuses a quorum route with an outsider" $
        verifyRetireEvidence validRR{reSigners = [q1m, keyA]}
            `shouldSatisfy` isLeft
    it "refuses a creation mint missing the rep" $
        verifyRetireEvidence validLT{reCreationMint = [("app-policy", "approval", -1)]}
            `shouldSatisfy` isLeft
    it "derives the single positive mint policy" $
        positiveMintPolicy [("app", "a", -1), (policyR, repA, 1)]
            `shouldBe` Right policyR
    it "refuses several positive mint policies" $
        positiveMintPolicy [(policyR, repA, 1), (policyX, repA, 1)]
            `shouldSatisfy` isLeft
    it "refuses no positive mint policy" $
        positiveMintPolicy [("app", "a", -1)]
            `shouldSatisfy` isLeft
  where
    isLeft (Left _) = True
    isLeft _ = False
    q1m = BS.replicate 28 0x11
