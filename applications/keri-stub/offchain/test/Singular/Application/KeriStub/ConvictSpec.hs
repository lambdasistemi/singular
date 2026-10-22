{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.ConvictSpec
Description : What a keri-stub convict books, decided and checked purely
License     : Apache-2.0

Rows over the termination 'planConvict' builds: the edge, the redeemer the
custody is spent with, which carries the evidence hash, and who signs; and
rows over the booking refusal the verb checks before anything is signed, with
the named client-policy reason. Every expected value is derived at run time
and never typed into the spec. The custody entering the request whole, the
trie-ready tag minted alone and the fold taking the custody in are read off a
booking and a fold the producer ran, in the producers' spec: the fold pays
the controller nothing.
-}
module Singular.Application.KeriStub.ConvictSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (isInfixOf)
import Test.Hspec

import PlutusCore.Data qualified as PLC

import Singular.Application.KeriStub.Convict
    ( ConvictBooking (..)
    , planConvict
    )
import Singular.CLI.Booking
    ( BookingVerb (..)
    , bookingRefusal
    , refusalFields
    , refusalReason
    )
import Singular.CLI.Proof (Leaf (..))
import Singular.Registry.Types (edgeUpdateTerminal)

spec :: Spec
spec = describe "the convict booking" $ do
    booking
    binding
    refusal

controllerA :: ByteString
controllerA = BS.replicate 28 7

evidenceA :: ByteString
evidenceA = "evidence-hash-1"

evidenceB :: ByteString
evidenceB = "evidence-hash-2"

bookingA :: ConvictBooking
bookingA = planConvict controllerA evidenceA

keyA :: ByteString
keyA = "key-a"

booking :: Spec
booking = describe "what a convict books" $ do
    it "books updateTerminal" $
        cbEdge bookingA `shouldBe` edgeUpdateTerminal
    it "is signed by the holding's controller" $
        cbSigners bookingA `shouldBe` [controllerA]

binding :: Spec
binding = describe "the redeemer the custody is spent with" $ do
    it "carries the evidence hash" $
        cbRedeemer bookingA `shouldBe` PLC.Constr 0 [PLC.B evidenceA]
    it "binds the evidence: two hashes book different redeemers" $
        cbRedeemer (planConvict controllerA evidenceB)
            `shouldNotBe` cbRedeemer bookingA
    it "binds the controller: two controllers sign different bookings" $
        cbSigners (planConvict (BS.replicate 28 8) evidenceA)
            `shouldNotBe` cbSigners bookingA

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
