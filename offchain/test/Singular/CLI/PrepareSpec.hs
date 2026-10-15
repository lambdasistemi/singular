{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.PrepareSpec
Description : The funding seam refuses before signing and measures honestly
License     : Apache-2.0

The seam's pure decisions: the shortfall refusal names what is needed,
what the wallet may spend and the short step and ends that nothing was
submitted; the allowance refusal names the command outlay and the
preparation fee against the allowance; the requirement is the measured
fee, collateral and change floor; an explicit choice is refused with
today's text. Every amount is fixed in the test; the builders they pin
are exercised by the command rows.
-}
module Singular.CLI.PrepareSpec (spec) where

import Data.Aeson (toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Text qualified as T
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.CLI.Outlay (Outlay (..), collateralOfFee)
import Singular.CLI.Prepare
    ( PrepareRefusal (..)
    , allowanceRefusal
    , explicitRefusal
    , measureRequirement
    , overAllowance
    , preparationFields
    , shortfallRefusal
    )
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.BookingFixture
    ( payer
    , preprodParams
    )
import Singular.Registry.TxBuilder.Prepare
    ( Preparation (..)
    , PrepareError (..)
    , planPreparation
    )
import Singular.Registry.Wallet (bech32Address)

spec :: Spec
spec = describe "the funding seam" $ do
    shortfallText
    allowanceText
    allowanceGate
    requirementMeasure
    explicitText
    receiptPreparation

testPayer :: Addr
testPayer = payer

outRef :: Char -> TxIn
outRef c =
    either (error . ("PrepareSpec fixture: " <>)) id $
        parseOutRef (T.pack (replicate 64 c <> "#0"))

shortfallWallet :: [(TxIn, TxOut ConwayEra)]
shortfallWallet =
    [ (outRef 'a', adaLike 1_000_000)
    , (outRef 'b', adaLike 2_000_000)
    ]
  where
    adaLike n = mkBasicTxOut testPayer (MaryValue (Coin n) mempty)

shortfallErr :: PrepareError
shortfallErr =
    PrepareShortfall
        { prepareRequired = 5_000_000
        , prepareFee = Just 200_000
        , prepareRemainderMin = 900_000
        , prepareHeld = 3_000_000
        , prepareLargest = 2_000_000
        }

shortfallExpected :: String
shortfallExpected =
    "preparation-unfunded: the wallet holds 3000000 lovelace but 6100000 is required for the preparation (5000000 for the command, 200000 fee and 900000 remainder floor) (client policy); nothing was submitted"

shortfallText :: Spec
shortfallText = describe "the shortfall refusal" $ do
    it "names need, holdings and step" $ do
        let (text, fields) =
                shortfallRefusal testPayer shortfallWallet shortfallErr
            check k v = fields `shouldContain` [(k, v)]
        text `shouldBe` shortfallExpected
        check "held" (toJSON (3_000_000 :: Integer))
        check "required" (toJSON (6_100_000 :: Integer))
        check "shortfall" (toJSON (3_100_000 :: Integer))
        check "utxoCount" (toJSON (2 :: Int))
        check "wallet" (toJSON (T.pack (bech32Address testPayer)))
        check "policy" (toJSON ("client" :: T.Text))
        check "requiredIs" (toJSON ("preparation" :: T.Text))
        check "fee" (toJSON (Just (200_000 :: Integer)))
        check "remainderMin" (toJSON (900_000 :: Integer))
        check "largest" (toJSON (2_000_000 :: Integer))
    it "says no fee measured when no attempt priced one" $ do
        let (text, _) =
                shortfallRefusal
                    testPayer
                    []
                    (PrepareShortfall 1_500_000 Nothing 800_000 0 0)
        text
            `shouldBe` ( "preparation-unfunded: the wallet holds 0 lovelace but 2300000 is required"
                            <> " for the preparation (1500000 for the command, no fee measured and 800000 remainder floor)"
                            <> " (client policy); nothing was submitted"
                       )

allowanceText :: Spec
allowanceText = describe "the allowance refusal" $ do
    it "names both amounts before anything is submitted" $ do
        let outlay = Outlay{outlayFee = 200_000, outlayBond = 0, outlayFoldBound = 0}
            (text, fields) = allowanceRefusal 100_000 outlay 50_000 Nothing
        text
            `shouldBe` ( "the measured outlay of 200000 lovelace with the preparation fee of 50000"
                            <> " lovelace passes the approved allowance of 100000 (client policy); nothing was submitted"
                       )
        lookup "preparationFee" fields
            `shouldBe` Just (toJSON (50_000 :: Integer))
        lookup "allowance" fields
            `shouldBe` Just (toJSON (100_000 :: Integer))
    it "refuses an allowance the command alone fits with the stable text" $ do
        let outlay = Outlay{outlayFee = 200_000, outlayBond = 0, outlayFoldBound = 0}
            (text, fields) = allowanceRefusal 200_000 outlay 50_000 Nothing
        text
            `shouldBe` ( "the measured outlay of 200000 lovelace with the preparation fee of 50000"
                            <> " lovelace passes the approved allowance of 200000 (client policy); nothing was submitted"
                       )
        lookup "preparationFee" fields
            `shouldBe` Just (toJSON (50_000 :: Integer))
        lookup "allowance" fields
            `shouldBe` Just (toJSON (200_000 :: Integer))
    it "names the confirmed preparation once one stands" $ do
        let outlay = Outlay{outlayFee = 200_000, outlayBond = 0, outlayFoldBound = 0}
            (text, _) = allowanceRefusal 100_000 outlay 50_000 (Just (outRef 'a'))
        text
            `shouldBe` ( "the measured outlay of 200000 lovelace with the preparation fee of 50000"
                            <> " lovelace passes the approved allowance of 100000 (client policy); the preparation "
                            <> T.unpack (renderOutRef (outRef 'a'))
                            <> " stands confirmed and the command was not signed"
                       )

allowanceGate :: Spec
allowanceGate = describe "the allowance gate" $ do
    it "no allowance approves any preparation" $ do
        overAllowance Nothing (Outlay 0 0 0) 0 `shouldBe` Nothing
    it "command plus preparation within the allowance passes" $ do
        overAllowance (Just 300_000) (Outlay 200_000 0 0) 50_000
            `shouldBe` Nothing
    it "command plus preparation past the allowance names both" $ do
        overAllowance (Just 100_000) (Outlay 200_000 0 0) 50_000
            `shouldBe` Just (100_000, Outlay 200_000 0 0, 50_000)
    it "exactly the allowance still passes" $ do
        overAllowance (Just 250_000) (Outlay 200_000 0 0) 50_000
            `shouldBe` Nothing
    it "one lovelace below outlay plus fee is refused" $ do
        let outlay = Outlay 200_000 0 0
            fee = 50_000
            limit = 200_000 + 50_000
        overAllowance (Just limit) outlay fee `shouldBe` Nothing
        overAllowance (Just (limit - 1)) outlay fee
            `shouldBe` Just (limit - 1, outlay, fee)
    it "an allowance fitting the command alone is refused" $ do
        let outlay = Outlay 200_000 0 0
            fee = 50_000
        overAllowance (Just 200_000) outlay fee
            `shouldBe` Just (200_000, outlay, fee)

requirementMeasure :: Spec
requirementMeasure = describe "the measured requirement" $ do
    it "is fee, collateral and change floor of a built preparation" $ do
        let wallet =
                [
                    ( outRef 'a'
                    , mkBasicTxOut testPayer (MaryValue (Coin 5_000_000) mempty)
                    )
                ]
        case planPreparation preprodParams testPayer 1_500_000 wallet of
            Left err -> expectationFailure ("refused a covering wallet: " <> show err)
            Right prep -> do
                let tx = prepTx prep
                    Coin fee = tx ^. (bodyTxL . feeTxBodyL)
                    outs = toList (tx ^. (bodyTxL . outputsTxBodyL))
                    atPayer = [o | o <- outs, o ^. addrTxOutL == testPayer]
                    changeFloor =
                        maximum
                            [c | o <- atPayer, let Coin c = getMinCoinTxOut preprodParams o]
                    expected = fee + collateralOfFee preprodParams fee + changeFloor
                measureRequirement preprodParams testPayer tx `shouldBe` expected

explicitText :: Spec
explicitText = describe "an explicit funding choice" $ do
    it "is refused with today's text for fold, reject and reclaim" $ do
        let why = "the chosen funding output is not an ada-only output of the payer"
            refused step = case explicitRefusal step why of
                ExplicitFundingRefusal s -> s
                _ -> error "PrepareSpec: explicit refusal took another shape"
        refused "fold"
            `shouldBe` "the wallet cannot fund the fold: the chosen funding output is not an ada-only output of the payer"
        refused "reject"
            `shouldBe` "the wallet cannot fund the reject: the chosen funding output is not an ada-only output of the payer"
        refused "reclaim"
            `shouldBe` "the wallet cannot fund the reclaim: the chosen funding output is not an ada-only output of the payer"

receiptPreparation :: Spec
receiptPreparation = describe "the receipt preparation" $ do
    it "is absent when no preparation was made" $ do
        preparationFields Nothing `shouldBe` []
    it "names transaction, output, lovelace and fee when one was made" $ do
        let wallet =
                [
                    ( outRef 'a'
                    , mkBasicTxOut testPayer (MaryValue (Coin 5_000_000) mempty)
                    )
                ]
        case planPreparation preprodParams testPayer 1_500_000 wallet of
            Left err -> expectationFailure ("refused a covering wallet: " <> show err)
            Right prep -> case preparationFields (Just prep) of
                [("preparation", Aeson.Object o)] -> do
                    KeyMap.member "transaction" o `shouldBe` True
                    KeyMap.member "output" o `shouldBe` True
                    KeyMap.member "lovelace" o `shouldBe` True
                    KeyMap.member "fee" o `shouldBe` True
                    KeyMap.lookup "lovelace" o
                        `shouldBe` Just (toJSON (1_500_000 :: Integer))
                _ -> expectationFailure "the preparation field has another shape"
