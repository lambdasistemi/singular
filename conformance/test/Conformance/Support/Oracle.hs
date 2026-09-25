{- | How the model's verdict on a submitted transaction is read off the driver.

Appendix material: the law's outcome comes from the driver's row, and when the
law accepts, the driver's judgement of the transaction's outputs decides
whether the model still accepts. The judgement's reason is the model's, never
the runner's.
-}
module Conformance.Support.Oracle (spec) where

import Conformance.Lean.Oracle (modelVerdict)
import Data.Aeson (Value (..), object, (.=))
import Data.Either (isLeft)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

-- | A driver row with this outcome and reason.
row :: String -> Maybe String -> Value
row outcome reason = object ["outcome" .= outcome, "reason" .= reason]

-- | A driver row judging outputs: the law accepted, and `settle` answered.
judged :: Maybe String -> Value
judged verdict = object ["outcome" .= ("accepted" :: String), "reason" .= Null, "settle" .= verdict]

spec :: Spec
spec = describe "Reading the model's verdict on a submitted transaction" $ do
    it "refuses, for the judgement's reason, outputs that do not pay what the exit owes" $
        modelVerdict (row "accepted" Nothing) (Just (judged (Just "destination")))
            `shouldBe` Right (String "refused", String "destination")

    it "accepts outputs the judgement settles" $
        modelVerdict (row "accepted" Nothing) (Just (judged Nothing))
            `shouldBe` Right (String "accepted", Null)

    it "keeps the law's refusal whatever the outputs" $
        modelVerdict (row "refused" (Just "key-exists")) (Just (judged (Just "destination")))
            `shouldBe` Right (String "refused", String "key-exists")

    it "keeps the law's acceptance when no transaction was judged" $
        modelVerdict (row "accepted" Nothing) Nothing
            `shouldBe` Right (String "accepted", Null)

    it "refuses to read a judgement that omits its verdict" $
        modelVerdict (row "accepted" Nothing) (Just (row "accepted" Nothing))
            `shouldSatisfy` isLeft
