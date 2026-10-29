{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

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
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Lens.Micro ((^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Alonzo.Scripts
    ( fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV2)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxIn (..))

import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    )
import Singular.Registry.SyntheticLedger (unitProgram)
import Singular.State.Assemble (assembleTransaction)
import Singular.State.Publication
    ( Publication (..)
    , ReferenceDiscovery (..)
    , References (..)
    , planReferences
    )
import Singular.State.Refusal (Refusal (..))
import Singular.State.Script
    ( ScriptSource (..)
    , StateScript (..)
    , referenceOutputs
    )
import Singular.State.StateWorld

spec :: Spec
spec = do
    describe "the first registry of an application" $ do
        it
            "publishes both scripts in one transaction when no live copy exists"
            $ do
                sc <- publishing
                References{referencesLive = live, referencesPublication = publication} <-
                    planned sc id
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
                References{referencesLive = _, referencesPublication = publication} <-
                    planned sc id
                Publication tx _ <- expectPublication publication
                soundnessProblems (scWorld sc) tx `shouldReturn` []

        it
            "publishes exactly the scripts, whatever the order or repetition asked"
            $ do
                sc <- publishing
                References{referencesLive = _, referencesPublication = publication} <-
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
            References{referencesLive = _, referencesPublication = first} <-
                planned sc id
            Publication tx located <- expectPublication first
            applyTx (scWorld sc) tx
            References{referencesLive = live, referencesPublication = later} <-
                planned sc id
            fmap publicationTx later `shouldBe` Nothing
            sort (map fst live) `shouldBe` sort (wanted sc)
            sort [ref | (_, (ref, _)) <- live] `shouldBe` sort (map snd located)

        it "publishes only the script no output carries" $ do
            sc <- publishing
            let stateCopy = txInOf '5' 0
            addLive
                (scWorld sc)
                [(stateCopy, referenceHolder (scPayer sc) (ssScript (scState sc)))]
            References{referencesLive = live, referencesPublication = partial} <-
                planned sc id
            map fst live `shouldBe` [stateHash sc]
            map (fst . snd) live `shouldBe` [stateCopy]
            Publication _ located <- expectPublication partial
            map fst located `shouldBe` [standInHash]

        it
            "publishes a spent copy again, exactly as when no live copy was found"
            $ do
                sc <- publishing
                References{referencesLive = _, referencesPublication = initial} <-
                    planned sc id
                Publication published located <- expectPublication initial
                applyTx (scWorld sc) published
                ref <-
                    maybe
                        (fail "state script not published")
                        pure
                        (lookup (stateHash sc) located)
                Just copy <- outputAt (scWorld sc) ref
                withSession
                    (scWorld sc)
                    ( \session -> referenceOutputs session (ssScript (scState sc)) (Referenced ref)
                    )
                    `shouldReturn` Right [(ref, copy)]
                spent <- withSession (scWorld sc) $ \session ->
                    assembleTransaction session [(ref, copy)] [] (scPayer sc) (pure ())
                        >>= expectBuilt
                soundnessProblems (scWorld sc) spent `shouldReturn` []
                applyTx (scWorld sc) spent
                withSession
                    (scWorld sc)
                    ( \session -> referenceOutputs session (ssScript (scState sc)) (Referenced ref)
                    )
                    `shouldReturn` Left (ReferenceScriptMissing ref)
                References{referencesLive = live, referencesPublication = later} <-
                    planned sc id
                map fst live `shouldBe` [standInHash]
                Publication _ replacements <- expectPublication later
                map fst replacements `shouldBe` [stateHash sc]
                map snd replacements `shouldNotContain` [ref]

    describe "scripts of another application" $ do
        it
            "publishes its own state script for another policy or application release"
            $ do
                sc <- publishing
                References{referencesLive = _, referencesPublication = first} <-
                    planned sc id
                Publication tx old <- expectPublication first
                applyTx (scWorld sc) tx
                mapM_
                    ( \policy -> do
                        own <- stateScriptFor policy
                        hashScript (ssScript own) `shouldNotBe` stateHash sc
                        References{referencesLive = live, referencesPublication = publication} <- withSession (scWorld sc) $ \session ->
                            planReferences session (scPayer sc) [ssScript own, standIn]
                                >>= expectBuilt
                        map fst live `shouldBe` [standInHash]
                        Publication _ new <- expectPublication publication
                        map fst new `shouldBe` [hashScript (ssScript own)]
                        map snd new `shouldNotContain` map snd old
                        oldRef <-
                            maybe
                                (fail "the old state script has no publication")
                                pure
                                (lookup (stateHash sc) old)
                        let expected = hashScript (ssScript own)
                            lying session =
                                session
                                    { outputs = \query -> case query of
                                        CarryingReferenceScript asked | asked == expected -> outputs session (AtTxIn oldRef)
                                        _ -> outputs session query
                                    }
                        checked <- withSession (scWorld sc) $ \session ->
                            planReferences (lying session) (scPayer sc) [ssScript own, standIn]
                                >>= expectBuilt
                        map fst (referencesLive checked) `shouldBe` [standInHash]
                        lookup
                            expected
                            [ (discoveryHash entry, discoveryCandidates entry)
                            | entry <- referencesDiscovery checked
                            ]
                            `shouldBe` Just [(oldRef, Just (stateHash sc))]
                    )
                    [ PolicyID (hashScript otherScript)
                    , PolicyID (hashScript applicationCode)
                    ]

        it "does not reuse identical program bytes under another language" $ do
            sc <- publishing
            let earlier :: Script ConwayEra
                earlier =
                    fromPlutusScript $
                        fromMaybe (error "valid older language") $
                            mkPlutusScript (Plutus @PlutusV2 (PlutusBinary (unitProgram 1)))
                wrong = txInOf '6' 0
                lying session =
                    session
                        { outputs = \query -> case query of
                            CarryingReferenceScript _ -> outputs session (AtTxIn wrong)
                            _ -> outputs session query
                        }
            hashScript earlier `shouldNotBe` standInHash
            addLive (scWorld sc) [(wrong, referenceHolder (scPayer sc) earlier)]
            withSession
                (scWorld sc)
                (\session -> referenceOutputs session standIn (Referenced wrong))
                `shouldReturn` Left
                    (ReferenceScriptMismatch wrong (Just (hashScript earlier)) standInHash)
            References{referencesLive = live, referencesPublication = publication} <-
                planned sc lying
            live `shouldBe` []
            Publication _ located <- expectPublication publication
            sort (map fst located) `shouldBe` sort (wanted sc)

    describe "a reference output that carries another script" $ do
        it
            "names a never-created explicit reference as missing, like a spent one"
            $ do
                sc <- publishing
                let missing = txInOf '6' 0
                withSession
                    (scWorld sc)
                    (\session -> referenceOutputs session standIn (Referenced missing))
                    `shouldReturn` Left (ReferenceScriptMissing missing)

        it "chooses the lowest genuine reference and skips foreign candidates" $ do
            sc <- publishing
            let low = txInOf '3' 0
                high = txInOf '4' 0
                wrong = txInOf '5' 0
                candidates =
                    [ (high, referenceHolder (scPayer sc) standIn)
                    , (wrong, referenceHolder (scPayer sc) otherScript)
                    , (low, referenceHolder (scPayer sc) standIn)
                    ]
                answering session =
                    session
                        { outputs = \query -> case query of
                            CarryingReferenceScript h
                                | h == standInHash ->
                                    outputs session (AnyOf (fmap AtTxIn (high :| [wrong, low])))
                            _ -> outputs session query
                        }
            addLive (scWorld sc) candidates
            References
                { referencesLive = live
                , referencesPublication = publication
                , referencesDiscovery = inspected
                } <-
                planned sc answering
            map (fst . snd) live `shouldBe` [low]
            [ (discoveryHash entry, sort (discoveryCandidates entry))
              | entry <- inspected
              ]
                `shouldBe` [ (stateHash sc, [])
                           ,
                               ( standInHash
                               , sort
                                    [ (high, Just standInHash)
                                    , (wrong, Just (hashScript otherScript))
                                    , (low, Just standInHash)
                                    ]
                               )
                           ]
            Publication _ located <- expectPublication publication
            map fst located `shouldBe` [stateHash sc]

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
            References{referencesLive = live, referencesPublication = publication} <-
                planned sc lying
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
