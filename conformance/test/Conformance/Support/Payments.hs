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
    ExitFacts (..),
    FoldOutput (..),
    OwnerReading (..),
    Payee (..),
    Payment (..),
    OutputEdit (..),
    foldPayments,
    readBound,
    readOwner,
    tamperEdits,
 )
import Conformance.Story.Live (Edge (..), Exit (..), Tamper (..))
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Text (Text)
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
        , outputReference = Nothing
        }

-- | The registry's state continuation: a script output, paying nobody.
state :: FoldOutput
state = FoldOutput "cage" "" 1500000 False "inline" [] False Nothing

facts :: Edge -> ExitFacts
facts edge = ExitFacts Fold edge owner Nothing Nothing

-- | The facts of a reject or a retraction of an insertActive request sitting at
-- the output reference `booked`.
exitFacts :: Exit -> ExitFacts
exitFacts exit = ExitFacts exit InsertActive owner Nothing (Just booked)

-- | The output reference the request sat at, and another one.
booked, elsewhere :: Text
booked = "booked#0"
elsewhere = "other#1"

-- | An output at the owner's key bound, by its inline datum, to a reference.
boundTo :: Text -> Integer -> FoldOutput
boundTo reference lovelace = (at owner lovelace){outputDatum = "inline", outputReference = Just reference}

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

    it "credits a reject's owner every output at the owner's key, whatever edge it named" $ do
        -- A reject delivers no token: the refund returning the approval and
        -- the change both sit at the owner's key.
        let outputs =
                [ state
                , (at owner 2000000){outputApprovals = ["approval-a"]}
                , at owner 7000000
                , at holder 3000000
                ]
        foldPayments (exitFacts Reject) outputs
            `shouldBe` Right [Payment (Owner owner) 9000000]

    it "reads a retraction's return off the one output bound to the request it retracts" $ do
        -- The chain credits the one output at the owner's key whose inline
        -- datum is the retracted request's own reference; ada-only change at
        -- the owner's key returns nothing of it, nor do fragments summed.
        let returnOf = foldPayments (exitFacts Retract)
        returnOf [boundTo booked 62000000, at owner 5000000]
            `shouldBe` Right [Payment (Owner owner) 62000000]
        returnOf [boundTo booked 61999999, boundTo booked 1, at owner 5000000]
            `shouldBe` Right [Payment (Owner owner) 61999999]
        returnOf [boundTo elsewhere 62000000, at owner 5000000]
            `shouldBe` Right [Payment (Owner owner) 0]
        returnOf [(boundTo booked 62000000){outputKey = stranger}]
            `shouldBe` Right [Payment (Owner owner) 0]

    it "reads no return from an output presenting the reference other than as its inline datum" $ do
        let unbound = (boundTo booked 62000000){outputDatum = "none"}
        foldPayments (exitFacts Retract) [unbound, at owner 5000000]
            `shouldBe` Right [Payment (Owner owner) 0]
        readBound owner booked [unbound] `shouldBe` Right Nothing

    it "reads the retraction's return as the one output bound to the request presents it" $ do
        readBound owner booked [boundTo booked 62000000, at owner 5000000]
            `shouldBe` Right (Just (OwnerReading 62000000 "inline" []))
        readBound owner booked [boundTo elsewhere 62000000, at owner 5000000]
            `shouldBe` Right Nothing
        -- Several outputs bound to the request are read as the chain reads them,
        -- by the largest: beside a sufficient one an extra one changes nothing,
        -- and fragments short of the floor reach the judgement as its largest.
        readBound owner booked [boundTo booked 62000000, boundTo booked 1]
            `shouldBe` Right (Just (OwnerReading 62000000 "inline" []))
        readBound owner booked [boundTo booked 61999999, boundTo booked 1]
            `shouldBe` Right (Just (OwnerReading 61999999 "inline" []))

    it "tampers a reject's refund as it tampers a fold returning the deposit" $ do
        let returning = [state, (at owner 2000000){outputApprovals = ["approval-a"]}, at owner 7000000]
        exitPaymentsAfter ShortByOne (exitFacts Reject) returning
            `shouldBe` Right [Payment (Owner owner) 1999999]
        exitPaymentsAfter OtherAddress (exitFacts Reject) returning
            `shouldBe` Right [Payment (Owner owner) 0]

    it "tampers a retraction's bound return: short, elsewhere, rebound, or beside the state" $ do
        let returning = [boundTo booked 62000000, at owner 5000000]
            retracting = exitFacts Retract
        tamperEdits ShortByOne retracting returning
            `shouldBe` Right [Relovelace 0 61999999, Relovelace 1 5000001]
        tamperEdits OtherAddress retracting returning `shouldBe` Right [Readdress 0]
        tamperEdits OtherReference retracting returning `shouldBe` Right [Rebind 0]
        tamperEdits StateSpent retracting returning `shouldBe` Right [SpendState]
        exitPaymentsAfter ShortByOne retracting returning
            `shouldBe` Right [Payment (Owner owner) 61999999]
        exitPaymentsAfter OtherAddress retracting returning
            `shouldBe` Right [Payment (Owner owner) 0]
        exitPaymentsAfter OtherReference retracting returning
            `shouldBe` Right [Payment (Owner owner) 0]
        mapM_ (\alteration -> exitConserved alteration retracting returning)
            [ShortByOne, OtherAddress, OtherReference, StateSpent]

    it "binds and spends beside the state only for a retraction" $ do
        let returning = [state, (at owner 2000000){outputApprovals = ["approval-a"]}, at owner 7000000]
        mapM_
            ( \alteration -> do
                tamperEdits alteration (exitFacts Reject) returning `shouldSatisfy` isLeft
                tamperEdits alteration (facts DeleteActive) returning `shouldSatisfy` isLeft
            )
            [OtherReference, StateSpent]

-- | An absent custody output at the cage.
custody :: Integer -> FoldOutput
custody lovelace =
    (at "" lovelace){outputAddress = "cage", outputDatum = "inline", outputCustody = True}

stranger :: ByteString
stranger = "stranger-key"

{- | An exit's outputs after a tamper's edits: a redirected output lands at the
stranger's key, a rebound one presents the other reference, and a state spend
changes no output.
-}
exitTampered :: Tamper -> ExitFacts -> [FoldOutput] -> Either String [FoldOutput]
exitTampered alteration exitFacts' outputs =
    foldl apply outputs <$> tamperEdits alteration exitFacts' outputs
  where
    apply outs (Readdress i) =
        adjust i (\o -> o{outputAddress = "address-of-" <> stranger, outputKey = stranger, outputCustody = False}) outs
    apply outs (Relovelace i lovelace) = adjust i (\o -> o{outputLovelace = lovelace}) outs
    apply outs (Rebind i) = adjust i (\o -> o{outputReference = Just elsewhere}) outs
    apply outs SpendState = outs
    adjust i f outs = [if j == i then f o else o | (j, o) <- zip [0 :: Int ..] outs]

-- | What the fold pays once tampered, as the chain reads it.
paymentsAfter :: Tamper -> Edge -> [FoldOutput] -> Either String [Payment]
paymentsAfter alteration edge = exitPaymentsAfter alteration (facts edge)

-- | What an exit pays once tampered, as the chain reads it.
exitPaymentsAfter :: Tamper -> ExitFacts -> [FoldOutput] -> Either String [Payment]
exitPaymentsAfter alteration exitFacts' outputs =
    exitTampered alteration exitFacts' outputs >>= foldPayments exitFacts'

-- | A tamper moves value between outputs and never creates or destroys it.
conserved :: Tamper -> Edge -> [FoldOutput] -> IO ()
conserved alteration edge = exitConserved alteration (facts edge)

exitConserved :: Tamper -> ExitFacts -> [FoldOutput] -> IO ()
exitConserved alteration exitFacts' outputs =
    fmap (sum . map outputLovelace) (exitTampered alteration exitFacts' outputs)
        `shouldBe` Right (sum (map outputLovelace outputs))
