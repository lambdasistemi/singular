{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.State.Assemble
Description : What the state builders share: the payer, the chain reads and the assembly
License     : Apache-2.0

A state transaction is built from facts read before it is built: the payer's
funding output, the outputs it spends or reads, and the slot the chain has
reached. This module reads the payer, answers an output query without losing
the difference between an absent output and a failed read, picks a validity
interval that starts at the tip, and hands a transaction program to the
transaction builder with the session's own script evaluator, so a script the
validator refuses stops the build.
-}
module Singular.State.Assemble
    ( -- * Programs
      NoQuery
    , Program

      -- * The payer
    , Payer (..)
    , PayerFault (..)
    , findPayer
    , resolvePayer
    , resolvePayerReserving

      -- * Reading the chain
    , readOutputs
    , inlineDatumOf
    , holdsOnly
    , tipSlot
    , validityFromTip

      -- * Assembly
    , assemble
    , assembleTransaction
    ) where

import Control.Exception (Exception, throwIO, try)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (lefts)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC
import PlutusCore.Evaluation.Machine.ExBudget
    ( ExRestrictingBudget (..)
    )
import PlutusCore.Evaluation.Machine.Exception qualified as Machine
import PlutusLedgerApi.Common qualified as Plutus
import UntypedPlutusCore.Evaluation.Machine.Cek qualified as Cek

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Plutus.Evaluate
    ( TransactionScriptFailure (..)
    )
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL, ppMaxTxSizeL)
import Cardano.Ledger.Api.Scripts.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )
import Cardano.Ledger.Api.Tx (witsTxL)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (Guard))
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, PParams, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery
    , Outputs
    , ReadFailure
    , Session (..)
    , TipObservation (..)
    )
import Singular.Registry.NetworkTime (NetworkTimeFailure (..))
import Singular.Registry.SessionIO
    ( outputsAt
    , parameters
    , validityUpper
    )
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.TxBuilder.Edges (selectFunding)
import Singular.State.Refusal
    ( CapacityLimit (..)
    , Refusal (..)
    , capacityMessage
    )

{- | No queries. A state transaction reads the chain before it is built,
never while it is.
-}
data NoQuery a

-- | A transaction program as the state builders write it.
type Program = Tx.TxBuild NoQuery Void

{- | The payer of a transaction: the key that signs it, and the ADA-only output
that funds it and secures it as collateral.
-}
data Payer = Payer
    { payerNetwork :: Network
    , payerKey :: KeyHash Guard
    , payerFunding :: (TxIn, TxOut ConwayEra)
    }

-- | Why an address cannot pay for a transaction.
data PayerFault
    = -- | It holds no ADA-only output to fund and secure a transaction.
      NoFunding
    | -- | Its payment credential is a script, which cannot sign.
      NotAKey
    deriving stock (Eq, Show)

{- | The payer at an address: refused when the address is not a key's, or when
it holds no ADA-only output to fund and secure a transaction.
-}
findPayer
    :: Session NoWitness IO -> Addr -> IO (Either PayerFault Payer)
findPayer = findPayerReserving []

-- | Select funding without spending outputs reserved for a later transaction.
findPayerReserving
    :: [TxIn]
    -> Session NoWitness IO
    -> Addr
    -> IO (Either PayerFault Payer)
findPayerReserving reserved session address = case address of
    Addr net (KeyHashObj (KeyHash key)) _ -> do
        known <- outputsAt session address
        pure $ case selectFunding
            Nothing
            [entry | entry@(ref, _) <- known, ref `notElem` reserved] of
            Left _ -> Left NoFunding
            Right funding -> Right (Payer net (KeyHash key) funding)
    _ -> pure (Left NotAKey)

-- | The payer at an address, with the refusal of the state builders.
resolvePayer
    :: Session NoWitness IO -> Addr -> IO (Either Refusal Payer)
resolvePayer = resolvePayerReserving []

{- | The payer of a publication that must leave the reserved outputs unspent
for a later transaction. Selection still uses the session's actual wallet
outputs and the ordinary ADA-only funding rule.
-}
resolvePayerReserving
    :: [TxIn]
    -> Session NoWitness IO
    -> Addr
    -> IO (Either Refusal Payer)
resolvePayerReserving reserved session address =
    first refusal <$> findPayerReserving reserved session address
  where
    refusal = \case
        NoFunding -> PayerHasNoFunding
        NotAKey -> PayerIsNotAKey

{- | The outputs the session answers a query with. An absent exact reference
comes back as a 'ReadFailure' for the caller to name; any other failure is for
the caller to throw.
-}
readOutputs
    :: Session NoWitness IO -> OutputQuery -> IO (Either ReadFailure Outputs)
readOutputs session query = fmap value <$> outputs session query

-- | The inline datum of an output.
inlineDatumOf :: TxOut ConwayEra -> Maybe PLC.Data
inlineDatumOf output = case output ^. datumTxOutL of
    Datum binary -> let Data d = binaryDataToData binary in Just d
    _ -> Nothing

-- | The output holds this token once and nothing but ADA besides.
holdsOnly :: PolicyID -> AssetName -> TxOut ConwayEra -> Bool
holdsOnly policy name output =
    let MaryValue _ (MultiAsset assets) = output ^. valueTxOutL
    in  assets == Map.singleton policy (Map.singleton name 1)

-- | The slot the chain has reached.
tipSlot :: Session NoWitness IO -> IO SlotNo
tipSlot session = observedSlot <$> Services.tip session

{- | The last slot a transaction that starts at the tip can end before, when
it must end no later than @wanted@: nothing when the interval from the tip is
too short to be usable, and the nearer slot when the ledger's horizon is
nearer. The bound is exclusive, as a validity interval's end is.
-}
validityFromTip
    :: Session NoWitness IO -> SlotNo -> SlotNo -> IO (Maybe SlotNo)
validityFromTip session now wanted
    | toInteger (unSlotNo wanted) < toInteger (unSlotNo now) + 2 =
        pure Nothing
    | otherwise = do
        selected <- try (validityUpper session now (Just now) wanted)
        case selected of
            Right upper -> pure (Just upper)
            Left WindowTooShort{} -> pure Nothing
            Left failure -> throwIO (failure :: NetworkTimeFailure)

{- | Build a transaction from a program. The session's own evaluator runs every
script, so a script the validator refuses stops the build with its message.
-}
assemble
    :: Session NoWitness IO
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The outputs the transaction spends
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The outputs it reads by reference
    -> Addr
    -- ^ Where the change goes
    -> Program ()
    -> IO (Either Text ConwayTx)
assemble session spent referenced change program =
    first message
        <$> assembleTransaction session spent referenced change program
  where
    message (BuildFailed reason) = reason
    message (CapacityExceeded limit) = capacityMessage limit
    message other = Text.pack (show other)

-- The builder's evaluator callback carries strings. A private, narrowly caught
-- exception preserves typed capacity until the builder returns to our boundary.
newtype ProbeCapacity = ProbeCapacity CapacityLimit
    deriving stock (Show)

instance Exception ProbeCapacity

evaluate
    :: PParams ConwayEra
    -> Session NoWitness IO
    -> ConwayTx
    -> IO
        (Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))
evaluate protocol session tx = do
    results <- Services.evaluateTx session tx
    let failures = lefts (Map.elems results)
    case traverse (evaluationCapacity protocol) failures of
        Just (limit : _) -> throwIO (ProbeCapacity limit)
        _ -> pure (Map.map (either (Left . show) Right) results)

-- Only actual CEK exhaustion qualifies. A negative remaining budget records
-- work already attempted, not an estimate of the cost of finishing the script.
evaluationCapacity
    :: PParams ConwayEra
    -> TransactionScriptFailure ConwayEra
    -> Maybe CapacityLimit
evaluationCapacity protocol = \case
    ValidationFailure
        _
        ( Plutus.CekError
                ( Machine.ErrorWithCause
                        ( Machine.OperationalError
                                ( Cek.CekOutOfExError
                                        ( ExRestrictingBudget
                                                (Plutus.ExBudget (Plutus.ExCPU cpu) (Plutus.ExMemory mem))
                                            )
                                    )
                            )
                        _
                    )
            )
        _
        _
            | mem < 0 ->
                Just
                    (ExecutionMemory (memoryLimit - Plutus.fromSatInt mem) memoryLimit)
            | cpu < 0 ->
                Just (ExecutionSteps (stepLimit - Plutus.fromSatInt cpu) stepLimit)
    _ -> Nothing
  where
    ExUnits memory steps = protocol ^. ppMaxTxExUnitsL
    memoryLimit = toInteger memory
    stepLimit = toInteger steps

-- | The transaction of a program, with the refusal of the state builders.
assembleTransaction
    :: Session NoWitness IO
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> Program ()
    -> IO (Either Refusal ConwayTx)
assembleTransaction session spent referenced change program = do
    protocol <- parameters session
    built <-
        try $
            Tx.build
                (Tx.mkPParamsBound protocol)
                (Tx.InterpretIO noQuery)
                (evaluate protocol session)
                spent
                referenced
                change
                program
    pure $ case built of
        Left (ProbeCapacity limit) -> Left (CapacityExceeded limit)
        Right (Left failure) -> Left (BuildFailed (Text.pack (show failure)))
        Right (Right tx) ->
            maybe (Right tx) (Left . CapacityExceeded) (capacityOf protocol tx)
  where
    noQuery :: NoQuery a -> IO b
    noQuery query = case query of {}

{- | Compare actual final bytes and declared execution units with the session's
parameters. No builder message is interpreted as a capacity refusal.
-}
capacityOf :: PParams ConwayEra -> ConwayTx -> Maybe CapacityLimit
capacityOf protocol tx
    | bytes > byteLimit = Just (TransactionSize bytes byteLimit)
    | memory > memoryLimit = Just (ExecutionMemory memory memoryLimit)
    | steps > stepLimit = Just (ExecutionSteps steps stepLimit)
    | otherwise = Nothing
  where
    bytes = toInteger (LBS.length (serialize (eraProtVerHigh @ConwayEra) tx))
    byteLimit = toInteger (protocol ^. ppMaxTxSizeL)
    ExUnits maxMemory maxSteps = protocol ^. ppMaxTxExUnitsL
    memoryLimit = toInteger maxMemory
    stepLimit = toInteger maxSteps
    Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    budgets = map snd (Map.elems redeemers)
    memory = sum [toInteger used | ExUnits used _ <- budgets]
    steps = sum [toInteger used | ExUnits _ used <- budgets]
