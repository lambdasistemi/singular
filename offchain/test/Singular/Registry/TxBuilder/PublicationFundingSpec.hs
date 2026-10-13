{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.PublicationFundingSpec
Description : One owner of the publication arithmetic
License     : Apache-2.0

The shortest largest-first prefix whose total covers the reference output
plus the fee plus a change strictly above the minimum funds a publication;
a covering output spends exactly one input and it is the largest. A shortfall
names needed, held and largest; an oversize prefix names size and limit.
-}
module Singular.Registry.TxBuilder.PublicationFundingSpec (spec) where

import Data.Text qualified as T
import Lens.Micro ((^.))
import Numeric (showHex)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.TxBuilder.BookingFixture
    ( applicationScript
    , payer
    , preprodParams
    )
import Singular.Registry.TxBuilder.Edges
    ( PublicationFundingError (..)
    , selectPublicationInputs
    )

spec :: Spec
spec = do
    selectsCovering
    selectsPrefix
    namesShortfall
    namesOversize

fundRef :: Int -> TxIn
fundRef n =
    either (error . ("PublicationFundingSpec fixture: " <>)) id $
        parseOutRef (T.pack (pad <> "#0"))
  where
    h = showHex n ""
    pad = replicate (64 - length h) '0' <> h

testPayer :: Addr
testPayer = payer

adaAt :: Integer -> TxOut ConwayEra
adaAt n = mkBasicTxOut testPayer (MaryValue (Coin n) mempty)

selectsCovering :: Spec
selectsCovering = describe "a covering output spends one largest input" $ do
    it "picks the largest when it covers" $ do
        let permitted =
                [(fundRef 0, adaAt 10_000_000), (fundRef 1, adaAt 100_000_000)]
        case selectPublicationInputs
            preprodParams
            testPayer
            applicationScript
            permitted of
            Left err -> expectationFailure ("not funded: " <> show err)
            Right (funds, _, _) -> map fst funds `shouldBe` [fundRef 1]

selectsPrefix :: Spec
selectsPrefix = describe "otherwise the shortest largest-first prefix" $ do
    it "spends two 25 tADA and never a third" $ do
        let permitted =
                [ (fundRef 0, adaAt 25_000_000)
                , (fundRef 1, adaAt 25_000_000)
                , (fundRef 2, adaAt 25_000_000)
                ]
        case selectPublicationInputs
            preprodParams
            testPayer
            applicationScript
            permitted of
            Left err -> expectationFailure ("not funded: " <> show err)
            Right (funds, _, change) -> do
                length funds `shouldBe` 2
                change `shouldSatisfy` (> 1_000_000)

namesShortfall :: Spec
namesShortfall = describe "a shortfall names needed held largest" $ do
    it "names all three totals" $ do
        let permitted = [(fundRef 0, adaAt 10_000_000), (fundRef 1, adaAt 10_000_000)]
        case selectPublicationInputs
            preprodParams
            testPayer
            applicationScript
            permitted of
            Right _ -> expectationFailure "an unfundable prefix funded"
            Left (PublicationShortfall needed held largest) -> do
                needed `shouldSatisfy` (> held)
                largest `shouldBe` 10_000_000
            Left err -> expectationFailure ("wrong refusal: " <> show err)

namesOversize :: Spec
namesOversize = describe "an oversize prefix names size and limit" $ do
    it "dust is refused up front" $ do
        let permitted = [(fundRef n, adaAt 200_000) | n <- [0 .. 499]]
            limit = fromIntegral (preprodParams ^. ppMaxTxSizeL)
        case selectPublicationInputs
            preprodParams
            testPayer
            applicationScript
            permitted of
            Right _ -> expectationFailure "an oversize prefix funded"
            Left (PublicationOversize size lim) -> do
                lim `shouldBe` limit
                size `shouldSatisfy` (> lim)
            Left err -> expectationFailure ("wrong refusal: " <> show err)
