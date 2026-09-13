{- | Unit tests for the completion-binding predicates (NOTE-028/029).

Same trust split as `RetireVerifySpec`: what is pinned here is every
predicate the independent reader applies to a completion — co-created
pair, exact burn, singleton-`Modify`, genuine root change, and
permissionless authorization (empty required signers, fee-owner-only
witness outside every route). Resolution (finding the custody, the
request, the state transition in retained CBOR) lives in the reader
executable and is proved by the VERIFIED-COMPLETE run, not here.
-}
module Naming.CompleteVerifySpec (spec) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Naming.Register (overMarkerFor)
import Naming.Verify (
    CompleteEvidence (..),
    verifyCompletion,
 )

policyR, repA, rootOld, rootNew, ctrlA, q1m, q2m, feeK, otherK :: ByteString
policyR = BS.replicate 28 0x52
repA = BS.replicate 32 0x41
rootOld = BS.replicate 32 0x0a
rootNew = BS.replicate 32 0x0b
ctrlA = BS.replicate 28 0xaa
q1m = BS.replicate 28 0x11
q2m = BS.replicate 28 0x12
feeK = BS.replicate 28 0xf0
otherK = BS.replicate 28 0xe0

-- | A valid permissionless completion bundle.
validComplete :: CompleteEvidence
validComplete =
    CompleteEvidence
        { ceRetireTx = "TxR"
        , ceCompleteTx = "TxC"
        , ceCustodyTxid = "TxR"
        , ceRequestTxid = "TxR"
        , ceReqOld = repA
        , ceReqNew = overMarkerFor repA
        , ceRepPolicy = policyR
        , ceRepName = repA
        , ceCustodyPolicy = policyR
        , ceCustodyName = repA
        , ceCustodyQty = 1
        , ceMint = [(policyR, repA, -1)]
        , ceBurnRedeemerOk = True
        , ceIsModify = True
        , ceActionCount = 1
        , ceRootBefore = rootOld
        , ceRootAfter = rootNew
        , ceReqSigners = []
        , ceWitnesses = [feeK]
        , ceFeeOwner = feeK
        , ceRouteKeys = [ctrlA, q1m, q2m]
        }

spec :: Spec
spec = describe "Completion evidence" $ do
    it "accepts a valid permissionless completion" $
        verifyCompletion validComplete `shouldBe` Right ()
    it "refuses a request from another creator (wrong pairing)" $
        verifyCompletion validComplete{ceRequestTxid = "TxX"}
            `shouldSatisfy` isLeft
    it "refuses a missing request (empty creator)" $
        verifyCompletion validComplete{ceRequestTxid = ""}
            `shouldSatisfy` isLeft
    it "refuses a folded request from the wrong old value" $
        verifyCompletion validComplete{ceReqOld = BS.replicate 32 0x42}
            `shouldSatisfy` isLeft
    it "refuses a folded request not writing the marker" $
        verifyCompletion validComplete{ceReqNew = BS.replicate 36 0x43}
            `shouldSatisfy` isLeft
    it "refuses a wrong custody policy" $
        verifyCompletion validComplete{ceCustodyPolicy = BS.replicate 28 0x58}
            `shouldSatisfy` isLeft
    it "refuses a wrong custody name" $
        verifyCompletion validComplete{ceCustodyName = BS.replicate 32 0x42}
            `shouldSatisfy` isLeft
    it "refuses a wrong custody quantity" $
        verifyCompletion validComplete{ceCustodyQty = 2}
            `shouldSatisfy` isLeft
    it "refuses a mint that is not exactly the burn" $
        verifyCompletion validComplete{ceMint = [(policyR, repA, -1), (policyR, repA, -1)]}
            `shouldSatisfy` isLeft
    it "refuses a missing burn" $
        verifyCompletion validComplete{ceMint = []}
            `shouldSatisfy` isLeft
    it "refuses a wrong burn redeemer" $
        verifyCompletion validComplete{ceBurnRedeemerOk = False}
            `shouldSatisfy` isLeft
    it "refuses a non-Modify state spend" $
        verifyCompletion validComplete{ceIsModify = False}
            `shouldSatisfy` isLeft
    it "refuses a multi-action Modify" $
        verifyCompletion validComplete{ceActionCount = 2}
            `shouldSatisfy` isLeft
    it "refuses a preserved root (Rejected shape)" $
        verifyCompletion validComplete{ceRootAfter = rootOld}
            `shouldSatisfy` isLeft
    it "refuses nonempty required signers (not permissionless)" $
        verifyCompletion validComplete{ceReqSigners = [ctrlA]}
            `shouldSatisfy` isLeft
    it "refuses an extra witness beyond the fee owner" $
        verifyCompletion validComplete{ceWitnesses = [feeK, otherK]}
            `shouldSatisfy` isLeft
    it "refuses a route key witnessing" $
        verifyCompletion validComplete{ceWitnesses = [ctrlA], ceFeeOwner = ctrlA}
            `shouldSatisfy` isLeft
  where
    isLeft (Left _) = True
    isLeft _ = False
