{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.OutlaySpec
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
module Singular.Application.OpenDatum.OutlaySpec (spec) where

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

import Cardano.Ledger.Api.PParams
    ( ppCollateralPercentageL
    , ppTxFeePerByteL
    )
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
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Coin
    ( Coin (..)
    , CoinPerByte (..)
    , CompactForm (CompactCoin)
    )
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Balance (refScriptsSize)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.BurnSourceSpec (builtFoldUnder)
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

-- | A wallet holding these lovelace amounts in as many outputs.
walletOf :: [Integer] -> [(TxIn, TxOut ConwayEra)]
walletOf amounts =
    [ (TxIn txid (TxIx ix), mkBasicTxOut payer coin)
    | (ix, c) <- zip [0 ..] amounts
    , let coin = MaryValue (Coin c) mempty
    ]
  where
    TxIn txid _ = refIn

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
    it
        "stops the fold its own view makes dearer than what its booking left of the allowance, and passes the one it does not"
        $ do
            -- The allowance a booking under tree-change-requires-approval was approved against: its fee, its
            -- bond and the fold's bound under tree-change-requires-approval's parameters, exactly.
            let booking = bookingWith 400_000 3_000_000
                p1 = preprodParams
                p2 = preprodParams & ppTxFeePerByteL .~ CoinPerByte (CompactCoin 10_000)
                spent = bookingOutlay p1 [] booking
                approved = Just (outlayTotal spent)
                left = leftForFold approved spent
            left `shouldBe` Just (outlayFoldBound spent)
            -- The same registry's fold, built by the production builder under
            -- each view's parameters after the booking confirmed.
            underP1 <- builtFoldUnder p1
            underP2 <- builtFoldUnder p2
            -- What makes the two cases mean something: tree-change-requires-approval's fold is within what
            -- is left, P2's is past it.
            Just (outlayTotal (foldOutlay underP1)) `shouldSatisfy` (<= left)
            Just (outlayTotal (foldOutlay underP2)) `shouldSatisfy` (> left)
            foldPastAllowance approved spent underP1 `shouldBe` Nothing
            fmap fst (foldPastAllowance approved spent underP2) `shouldBe` left
            fmap snd (foldPastAllowance approved spent underP2)
                `shouldBe` Just (foldOutlay underP2)
            -- With no allowance named the fold is not bounded.
            foldPastAllowance Nothing spent underP2 `shouldBe` Nothing
    it
        "leaves a termination's fold the remainder the wallet's own outlay leaves, whatever custody its request took in"
        $ do
            -- A custody of 4 ada, an addition of 2, a booking fee of 0.2 and a
            -- fold bound of 1: the wallet puts out 0.2 + 2 + 1 = 3.2. The
            -- request holds 6, of which 4 was the key's already.
            let spent =
                    Outlay
                        { outlayFee = 200_000
                        , outlayBond = 2_000_000
                        , outlayFoldBound = 1_000_000
                        }
                approved = Just 3_200_000
                booking = bookingWith 200_000 6_000_000
            outlayTotal spent `shouldBe` 3_200_000
            -- what a termination's own measure takes of the same booking
            let measured = terminationOutlay preprodParams [] 4_000_000 booking
            (outlayFee measured, outlayBond measured)
                `shouldBe` (200_000, 2_000_000)
            leftForFold approved spent `shouldBe` Just 1_000_000
            -- a fold costing 0.5 is within it; one costing more than the
            -- remainder, so that the wallet's total passes the allowance, is not
            foldPastAllowance approved spent (bookingWith 500_000 3_000_000)
                `shouldBe` Nothing
            fmap
                fst
                (foldPastAllowance approved spent (bookingWith 1_000_001 3_000_000))
                `shouldBe` Just 1_000_000
            -- charging the whole request instead, as the earlier accounting did,
            -- leaves the remainder negative and refuses every fold
            leftForFold approved spent{outlayBond = 6_000_000}
                `shouldBe` Just (-3_000_000)
    it
        "leaves a registration's fold what it always left: the allowance less the booking's fee and its whole bond"
        $ property
        $ forAll ((,) <$> fees <*> bonds)
        $ \(fee, bond) ->
            let booking = bookingWith fee bond
                spent = bookingOutlay preprodParams [] booking
                approved = Just (outlayTotal spent)
            in  leftForFold approved spent
                    === Just (outlayFoldBound spent)
    it
        "leaves a fold the allowance less the booking and the preparation that funded it, the preparation counted once"
        $ do
            -- a booking with a fee of 0.2 and a bond of 2, funded by a
            -- preparation of 0.1, and a fold bound of 1: the wallet puts out
            -- 0.1 + 0.2 + 2 + 1 = 3.3
            let booked =
                    Outlay
                        { outlayFee = 200_000
                        , outlayBond = 2_000_000
                        , outlayFoldBound = 1_000_000
                        }
                spent = withPreparationFee 100_000 booked
                approved = Just 3_300_000
            outlayTotal spent `shouldBe` 3_300_000
            leftForFold approved spent `shouldBe` Just 1_000_000
            -- a fold costing the remainder is within it; one lovelace more is
            -- not, where the booking alone would have left room for it
            foldPastAllowance approved spent (bookingWith 1_000_000 3_000_000)
                `shouldBe` Nothing
            fmap
                fst
                (foldPastAllowance approved spent (bookingWith 1_000_001 3_000_000))
                `shouldBe` Just 1_000_000
            leftForFold approved booked `shouldBe` Just 1_100_000
    it
        "adds a preparation's fee to the booking's fee alone, and nothing when there was none"
        $ property
        $ forAll ((,,) <$> fees <*> bonds <*> fees)
        $ \(fee, bond, preparation) ->
            let spent = bookingOutlay preprodParams [] (bookingWith fee bond)
                approved = Just (outlayTotal spent + 5_000_000)
                paid = withPreparationFee preparation spent
            in  ( withPreparationFee 0 spent
                , outlayBond paid
                , outlayFoldBound paid
                , leftForFold approved paid
                )
                    === ( spent
                        , outlayBond spent
                        , outlayFoldBound spent
                        , subtract preparation <$> leftForFold approved spent
                        )
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
    it "holds nothing back when the wallet covers what is required (#526)" $ do
        let outs = walletOf [10_000_000, 10_000_000]
            held = 10_000_000 + 10_000_000
        walletShortfall outs held `shouldBe` Nothing
        walletShortfall outs (held - 1) `shouldBe` Nothing
        walletShortfall outs 1 `shouldBe` Nothing
    it
        "names what the wallet lacks, to the lovelace, at the boundary (#526)"
        $ do
            let outs = walletOf [10_000_000, 10_000_000]
                held = 10_000_000 + 10_000_000
                fee = 10_000_000
                bond = 8_000_000
                bound = 5_000_000
                required = fee + bond + bound
            -- Well under: the shortfall is the arithmetic difference.
            walletShortfall outs required
                `shouldBe` Just (held, required - held)
            -- One lovelace under: still refused, shortfall of one.
            walletShortfall outs (held + 1) `shouldBe` Just (held, 1)
            -- An empty wallet holds nothing and lacks all of it.
            walletShortfall [] required `shouldBe` Just (0, required)
    it "totals every output the wallet holds, over more than one (#526)" $ do
        let outs = walletOf [1_000_000, 2_000_000, 3_000_000]
            held = 1_000_000 + 2_000_000 + 3_000_000
        walletShortfall outs (held + 500_000)
            `shouldBe` Just (held, 500_000)
        walletShortfall outs held `shouldBe` Nothing
  where
    fees = chooseInteger (155_381, 4_000_000) :: Gen Integer
    bonds = chooseInteger (2_000_000, 8_000_000) :: Gen Integer
    percentages = chooseInteger (100, 300) :: Gen Integer
