{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.RegisterSpec
Description : What a keri-stub register books, decided and checked purely
License     : Apache-2.0

Rows over the register booking 'planRegister' builds: the edge, the
destination the fold delivers to, the datum the request carries and the
deposit it protects. Every expected value is derived at run time (the stub
script's address from its own bytes through the ledger's own hash) and never
typed into the spec. The tags a booking mints and the request it makes are
the registry's own: the rows that read them off a booking built by the
producer are in the producers' spec.
-}
module Singular.Application.KeriStub.RegisterSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Test.Hspec

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import PlutusCore.Data qualified as PLC

import Singular.Application.KeriStub.Datum
    ( Holding (..)
    , holdingToData
    )
import Singular.Application.KeriStub.Register
    ( RegisterBooking (..)
    , defaultDeposit
    , planRegister
    )
import Singular.Application.KeriStub.Script (keriStubScript)
import Singular.Registry.TxBuilder.Edges (edgeDeposit)
import Singular.Registry.Types (edgeInsertActive)

spec :: Spec
spec = describe "the register booking" $ do
    booking
    binding

keyA :: ByteString
keyA = "key-a"

keyB :: ByteString
keyB = "key-b"

controllerA :: ByteString
controllerA = BS.replicate 28 7

deposit :: Integer
deposit = 4_000_000

payload :: PLC.Data
payload = PLC.B "prefix-a"

bookingA :: RegisterBooking
bookingA = planRegister keyA controllerA deposit payload

-- | The stub script's own enterprise address, derived from its bytes.
stubAddressBytes :: ByteString
stubAddressBytes =
    serialiseAddr
        (Addr Testnet (ScriptHashObj (hashScript keriStubScript)) StakeRefNull)

booking :: Spec
booking = describe "what a register books" $ do
    it "books insertActive" $
        registerEdge bookingA `shouldBe` edgeInsertActive
    it "delivers to the stub script's own enterprise address" $
        fst (registerDestination bookingA) `shouldBe` stubAddressBytes
    it "carries the holding as the datum the delivered output holds" $
        snd (registerDestination bookingA)
            `shouldBe` Just
                ( holdingToData
                    Holding
                        { hdKey = keyA
                        , hdController = controllerA
                        , hdDeposit = deposit
                        , hdPayload = payload
                        }
                )
    it "protects the deposit it was given, as the registration's carrier" $
        registerDeposit bookingA `shouldBe` deposit
    it "defaults to the library's booking deposit when none is given" $
        defaultDeposit `shouldBe` edgeDeposit

binding :: Spec
binding = describe "what the holding binds" $ do
    it "binds the key: two keys book different holdings" $ do
        let b = planRegister keyB controllerA deposit payload
        snd (registerDestination b)
            `shouldNotBe` snd (registerDestination bookingA)
    it "binds the controller: two controllers book different holdings" $ do
        let b = planRegister keyA (BS.replicate 28 8) deposit payload
        snd (registerDestination b)
            `shouldNotBe` snd (registerDestination bookingA)
    it "binds the payload: two payloads book different holdings" $ do
        let b = planRegister keyA controllerA deposit (PLC.B "prefix-b")
        snd (registerDestination b)
            `shouldNotBe` snd (registerDestination bookingA)
