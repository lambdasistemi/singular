{- |
Module      : Singular.Application.OpenDatum.Requests.Assemble
Description : What the request builders share: the payer, the chain reads and the assembly
License     : Apache-2.0

A request transaction is built from facts read before it is built: the payer's
funding output, the outputs it spends or reads, and the slot the chain has
reached. This module reads the payer, answers an output query without losing
the difference between an absent output and a failed read, picks a validity
interval that starts at the tip, and hands a transaction program to the
transaction builder with the session's own script evaluator, so a script the
validator refuses stops the build.
-}
module Singular.Application.OpenDatum.Requests.Assemble
    ( -- * No queries
      NoQuery

      -- * The payer
    , Payer (..)
    , resolvePayer

      -- * Reading the chain
    , readOutputs
    , inlineDatumOf
    , tipSlot
    , validityFromTip

      -- * Assembly
    , assembleTransaction
    ) where

import Control.Exception (throwIO, try)
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Void (Void)
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Scripts.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (Guard))
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
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

{- | No queries. A request transaction reads the chain before it is built,
never while it is.
-}
data NoQuery a

{- | The payer of a transaction: the key that signs it, and the ADA-only output
that funds it and secures it as collateral.
-}
data Payer = Payer
    { payerNetwork :: Network
    , payerKey :: KeyHash Guard
    , payerFunding :: (TxIn, TxOut ConwayEra)
    }

{- | The payer at an address: refused when the address is not a key's, or when
it holds no ADA-only output to fund and secure a transaction.
-}
resolvePayer
    :: Session NoWitness IO -> Addr -> IO (Either Refusal Payer)
resolvePayer session address = case address of
    Addr net (KeyHashObj (KeyHash key)) _ -> do
        known <- outputsAt session address
        pure $ case selectFunding Nothing known of
            Left _ -> Left PayerHasNoFunding
            Right funding -> Right (Payer net (KeyHash key) funding)
    _ -> pure (Left PayerIsNotAKey)

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
assembleTransaction
    :: Session NoWitness IO
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The outputs the transaction spends
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The outputs it reads by reference
    -> Addr
    -- ^ Where the change goes
    -> Tx.TxBuild NoQuery Void ()
    -> IO (Either Refusal ConwayTx)
assembleTransaction session spent referenced change program = do
    protocol <- parameters session
    built <-
        Tx.build
            (Tx.mkPParamsBound protocol)
            (Tx.InterpretIO noQuery)
            (evaluate session)
            spent
            referenced
            change
            program
    pure (first (BuildFailed . Text.pack . show) built)
  where
    noQuery :: NoQuery a -> IO b
    noQuery query = case query of {}

evaluate
    :: Session NoWitness IO
    -> ConwayTx
    -> IO
        (Map.Map (ConwayPlutusPurpose AsIx ConwayEra) (Either String ExUnits))
evaluate session tx =
    Map.map (either (Left . show) Right)
        <$> Services.evaluateTx session tx
