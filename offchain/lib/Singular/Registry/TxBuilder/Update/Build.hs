{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.Update.Build
Description : Fold transaction assembly — one DSL program
License     : Apache-2.0

The transaction side of a fold: the empty query GADT the fold's DSL
programs run under, the evaluation adapter that turns the provider's
script budgets into the shape the DSL consumes, and the one program
that assembles the update transaction — spends, mints, outputs,
signatures, scripts or references, collateral and validity — from the
prepared context and the decided duties.

This module owns no queries and no duty decisions; see
"Singular.Registry.TxBuilder.Update.Context" and
"Singular.Registry.TxBuilder.Update.Duties". The public surface stays
"Singular.Registry.TxBuilder.Update" (#267).
-}
module Singular.Registry.TxBuilder.Update.Build (
    NoCtx,
    mkEvalTx,
    buildProgram,
) where

import Data.Map.Strict qualified as Map
import Data.Void (Void)
import Lens.Micro ((^.))

import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.Api.Tx (
    bodyTxL,
 )
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway.Scripts (
    ConwayPlutusPurpose,
 )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build qualified as Tx

import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Ledger (
    ConwayEra,
    PParams,
    TxIn,
 )
import Singular.Registry.Provider (
    Provider (..),
 )
import Singular.Registry.TxBuilder.ConnectedFold (
    ConnectedMint (..),
    ConnectedSpend (..),
 )
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Update.Duties (
    RegistryDuties (..),
 )
import Singular.Registry.Types (
    OnChainTokenState,
    ProofStep,
    RequestAction (..),
    UpdateRedeemer (..),
 )

-- | Empty query GADT (no context needed).
data NoCtx a

-- | Wrap the Provider's evaluateTx for the DSL.
mkEvalTx ::
    Provider IO ->
    ConwayTx ->
    IO
        ( Map.Map
            ( ConwayPlutusPurpose
                AsIx
                ConwayEra
            )
            (Either String ExUnits)
        )
mkEvalTx prov tx = do
    r <- evaluateTx prov tx
    pure $
        Map.map
            ( \case
                Left e -> Left (show e)
                Right eu -> Right eu
            )
            r

-- | The TxBuild DSL program for an update tx.
buildProgram ::
    CageConfig ->
    PParams ConwayEra ->
    TxIn ->
    TxOut ConwayEra ->
    [(TxIn, TxOut ConwayEra)] ->
    (TxIn, TxOut ConwayEra) ->
    OnChainTokenState ->
    TxOut ConwayEra ->
    Script ConwayEra ->
    Script ConwayEra ->
    [[ProofStep]] ->
    SlotNo ->
    RegistryDuties ->
    [(TxIn, TxOut ConwayEra)] ->
    Tx.TxBuild NoCtx Void ()
buildProgram
    _cfg
    _pp
    stateIn
    _stateOut
    reqUtxos
    feeUtxo
    _oldState
    newStateOut
    script
    requestScript
    proofs
    upperSlot
    duties
    refUtxos = do
        let stateRef = txInToRef stateIn
        let actions = map Update proofs
        _ <- Tx.spendScript stateIn (Modify actions)
        mapM_
            ( \(rIn, _) ->
                Tx.spendScript
                    rIn
                    (Contribute stateRef)
            )
            reqUtxos
        _ <- Tx.output newStateOut
        Coin _fee <- Tx.peek $ \tx ->
            let f = tx ^. bodyTxL . feeTxBodyL
             in if f > Coin 0
                    then Tx.Ok f
                    else Tx.Iterate f
        -- #157 C10: the pinned consumer and its mandatory withdrawal are
        -- gone. Every rule it re-walked beside the fold — request value
        -- coverage, the mint binding — is the cage's own now, checked
        -- once from the transaction's own evidence.
        -- #157 C5/C6/T1-T6: what the edges owe. The custody an edge
        -- consumes is spent, the tokens it moves are minted or burned
        -- under the registry's own three policies, and the carriers it
        -- owes — custody, destination, deposit return — are created.
        mapM_
            (\sp -> Tx.spendScript (fst (csUtxo sp)) (csRedeemer sp))
            (rdSpends duties)
        -- #177 I177-BUILDER: the burn source of a retirement or of an
        -- active deletion. It is an ordinary input, not a script spend:
        -- the active witness sits at the holder's own address, and the
        -- key that signs the fold is the key that owns it.
        mapM_ (Tx.spend . fst) (rdInputs duties)
        mapM_
            (\m -> Tx.mint (cmPolicy m) (cmAssets m) (cmRedeemer m))
            (rdMints duties)
        mapM_ Tx.output (rdOutputs duties)
        mapM_ Tx.requireSignature (rdSigners duties)
        if null refUtxos
            then do
                Tx.attachScript script
                Tx.attachScript requestScript
                mapM_ (Tx.attachScript . csScript) (rdSpends duties)
                mapM_ (Tx.attachScript . cmScript) (rdMints duties)
            else mapM_ (Tx.reference . fst) refUtxos
        Tx.collateral (fst feeUtxo)
        Tx.validTo upperSlot
