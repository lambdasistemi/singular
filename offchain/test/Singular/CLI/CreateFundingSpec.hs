{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.CreateFundingSpec
Description : A create completes or refuses before submitting anything
License     : Apache-2.0

Carol runs @create@ with an ordinary funded wallet (several ada-only
outputs, none needing a hand split): it either completes with every
reference script published and usable, or refuses before submitting
anything, naming what the wallet lacks. @create --preview@ gives the
same verdict. No half-made registries (#406, #478).

These rows run the entry points that exist on the base
('publicationFunding' and 'publishRefScriptTx' over a stub session):
a fragmented wallet of small outputs funds the run; a covering output
spends exactly one input and it is the largest; otherwise the shortest
largest-first prefix covers; the judgement and the builder agree at the
boundary; the refusal names total, largest and run need; an oversize
prefix is refused up front naming size and limit. Each expected value
is derived at run time from the producer, never typed.
-}
module Singular.CLI.CreateFundingSpec (spec) where

import Control.Exception (SomeException, try)
import Data.Foldable (toList)
import Data.List (isInfixOf)
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((^.))
import Numeric (showHex)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (inputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut)
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.Registry
    ( IdentityError (..)
    , publicationFunding
    , renderIdentityError
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.StubSession
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture
    ( applicationScript
    , payer
    , preprodParams
    )
import Singular.Registry.TxBuilder.Edges (publishRefScriptTx)

spec :: Spec
spec = do
    fragmentedFundsRun
    coveringChoosesOneLargest
    shortestPrefixCovers
    refusalNamesTotals
    oversizeRefusedUpFront
    boundaryAgrees

outRef :: Char -> TxIn
outRef c =
    either (error . ("CreateFundingSpec fixture: " <>)) id $
        parseOutRef (T.pack (replicate 64 c <> "#0"))

seedIn :: TxIn
seedIn = outRef '1'

fundRef :: Int -> TxIn
fundRef n =
    either (error . ("CreateFundingSpec fixture: " <>)) id $
        parseOutRef (T.pack (pad <> "#0"))
  where
    h = showHex n ""
    pad = replicate (64 - length h) '0' <> h

testPayer :: Addr
testPayer = payer

adaAt :: Integer -> TxOut ConwayEra
adaAt n = mkBasicTxOut testPayer (MaryValue (Coin n) mempty)

{- | One large publication before the boot, nothing after, small boot cost.
The script is the 9k application witness: a single small output cannot
cover it, but several together can.
-}
beforeOne :: [(T.Text, Script ConwayEra)]
beforeOne = [("state", applicationScript)]

bootCost :: Integer
bootCost = 5_000_000

fragmentedFundsRun :: Spec
fragmentedFundsRun = describe "a fragmented wallet funds the run" $ do
    it "five 10 tADA outputs fund one large publication" $ do
        let wallet =
                (seedIn, adaAt 5_000_000)
                    : [(fundRef n, adaAt 10_000_000) | n <- [0 .. 4]]
        publicationFunding preprodParams seedIn bootCost beforeOne [] wallet
            `shouldBe` Right ()

coveringChoosesOneLargest :: Spec
coveringChoosesOneLargest = describe "a covering output is chosen" $ do
    it "one covering output means exactly one input and it is the largest" $ do
        let wallet =
                [ (seedIn, adaAt 5_000_000)
                , (fundRef 0, adaAt 10_000_000)
                , (fundRef 1, adaAt 100_000_000)
                ]
        (tx, _) <- runPublish wallet applicationScript
        let spent = toList (tx ^. bodyTxL . inputsTxBodyL)
        spent `shouldBe` [fundRef 1]

shortestPrefixCovers :: Spec
shortestPrefixCovers = describe "the shortest largest-first prefix" $ do
    it "two 25 tADA outputs cover what one cannot, and no third is spent" $ do
        let wallet =
                [ (seedIn, adaAt 5_000_000)
                , (fundRef 0, adaAt 25_000_000)
                , (fundRef 1, adaAt 25_000_000)
                , (fundRef 2, adaAt 25_000_000)
                ]
        (tx, _) <- runPublish wallet applicationScript
        let spent = toList (tx ^. bodyTxL . inputsTxBodyL)
        length spent `shouldBe` 2
        spent `shouldContain` [fundRef 0]
        spent `shouldContain` [fundRef 1]

refusalNamesTotals :: Spec
refusalNamesTotals = describe "the refusal names total largest and run need" $ do
    it
        "begins publication-unfunded, ends nothing was submitted, names totals"
        $ do
            let wallet =
                    [ (seedIn, adaAt 5_000_000)
                    , (fundRef 0, adaAt 10_000_000)
                    , (fundRef 1, adaAt 10_000_000)
                    ]
            case publicationFunding preprodParams seedIn bootCost beforeOne [] wallet of
                Right _ -> expectationFailure "an unfundable wallet funded the run"
                Left err -> do
                    let text = renderIdentityError err
                    text `shouldSatisfy` ("publication-unfunded" `isInfixOf`)
                    text `shouldSatisfy` ("nothing was submitted" `isInfixOf`)
                    -- The new verdict names the totals in plain words; the base
                    -- names only the largest single output.
                    text `shouldSatisfy` ("total" `isInfixOf`)
                    text `shouldSatisfy` ("run" `isInfixOf`)

oversizeRefusedUpFront :: Spec
oversizeRefusedUpFront = describe "an oversize publication is refused up front" $ do
    it "many dust outputs are refused naming size and limit" $ do
        let dust = [(fundRef n, adaAt 200_000) | n <- [0 .. 499]]
            wallet = (seedIn, adaAt 5_000_000) : dust
            limit = preprodParams ^. ppMaxTxSizeL
        case publicationFunding preprodParams seedIn bootCost beforeOne [] wallet of
            Right _ -> expectationFailure "an oversize wallet funded the run"
            Left err -> do
                let text = renderIdentityError err
                text `shouldSatisfy` ("publication-unfunded" `isInfixOf`)
                text `shouldSatisfy` ("size" `isInfixOf`)
                text `shouldSatisfy` (show limit `isInfixOf`)

boundaryAgrees :: Spec
boundaryAgrees = describe "judgement and builder agree at the boundary" $ do
    it "the smallest covering multi-input wallet is accepted by both" $ do
        -- Derived at run time: the needed total from a probe refusal.
        needed <- case publicationFunding
            preprodParams
            seedIn
            bootCost
            beforeOne
            []
            [(seedIn, adaAt 5_000_000), (fundRef 0, adaAt 1_000_000)] of
            Right _ -> fail "a 1 tADA wallet funded a large publication"
            Left (PublicationUnfunded _ need _) -> pure need
            Left err -> fail ("unexpected refusal: " <> renderIdentityError err)
        -- Two outputs just under half each cannot cover alone; together
        -- they just cover past the strict minimum. One lovelace less
        -- refuses both.
        let half = needed `div` 2
            covering =
                [ (seedIn, adaAt 5_000_000)
                , (fundRef 0, adaAt half)
                , (fundRef 1, adaAt (needed - half + 1))
                ]
            short =
                [ (seedIn, adaAt 5_000_000)
                , (fundRef 0, adaAt half)
                , (fundRef 1, adaAt (needed - half))
                ]
        publicationFunding preprodParams seedIn bootCost beforeOne [] covering
            `shouldBe` Right ()
        case publicationFunding preprodParams seedIn bootCost beforeOne [] short of
            Right _ -> expectationFailure "one lovelace less still funded the run"
            Left _ -> pure ()
        (_, _) <- runPublish covering applicationScript
        refused <-
            try (runPublish short applicationScript)
                :: IO (Either SomeException (ConwayTx, TxOut ConwayEra))
        case refused of
            Left _ -> pure ()
            Right _ ->
                expectationFailure
                    "the builder still funded the one-lovelace-short wallet"
        pure ()

{- | Run the real builder against exact wallet outputs over a stub session,
reserving the seed as publications before the boot do.
-}
runPublish
    :: [(TxIn, TxOut ConwayEra)]
    -> Script ConwayEra
    -> IO (ConwayTx, TxOut ConwayEra)
runPublish wallet script = do
    let session =
            withAddressOutputs (\_ -> pure wallet) $
                withParameters preprodParams $
                    withTime (pure syntheticTime) stubSession
    publishRefScriptTx (Set.singleton seedIn) session testPayer script
