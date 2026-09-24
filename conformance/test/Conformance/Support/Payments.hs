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
    OutputEdit (..),
    foldPayments,
    readOwner,
    tamperEdits,
 )
import Conformance.Story.Live (Edge (..), Tamper (..))
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
        , outputCustody = False
        }

-- | The registry's state continuation: a script output, paying nobody.
state :: FoldOutput
state = FoldOutput "cage" "" 1500000 False "inline" [] False

facts :: Edge -> FoldFacts
facts edge = FoldFacts edge owner Nothing

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

    it "locks an absent insertion's deposit in custody" $ do
        foldPayments (facts InsertAbsent) [state, custody 2100000, at owner 9000000]
            `shouldBe` Right [Payment Custody 2100000]
        foldPayments (facts InsertAbsent) [state, at owner 9000000] `shouldSatisfy` isLeft

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

    it "sends every output paying what a fold owes to another address" $ do
        let carrier = (at holder 2000000){outputCarrier = True}
            delivering = [state, carrier, at owner 9000000]
            returning = [state, (at owner 2000000){outputApprovals = ["approval-a"]}, at owner 7000000]
        paymentsAfter OtherAddress InsertActive delivering
            `shouldBe` Right [Payment (Destination ("address-of-" <> stranger)) 2000000]
        paymentsAfter OtherAddress DeleteActive returning
            `shouldBe` Right [Payment (Owner owner) 0]
        conserved OtherAddress InsertActive delivering
        conserved OtherAddress DeleteActive returning

    it "pays what a fold owes one lovelace short, the lovelace going to its change" $ do
        let carrier = (at holder 2000000){outputCarrier = True}
            delivering = [state, carrier, at owner 9000000]
            returning = [state, (at owner 2000000){outputApprovals = ["approval-a"]}, at owner 7000000]
            locking = [state, custody 2000000, at owner 9000000]
        paymentsAfter ShortByOne InsertActive delivering
            `shouldBe` Right [Payment (Destination (outputAddress carrier)) 1999999]
        -- The change credits the owner too, so it leaves the owner's key.
        paymentsAfter ShortByOne DeleteActive returning
            `shouldBe` Right [Payment (Owner owner) 1999999]
        paymentsAfter ShortByOne InsertAbsent locking
            `shouldBe` Right [Payment Custody 1999999]
        mapM_ (\(edge, outputs) -> conserved ShortByOne edge outputs)
            [(InsertActive, delivering), (DeleteActive, returning), (InsertAbsent, locking)]

    it "moves an absent insertion's custody away from the cage" $
        paymentsAfter OtherAddress InsertAbsent [state, custody 2000000, at owner 9000000]
            `shouldSatisfy` isLeft

    it "changes no output for an extra signer" $
        tamperEdits ExtraSigner (facts InsertActive)
            [state, (at holder 2000000){outputCarrier = True}, at owner 9000000]
            `shouldBe` Right []

    it "refuses to tamper a payment the transaction does not make" $ do
        tamperEdits OtherAddress (facts InsertActive) [state, at owner 9000000]
            `shouldSatisfy` isLeft
        tamperEdits ShortByOne (facts InsertActive) [state, at owner 9000000]
            `shouldSatisfy` isLeft
        -- With no change beside it, the lovelace taken has nowhere to go.
        tamperEdits ShortByOne (facts InsertActive) [state, (at holder 2000000){outputCarrier = True}]
            `shouldSatisfy` isLeft

-- | An absent custody output at the cage.
custody :: Integer -> FoldOutput
custody lovelace =
    (at "" lovelace){outputAddress = "cage", outputDatum = "inline", outputCustody = True}

stranger :: ByteString
stranger = "stranger-key"

{- | The fold's outputs after a tamper's edits, a redirected output landing at
the stranger's key, which is no cage.
-}
tampered :: Tamper -> Edge -> [FoldOutput] -> Either String [FoldOutput]
tampered alteration edge outputs =
    foldl apply outputs <$> tamperEdits alteration (facts edge) outputs
  where
    apply outs (Readdress i) =
        adjust i (\o -> o{outputAddress = "address-of-" <> stranger, outputKey = stranger, outputCustody = False}) outs
    apply outs (Relovelace i lovelace) = adjust i (\o -> o{outputLovelace = lovelace}) outs
    adjust i f outs = [if j == i then f o else o | (j, o) <- zip [0 :: Int ..] outs]

-- | What the fold pays once tampered, as the chain reads it.
paymentsAfter :: Tamper -> Edge -> [FoldOutput] -> Either String [Payment]
paymentsAfter alteration edge outputs =
    tampered alteration edge outputs >>= foldPayments (facts edge)

-- | A tamper moves value between outputs and never creates or destroys it.
conserved :: Tamper -> Edge -> [FoldOutput] -> IO ()
conserved alteration edge outputs =
    fmap (sum . map outputLovelace) (tampered alteration edge outputs)
        `shouldBe` Right (sum (map outputLovelace outputs))
