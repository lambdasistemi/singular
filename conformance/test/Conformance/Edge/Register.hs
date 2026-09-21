{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Register an active key: request, apply, and observe its active witness.
-- Journey: offchain/journey/register; this subject uses the open registry,
-- while that journey also exercises the naming application's approval.
-- Given one registered key, its requested address, and a landed fold, these
-- cases validate the receipt evidence. They do not rerun the journey.
-- The duplicate is a second insert at that same occupied key; its control is
-- a separate accepted transaction. Every refusal states the altered fact.
module Conformance.Edge.Register (spec, story, insertActiveRow, conjuncts) where

import Control.Monad.Operational (Program)
import Test.Hspec (Spec)
import Conformance.Story
import Conformance.Fixture.ActiveRegistration (activeHex, openHex, keyHex, keyAHex, keyBHex, walletAddr, dupTx, mintControlTx, otherName, otherAddress, otherApproval, emptyValue, unlandedTx)

spec :: Spec
spec = runStory story

story :: Program StoryI ()
story = theorem insertActiveRow $ do
    clause
        "the destination holds exactly one active token at the requested address"
        do
            conjunct "address := some r.output"
            conjunct "assets := [((.active, r.key), 1)]"
            conjunct "kindCount t.state .active r.key = 1"
        do
            accepts "one active token at the key, at the address the request named" unchanged

            rejects
                "no token delivered"
                "the conclusion is exactly one, so zero is a distinct defect from a wrong one" $
                    deliver nothing

            rejects
                "two tokens delivered at the key"
                "a per-kind total cannot see a quantity right in kind and wrong in count" $
                    deliver $ activeToken keyHex 2

            rejects
                "a token delivered under the open policy instead of the active one"
                "the policy is half the token identity; an open-policy token is never the active witness" $
                    deliver $ token openHex keyHex 1

            rejects
                "a token whose asset name is not the key"
                "the asset name is the key; a token under another name is a different holding" $
                    deliver $ token activeHex otherName 1

            rejects
                "a token observed at an address the request did not name"
                "the destination is the address the request named; the same token elsewhere misses it" $
                    observedAddress otherAddress

    unexercised
        "the signature-set invariance conjunct"
        "no receipt field carries the approval's signature set"

    clause
        "the fold mints exactly one active token at the key"
        do
            conjunct "mint := [((.active, r.key), 1)]"
        do
            rejects
                "a mint that is not exactly one token at the key"
                "the fold must mint what the destination holds; an empty mint funds nothing" $
                    minted nothing

    clause
        "the open application declares no parameter"
        do
            conjunct "openPolicyParameters = []"
        do
            rejects
                "an open application that declares a parameter"
                "the open policy is parameterless; a declared parameter names a different application" $
                    openParameters 1

    clause
        "the fold pays no refund"
        do
            conjunct "refunds := []"
        do
            rejects
                "a fold that paid a refund"
                "the concluded transaction refunds nothing; a paid refund moves value the rule never sends" $
                    refunds $ lovelace 1_000_000

    clause
        "the fold requires no signer"
        do
            conjunct "signers := []"
        do
            rejects
                "a fold that required a signer"
                "the concluded transaction is unsigned; a required signer adds an authorization the rule never grants" $
                    signers $ signer walletAddr

    clause
        "the request lovelace covers the tip"
        do
            conjunct "lovelaceCoversTip s.config lovelace = true"
        do
            rejects
                "a request whose lovelace does not cover the tip"
                "the hypothesis needs the tip on hand; below it the rule does not apply" $
                    requestLovelace 999_999

    clause
        "the destination is bound by the approval"
        do
            conjunct "destinationDatumBinds r = true"
        do
            rejects
                "a destination binding the approval does not carry"
                "equality of the carried and recomputed approval name is the binding; a mismatch delivers where nothing authorized" $
                    approvalRecomputed otherApproval

    clause
        "only the root pin moves"
        do
            conjunct "onlyRootChanged s.config t.state.config = true"
        do
            rejects
                "a fold that moved a non-root configuration pin"
                "only the root may move; any other difference is a configuration change the fold must not make" $
                    configAfter $ do
                        maxFee 2_000_000
                        restUnchanged

            rejects
                "a configuration observation that lost a pin"
                "the pin comparison needs both sides; a lost pin is an unobserved configuration, not an unchanged one" $
                    configBefore noPins

    clause
        "a second insert at the same key is refused"
        do
            conjunct "txOf t.state r₂ lovelace = .error \"key-exists\""
        do
            acceptsBecause
                "a leg whose trace the ledger did not surface is accepted"
                "a script-execution failure carries an empty log list, so absence is the normal case, not an incomplete leg" $
                    onLeg duplicate omitTrace

            rejects
                "a leg whose control is the transaction it refused"
                "the control must be an accepted transaction; a leg that controls for itself proves the builder can build nothing" $
                    onLeg duplicate $ controlTxid dupTx

            rejects
                "a leg naming no failing script"
                "attribution needs the failing script; without it the refusal blames nothing" $
                    onLeg duplicate $ hashes noHashes

            rejects
                "a leg naming an empty failing script"
                "an empty hash attributes to nothing" $
                    onLeg duplicate $ hashes $ hash emptyValue

            rejects
                "a duplicate leg naming two keys"
                "the duplicate names the one occupied key; a second key belongs to the other fixture" $
                    onLeg duplicate $ keys $ do
                        key keyHex
                        key keyBHex

            rejects
                "a duplicate leg naming a key the fold did not insert"
                "the refusal is key-exists on the inserted key; a key the fold never inserted cannot exist yet" $
                    onLeg duplicate $ keys $ key keyAHex

            rejects
                "a duplicate leg carrying mint arithmetic"
                "the duplicate is refused before any mint runs; arithmetic on it claims to be the keyed-mint witness" $
                    onLeg duplicate $ claimedMint $ mint activeHex keyAHex 2

            rejects
                "a refused transaction that also landed as a fold"
                "a refused transaction never lands; a landed txid identifies an acceptance, not a refusal" $
                    onLeg duplicate $ txid mintControlTx

            rejects
                "a control that never landed a fold"
                "the control must be a landed accepting fold; a transaction the run never landed accepts nothing" $
                    onLeg duplicate $ controlTxid unlandedTx


-- | The active-registration obligation.
insertActiveRow :: Binding
insertActiveRow =
    mkBoundObligation
        "Singular.Statements.insert_active_transaction_row"
        "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
        "265c595"

-- | Verbatim Lean anchors used by this subject.
conjuncts :: [String]
conjuncts = [ "address := some r.output"
          , "assets := [((.active, r.key), 1)]"
          , "kindCount t.state .active r.key = 1"
          , "mint := [((.active, r.key), 1)]"
          , "openPolicyParameters = []"
          , "refunds := []"
          , "signers := []"
          , "lovelaceCoversTip s.config lovelace = true"
          , "destinationDatumBinds r = true"
          , "onlyRootChanged s.config t.state.config = true"
          , "txOf t.state r₂ lovelace = .error \"key-exists\""
    ]
