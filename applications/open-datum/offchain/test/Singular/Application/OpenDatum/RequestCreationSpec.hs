{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.RequestCreationSpec
Description : The creation of a registry of open datum meets both compiled validators
License     : Apache-2.0

As the creator of a registry of open datum I spend a seed of mine, and one
transaction creates the registry's state and its configuration record. The
state validator and the request validator both run on it and both accept it:
the state token is minted once and the record is the only birth of its token.
The record carries the five parameters I chose and is created once, whatever
the steps of the application ask.
-}
module Singular.Application.OpenDatum.RequestCreationSpec
    ( spec
    ) where

import Control.Monad (void)
import Data.Text qualified as T
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Ledger.Api.Tx.Out (addrTxOutL)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.CreationWorld
import Singular.Application.OpenDatum.RequestWorld
    ( assetsOf
    , inlineDatum
    , keyAddress
    , mapOutput
    , mintedOf
    , network
    , outputsOf
    , tokenQuantity
    , txInOf
    )
import Singular.Application.OpenDatum.Requests.Configuration
    ( configurationCreate
    )
import Singular.Application.OpenDatum.Requests.Records
    ( decodeConfiguration
    )
import Singular.Application.OpenDatum.Requests.Script
    ( requestPolicy
    )
import Singular.Registry.TrieState (RegistryIdentity (..))
import Singular.State.Genesis (buildGenesis)
import Singular.State.Preimage (configurationTokenName, seedData)
import Singular.State.Refusal (Refusal (..))
import Singular.State.Script (statePolicy)

spec :: Spec
spec = do
    describe
        "the creation of a registry, built with its configuration record"
        $ do
            it "is accepted by both compiled validators" $ do
                world <- newCreation
                (tx, _) <- createRegistry world >>= either (fail . show) pure
                judged <- judge world tx
                everyScriptAccepts judged `shouldBe` True
                purposesRun judged `shouldBe` [(Mint, 2)]

            it
                "mints the state token and the configuration token once each, and nothing else"
                $ do
                    world <- newCreation
                    (tx, registry@(RegistryIdentity _ stateName)) <-
                        createRegistry world >>= either (fail . show) pure
                    mintedOf tx
                        `shouldMatchList` [ (statePolicy (crState world), stateName, 1)
                                          , (requestPolicy (crRequest world), configurationTokenName registry, 1)
                                          ]

            it
                "creates one configuration record at the request address, holding its token alone, with the parameters inline"
                $ do
                    world <- newCreation
                    (tx, registry) <- createRegistry world >>= either (fail . show) pure
                    let policy = requestPolicy (crRequest world)
                        name = configurationTokenName registry
                        records = [out | out <- outputsOf tx, tokenQuantity policy name out == 1]
                    length records `shouldBe` 1
                    case records of
                        [found] -> do
                            assetsOf found `shouldBe` [(policy, name, 1)]
                            (inlineDatum found >>= decodeConfiguration) `shouldBe` Just parameters
                        _ -> expectationFailure "not exactly one record"

            it
                "pays its way: value is conserved, outputs hold their minimum, collateral is declared"
                $ do
                    world <- newCreation
                    (tx, _) <- createRegistry world >>= either (fail . show) pure
                    soundnessProblems world tx `shouldReturn` []

    describe "the two validators judge the same transaction" $ do
        it
            "the request validator refuses once the record sits at another address"
            $ do
                world <- newCreation
                (tx, registry) <- createRegistry world >>= either (fail . show) pure
                refused world (moveRecord world registry tx)

        it
            "the request validator refuses once its redeemer names another seed"
            $ do
                world <- newCreation
                (tx, _) <- createRegistry world >>= either (fail . show) pure
                refused world (mapRedeemers (otherSeed (txInOf '9' 9)) tx)

    describe "a second configuration record" $ do
        it
            "stops the build: the request validator refuses the creation, which one record passes"
            $ do
                world <- newCreation
                single <- createRegistry world
                void single `shouldBe` Right ()
                references <- requestReferences world
                outcome <-
                    withSession world $ \session ->
                        buildGenesis
                            session
                            (crState world)
                            (crSeed world)
                            (crBooker world)
                            references
                            ( \registry -> do
                                record world registry
                                record world registry
                            )
                case outcome of
                    Left (BuildFailed message) ->
                        T.unpack message `shouldContain` "EvalFailure (ConwayMinting"
                    Left other -> expectationFailure ("another refusal: " <> show other)
                    Right _ -> expectationFailure "the creation with two records was built"
  where
    record world registry =
        configurationCreate
            (crRequest world)
            network
            registry
            (crSeed world)
            parameters
    refused world tx = do
        judged <- judge world tx
        refusedBy judged `shouldBe` True

{- | The transaction with the configuration record at an address that is not
the request validator's.
-}
moveRecord :: Creation -> RegistryIdentity -> ConwayTx -> ConwayTx
moveRecord world registry tx =
    mapOutput
        ( holderIndex
            (requestPolicy (crRequest world))
            (configurationTokenName registry)
            tx
        )
        (\out -> out & addrTxOutL .~ keyAddress 0x66)
        tx

{- | Name another seed in the request validator's redeemer, and leave the
state policy's redeemer as it is.
-}
otherSeed :: TxIn -> a -> PLC.Data -> PLC.Data
otherSeed seed _ = \case
    PLC.List [PLC.Constr 0 [policy, name, _, output]] ->
        PLC.List [PLC.Constr 0 [policy, name, seedData seed, output]]
    other -> other
