{-# LANGUAGE LambdaCase #-}

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

import Control.Exception (throwIO, try)
import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
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
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Keys (KeyHash (..), KeyRole (Guard))
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

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
import Singular.State.Refusal (Refusal (..))

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
findPayer session address = case address of
    Addr net (KeyHashObj (KeyHash key)) _ -> do
        known <- outputsAt session address
        pure $ case selectFunding Nothing known of
            Left _ -> Left NoFunding
            Right funding -> Right (Payer net (KeyHash key) funding)
    _ -> pure (Left NotAKey)

-- | The payer at an address, with the refusal of the state builders.
resolvePayer
    :: Session NoWitness IO -> Addr -> IO (Either Refusal Payer)
resolvePayer session address =
    first refusal <$> findPayer session address
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
assemble session spent referenced change program = do
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
    pure (first (Text.pack . show) built)
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

-- | The transaction of a program, with the refusal of the state builders.
assembleTransaction
    :: Session NoWitness IO
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> Program ()
    -> IO (Either Refusal ConwayTx)
assembleTransaction session spent referenced change program =
    first BuildFailed <$> assemble session spent referenced change program
