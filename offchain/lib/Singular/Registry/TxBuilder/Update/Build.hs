{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.Update.Build
Description : Fold transaction assembly — the evaluation adapter
License     : Apache-2.0

The transaction side of a fold: the empty query generalized algebraic data
type the story language programs run under, and the evaluation adapter that
turns the provider's script budgets into the shape the story language
consumes. The one program that assembles the fold, with its spends, mints,
outputs, scripts or references, collateral and validity, is
"Singular.Registry.TxBuilder.ConnectedFold"; no second assembler lives here.

This module owns no queries and no duty decisions; see
"Singular.Registry.TxBuilder.Update.Context" and
"Singular.Registry.TxBuilder.Update.Duties". The public surface stays
"Singular.Registry.TxBuilder.Update" (#267).
-}
module Singular.Registry.TxBuilder.Update.Build
    ( NoCtx
    , mkEvalTx
    ) where

import Data.Map.Strict qualified as Map

import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Conway.Scripts
    ( ConwayPlutusPurpose
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Tx.Ledger
    ( ConwayTx
    )

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( ConwayEra
    )
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO qualified as Services

-- | Empty query generalized algebraic data type (no context needed).
data NoCtx a

-- | Wrap the view's script evaluation for the story language.
mkEvalTx
    :: Session NoWitness IO
    -> ConwayTx
    -> IO
        ( Map.Map
            ( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
            (Either String ExUnits)
        )
mkEvalTx view tx = do
    r <- Services.evaluateTx view tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r
