{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.RegisterSpec
Description : What a keri-stub register books, decided and checked purely
License     : Apache-2.0

Rows over the register booking 'planRegister' builds: the edge, the
destination the fold delivers to, the datum the request carries, the
deposit it protects, and the approval that certifies the mint. Every
expected value is derived at run time — the stub script's address from
its own bytes through the ledger's own hash, the approval asset name by
the library's own binding formula, the redeemer by the same tuple the
registry's own approvals spell — never typed into the spec.
-}
module Singular.Application.KeriStub.RegisterSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec

import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
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
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , edgeDeposit
    )
import Singular.Registry.TxBuilder.Internal
    ( approvalDestination
    , approvalName
    )
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

stateIn :: TxIn
stateIn = case parseOutRef (T.pack (replicate 64 'a' <> "#0")) of
    Right i -> i
    Left why -> error ("RegisterSpec: bad outref: " <> why)

bookingA :: RegisterBooking
bookingA = planRegister stateIn keyA controllerA deposit payload

-- | The stub script's own enterprise address, derived from its bytes.
stubAddressBytes :: ByteString
stubAddressBytes =
    serialiseAddr
        (Addr Testnet (ScriptHashObj (hashScript keriStubScript)) StakeRefNull)

booking :: Spec
booking = describe "what a register books" $ do
    it "books insertActive" $
        rbEdge bookingA `shouldBe` edgeInsertActive
    it "delivers to the stub script's own enterprise address" $
        fst (rbDestination bookingA) `shouldBe` stubAddressBytes
    it "carries the holding as the datum the delivered output holds" $
        snd (rbDestination bookingA)
            `shouldBe` Just
                ( holdingToData
                    Holding
                        { hdKey = keyA
                        , hdController = controllerA
                        , hdDeposit = deposit
                        , hdPayload = payload
                        }
                )
    it "protects the deposit it was given" $
        rbDeposit bookingA `shouldBe` deposit
    it "defaults to the library's booking deposit when none is given" $
        defaultDeposit `shouldBe` edgeDeposit
    it
        "certifies with the stub's script, attached, the state by reference"
        $ do
            let approval = rbApproval bookingA
            baScript approval `shouldBe` (keriStubScript :: Script ConwayEra)
            baScriptReference approval `shouldBe` Nothing
            baReferenceInputs approval `shouldBe` Set.singleton stateIn

binding :: Spec
binding = describe "the approval the mint requires" $ do
    it "mints exactly one asset of one policy, in quantity one" $ do
        let MultiAsset minted = baAsset (rbApproval bookingA)
        case Map.toList minted of
            [(policy, names)] -> do
                policy `shouldBe` PolicyID (hashScript keriStubScript)
                case Map.toList names of
                    [(AssetName theName, quantity)] -> do
                        SBS.length theName `shouldBe` 32
                        quantity `shouldBe` 1
                    other -> expectationFailure ("not one asset name: " <> show (length other))
            other -> expectationFailure ("not one policy: " <> show (length other))
    it "names the asset by the library's binding formula, recomputed here" $ do
        let (address, datumHash) = approvalDestination (rbDestination bookingA)
            expected =
                approvalName
                    edgeInsertActive
                    keyA
                    controllerA
                    (address, datumHash)
        baAsset (rbApproval bookingA)
            `shouldBe` MultiAsset
                ( Map.singleton
                    (PolicyID (hashScript keriStubScript))
                    (Map.singleton (AssetName (SBS.toShort expected)) 1)
                )
    it
        "spells the same Approve redeemer the registry's own approvals spell"
        $ do
            let (address, datumHash) = approvalDestination (rbDestination bookingA)
            baRedeemer (rbApproval bookingA)
                `shouldBe` PLC.Constr
                    0
                    [ PLC.I edgeInsertActive
                    , PLC.B keyA
                    , PLC.B controllerA
                    , PLC.List [PLC.B address, PLC.B datumHash]
                    ]
    it "binds the key: two keys book differently-named approvals" $ do
        let b = planRegister stateIn keyB controllerA deposit payload
        baAsset (rbApproval b) `shouldNotBe` baAsset (rbApproval bookingA)
