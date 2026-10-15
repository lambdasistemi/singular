{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.PrepareSpec
Description : One preparation transaction funds a wallet with no output to spend
License     : Apache-2.0

'planPreparation' makes an ada-only output holding the requirement from the
fewest largest-first spendable outputs, priced by the ledger's own
balancing. These rows pin that: conservation of every asset across the
transaction, no reference-script output ever spent, the remainder at or
above its minimum, the funding output first and exact, largest-first
prefix order, and the one-lovelace boundary where judgement and builder
agree. Generated wallets cover the properties; the boundary pair is
computed by search in a byte-stable range, so the verdict never depends
on encoding edges. Every amount compared after planning is read from the
planned transaction or the wallet, never typed.
-}
module Singular.Registry.TxBuilder.PrepareSpec (spec) where

import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , choose
    , chooseInteger
    , counterexample
    , forAll
    , property
    , vectorOf
    , (.&&.)
    , (===)
    )

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.TxBuilder.BookingFixture
    ( applicationPolicy
    , applicationScript
    , payer
    , preprodParams
    )
import Singular.Registry.TxBuilder.Prepare
    ( Preparation (..)
    , PrepareError (..)
    , planPreparation
    , spendableOuts
    )

spec :: Spec
spec = describe "one preparation transaction" $ do
    conservation
    noReferenceSpent
    remainderMinimum
    fundingFirstExact
    prefixOrder
    fewestDeterministic
    boundaryAgreement
    shortfalls

testPayer :: Addr
testPayer = payer

testParams :: PParams ConwayEra
testParams = preprodParams

outRef :: Char -> TxIn
outRef c =
    either (error . ("PrepareSpec fixture: " <>)) id $
        parseOutRef (T.pack (replicate 64 c <> "#0"))

adaAt :: Integer -> TxOut ConwayEra
adaAt n = mkBasicTxOut testPayer (MaryValue (Coin n) mempty)

tokenAt :: Integer -> TxOut ConwayEra
tokenAt n =
    mkBasicTxOut
        testPayer
        ( MaryValue
            (Coin n)
            ( MultiAsset
                ( Map.singleton
                    applicationPolicy
                    (Map.fromList [(AssetName "tok-a", 2), (AssetName "tok-b", 1)])
                )
            )
        )

refAt :: Integer -> TxOut ConwayEra
refAt n =
    mkBasicTxOut testPayer (MaryValue (Coin n) mempty)
        & referenceScriptTxOutL .~ SJust applicationScript

-- | The outputs of a planned transaction, in order.
txOutputs :: Preparation -> [TxOut ConwayEra]
txOutputs p = toList (prepTx p ^. (bodyTxL . outputsTxBodyL))

-- | The fee of a planned transaction, read from its body.
txFee :: Preparation -> Integer
txFee p = let Coin f = prepTx p ^. (bodyTxL . feeTxBodyL) in f

-- | Lovelace and tokens of one output.
assetsOf :: TxOut ConwayEra -> (Integer, MultiAsset)
assetsOf o =
    let MaryValue (Coin c) m = o ^. valueTxOutL
    in  (c, m)

{- | A generated wallet: one to four outputs, ada-only, token-carrying
and reference-script outputs mixed, amounts in a byte-stable range.
-}
genWallet :: Gen [(TxIn, TxOut ConwayEra)]
genWallet = do
    n <- choose (1, 4)
    outs <- vectorOf n genOutput
    pure (zipWith (\c o -> (outRef c, o)) "abcdef" outs)

genOutput :: Gen (TxOut ConwayEra)
genOutput = do
    lovelace <- chooseInteger (1_000_000, 5_000_000)
    kind <- choose (0, 2 :: Int)
    pure $ case kind of
        0 -> adaAt lovelace
        1 -> tokenAt lovelace
        _ -> refAt lovelace

{- | A generated wallet holding at least one reference-script output,
sometimes the largest.
-}
genWalletWithRef :: Gen [(TxIn, TxOut ConwayEra)]
genWalletWithRef = do
    base <- genWallet
    refLovelace <- chooseInteger (1_000_000, 8_000_000)
    pure (base <> [(outRef 'e', refAt refLovelace)])

genRequirement :: Gen Integer
genRequirement = chooseInteger (1_000_000, 2_000_000)

conservation :: Spec
conservation = describe "conservation" $ do
    it
        "every lovelace and token of the spends is in the funding plus the remainder"
        $ property
        $ forAll genWallet
        $ \w ->
            forAll genRequirement $ \r -> case planPreparation testParams testPayer r w of
                Left _ -> property True
                Right p -> case txOutputs p of
                    [fundOut, changeOut] ->
                        let (inAda, inMA) =
                                foldr
                                    (\(a1, m1) (a2, m2) -> (a1 + a2, m1 <> m2))
                                    (0, mempty)
                                    [assetsOf o | (_, o) <- prepSpent p]
                            (fundAda, fundMA) = assetsOf fundOut
                            (changeAda, changeMA) = assetsOf changeOut
                        in  (inAda === fundAda + txFee p + changeAda)
                                .&&. (inMA === fundMA <> changeMA)
                    _ -> counterexample "not two outputs" (property False)

noReferenceSpent :: Spec
noReferenceSpent = describe "reference scripts" $ do
    it
        "never spends an output carrying a reference script, whatever its size"
        $ property
        $ forAll genWalletWithRef
        $ \w ->
            forAll genRequirement $ \r -> case planPreparation testParams testPayer r w of
                Left _ -> property True
                Right p ->
                    let spentIns = map fst (prepSpent p)
                        refIns = [i | (i, o) <- w, o ^. referenceScriptTxOutL /= SNothing]
                    in  filter (`elem` spentIns) refIns === []

remainderMinimum :: Spec
remainderMinimum = describe "the remainder" $ do
    it "holds at or above the ledger minimum for its assets" $
        property $
            forAll genWallet $ \w ->
                forAll genRequirement $ \r -> case planPreparation testParams testPayer r w of
                    Left _ -> property True
                    Right p -> case txOutputs p of
                        [_, changeOut] ->
                            let Coin changeAda = changeOut ^. coinTxOutL
                                Coin changeMin = getMinCoinTxOut testParams changeOut
                            in  (changeAda >= changeMin) .&&. (changeAda === prepRemainderCoin p)
                        _ -> counterexample "not two outputs" (property False)

fundingFirstExact :: Spec
fundingFirstExact = describe "the funding output" $ do
    it
        "is the transaction's first output, ada only, holding the requirement"
        $ property
        $ forAll genWallet
        $ \w ->
            forAll genRequirement $ \r -> case planPreparation testParams testPayer r w of
                Left _ -> property True
                Right p -> case txOutputs p of
                    [fundOut, _] ->
                        let Coin fundAda = fundOut ^. coinTxOutL
                            MaryValue _ (MultiAsset fundMA) = fundOut ^. valueTxOutL
                        in  (prepFunding p === TxIn (txIdTx (prepTx p)) (TxIx 0))
                                .&&. (fundAda === r)
                                .&&. (fundAda === prepFundingCoin p)
                                .&&. (fundOut ^. referenceScriptTxOutL === SNothing)
                                .&&. Map.null fundMA
                    _ -> counterexample "not two outputs" (property False)

prefixOrder :: Spec
prefixOrder = describe "selection order" $ do
    it "spends a prefix of the largest-first spendable outputs" $
        property $
            forAll genWallet $ \w ->
                forAll genRequirement $ \r -> case planPreparation testParams testPayer r w of
                    Left _ -> property True
                    Right p ->
                        let ordered = sortOn (Down . (^. coinTxOutL) . snd) (spendableOuts w)
                        in  map fst (prepSpent p)
                                === map fst (take (length (prepSpent p)) ordered)

fewestDeterministic :: Spec
fewestDeterministic = describe "the fewest outputs" $ do
    it "spends one output alone when it covers funding, fee and remainder" $ do
        let w = [(outRef 'a', adaAt 5_000_000), (outRef 'b', adaAt 1_000_000)]
        case planPreparation testParams testPayer 1_500_000 w of
            Left err -> expectationFailure ("refused a covering wallet: " <> show err)
            Right p -> map fst (prepSpent p) `shouldBe` [outRef 'a']
    it
        "spends the largest first and takes a second only when one cannot cover"
        $ do
            -- Listed smaller-first: the 2 tADA output cannot leave a remainder
            -- above its minimum beside 1.5 tADA funding, so both are spent,
            -- largest first.
            let w = [(outRef 'a', adaAt 1_000_000), (outRef 'b', adaAt 2_000_000)]
            case planPreparation testParams testPayer 1_500_000 w of
                Left err -> expectationFailure ("refused a covering wallet: " <> show err)
                Right p -> map fst (prepSpent p) `shouldBe` [outRef 'b', outRef 'a']

boundaryAgreement :: Spec
boundaryAgreement = describe "the one-lovelace boundary" $ do
    it "accepts the searched smallest single-output wallet" $ do
        case accept (search requirement (requirement + 2_000_000)) of
            Left err ->
                expectationFailure ("refused the searched threshold: " <> show err)
            Right _ -> pure ()
    it "refuses one lovelace under it, naming the shortfall" $ do
        let threshold = search requirement (requirement + 2_000_000)
            feeAt = either (const Nothing) (Just . prepFee) (accept threshold)
        case accept (threshold - 1) of
            Right _ -> expectationFailure "accepted one lovelace under the threshold"
            Left (PrepareShortfall required fee remainderMin held largest) -> do
                required `shouldBe` requirement
                remainderMin `shouldBe` remainderFloor
                held `shouldBe` (threshold - 1)
                largest `shouldBe` (threshold - 1)
                fee `shouldBe` feeAt
  where
    requirement = 1_500_000
    remainderFloor =
        let Coin c = getMinCoinTxOut testParams (adaAt 0)
        in  c
    accept lovelace =
        planPreparation
            testParams
            testPayer
            requirement
            [(outRef 'a', adaAt lovelace)]
    search lo hi
        | lo >= hi = lo
        | otherwise =
            let mid = (lo + hi) `div` 2
            in  case accept mid of
                    Right _ -> search lo mid
                    Left _ -> search (mid + 1) hi

shortfalls :: Spec
shortfalls = describe "short wallets" $ do
    it "an empty wallet is refused with no measured fee and nothing held" $ do
        case planPreparation testParams testPayer 1_500_000 [] of
            Left (PrepareShortfall required fee remainderMin held largest) -> do
                required `shouldBe` 1_500_000
                fee `shouldBe` Nothing
                held `shouldBe` 0
                largest `shouldBe` 0
                remainderMin `shouldSatisfy` (> 0)
            Right _ -> expectationFailure "planned a preparation from nothing"
    it "reference-script outputs alone cannot fund" $ do
        let w = [(outRef 'a', refAt 8_000_000), (outRef 'b', refAt 9_000_000)]
        case planPreparation testParams testPayer 1_500_000 w of
            Left (PrepareShortfall _ fee _ held _) -> do
                fee `shouldBe` Nothing
                held `shouldBe` 0
            Right _ -> expectationFailure "spent a reference-script output"
