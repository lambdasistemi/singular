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

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (forM_, toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
import Test.QuickCheck
    ( Gen
    , Property
    , checkCoverage
    , choose
    , chooseInteger
    , counterexample
    , cover
    , elements
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
    , PolicyID
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
import Singular.Registry.TxBuilder.Internal (policyIdFromPin)
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
    sharedPolicies

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

{- | As Alice, my approvals sit in several outputs, some of them under one
policy. Planning a preparation from them must not lose or merge any of
them: the remainder holds, asset by asset, exactly what the spent outputs
held, and a wallet that holds more than the preparation needs is planned,
not refused as short. The sums below are written independently of the
planner (one key per policy and asset name, added), never the planner's own
combination of the outputs' maps.
-}
sharedPolicies :: Spec
sharedPolicies = describe "outputs that share a policy" $ do
    forM_ sharedWallets $ \(label, wallet) ->
        it ("plans a wallet of " <> label <> " and conserves every asset") $
            case planPreparation testParams testPayer 1_500_000 wallet of
                Left err ->
                    expectationFailure
                        ( "refused a wallet holding "
                            <> show (heldBy wallet)
                            <> " lovelace for a requirement of 1500000: "
                            <> show err
                        )
                Right p -> expectAssetsConserved wallet p
    it
        "plans from several outputs and conserves each asset, whatever policies and names they share"
        $ checkCoverage
        $ forAll genSharedWallet
        $ \w ->
            forAll genRequirement $ \r -> case planPreparation testParams testPayer r w of
                Left err ->
                    counterexample
                        ( "refused a wallet holding "
                            <> show (heldBy w)
                            <> " lovelace for a requirement of "
                            <> show r
                            <> ": "
                            <> show err
                        )
                        (property False)
                Right p ->
                    cover 25 (length (prepSpent p) > 1) "spends several outputs" $
                        conservedAssets w p
    it
        "a wallet too short to plan names the ledger minimum for returning every asset it holds, shared policy included"
        $ do
            let wallet =
                    [ (i, setCoin 600_000 o)
                    | (i, o) <-
                        sharedWalletOf
                            [ (applicationPolicy, "tok-a", 3)
                            , (applicationPolicy, "tok-b", 5)
                            ]
                    ]
                held = perAsset (map snd wallet)
                everything =
                    mkBasicTxOut
                        testPayer
                        ( MaryValue
                            (Coin 0)
                            ( MultiAsset
                                ( Map.fromListWith
                                    (Map.unionWith (+))
                                    [(p, Map.singleton n q) | ((p, n), q) <- Map.toList held]
                                )
                            )
                        )
                Coin floorForAll = getMinCoinTxOut testParams everything
            case planPreparation testParams testPayer 1_500_000 wallet of
                Right _ ->
                    expectationFailure
                        "planned a preparation from a wallet holding less than the requirement"
                Left (PrepareShortfall required _ remainderMin heldAda _) -> do
                    required `shouldBe` 1_500_000
                    heldAda `shouldBe` heldBy wallet
                    remainderMin `shouldBe` floorForAll
    it
        "a wallet too short to plan prices the return of a shared name at the sum of its quantities, across a size boundary of the encoding"
        $ do
            let wallet =
                    [ (i, setCoin 1_200_000 o)
                    | (i, o) <-
                        sharedWalletOf
                            [ (applicationPolicy, "tok-a", 17)
                            , (applicationPolicy, "tok-a", 17)
                            ]
                    ]
                summed = perAsset (map snd wallet)
                holding quantities =
                    mkBasicTxOut
                        testPayer
                        ( MaryValue
                            (Coin 0)
                            ( MultiAsset
                                ( Map.fromListWith
                                    (Map.unionWith (+))
                                    [(p, Map.singleton n q) | ((p, n), q) <- Map.toList quantities]
                                )
                            )
                        )
                Coin floorForSum = getMinCoinTxOut testParams (holding summed)
                Coin floorForOne =
                    getMinCoinTxOut
                        testParams
                        (holding (perAsset (map snd (take 1 wallet))))
            -- the instrument sees the boundary: 17 and 34 are one and two
            -- bytes of the encoding, so their minimums differ
            summed
                `shouldBe` Map.singleton (applicationPolicy, AssetName "tok-a") 34
            floorForSum `shouldSatisfy` (> floorForOne)
            case planPreparation testParams testPayer 3_000_000 wallet of
                Right _ ->
                    expectationFailure
                        "planned a preparation from a wallet holding less than the requirement"
                Left (PrepareShortfall required _ remainderMin heldAda _) -> do
                    required `shouldBe` 3_000_000
                    heldAda `shouldBe` heldBy wallet
                    remainderMin `shouldBe` floorForSum
    it "the independent sums tell a shared policy's two names from one" $ do
        -- a negative control for the instrument itself: the sums keep
        -- every (policy, name) pair, so a combination that drops one differs
        let w =
                snd
                    <$> sharedWalletOf
                        [(applicationPolicy, "tok-a", 3), (applicationPolicy, "tok-b", 5)]
        perAsset w
            `shouldBe` Map.fromList
                [ ((applicationPolicy, AssetName "tok-a"), 3)
                , ((applicationPolicy, AssetName "tok-b"), 5)
                ]
        perAsset (w <> w)
            `shouldBe` Map.fromList
                [ ((applicationPolicy, AssetName "tok-a"), 6)
                , ((applicationPolicy, AssetName "tok-b"), 10)
                ]
  where
    sharedWallets =
        [
            ( "two outputs, one policy, two names"
            , sharedWalletOf
                [(applicationPolicy, "tok-a", 3), (applicationPolicy, "tok-b", 5)]
            )
        ,
            ( "two outputs, one policy, the same name"
            , sharedWalletOf
                [(applicationPolicy, "tok-a", 3), (applicationPolicy, "tok-a", 5)]
            )
        ,
            ( "two outputs, two policies"
            , sharedWalletOf
                [(applicationPolicy, "tok-a", 3), (otherPolicy, "tok-b", 5)]
            )
        ,
            ( "one output holding both names"
            ,
                [
                    ( outRef 'a'
                    , mkBasicTxOut
                        testPayer
                        ( MaryValue
                            (Coin (2 * sharedAda))
                            ( MultiAsset
                                ( Map.singleton
                                    applicationPolicy
                                    (Map.fromList [(AssetName "tok-a", 3), (AssetName "tok-b", 5)])
                                )
                            )
                        )
                    )
                ]
            )
        ]

-- | Each output of the shared-policy wallets holds this much: little ada.
sharedAda :: Integer
sharedAda = 2_300_000

-- | A policy the application's does not share.
otherPolicy :: PolicyID
otherPolicy = policyIdFromPin (SBS.toShort (BS.replicate 28 7))

-- | One token-carrying output per (policy, name, quantity), each with 'sharedAda'.
sharedWalletOf
    :: [(PolicyID, SBS.ShortByteString, Integer)]
    -> [(TxIn, TxOut ConwayEra)]
sharedWalletOf holdings =
    [ ( outRef c
      , mkBasicTxOut
            testPayer
            ( MaryValue
                (Coin sharedAda)
                ( MultiAsset
                    (Map.singleton policy (Map.singleton (AssetName name) quantity))
                )
            )
      )
    | (c, (policy, name, quantity)) <- zip "abcdef" holdings
    ]

-- | An output with its lovelace set.
setCoin :: Integer -> TxOut ConwayEra -> TxOut ConwayEra
setCoin lovelace o = o & coinTxOutL .~ Coin lovelace

-- | The lovelace a wallet holds, added.
heldBy :: [(TxIn, TxOut ConwayEra)] -> Integer
heldBy w = sum [c | (_, o) <- w, let (c, _) = assetsOf o]

{- | The quantity of every (policy, name) a list of outputs holds, added by
key: independent of the planner and of any semigroup on the maps.
-}
perAsset :: [TxOut ConwayEra] -> Map.Map (PolicyID, AssetName) Integer
perAsset outs =
    Map.fromListWith
        (+)
        [ ((policy, name), q)
        | o <- outs
        , let MaryValue _ (MultiAsset m) = o ^. valueTxOutL
        , (policy, names) <- Map.toList m
        , (name, q) <- Map.toList names
        ]

{- | A planned preparation conserves every asset: its funding output holds
none, its remainder holds, asset by asset, what the spent outputs held, and
that plus what stayed unspent is what the wallet held.
-}
conservedAssets
    :: [(TxIn, TxOut ConwayEra)] -> Preparation -> Property
conservedAssets w p = case txOutputs p of
    [fundOut, changeOut] ->
        let spentOuts = map snd (prepSpent p)
            spentIns = map fst (prepSpent p)
            unspent = [o | (i, o) <- w, i `notElem` spentIns]
        in  (perAsset [fundOut] === Map.empty)
                .&&. (perAsset [changeOut] === perAsset spentOuts)
                .&&. ( Map.unionWith (+) (perAsset [changeOut]) (perAsset unspent)
                        === perAsset (map snd w)
                     )
    _ -> counterexample "not two outputs" (property False)

expectAssetsConserved
    :: [(TxIn, TxOut ConwayEra)] -> Preparation -> Expectation
expectAssetsConserved w p =
    case txOutputs p of
        [fundOut, changeOut] -> do
            let spentIns = map fst (prepSpent p)
            perAsset [fundOut] `shouldBe` Map.empty
            perAsset [changeOut] `shouldBe` perAsset (map snd (prepSpent p))
            Map.unionWith
                (+)
                (perAsset [changeOut])
                (perAsset [o | (i, o) <- w, i `notElem` spentIns])
                `shouldBe` perAsset (map snd w)
        _ -> expectationFailure "the preparation is not two outputs"

{- | A generated wallet of three to five token-carrying outputs with little
ada each, whose policies and asset names overlap (two policies, three names)
and whose quantities differ.
-}
genSharedWallet :: Gen [(TxIn, TxOut ConwayEra)]
genSharedWallet = do
    n <- choose (3, 5)
    outs <- vectorOf n genSharedOutput
    pure (zipWith (\c o -> (outRef c, o)) "abcdef" outs)

genSharedOutput :: Gen (TxOut ConwayEra)
genSharedOutput = do
    lovelace <- chooseInteger (2_000_000, 3_000_000)
    policy <- elements [applicationPolicy, otherPolicy]
    count <- choose (1, 2)
    named <-
        vectorOf
            count
            ((,) <$> elements ["tok-a", "tok-b", "tok-c"] <*> chooseInteger (1, 9))
    pure
        ( mkBasicTxOut
            testPayer
            ( MaryValue
                (Coin lovelace)
                ( MultiAsset
                    ( Map.singleton
                        policy
                        (Map.fromList [(AssetName name, q) | (name, q) <- named])
                    )
                )
            )
        )

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
