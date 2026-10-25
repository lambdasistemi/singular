{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Requests.Assemble
Description : What the request builders share: the payer, the chain reads and the assembly
License     : Apache-2.0

A request transaction is built from facts read before it is built: the payer's
funding output, the outputs it spends or reads, and the slot the chain has
reached. The reads and the assembly are those of the Singular state builders;
this module gives their faults the names a request builder declines with.
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
    , holdsOnly
    , tipSlot
    , validityFromTip

      -- * Assembly
    , assembleTransaction
    ) where

import Data.Bifunctor (first)
import Data.Void (Void)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (Session)
import Singular.State.Assemble
    ( NoQuery
    , Payer (..)
    , PayerFault (..)
    , assemble
    , findPayer
    , holdsOnly
    , inlineDatumOf
    , readOutputs
    , tipSlot
    , validityFromTip
    )

{- | The payer at an address: refused when the address is not a key's, or when
it holds no ADA-only output to fund and secure a transaction.
-}
resolvePayer
    :: Session NoWitness IO -> Addr -> IO (Either Refusal Payer)
resolvePayer session address =
    first refusal <$> findPayer session address
  where
    refusal = \case
        NoFunding -> PayerHasNoFunding
        NotAKey -> PayerIsNotAKey

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
assembleTransaction session spent referenced change program =
    first BuildFailed <$> assemble session spent referenced change program
