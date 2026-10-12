{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.KeriStub.DatumSpec
Description : The stub holding datum round-trips and names every refusal
License     : Apache-2.0
-}
module Singular.Application.KeriStub.DatumSpec (spec) where

import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Test.Hspec
import Test.QuickCheck

import PlutusCore.Data qualified as PLC

import Singular.Application.KeriStub.Datum

spec :: Spec
spec = describe "the stub holding datum" $ do
    roundTrip
    refusals

holdingWith :: PLC.Data -> Holding
holdingWith p =
    Holding
        { hdKey = "key"
        , hdController = BS.replicate 28 3
        , hdDeposit = 2_000_000
        , hdPayload = p
        }

roundTrip :: Spec
roundTrip = describe "the codec" $ do
    it "round-trips any payload" $
        property $ \n ->
            let p = PLC.I n
            in  holdingFromData (holdingToData (holdingWith p))
                    === Right (holdingWith p)
    it "keeps key, controller and deposit" $
        let h = holdingWith (PLC.B "prefix")
        in  case holdingFromData (holdingToData h) of
                Right decoded -> do
                    hdKey decoded `shouldBe` hdKey h
                    hdController decoded `shouldBe` hdController h
                    hdDeposit decoded `shouldBe` hdDeposit h
                    hdPayload decoded `shouldBe` hdPayload h
                Left why ->
                    expectationFailure ("round trip refused: " <> why)

refusals :: Spec
refusals = describe "the refusals" $ do
    it "is not another constructor" $
        holdingFromData (PLC.Constr 1 [])
            `shouldSatisfy` isLeft
    it "is not a bare integer" $
        holdingFromData (PLC.I 7)
            `shouldSatisfy` isLeft
    it "needs four fields" $
        holdingFromData (PLC.Constr 0 [PLC.B "key"])
            `shouldSatisfy` isLeft
    it "refuses a key that is not bytes" $
        holdingFromData
            (PLC.Constr 0 [PLC.I 1, PLC.B "c", PLC.I 1, PLC.I 1])
            `shouldSatisfy` isLeft
    it "refuses an empty key" $
        holdingFromData
            (PLC.Constr 0 [PLC.B "", PLC.B (BS.replicate 28 3), PLC.I 1, PLC.I 1])
            `shouldSatisfy` isLeft
    it "refuses a key past 32 bytes" $
        holdingFromData
            ( PLC.Constr
                0
                [ PLC.B (BS.replicate 33 9)
                , PLC.B (BS.replicate 28 3)
                , PLC.I 1
                , PLC.I 1
                ]
            )
            `shouldSatisfy` isLeft
    it "refuses a controller that is not bytes" $
        holdingFromData
            (PLC.Constr 0 [PLC.B "key", PLC.I 2, PLC.I 1, PLC.I 1])
            `shouldSatisfy` isLeft
    it "refuses a controller that is not 28 bytes" $
        holdingFromData
            (PLC.Constr 0 [PLC.B "key", PLC.B "short", PLC.I 1, PLC.I 1])
            `shouldSatisfy` isLeft
    it "refuses a deposit that is not an integer" $
        holdingFromData
            ( PLC.Constr
                0
                [ PLC.B "key"
                , PLC.B (BS.replicate 28 3)
                , PLC.B "lovelace"
                , PLC.I 1
                ]
            )
            `shouldSatisfy` isLeft
    it "refuses a negative deposit" $
        holdingFromData
            ( PLC.Constr
                0
                [ PLC.B "key"
                , PLC.B (BS.replicate 28 3)
                , PLC.I (-1)
                , PLC.I 1
                ]
            )
            `shouldSatisfy` isLeft
    it "takes any payload unread" $
        case holdingFromData
            ( PLC.Constr
                0
                [ PLC.B "key"
                , PLC.B (BS.replicate 28 3)
                , PLC.I 0
                , PLC.Map [(PLC.I 1, PLC.B "x")]
                ]
            ) of
            Right h -> hdPayload h `shouldBe` PLC.Map [(PLC.I 1, PLC.B "x")]
            Left why -> expectationFailure ("payload refused: " <> why)
