{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Register an active key: request, apply, and observe its active witness.
-- Journey: offchain/journey/register; this subject uses the open registry,
-- while that journey also exercises the naming application's approval.
-- Given one registered key, its requested address, and a landed fold, these
-- cases validate the receipt evidence. They do not rerun the journey.
-- The duplicate is a second insert at that same occupied key; its control is
-- a separate accepted transaction. Every refusal states the altered fact.
module Conformance.Support.RegistrationReport (spec, story, insertActiveRow, conjuncts) where

import Control.Monad.Operational (Program)
import Test.Hspec (Spec)
import Conformance.Story
import Conformance.Edge.Register (conjuncts)
import Conformance.Lean.Registration qualified as Lean
import Conformance.Story.Specification (theoremBinding)
import Conformance.Fixture.ActiveRegistration (activeHex, openHex, keyHex, keyAHex, keyBHex, walletAddr, dupTx, mintControlTx, otherName, otherAddress, otherApproval, emptyValue, unlandedTx)

spec :: Spec
spec = runStory story

insertActiveRow :: Binding
insertActiveRow = theoremBinding Lean.insertActiveRow

story :: Program StoryI ()
story = theorem insertActiveRow $ do
    clause
        "The requested address must receive exactly one active token for the registered key"
        do
            conjunct "address := some r.output"
            conjunct "assets := [((.active, r.key), 1)]"
            conjunct "kindCount t.state .active r.key = 1"
        do
            accepts "A registration report is accepted when the requested address receives one active token for the key" unchanged

            rejects
                "A registration report is rejected if no active token is delivered"
                "The recipient must receive one active token; receiving none does not establish registration." $
                    deliver nothing

            rejects
                "A registration report is rejected if two active tokens are delivered for the same key"
                "The recipient must receive exactly one active token for this key, not two." $
                    deliver $ activeToken keyHex 2

            rejects
                "A registration report is rejected if the delivered token comes from the wrong minting policy"
                "The open-policy token cannot stand in for the active token required by this registration." $
                    deliver $ token openHex keyHex 1

            rejects
                "A registration report is rejected if the token names a different key"
                "The token name must identify the registered key. A token naming another key does not meet the requirement." $
                    deliver $ token activeHex otherName 1

            rejects
                "A registration report is rejected if the token goes to the wrong address"
                "The request specifies who receives the token. Delivery to another address does not satisfy it." $
                    observedAddress otherAddress

    unexercised
        "Registration preserves the signatures supplied with the approval"
        "Not demonstrated: the report does not record which signatures the approval carried"

    clause
        "Applying the registration request must create one active token for its key"
        do
            conjunct "mint := [((.active, r.key), 1)]"
        do
            rejects
                "A registration report is rejected if no active token was created for the key"
                "Applying the request must create the active token that the recipient receives." $
                    minted nothing

    clause
        "The open registry application takes no parameters"
        do
            conjunct "openPolicyParameters = []"
        do
            rejects
                "A registration report is rejected if the open application declares a parameter"
                "The open application takes no parameters. A report describing an application with a parameter does not describe it." $
                    openParameters 1

    clause
        "Applying this registration request pays no refund"
        do
            conjunct "refunds := []"
        do
            rejects
                "A registration report is rejected if applying the request also pays a refund"
                "This registration is specified to pay no refund. A reported refund contradicts that result." $
                    refunds $ lovelace 1_000_000

    clause
        "Applying this registration request requires no additional signer"
        do
            conjunct "signers := []"
        do
            rejects
                "A registration report is rejected if applying the request requires a signer"
                "This request-processing transaction requires no signer. The report must not add that requirement." $
                    signers $ signer walletAddr

    clause
        "The request must supply enough ada to pay the processing tip"
        do
            conjunct "lovelaceCoversTip s.config lovelace = true"
        do
            rejects
                "A registration report is rejected if the request cannot pay the processing tip"
                "The request supplies 999,999 lovelace, which is below the 1,000,000-lovelace processing tip in this example." $
                    requestLovelace 999_999

    clause
        "The delivery address must match the approval"
        do
            conjunct "destinationDatumBinds r = true"
        do
            rejects
                "A registration report is rejected if the approval does not match the delivery address"
                "The recorded approval must match the approval calculated for the requested destination." $
                    approvalRecomputed otherApproval

    clause
        "Applying a request may update the registry contents but must preserve its other settings"
        do
            conjunct "onlyRootChanged s.config t.state.config = true"
        do
            rejects
                "A registration report is rejected if applying the request changes the maximum fee"
                "Processing a registration updates the registry contents, not the maximum fee or other settings." $
                    configAfter $ do
                        maxFee 2_000_000
                        restUnchanged

            rejects
                "A registration report is rejected if the original settings are missing"
                "The report needs the settings from before and after processing so they can be compared." $
                    configBefore noPins

    clause
        "Registering an already registered key must fail"
        do
            conjunct "txOf t.state r₂ lovelace = .error \"key-exists\""
        do
            acceptsBecause
                "Evidence of a rejected duplicate registration is accepted without a script log"
                "A script can fail without emitting a log. The report still identifies the rejected transaction and failing script." $
                    onLeg duplicate omitTrace

            rejects
                "Rejects duplicate-registration evidence that calls the same transaction both rejected and successful"
                "The example needs a separate successful transaction to show that the duplicate key caused the rejection." $
                    onLeg duplicate $ controlTxid dupTx

            rejects
                "Rejects duplicate-registration evidence that does not identify the script that failed"
                "A failed transaction alone does not show that the intended script rejected the duplicate key." $
                    onLeg duplicate $ hashes noHashes

            rejects
                "Rejects duplicate-registration evidence with a blank identifier for the failing script"
                "A blank script identifier cannot establish which script rejected the transaction." $
                    onLeg duplicate $ hashes $ hash emptyValue

            rejects
                "Rejects duplicate-registration evidence naming two keys instead of the one already registered"
                "This example attempts to register the one key already registered earlier in the run." $
                    onLeg duplicate $ keys $ do
                        key keyHex
                        key keyBHex

            rejects
                "Rejects duplicate-registration evidence naming a key this run never registered"
                "To demonstrate a duplicate, this run must first register the same key." $
                    onLeg duplicate $ keys $ key keyAHex

            rejects
                "Rejects duplicate-registration evidence mixed with token allocation data from the separate batch example"
                "The duplicate-registration example and the token-allocation example must remain separate reports." $
                    onLeg duplicate $ claimedMint $ mint activeHex keyAHex 2

            rejects
                "Rejects duplicate-registration evidence if the rejected transaction also appears among successful transactions"
                "The same transaction cannot be reported as both rejected and successfully applied." $
                    onLeg duplicate $ txid mintControlTx

            rejects
                "Rejects duplicate-registration evidence if the successful comparison transaction is absent from the run"
                "The report must show that the successful comparison transaction was actually applied during this run." $
                    onLeg duplicate $ controlTxid unlandedTx
