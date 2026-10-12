{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.ConvictSpec
Description : What a keri-stub convict books, decided and checked purely
License     : Apache-2.0

Rows over the termination 'planConvict' builds: the edge, the empty
destination a termination delivers to, the deposit it rides with, and
the approval that certifies the mint with the evidence hash in its
redeemer; rows over the booking refusal the verb checks before anything
is signed, with the named client-policy reason; and rows over the
release the convict's fold pays. Every expected value is derived at run
time — the approval asset name by the library's own binding formula,
the redeemer by the same tuple the registry's own approvals spell with
the evidence as its last field — never typed into the spec.
-}
module Singular.Application.KeriStub.ConvictSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Test.Hspec

import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC

import Singular.Application.KeriStub.Convict
    ( ConvictBooking (..)
    , planConvict
    )
import Singular.Application.KeriStub.Datum
    ( Holding (..)
    , holdingToData
    )
import Singular.Application.KeriStub.Script (keriStubScript)
import Singular.Application.KeriStub.Value (keriStubApplication)
import Singular.CLI.Booking
    ( BookingVerb (..)
    , bookingRefusal
    , refusalFields
    , refusalReason
    )
import Singular.CLI.Proof (Leaf (..))
import Singular.Registry.Application
    ( Application (..)
    , HoldingRules (..)
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Edges
    ( BookingApproval (..)
    , edgeDeposit
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , approvalDestination
    , approvalName
    , mkInlineDatum
    )
import Singular.Registry.TxBuilder.Update (HolderRelease (..))
import Singular.Registry.Types (edgeUpdateTerminal)

spec :: Spec
spec = describe "the convict booking" $ do
    booking
    binding
    refusal
    release

keyA :: ByteString
keyA = "key-a"

keyB :: ByteString
keyB = "key-b"

controllerA :: ByteString
controllerA = BS.replicate 28 7

evidenceA :: ByteString
evidenceA = "evidence-hash-1"

evidenceB :: ByteString
evidenceB = "evidence-hash-2"

stateIn :: TxIn
stateIn = case parseOutRef (T.pack (replicate 64 'a' <> "#0")) of
    Right i -> i
    Left why -> error ("ConvictSpec: bad outref: " <> why)

holdingIn :: TxIn
holdingIn = case parseOutRef (T.pack (replicate 64 'b' <> "#1")) of
    Right i -> i
    Left why -> error ("ConvictSpec: bad outref: " <> why)

bookingA :: ConvictBooking
bookingA = planConvict stateIn holdingIn keyA controllerA evidenceA

booking :: Spec
booking = describe "what a convict books" $ do
    it "books updateTerminal" $
        cbEdge bookingA `shouldBe` edgeUpdateTerminal
    it "delivers nowhere: a termination delivers nothing" $
        cbDestination bookingA `shouldBe` (BS.empty, Nothing)
    it "rides with the library's booking deposit" $
        cbDeposit bookingA `shouldBe` edgeDeposit
    it
        "certifies with the stub's script, attached, the state and the holding by reference"
        $ do
            let approval = cbApproval bookingA
            baScript approval `shouldBe` (keriStubScript :: Script ConwayEra)
            baScriptReference approval `shouldBe` Nothing
            baReferenceInputs approval
                `shouldBe` Set.fromList [stateIn, holdingIn]

binding :: Spec
binding = describe "the approval the mint requires" $ do
    it "mints exactly one asset of one policy, in quantity one" $ do
        let MultiAsset minted = baAsset (cbApproval bookingA)
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
        let (address, datumHash) = approvalDestination (cbDestination bookingA)
            expected =
                approvalName
                    edgeUpdateTerminal
                    keyA
                    controllerA
                    (address, datumHash)
        baAsset (cbApproval bookingA)
            `shouldBe` MultiAsset
                ( Map.singleton
                    (PolicyID (hashScript keriStubScript))
                    (Map.singleton (AssetName (SBS.toShort expected)) 1)
                )
    it
        "carries the evidence hash in the Approve redeemer the registry's own approvals spell"
        $ do
            let (address, datumHash) = approvalDestination (cbDestination bookingA)
            baRedeemer (cbApproval bookingA)
                `shouldBe` PLC.Constr
                    0
                    [ PLC.I edgeUpdateTerminal
                    , PLC.B keyA
                    , PLC.B controllerA
                    , PLC.List [PLC.B address, PLC.B datumHash]
                    , PLC.B evidenceA
                    ]
    it "binds the evidence: two hashes book different redeemers" $ do
        let b = planConvict stateIn holdingIn keyA controllerA evidenceB
        baRedeemer (cbApproval b)
            `shouldNotBe` baRedeemer (cbApproval bookingA)
    it "binds the key: two keys book differently-named approvals" $ do
        let b = planConvict stateIn holdingIn keyB controllerA evidenceA
        baAsset (cbApproval b) `shouldNotBe` baAsset (cbApproval bookingA)

refusal :: Spec
refusal = describe "the refusal before anything is signed" $ do
    it "refuses a key that is not registered, naming it a client policy" $
        case bookingRefusal BookTerminate keyA Unknown of
            Just r -> do
                refusalReason r `shouldSatisfy` isInfixOf "is not registered"
                refusalReason r `shouldSatisfy` isInfixOf "(client policy)"
                lookup "verb" (refusalFields r) `shouldBe` Just "terminate"
                lookup "edge" (refusalFields r) `shouldBe` Just "updateTerminal"
                lookup "leafFound" (refusalFields r) `shouldBe` Just "unknown"
                lookup "leafRequired" (refusalFields r) `shouldBe` Just "active"
                lookup "policy" (refusalFields r) `shouldBe` Just "client"
            Nothing ->
                expectationFailure "an unknown key was booked for termination"
    it "refuses a key that is already retired, naming it a client policy" $
        case bookingRefusal BookTerminate keyA Terminal of
            Just r -> do
                refusalReason r `shouldSatisfy` isInfixOf "is already retired"
                refusalReason r `shouldSatisfy` isInfixOf "(client policy)"
            Nothing ->
                expectationFailure "a terminal key was booked for termination"
    it "books a key that is active" $
        bookingRefusal BookTerminate keyA Active `shouldBe` Nothing

release :: Spec
release = describe "the release the convict's fold pays" $ do
    it "spends with a unit redeemer, the controller and the deposit" $
        case hrReleaseOf rules undefined pair of
            Right (found, rel) -> do
                found `shouldBe` fst pair
                hrRedeemer rel `shouldBe` PLC.Constr 0 []
                hrRecipient rel `shouldBe` controllerA
                hrReleased rel `shouldBe` 2_000_000
            Left why ->
                expectationFailure ("release refused: " <> T.unpack why)
  where
    rules = case appHolding keriStubApplication of
        Just r -> r
        Nothing -> error "ConvictSpec: the stub value carries no holding rules"
    holding =
        Holding
            { hdKey = keyA
            , hdController = controllerA
            , hdDeposit = 2_000_000
            , hdPayload = PLC.B "prefix-a"
            }
    pair =
        ( holdingIn
        , mkBasicTxOut
            (addrFromKeyHashBytes Testnet (BS.replicate 28 9))
            (MaryValue (Coin 3_000_000) mempty)
            & datumTxOutL .~ mkInlineDatum (holdingToData holding)
        )
