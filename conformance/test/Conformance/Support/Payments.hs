{- | What reading a fold's payments off its transaction must establish.

Appendix material: evidence about how the live runner reads the chain, not
about the registry. Each case is one fold's outputs as the chain would carry
them, and the payments the chain's settlement credits: a delivering fold pays
the deposit with the token, a fold delivering nothing pays the owner's key the
summed lovelace of every output at that key that carries no delivered token, an
absent insertion locks it in custody, and a spent custody is refunded in full.
-}
module Conformance.Support.Payments (spec) where

import Conformance.Observe.Payments (
    FoldFacts (..),
    FoldOutput (..),
    OwnerReading (..),
    Payee (..),
    Payment (..),
    foldPayments,
    readOwner,
 )
import Conformance.Story.Live (Edge (..))
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

owner, holder, refunded :: ByteString
owner = "owner-key"
holder = "holder-key"
refunded = "refund-key"

-- | An output at a key-hash address named after its key.
at :: ByteString -> Integer -> FoldOutput
at key lovelace =
    FoldOutput
        { outputAddress = "address-of-" <> key
        , outputKey = key
        , outputLovelace = lovelace
        , outputCarrier = False
        , outputDatum = "none"
        , outputApprovals = []
        }

-- | The registry's state continuation: a script output, paying nobody.
state :: FoldOutput
state = FoldOutput "cage" "" 1500000 False "inline" []

facts :: Edge -> FoldFacts
facts edge = FoldFacts edge owner Nothing Nothing

spec :: Spec
spec = describe "Reading a fold's payments off its transaction" $ do
    it "credits the owner every output at the owner's key for a fold delivering nothing" $ do
        -- The deposit's own output carries the returned approval; the change
        -- is ada-only. The chain counts both toward the owner's key.
        let outputs =
                [ state
                , (at owner 2000000){outputApprovals = ["approval-a"]}
                , at owner 7000000
                , at holder 3000000
                ]
        mapM_
            ( \edge ->
                foldPayments (facts edge) outputs
                    `shouldBe` Right [Payment (Owner owner) 9000000]
            )
            [UpdateTerminal, DeleteActive]

    it "reports a fold delivering nothing that pays the owner nothing as a zero payment" $
        foldPayments (facts DeleteActive) [state, at holder 3000000]
            `shouldBe` Right [Payment (Owner owner) 0]

    it "does not credit the owner an output carrying a delivered token" $
        foldPayments
            (facts UpdateTerminal)
            [state, (at owner 5000000){outputCarrier = True}, at owner 2000000]
            `shouldBe` Right [Payment (Owner owner) 2000000]

    it "pays a delivering fold's deposit with the token, at the carrier's address" $ do
        let carrier = (at holder 2500000){outputCarrier = True}
        mapM_
            ( \edge ->
                foldPayments (facts edge) [state, carrier, at owner 9000000]
                    `shouldBe` Right [Payment (Destination (outputAddress carrier)) 2500000]
            )
            [InsertActive, WitnessTerminal]

    it "refuses a delivering fold whose token is carried by no single output" $ do
        let carrier = (at holder 2500000){outputCarrier = True}
        foldPayments (facts InsertActive) [state, at owner 9000000]
            `shouldSatisfy` isLeft
        foldPayments (facts InsertActive) [state, carrier, carrier]
            `shouldSatisfy` isLeft

    it "locks an absent insertion's deposit in custody" $
        foldPayments ((facts InsertAbsent){factsCustody = Just 2100000}) [state, at owner 9000000]
            `shouldBe` Right [Payment Custody 2100000]

    it "states what the fold owes first, then the custody refund it pays" $ do
        let refund = at refunded 4000000
            carrier = (at holder 2500000){outputCarrier = True}
            spent = Just (outputAddress refund)
        foldPayments ((facts UpdateActive){factsRefund = spent}) [state, carrier, refund]
            `shouldBe` Right
                [ Payment (Destination (outputAddress carrier)) 2500000
                , Payment (Refund (outputAddress refund)) 4000000
                ]
        foldPayments
            ((facts DeleteAbsent){factsRefund = spent})
            [state, refund, at owner 2000000, at owner 6000000]
            `shouldBe` Right
                [ Payment (Owner owner) 8000000
                , Payment (Refund (outputAddress refund)) 4000000
                ]

    it "reads a custody refund as paid, above or short, off the outputs at its refund address" $ do
        -- The chain credits a refund address the summed lovelace of the
        -- outputs at it that carry no delivered token; the custody's value is
        -- the model's floor, never a selector.
        let spent = Just ("address-of-" <> refunded)
            refundOf outputs = foldPayments ((facts DeleteAbsent){factsRefund = spent}) (state : outputs)
            refund amount = Payment (Refund ("address-of-" <> refunded)) amount
            owed = Payment (Owner owner) 0
        refundOf [at refunded 4000001] `shouldBe` Right [owed, refund 4000001]
        refundOf [at refunded 3999999] `shouldBe` Right [owed, refund 3999999]
        refundOf [(at refunded 1000000){outputApprovals = ["approval-a"]}, at refunded 3000000]
            `shouldBe` Right [owed, refund 4000000]
        refundOf [] `shouldBe` Right [owed, refund 0]
        refundOf [(at refunded 4000000){outputCarrier = True}] `shouldBe` Right [owed, refund 0]

    it "refuses a spent custody with no observed source" $
        foldPayments ((facts DeleteAbsent){factsRefund = Nothing}) [state]
            `shouldSatisfy` isLeft

    it "reads the owner output off the outputs crediting the owner's key" $ do
        let deposit = (at owner 2000000){outputApprovals = ["approval-a"]}
            change = at owner 7000000
        readOwner owner [state, deposit, change, at holder 3000000]
            `shouldBe` Right (Just (OwnerReading 9000000 "none" ["approval-a"]))
        readOwner owner [state, at holder 3000000] `shouldBe` Right Nothing
        readOwner owner [deposit, change{outputDatum = "inline"}] `shouldSatisfy` isLeft
