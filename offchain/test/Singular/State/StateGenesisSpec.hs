{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.State.StateGenesisSpec
Description : The genesis builder meets the compiled state validator
License     : Apache-2.0

As the creator of a registry I spend a seed of mine and the state validator
accepts the transaction: one state token named from the seed, nothing else
minted under the state policy, one state output at the state address holding
only ADA and the token, with the empty root. The same transaction carries the
steps the application adds to the creation of its registry. Each row judges
the transaction with the ledger's own script evaluator against the compiled
validator, and is refused again when one fact of the transaction is made wrong.
-}
module Singular.State.StateGenesisSpec
    ( spec
    ) where

import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinData (..))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.TrieState (RegistryIdentity (..))
import Singular.Registry.TxBuilder.Internal (mkInlineDatum)
import Singular.State.Genesis (buildGenesis)
import Singular.State.Records (genesisRedeemer, stateDatum)
import Singular.State.Refusal (Refusal (..))
import Singular.State.Script
    ( StateScript (..)
    , stateAddress
    , statePolicy
    )
import Singular.State.StateWorld

spec :: Spec
spec = do
    describe "the compiled validator the rows judge with" $ do
        it "is the validator the identity manifest pins" $ do
            unapplied <- unappliedHash
            pinned <- pinnedUnappliedHash
            unapplied `shouldBe` pinned

        it
            "accepts a genesis assembled by hand and refuses it for another seed"
            $ do
                sc <- creation
                let hand = handGenesis (scScript sc) (scSeed sc) (ada 100)
                accepted <- judge (scWorld sc) hand
                everyScriptAccepts accepted `shouldBe` True
                purposesRun accepted `shouldBe` [(Mint, 1)]
                judgedOther <-
                    judge
                        (scWorld sc)
                        (mapRedeemers (\_ _ -> genesisRedeemer (txInOf '9' 9)) hand)
                refusedBy judgedOther `shouldBe` True

    describe "the built genesis" $ do
        it "is accepted by the compiled validator" $ do
            sc <- creation
            (tx, _) <- built sc
            judged <- judge (scWorld sc) tx
            everyScriptAccepts judged `shouldBe` True
            purposesRun judged `shouldBe` [(Mint, 1)]

        it
            "spends the seed and mints one state token named from it, and nothing else"
            $ do
                sc <- creation
                (tx, RegistryIdentity _ name) <- built sc
                inputsOf tx `shouldSatisfy` elem (scSeed sc)
                mintedOf tx `shouldBe` [(statePolicy (scScript sc), name, 1)]

        it
            "creates one state output at the state address with the token alone and the empty root"
            $ do
                sc <- creation
                (tx, RegistryIdentity _ name) <- built sc
                let policy = statePolicy (scScript sc)
                    holders = [out | out <- outputsOf tx, tokenQuantity policy name out == 1]
                length holders `shouldBe` 1
                state <- onlyOne holders
                assetsOf state `shouldBe` [(policy, name, 1)]
                inlineDatum state `shouldBe` Just (stateDatum (BS.replicate 32 0))
                outputAddress state `shouldBe` stateAddress network (scScript sc)

        it "returns the registry the seed creates under the state validator" $ do
            sc <- creation
            (_, registry) <- built sc
            registry `shouldBe` registryOf (scScript sc) (scSeed sc)

        it
            "pays its way: value is conserved, outputs hold their minimum, collateral is declared"
            $ do
                sc <- creation
                (tx, _) <- built sc
                soundnessProblems (scWorld sc) tx `shouldReturn` []

    describe "the steps the application adds" $ do
        it
            "are part of the same transaction and receive the registry it creates"
            $ do
                sc <- creation
                let step (RegistryIdentity _ (AssetName name)) = do
                        _ <-
                            Tx.payTo'
                                (keyAddress 0x55)
                                (MaryValue (ada 2) mempty)
                                (BuiltinData (PLC.B (SBS.fromShort name)))
                        pure ()
                (tx, RegistryIdentity _ (AssetName name)) <-
                    withSession (scWorld sc) $ \session ->
                        buildGenesis session (scScript sc) (scSeed sc) (scPayer sc) step
                            >>= expectBuilt
                [ inlineDatum out
                  | out <- outputsOf tx
                  , outputAddress out == keyAddress 0x55
                  ]
                    `shouldBe` [Just (PLC.B (SBS.fromShort name))]
                judged <- judge (scWorld sc) tx
                everyScriptAccepts judged `shouldBe` True

    describe
        "the validator refuses the genesis once one fact of it is made wrong"
        $ do
            it "a second token under the state policy is minted" $ do
                sc <- creation
                (tx, RegistryIdentity _ name) <- built sc
                let tokens =
                        MultiAsset
                            ( Map.singleton
                                (statePolicy (scScript sc))
                                (Map.fromList [(name, 1), (AssetName "extra", 1)])
                            )
                refused sc (withMint tokens tx)

            it "the root of the state output is not the empty root" $ do
                sc <- creation
                (tx, _) <- built sc
                refused
                    sc
                    ( mapOutput
                        0
                        ( \out ->
                            out & datumTxOutL .~ mkInlineDatum (stateDatum (BS.replicate 32 1))
                        )
                        tx
                    )

            it "the state token sits at another address" $ do
                sc <- creation
                (tx, _) <- built sc
                refused
                    sc
                    (mapOutput 0 (\out -> out & addrTxOutL .~ keyAddress 0x66) tx)

            it
                "the seed the redeemer names is not the one the token is named from"
                $ do
                    sc <- creation
                    (tx, _) <- built sc
                    refused sc (mapRedeemers (\_ _ -> genesisRedeemer (txInOf '9' 9)) tx)

            it "the state token is not minted" $ do
                sc <- creation
                (tx, _) <- built sc
                refused sc (withoutMintOf (statePolicy (scScript sc)) tx)

    describe "the builder declines before it builds" $ do
        it "a seed that the payer does not hold" $ do
            sc <- creation
            outcome <- declined sc (txInOf '7' 7) (scPayer sc)
            outcome `shouldBe` Left (SeedNotAtPayer (txInOf '7' 7))

        it "a payer whose address holds no ADA" $ do
            sc <- creation
            outcome <- declined sc (scSeed sc) (keyAddress 0x99)
            outcome `shouldBe` Left PayerHasNoFunding

        it "a payer that is a script" $ do
            sc <- creation
            outcome <- declined sc (scSeed sc) standInAddress
            outcome `shouldBe` Left PayerIsNotAKey

-- | A chain with a payer who holds the seed, and the state validator of the stand-in.
data Scenario = Scenario
    { scWorld :: World
    , scScript :: StateScript
    , scPayer :: Addr
    , scSeed :: TxIn
    }

creation :: IO Scenario
creation = do
    script <- stateScriptFor standInPolicy
    let payer = keyAddress 0x41
    world <-
        newWorld
            [ (seedOf, mkBasicTxOut payer (inject (ada 100)))
            , (txInOf '2' 0, mkBasicTxOut payer (inject (ada 10)))
            ]
    pure (Scenario world script payer seedOf)

-- | The genesis the builder returns for the scenario's seed, with no steps of the application.
built :: Scenario -> IO (ConwayTx, RegistryIdentity)
built sc =
    withSession (scWorld sc) $ \session ->
        buildGenesis
            session
            (scScript sc)
            (scSeed sc)
            (scPayer sc)
            (const (pure ()))
            >>= expectBuilt

-- | The builder's answer for a seed and a payer, reduced to its refusal.
declined :: Scenario -> TxIn -> Addr -> IO (Either Refusal ())
declined sc seed payer =
    withSession (scWorld sc) $ \session ->
        void
            <$> buildGenesis session (scScript sc) seed payer (const (pure ()))

-- | The validator refuses the transaction: some script purpose answers with a failure.
refused :: Scenario -> ConwayTx -> Expectation
refused sc tx = do
    judged <- judge (scWorld sc) tx
    refusedBy judged `shouldBe` True

-- | The single element of a list, or a failed row.
onlyOne :: [a] -> IO a
onlyOne = \case
    [one] -> pure one
    other -> do
        expectationFailure ("expected one, found " <> show (length other))
        fail "not one"
