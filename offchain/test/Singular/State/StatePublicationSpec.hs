{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.State.StatePublicationSpec
Description : The scripts of an application are published once and reused
License     : Apache-2.0

As the creator of the first registry of an application I publish the state
script and the application's script as reference scripts; as the creator of a
later registry I find the live copies and publish nothing. A reference output
that carries another script is never reused, whatever the provider answers for
the hash that was asked.
-}
module Singular.State.StatePublicationSpec
    ( spec
    ) where

import Data.List (sort)
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    )
import Singular.State.Publication
    ( Publication (..)
    , References (..)
    , planReferences
    )
import Singular.State.Script (StateScript (..))
import Singular.State.StateWorld

spec :: Spec
spec = do
    describe "the first registry of an application" $ do
        it
            "publishes both scripts in one transaction when no live copy exists"
            $ do
                sc <- publishing
                References live publication <- planned sc id
                live `shouldBe` []
                Publication tx located <- expectPublication publication
                sort (map fst located) `shouldBe` sort (wanted sc)
                mapM_
                    ( \(hash, TxIn txid (TxIx ix)) -> do
                        txid `shouldBe` txIdTx tx
                        let out = outputsOf tx !! fromIntegral ix
                        carried out `shouldBe` Just hash
                        outputAddress out `shouldBe` scPayer sc
                    )
                    located

        it
            "pays its way: value is conserved and every output holds its minimum"
            $ do
                sc <- publishing
                References _ publication <- planned sc id
                Publication tx _ <- expectPublication publication
                soundnessProblems (scWorld sc) tx `shouldReturn` []

        it
            "publishes exactly the scripts, whatever the order or repetition asked"
            $ do
                sc <- publishing
                References _ publication <-
                    withSession (scWorld sc) $ \session ->
                        planReferences
                            session
                            (scPayer sc)
                            [standIn, ssScript (scState sc), standIn]
                            >>= expectBuilt
                Publication _ located <- expectPublication publication
                sort (map fst located) `shouldBe` sort (wanted sc)

    describe "a later registry of the same application" $ do
        it "finds the live copies and publishes none" $ do
            sc <- publishing
            References _ first <- planned sc id
            Publication tx located <- expectPublication first
            applyTx (scWorld sc) tx
            References live later <- planned sc id
            fmap publicationTx later `shouldBe` Nothing
            sort (map fst live) `shouldBe` sort (wanted sc)
            sort [ref | (_, (ref, _)) <- live] `shouldBe` sort (map snd located)

        it "publishes only the script no output carries" $ do
            sc <- publishing
            let stateCopy = txInOf '5' 0
            addLive
                (scWorld sc)
                [(stateCopy, referenceHolder (scPayer sc) (ssScript (scState sc)))]
            References live partial <- planned sc id
            map fst live `shouldBe` [stateHash sc]
            map (fst . snd) live `shouldBe` [stateCopy]
            Publication _ located <- expectPublication partial
            map fst located `shouldBe` [standInHash]

    describe "a reference output that carries another script" $ do
        it "is never reused, whatever the provider answers for the hash asked" $ do
            sc <- publishing
            -- a provider that answers every hash with an output carrying another script
            let impostor = txInOf '6' 0
                lying session =
                    session
                        { outputs = \query -> case query of
                            CarryingReferenceScript _ ->
                                outputs session (AtTxIn impostor)
                            _ -> outputs session query
                        }
            addLive
                (scWorld sc)
                [(impostor, referenceHolder (scPayer sc) otherScript)]
            References live publication <- planned sc lying
            live `shouldBe` []
            Publication _ located <- expectPublication publication
            sort (map fst located) `shouldBe` sort (wanted sc)
  where
    planned sc through =
        withSession (scWorld sc) $ \session ->
            planReferences
                (through session)
                (scPayer sc)
                [ssScript (scState sc), standIn]
                >>= expectBuilt
    wanted sc = [stateHash sc, standInHash]
    stateHash sc = hashScript (ssScript (scState sc))
    carried :: TxOut ConwayEra -> Maybe ScriptHash
    carried out = case out ^. referenceScriptTxOutL of
        SJust script -> Just (hashScript script)
        SNothing -> Nothing

expectPublication :: Maybe Publication -> IO Publication
expectPublication = \case
    Just publication -> pure publication
    Nothing -> do
        expectationFailure "the plan publishes nothing"
        fail "no publication"

data Scenario = Scenario
    { scWorld :: World
    , scState :: StateScript
    , scPayer :: Addr
    }

publishing :: IO Scenario
publishing = do
    script <- stateScriptFor standInPolicy
    let payer = keyAddress 0x41
    world <-
        newWorld
            [ (txInOf '1' 0, mkBasicTxOut payer (inject (ada 100)))
            , (txInOf '2' 0, mkBasicTxOut payer (inject (ada 40)))
            ]
    pure (Scenario world script payer)
