{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.OutlaySpec
Description : #300 — what a command puts out, judged against an approved allowance
License     : Apache-2.0

An approved allowance is worth something only if the number it is judged
against is the wallet's real outlay: the fee of the transaction about to be
sent, the bond its request output locks, and a bound on the fold that follows
that no fold can exceed. These rows fix each part under the public preprod
parameters, with every expected value derived here by arithmetic from those
parameters and from the bodies the rows build, never read from the functions
under test.
-}
module Singular.CLI.OutlaySpec (spec) where

import Data.ByteString qualified as BS
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , chooseInteger
    , forAll
    , property
    , (===)
    )

import Cardano.Ledger.Api.PParams (ppCollateralPercentageL)
import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Balance (refScriptsSize)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.Outlay
import Singular.Registry.Blueprint (applyBytesParam)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.BookingFixture
    ( payer
    , preprodParams
    , program
    )
import Singular.Registry.TxBuilder.Internal (scriptFromBytes)

-- | A booking as the outlay reads it: request output first, then change.
bookingWith :: Integer -> Integer -> ConwayTx
bookingWith fee bond =
    mkBasicTx
        ( mkBasicTxBody
            & feeTxBodyL .~ Coin fee
            & outputsTxBodyL
                .~ StrictSeq.fromList
                    [ mkBasicTxOut payer (MaryValue (Coin bond) mempty)
                    , mkBasicTxOut payer (MaryValue (Coin 7_000_000) mempty)
                    ]
        )

refIn :: TxIn
refIn =
    either error id (parseOutRef (T.pack (replicate 64 '8' <> "#0")))

-- | An output carrying a published script of realistic size.
published :: TxOut ConwayEra
published =
    mkBasicTxOut payer (MaryValue (Coin 50_000_000) mempty)
        & referenceScriptTxOutL
            .~ SJust
                ( scriptFromBytes
                    "t300-published"
                    (applyBytesParam (BS.replicate 9_000 0x61) program)
                )

-- | The fee of a transaction of the maximum size at the maximum units, by arithmetic.
maximumFold :: Integer
maximumFold =
    155_381
        + 44 * 16_384
        + ceiling (577 / 10_000 * 17_500_000 :: Rational)
        + ceiling (721 / 10_000_000 * 10_000_000_000 :: Rational)

spec :: Spec
spec = describe "a command's outlay against an approved allowance (#300)" $ do
    it "is the booking's fee and the request's bond" $
        property $
            forAll ((,) <$> fees <*> bonds) $ \(fee, bond) ->
                let o = bookingOutlay preprodParams [] (bookingWith fee bond)
                in  (outlayFee o, outlayBond o) === (fee, bond)
    it
        "bounds the fold by the fee of a maximum-size, maximum-units transaction"
        $ do
            let o = bookingOutlay preprodParams [] (bookingWith 1_000_000 3_000_000)
            outlayFoldBound o `shouldSatisfy` (>= maximumFold)
            outlayFoldBound o `shouldSatisfy` (<= maximumFold + 44 * 1_000)
    it "charges the reference-script tier of the outputs the fold reads" $ do
        let refs = [(refIn, published)]
            bare = bookingOutlay preprodParams [] (bookingWith 1 3_000_000)
            read' = bookingOutlay preprodParams refs (bookingWith 1 3_000_000)
            bytes = toInteger (refScriptsSize (Set.singleton refIn) refs)
        bytes `shouldSatisfy` (> 9_000)
        outlayFoldBound read' - outlayFoldBound bare `shouldBe` 15 * bytes
    it "is an update's fee alone" $
        property $
            forAll fees $ \fee ->
                updateOutlay (bookingWith fee 3_000_000)
                    === Outlay{outlayFee = fee, outlayBond = 0, outlayFoldBound = 0}
    it "totals the fee, the bond and the fold bound" $
        property $
            forAll ((,) <$> fees <*> bonds) $ \(fee, bond) ->
                outlayTotal (Outlay fee bond 2_500_000) === fee + bond + 2_500_000
    it
        "approves any outlay when no allowance was named, and refuses one over it"
        $ property
        $ forAll ((,) <$> fees <*> bonds)
        $ \(fee, bond) ->
            let o = Outlay fee bond 2_500_000
                total = fee + bond + 2_500_000
            in  ( withinAllowance Nothing o
                , withinAllowance (Just total) o
                , withinAllowance (Just (total - 1)) o
                )
                    === (True, True, False)
    it "rounds the collateral up to the protocol's percentage" $
        property $
            forAll ((,) <$> fees <*> percentages) $ \(fee, pct) ->
                let pp = preprodParams & ppCollateralPercentageL .~ fromIntegral pct
                    c = collateralOfFee pp fee
                in  (c * 100 >= fee * pct, (c - 1) * 100 < fee * pct)
                        === (True, True)
    it
        "states the declared total collateral, else the percentage of the fee"
        $ do
            collateralOf preprodParams (bookingWith 1_000_000 3_000_000)
                `shouldBe` 1_500_000
            collateralOf preprodParams (bookingWith 1_000_001 3_000_000)
                `shouldBe` 1_500_002
  where
    fees = chooseInteger (155_381, 4_000_000) :: Gen Integer
    bonds = chooseInteger (2_000_000, 8_000_000) :: Gen Integer
    percentages = chooseInteger (100, 300) :: Gen Integer
