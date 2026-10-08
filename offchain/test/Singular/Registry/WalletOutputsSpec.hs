{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.WalletOutputsSpec
Description : What each named selection of a wallet admits
License     : Apache-2.0

Alice holds a 300 ada script carrier, a large token holding and a plain
20 ada output, plus the burn-asset holdings the fold's negative mint
requires. Ordinary funding sees only the plain output; a chosen funding
input narrows it further or is refused; create's seed reserves; carriers
and burn candidates are named selections that funding never spends.
-}
module Singular.Registry.WalletOutputsSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (Testnet), StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TokenId (..))
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    )
import Singular.Registry.SessionIO (outputsAt)
import Singular.Registry.StateTokenFixture (refOf)
import Singular.Registry.StubSession
    ( stubSession
    , withAddressOutputs
    )
import Singular.Registry.TxBuilder.BookingFixture
    ( cfg
    , payer
    , tokenId
    )
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , mkRequestScript
    , policyIdFromPin
    )
import Singular.Registry.WalletOutputs

spec :: Spec
spec = describe "a wallet's named selections" $ do
    it "funds ordinary writes from the plain 20 ada output only" $ do
        w <- acquire
        map fst (fundingOutputs w) `shouldBe` [plainIn]
    it "never spends the carrier or the token holding as ordinary funding" $ do
        w <- acquire
        fundingOutputs w `shouldSatisfy` all (fundable . snd)
        fundable carrierOut `shouldBe` False
        fundable tokenOut `shouldBe` False
    it "narrows funding to the chosen plain output, and refuses any other choice" $ do
        w <- acquire
        fmap
            (map fst . fundingOutputs)
            (chosenFunding plainIn w)
            `shouldBe` Right [plainIn]
        [ either (const True) (const False) (chosenFunding i w)
          | i <- [carrierIn, tokenIn, refOf (T.replicate 64 "f" <> "#0")]
          ]
            `shouldBe` [True, True, True]
    it "keeps carriers and burn candidates when funding is narrowed" $ do
        w <- acquire
        case chosenFunding plainIn w of
            Left refusal -> expectationFailure (show refusal)
            Right narrowed -> do
                map fst (carriersOf (hashScript script) narrowed)
                    `shouldBe` [carrierIn]
                map fst (burnCandidates burnAsset narrowed)
                    `shouldBe` [holderIn, twiceIn]
    it "a narrowed session funds every later read from the chosen output, its other reads unchanged" $ do
        Right narrowed <- narrowFunding payer plainIn serving
        w <- acquireFrom narrowed
        map fst (fundingOutputs w) `shouldBe` [plainIn]
        map fst (carriersOf (hashScript script) w) `shouldBe` [carrierIn]
        map fst <$> outputsAt narrowed payer `shouldReturn` map fst wallet
        map fst <$> outputsAt narrowed elsewhere `shouldReturn` [elsewhereIn]
        w' <- acquireFrom narrowed
        map fst (fundingOutputs w') `shouldBe` [plainIn]
    it "a narrowing refuses an absent or ineligible choice as the input, a failed read as the read" $ do
        absent <-
            narrowFunding payer (refOf (T.replicate 64 "f" <> "#0")) serving
        ineligible <- narrowFunding payer carrierIn serving
        failed <- narrowFunding payer plainIn unreadable
        either describeRefusal (const "narrowed") absent `shouldBe` "input"
        either describeRefusal (const "narrowed") ineligible
            `shouldBe` "input"
        either describeRefusal (const "narrowed") failed `shouldBe` "read"
    it "takes create's seed only when it is plain, reserving it from funding" $ do
        w <- acquire
        fmap
            (\(u, v) -> (fst u, map fst (fundingOutputs v)))
            (seedOf plainIn w)
            `shouldBe` Right (plainIn, [])
        fmap (fst . fst) (seedOf carrierIn w)
            `shouldBe` Left SeedNotFundable
        fmap (fst . fst) (seedOf tokenIn w)
            `shouldBe` Left SeedNotFundable
        fmap
            (fst . fst)
            (seedOf (refOf (T.replicate 64 "f" <> "#0")) w)
            `shouldBe` Left SeedAbsent
    it "finds a script's carriers by the hash of the script each carries" $ do
        w <- acquire
        map fst (carriersOf (hashScript script) w)
            `shouldBe` [carrierIn]
        carriersOf
            (hashScript (mkRequestScript cfg otherToken))
            w
            `shouldBe` []
    it "offers a burn the outputs holding its asset, never another key's or policy's" $ do
        w <- acquire
        map fst (burnCandidates burnAsset w)
            `shouldBe` [holderIn, twiceIn]
    it "covers an amount from the smallest sufficient plain output" $ do
        w <- acquire
        fmap fst (coveringFunding 15_000_000 w) `shouldBe` Just plainIn
        fmap fst (coveringFunding 25_000_000 w) `shouldBe` Nothing
        fmap fst (coveringFunding 300_000_000 w) `shouldBe` Nothing
  where
    acquire = either (fail . show) pure =<< walletOutputs serving payer
    acquireFrom s = either (fail . show) pure =<< walletOutputs s payer
    describeRefusal = \case
        FundingInputRefusal _ -> "input" :: String
        FundingReadFailure _ -> "read"

-- ---------------------------------------------------------------------------
-- The wallet
-- ---------------------------------------------------------------------------

plainIn
    , carrierIn
    , tokenIn
    , holderIn
    , twiceIn
    , otherKeyIn
    , otherPolicyIn
    , elsewhereIn
        :: TxIn
plainIn = ref 'a'
carrierIn = ref 'c'
tokenIn = ref 'd'
holderIn = ref 'e'
twiceIn = ref '1'
otherKeyIn = ref '2'
otherPolicyIn = ref '3'
elsewhereIn = ref '4'

plainOut, carrierOut, tokenOut :: TxOut ConwayEra
plainOut = ada 20_000_000
carrierOut = ada 300_000_000 & referenceScriptTxOutL .~ SJust script
tokenOut = holding tokenPolicy "approval" 1 800_000_000

script :: Script ConwayEra
script = mkRequestScript cfg tokenId

burnAsset :: (PolicyID, AssetName)
burnAsset = (burnPolicy, AssetName "burn-key")

burnPolicy, tokenPolicy, otherPolicy :: PolicyID
burnPolicy = policyIdFromPin (SBS.toShort (BS.replicate 28 0xaa))
tokenPolicy = policyIdFromPin (SBS.toShort (BS.replicate 28 0xbb))
otherPolicy = policyIdFromPin (SBS.toShort (BS.replicate 28 0xcc))

otherToken :: TokenId
otherToken = TokenId (AssetName "another-registry")

wallet :: [(TxIn, TxOut ConwayEra)]
wallet =
    [ (plainIn, plainOut)
    , (carrierIn, carrierOut)
    , (tokenIn, tokenOut)
    , (holderIn, holding burnPolicy "burn-key" 1 2_000_000)
    , (twiceIn, holding burnPolicy "burn-key" 2 2_000_000)
    , (otherKeyIn, holding burnPolicy "another-key" 1 2_000_000)
    , (otherPolicyIn, holding otherPolicy "burn-key" 1 2_000_000)
    ]

ada :: Integer -> TxOut ConwayEra
ada c = mkBasicTxOut payer (MaryValue (Coin c) mempty)

holding
    :: PolicyID
    -> SBS.ShortByteString
    -> Integer
    -> Integer
    -> TxOut ConwayEra
holding policy name n c =
    mkBasicTxOut
        payer
        ( MaryValue
            (Coin c)
            (MultiAsset (Map.singleton policy (Map.singleton (AssetName name) n)))
        )

elsewhere :: Addr
elsewhere = addrFromKeyHashBytes Testnet (BS.replicate 28 0x44)

serving :: Session NoWitness IO
serving =
    withAddressOutputs
        ( \a ->
            pure $
                if a == payer
                    then wallet
                    else [(elsewhereIn, ada 7_000_000)]
        )
        stubSession

unreadable :: Session NoWitness IO
unreadable =
    serving
        { outputs = \case
            AtAddress _ -> pure (Left (BackendReadFailure "unreachable"))
            q -> outputs serving q
        }

ref :: Char -> TxIn
ref c = refOf (T.replicate 64 (T.singleton c) <> "#0")
