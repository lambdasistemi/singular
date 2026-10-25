{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.RequestConfigurationSpec
Description : The configuration record, composed into the creation of a registry
License     : Apache-2.0

As the author of the genesis builder I add the configuration record of the
registry to the transaction that creates it, with one step. The compiled
validator accepts the composition: the seed is spent, the state token is
minted once, and the record is the only birth of its token. The state policy is
a stand-in script here, because the validator reads only that the policy is
invoked and mints the one state token; the genesis itself is not built.
-}
module Singular.Application.OpenDatum.RequestConfigurationSpec
    ( spec
    ) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Void (Void)
import Lens.Micro ((&), (.~), (^.))
import PlutusCore.Data qualified as PLC
import Test.Hspec

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Inject (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.RequestWorld
    ( Purpose (..)
    , Scenario (..)
    , ada
    , addOutputs
    , applyTransaction
    , assetsOf
    , bookWithScript
    , chainSession
    , configuredParameters
    , everyScriptAccepts
    , expectBuilt
    , firstBooking
    , inlineDatum
    , judge
    , keyAddress
    , lookupOutput
    , mapOutput
    , mintedOf
    , network
    , newScenario
    , oracleConfiguration
    , outputsOf
    , redeemersOf
    , refusedBy
    , removeOutputs
    , seedIn
    , soundnessProblems
    , txInOf
    , validatorAddress
    , withDatum
    , withMint
    , withoutInput
    )
import Singular.Application.OpenDatum.Requests.Booking (Booking (..))
import Singular.Application.OpenDatum.Requests.Configuration
    ( configurationCreate
    )
import Singular.Application.OpenDatum.Requests.Records
    ( AsData (..)
    , RequestParameters (..)
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO (evaluateTx, parameters)
import Singular.Registry.SyntheticLedger (unitProgram)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal (scriptFromBytes)
import Singular.State.Preimage
    ( configurationTokenName
    , stateTokenName
    )

-- | A script that accepts everything, standing for the state policy of the registry.
standIn :: Script ConwayEra
standIn = scriptFromBytes "state stand-in" (unitProgram 1)

standInHash :: ScriptHash
standInHash = hashScript standIn

-- | The registry the seed creates, under the stand-in state policy.
genesisRegistry :: RegistryIdentity
genesisRegistry =
    RegistryIdentity
        (StatePolicyId (let ScriptHash h = standInHash in hashToBytes h))
        (stateTokenName seedIn)

stateName :: AssetName
stateName = stateTokenName seedIn

configurationName :: AssetName
configurationName = configurationTokenName genesisRegistry

-- | The parameters the record is created with, as the step takes them.
createdWith :: RequestParameters
createdWith =
    RequestParameters
        { rpRegistrationCost = 2_000_000
        , rpMinimumTip = 1_000_000
        , rpProcessTime = 600_000
        , rpRetractTime = 600_000
        , rpBookingWidth = 60_000
        }

-- | No queries: the creation reads nothing but the outputs it spends.
data NoQuery a

-- | A scenario with no record yet and the seed of the registry at the payer.
creationScenario :: IO Scenario
creationScenario = do
    sc <- newScenario (SlotNo 10_000)
    removeOutputs (scChain sc) [scRecord sc]
    addOutputs
        (scChain sc)
        [(seedIn, mkBasicTxOut (scPayer sc) (inject (ada 50)))]
    pure sc

-- | The step under test, for the scenario's validator.
theStep :: Scenario -> Tx.TxBuild q e ()
theStep sc =
    configurationCreate
        (scScript sc)
        network
        genesisRegistry
        seedIn
        createdWith

type Evaluator =
    ConwayTx
    -> IO (Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))

evaluator :: Session NoWitness IO -> Evaluator
evaluator session tx =
    Map.map (either (Left . show) Right) <$> evaluateTx session tx

-- | Build a transaction from these inputs, the program and a collateral input.
buildFrom
    :: Scenario
    -> TxIn
    -> [TxIn]
    -> Tx.TxBuild NoQuery Void ()
    -> IO (Either (Tx.BuildError Void) ConwayTx)
buildFrom sc collateral spent program = do
    let session = chainSession (scChain sc)
    pp <- parameters session
    resolved <- mapM (resolve sc) spent
    Tx.build
        (Tx.mkPParamsBound pp)
        (Tx.InterpretIO (const (pure undefined)))
        (evaluator session)
        resolved
        []
        (scPayer sc)
        (program >> Tx.collateral collateral)

resolve :: Scenario -> TxIn -> IO (TxIn, TxOut ConwayEra)
resolve sc ref =
    lookupOutput (scChain sc) ref
        >>= maybe (fail ("no output " <> show ref)) (pure . (,) ref)

-- | The creation of the registry: the seed is spent, the state token minted, the record added.
creationProgram :: Scenario -> Tx.TxBuild NoQuery Void ()
creationProgram sc = do
    _ <- Tx.spend seedIn
    Tx.mint
        (PolicyID standInHash)
        (Map.singleton stateName 1)
        (AsData (PLC.Constr 0 []))
    Tx.attachScript standIn
    theStep sc

creationTx :: Scenario -> IO ConwayTx
creationTx sc =
    buildFrom
        sc
        (scFunding sc)
        [seedIn, scFunding sc]
        (creationProgram sc)
        >>= expectBuilt

-- | The record: the output at the validator's address, with its index.
recordOutput :: Scenario -> ConwayTx -> Maybe (Int, TxOut ConwayEra)
recordOutput sc tx =
    listToMaybe
        [ (i, o)
        | (i, o) <- zip [0 ..] (outputsOf tx)
        , o ^. addrTxOutL == validatorAddress sc
        ]

-- | The output reference of the seed as the validator's redeemer holds it.
seedData :: PLC.Data
seedData = PLC.Constr 0 [PLC.B (BS.replicate 32 0x77), PLC.I 0]

nameBytes :: AssetName -> BS.ByteString
nameBytes (AssetName n) = SBS.fromShort n

type Mutation = Scenario -> Int -> ConwayTx -> ConwayTx

mutations :: [(String, Mutation)]
mutations =
    [ ("the seed is not spent", \_ _ -> withoutInput seedIn)
    ,
        ( "the state token is minted twice"
        , \sc _ -> withMint (mintOf sc 2 1)
        )
    ,
        ( "the configuration token is minted twice for one record"
        , \sc _ -> withMint (mintOf sc 1 2)
        )
    ,
        ( "the record holds another token besides its own"
        , \sc i -> mapOutput i (carryingBoth sc)
        )
    ,
        ( "the record is not a configuration"
        , \_ i -> mapOutput i (withDatum (PLC.I 1))
        )
    ,
        ( "the record sits at the address of a key"
        , \_ i -> mapOutput i (\o -> o & addrTxOutL .~ keyAddress 0x55)
        )
    ]
  where
    mintOf sc stateCount configurationCount =
        MultiAsset $
            Map.fromList
                [ (PolicyID standInHash, Map.singleton stateName stateCount)
                ,
                    ( PolicyID (scHash sc)
                    , Map.singleton configurationName configurationCount
                    )
                ]
    carryingBoth sc o =
        o
            & valueTxOutL
                .~ MaryValue
                    (Coin (3_000_000 :: Integer))
                    ( MultiAsset $
                        Map.fromList
                            [ (PolicyID (scHash sc), Map.singleton configurationName 1)
                            , (PolicyID standInHash, Map.singleton stateName 1)
                            ]
                    )

spec :: Spec
spec = do
    describe
        "the creation transaction of a registry with the configuration step in it"
        $ do
            it "is accepted by the compiled validator" $ do
                sc <- creationScenario
                tx <- creationTx sc
                verdicts <- judge (scChain sc) tx
                map fst verdicts `shouldBe` [Mint, Mint]
                verdicts `shouldSatisfy` everyScriptAccepts

            it "is a transaction the ledger can balance" $ do
                sc <- creationScenario
                tx <- creationTx sc
                _ <- maybe (fail "no record output") pure (recordOutput sc tx)
                soundnessProblems (scChain sc) tx `shouldReturn` []

            it
                "adds the record at the validator's address, holding exactly its token, with the parameters inline"
                $ do
                    sc <- creationScenario
                    tx <- creationTx sc
                    (_, record) <-
                        maybe (fail "no record output") pure (recordOutput sc tx)
                    assetsOf record
                        `shouldBe` [(PolicyID (scHash sc), configurationName, 1)]
                    inlineDatum record
                        `shouldBe` Just (oracleConfiguration configuredParameters)

            it "mints the one configuration token beside the one state token" $ do
                sc <- creationScenario
                tx <- creationTx sc
                sort (mintedOf tx)
                    `shouldBe` sort
                        [ (PolicyID (scHash sc), configurationName, 1)
                        , (PolicyID standInHash, stateName, 1)
                        ]

            it "names the output of the record in its mint action" $ do
                sc <- creationScenario
                tx <- creationTx sc
                (ix, _) <- maybe (fail "no record output") pure (recordOutput sc tx)
                let RegistryIdentity (StatePolicyId policy) _ = genesisRegistry
                    expected =
                        PLC.List
                            [ PLC.Constr
                                0
                                [ PLC.B policy
                                , PLC.B (nameBytes stateName)
                                , seedData
                                , PLC.I (toInteger ix)
                                ]
                            ]
                redeemersOf tx `shouldSatisfy` elem expected

            it "leaves a record that a booking of the registry reads" $ do
                sc <- creationScenario
                tx <- creationTx sc
                applyTransaction (scChain sc) tx
                booked <-
                    bookWithScript
                        sc
                        (scScript sc)
                        firstBooking{bookRegistry = genesisRegistry}
                        >>= expectBuilt
                verdicts <- judge (scChain sc) booked
                verdicts `shouldSatisfy` everyScriptAccepts

            describe "the validator refuses it again" $
                forM_ mutations $ \(name, mutate) ->
                    it ("when " <> name) $ do
                        sc <- creationScenario
                        tx <- creationTx sc
                        accepted <- judge (scChain sc) tx
                        accepted `shouldSatisfy` everyScriptAccepts
                        (ix, _) <- maybe (fail "no record output") pure (recordOutput sc tx)
                        refused <- judge (scChain sc) (mutate sc ix tx)
                        refused `shouldSatisfy` refusedBy

    describe "a later transaction" $
        it "cannot add a second record for the registry" $ do
            sc <- creationScenario
            tx <- creationTx sc
            applyTransaction (scChain sc) tx
            -- The seed is spent and the state token is not minted again; the
            -- later transaction is funded by another output of the payer.
            let spare = txInOf '4' 0
            later <- buildFrom sc spare [spare] (theStep sc)
            case later of
                Left (Tx.EvalFailure _ _) -> pure ()
                other ->
                    expectationFailure
                        ( "expected the validator to refuse the second record, got "
                            <> either show (const "a transaction") other
                        )
