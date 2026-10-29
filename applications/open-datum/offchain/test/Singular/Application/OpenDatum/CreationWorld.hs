{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Singular.Application.OpenDatum.CreationWorld
Description : Both compiled validators on one chain, from the creation of a registry to its fold
License     : Apache-2.0

What the composed rows share. The request validator is the compiled script of
the application blueprint; the state validator is the compiled script of the
Singular blueprint with the request validator's hash applied as its parameter,
the way a registry's creation applies it. The chain is the raw chain fixture,
with the history of every transaction applied to it, behind a real session. A
transaction is judged by the ledger's own script evaluator, so every script it
runs, of either validator, answers.
-}
module Singular.Application.OpenDatum.CreationWorld
    ( -- * The world
      Creation (..)
    , newCreation
    , newCreationFor
    , withPublicScripts
    , withSession
    , applyTx
    , setSlot
    , Purpose (..)
    , judge
    , everyScriptAccepts
    , refusedBy
    , purposesRun

      -- * The creation of a registry
    , parameters
    , createRegistry
    , requestReferences
    , created
    , holderIndex
    , outputAddress
    , outputAtIndex
    , controllerOf
    , paidTo
    , soundnessProblems
    , mapRedeemers

      -- * Booking and folding
    , bookAs
    , pendingOf
    ) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Lens.Micro ((%~), (&), (^.))
import PlutusCore.Data qualified as PLC

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Inject (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Conway.TxBody (treasuryDonationTxBodyL)
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value (AssetName, MaryValue (..), PolicyID)
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.ByteString (ByteString)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session (..)
    )

import Data.Set qualified as Set
import Singular.Application.OpenDatum.RequestWorld
    ( ada
    , attachedScript
    , inlineDatum
    , keyAddress
    , network
    , outputsOf
    , seedIn
    , tokenQuantity
    , txInOf
    )
import Singular.Application.OpenDatum.Requests.Booking
    ( Booking
    , buildBookRegistration
    )
import Singular.Application.OpenDatum.Requests.Configuration
    ( configurationCreate
    )
import Singular.Application.OpenDatum.Requests.Records
    ( RequestParameters (..)
    , decodeRegistration
    )
import Singular.Application.OpenDatum.Requests.Refusal (Refusal)
import Singular.Application.OpenDatum.Requests.Script
    ( RequestScript (..)
    , referenceOutputs
    , requestAddress
    , requestPolicy
    )
import Singular.Registry.Blueprint (loadBlueprint)
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , jumpChainTo
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionIO (evaluateTx, withLatest)
import Singular.Registry.SyntheticLedger (withSyntheticCosts)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TrieState (RegistryIdentity)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.State.Genesis (buildGenesis)
import Singular.State.Publication
    ( Publication (..)
    , References (..)
    , planNextReference
    )
import Singular.State.Refusal qualified as State
import Singular.State.Script
    ( ScriptSource (..)
    , StateScript (..)
    , stateScriptFromBlueprint
    )
import System.Environment (lookupEnv)

-- | Both validators, the chain they run on and the parties.
data Creation = Creation
    { crChain :: RawChain
    , crRequest :: RequestScript
    , crState :: StateScript
    , crBooker :: Addr
    , crFolder :: Addr
    , crSeed :: TxIn
    }

{- | A chain at slot 10000 of the synthetic network: the booker holds the seed
and a wallet, a second party holds a wallet of its own, and nothing else
exists.
-}
newCreation :: IO Creation
newCreation = newCreationFor (keyAddress 0x41) (keyAddress 0x42)

-- | The same public chain, with the parties' explicit addresses.
newCreationFor :: Addr -> Addr -> IO Creation
newCreationFor booker folder = do
    request <- attachedScript
    path <-
        lookupEnv "SINGULAR_STATE_BLUEPRINT" >>= \case
            Just value | not (null value) -> pure value
            _ ->
                fail
                    "SINGULAR_STATE_BLUEPRINT is not set: the rows need the compiled state validator"
    blueprint <-
        loadBlueprint path >>= either (fail . ("blueprint: " <>)) pure
    state <-
        either (fail . ("state script: " <>)) pure $
            stateScriptFromBlueprint blueprint (requestPolicy request)
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = 42
                , csTip = Nothing
                , csPParams = withSyntheticCosts preprodParams
                , csUTxO =
                    Map.fromList
                        [ (seedIn, mkBasicTxOut booker (inject (ada 100)))
                        , (txInOf '2' 0, mkBasicTxOut booker (inject (ada 100)))
                        , (txInOf '3' 0, mkBasicTxOut folder (inject (ada 50)))
                        ]
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    jumpChainTo chain (SlotNo 10_000)
    pure
        Creation
            { crChain = chain
            , crRequest = request
            , crState = StateScript state Attached
            , crBooker = booker
            , crFolder = folder
            , crSeed = seedIn
            }

{- | Publish the two scripts in separate bounded transactions, preserving the
creation seed, then use the observed live copies. Attaching both scripts to a
composed transaction exceeds the real network's byte limit.
-}
withPublicScripts :: Creation -> IO Creation
withPublicScripts world = do
    References{referencesLive = live, referencesPublication = publication} <- withSession world $ \session ->
        planNextReference
            [crSeed world]
            session
            (crBooker world)
            [ssScript (crState world), rsScript (crRequest world)]
            >>= either (fail . show) pure
    case publication of
        Just planned -> do
            problems <- soundnessProblems world (publicationTx planned)
            if null problems then pure () else fail (show problems)
            applyTx world (publicationTx planned)
            withPublicScripts world
        Nothing -> do
            let reference script =
                    maybe
                        (fail "no public script copy")
                        (pure . Referenced . fst)
                        (lookup (hashScript script) live)
            stateSource <- reference (ssScript (crState world))
            requestSource <- reference (rsScript (crRequest world))
            pure
                world
                    { crState = (crState world){ssSource = stateSource}
                    , crRequest = (crRequest world){rsSource = requestSource}
                    }

-- | Acquire one session of the chain and use it.
withSession :: Creation -> (Session NoWitness IO -> IO a) -> IO a
withSession world = withLatest (rawChainProvider (crChain world))

-- | Move the tip to a slot.
setSlot :: Creation -> Word -> IO ()
setSlot world slot = jumpChainTo (crChain world) (SlotNo (fromIntegral slot))

-- | Apply a transaction as a block would, recording it in the history.
applyTx :: Creation -> ConwayTx -> IO ()
applyTx world tx = do
    recordTransaction (crChain world) tx
    advanceChain (crChain world) $ \facts ->
        facts
            { csUTxO =
                Map.union
                    (Map.fromList made)
                    ( foldr
                        Map.delete
                        (csUTxO facts)
                        (Set.toList (tx ^. bodyTxL . inputsTxBodyL))
                    )
            }
  where
    made =
        [ (TxIn (txIdTx tx) (TxIx ix), out)
        | (ix, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
        ]

-- | The script purposes a transaction of the line can carry.
data Purpose = Mint | Spend | Other
    deriving stock (Eq, Ord, Show)

-- | The ledger's answer for each script purpose.
type Judgement = [(Purpose, Either String ExUnits)]

-- | The ledger's script evaluator on the transaction.
judge :: Creation -> ConwayTx -> IO Judgement
judge world tx = do
    result <- withSession world (`evaluateTx` tx)
    pure
        [ (purposeOf p, either (Left . show) Right r)
        | (p, r) <- Map.toAscList result
        ]
  where
    purposeOf :: ConwayPlutusPurpose AsIx ConwayEra -> Purpose
    purposeOf = \case
        ConwayMinting _ -> Mint
        ConwaySpending _ -> Spend
        _ -> Other

-- | Every purpose ran and was accepted, using memory and steps.
everyScriptAccepts :: Judgement -> Bool
everyScriptAccepts verdicts = not (null verdicts) && all ok verdicts
  where
    ok (_, Right (ExUnits memory steps)) = memory > 0 && steps > 0
    ok _ = False

-- | Some purpose was refused by its script.
refusedBy :: Judgement -> Bool
refusedBy = any (either (const True) (const False) . snd)

-- | How many scripts of each purpose the judgement ran.
purposesRun :: Judgement -> [(Purpose, Int)]
purposesRun verdicts =
    Map.toList
        (Map.fromListWith (+) [(purpose, 1) | (purpose, _) <- verdicts])

-- | The parameters a registry's configuration record is created with.
parameters :: RequestParameters
parameters =
    RequestParameters
        { rpRegistrationCost = 2_000_000
        , rpMinimumTip = 1_000_000
        , rpProcessTime = 600_000
        , rpRetractTime = 600_000
        , rpBookingWidth = 60_000
        }

-- | The outputs that carry the request validator's code, when it is referenced.
requestReferences :: Creation -> IO [(TxIn, TxOut ConwayEra)]
requestReferences world =
    withSession world $ \session ->
        referenceOutputs session (crRequest world)
            >>= either (fail . show) pure

{- | The creation of the registry the seed names: the state builder's genesis
with the configuration record of the request validator added to it.
-}
createRegistry
    :: Creation -> IO (Either State.Refusal (ConwayTx, RegistryIdentity))
createRegistry world = do
    references <- requestReferences world
    withSession world $ \session ->
        buildGenesis
            session
            (crState world)
            (crSeed world)
            (crBooker world)
            references
            ( \registry ->
                configurationCreate
                    (crRequest world)
                    network
                    registry
                    (crSeed world)
                    parameters
            )

-- | The registry created and applied to the chain.
created :: Creation -> IO RegistryIdentity
created world = do
    (tx, registry) <- createRegistry world >>= either (fail . show) pure
    applyTx world tx
    pure registry

-- | Book a registration as the booker would and apply it.
bookAs :: Creation -> Booking -> IO (Either Refusal ConwayTx)
bookAs world booking =
    withSession world $ \session ->
        buildBookRegistration
            session
            (crRequest world)
            booking
            (crBooker world)

{- | The pending registration a booking transaction created: its output at the
request address that carries a registration.
-}
pendingOf :: Creation -> ConwayTx -> TxIn
pendingOf world tx =
    case [ ix
         | (ix, out) <- zip [0 ..] (outputsOf tx)
         , outputAddress out == requestAddress network (crRequest world)
         , Just _ <- [inlineDatum out >>= decodeRegistration network]
         ] of
        ix : _ -> TxIn (txIdTx tx) (TxIx ix)
        [] -> error "the booking created no pending registration"

-- | The output at a reference, when it is live.
liveOutput :: Creation -> TxIn -> IO (Maybe (TxOut ConwayEra))
liveOutput world ref = withSession world $ \session -> do
    answer <- outputs session (AtTxIn ref)
    pure $ case answer of
        Right (Evidenced [(_, out)] _) -> Just out
        _ -> Nothing

{- | The ledger rules a builder can break without a validator noticing, as the
problems found: the value the transaction spends and mints is not the value it
pays and burns as fee; an output holds less than its minimum ADA; scripts run
and no collateral is declared.
-}
soundnessProblems :: Creation -> ConwayTx -> IO [String]
soundnessProblems world tx = do
    spent <-
        mapM
            ( \ref ->
                liveOutput world ref
                    >>= maybe (fail ("no output " <> show ref)) pure
            )
            (Set.toList (body ^. inputsTxBodyL))
    let pp = withSyntheticCosts preprodParams
        Coin fee = body ^. feeTxBodyL
        valueIn =
            mconcat (map (^. valueTxOutL) spent)
                <> MaryValue (Coin 0) (body ^. mintTxBodyL)
        Coin donation = body ^. treasuryDonationTxBodyL
        valueOut =
            mconcat (map (^. valueTxOutL) (outputsOf tx))
                <> MaryValue (Coin (fee + donation)) mempty
        Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
        thin =
            [ i
            | (i, o) <- zip [0 :: Int ..] (outputsOf tx)
            , o ^. coinTxOutL < getMinCoinTxOut pp o
            ]
    pure $
        [ "value is not conserved: "
            <> show valueIn
            <> " in, "
            <> show valueOut
            <> " out"
        | valueIn /= valueOut
        ]
            <> [ "outputs " <> show thin <> " hold less than their minimum ADA"
               | not (null thin)
               ]
            <> [ "no collateral is declared"
               | not (Map.null declared) && Set.null (body ^. collateralInputsTxBodyL)
               ]
  where
    body = tx ^. bodyTxL

-- | Change the data of the redeemers of a transaction.
mapRedeemers
    :: (ConwayPlutusPurpose AsIx ConwayEra -> PLC.Data -> PLC.Data)
    -> ConwayTx
    -> ConwayTx
mapRedeemers change tx =
    tx
        & witsTxL . rdmrsTxWitsL
            %~ \(Redeemers declared) ->
                Redeemers
                    ( Map.mapWithKey
                        (\purpose (Data d, units) -> (Data (change purpose d), units))
                        declared
                    )

-- | The index of the first output of a transaction that holds a token once.
holderIndex :: PolicyID -> AssetName -> ConwayTx -> Int
holderIndex policy name tx =
    case [ ix
         | (ix, out) <- zip [0 ..] (outputsOf tx)
         , tokenQuantity policy name out == 1
         ] of
        ix : _ -> ix
        [] -> error "no output holds the token"

-- | The address an output pays.
outputAddress :: TxOut ConwayEra -> Addr
outputAddress out = out ^. addrTxOutL

-- | The output at an index of a transaction.
outputAtIndex :: ConwayTx -> Int -> Maybe (TxOut ConwayEra)
outputAtIndex tx index = case drop index (outputsOf tx) of
    out : _ -> Just out
    [] -> Nothing

-- | The payment key hash of a key address: the controller a booking commits.
controllerOf :: Addr -> ByteString
controllerOf = \case
    Addr _ (KeyHashObj (KeyHash hash)) _ -> hashToBytes hash
    _ -> error "not a key address"

-- | The lovelace the outputs of a transaction pay to an address.
paidTo :: Addr -> ConwayTx -> Integer
paidTo address tx =
    sum
        [ let Coin c = out ^. coinTxOutL in c
        | out <- outputsOf tx
        , outputAddress out == address
        ]
