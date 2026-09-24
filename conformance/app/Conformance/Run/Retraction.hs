{- |
Module      : Conformance.Run.Retraction
Description : Declaring a live retraction's units, collateral and fee
License     : Apache-2.0
-}
module Conformance.Run.Retraction (declareRetraction) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx (bodyTxL, estimateMinFeeTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    collateralReturnTxBodyL,
    feeTxBodyL,
    outputsTxBodyL,
    scriptIntegrityHashTxBodyL,
    totalCollateralTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (StrictMaybe (SNothing))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Ledger (
    Coin (..),
    ConwayEra,
    ExUnits,
    PParams,
 )
import Singular.Registry.TxBuilder.Internal (computeScriptIntegrity)

{- | Declare a retraction's per-purpose units (none: keep the builder's), its
script integrity, collateral and fee. The collateral is the pot alone, whole:
the builder's collateral return and total were computed for the builder's own
collateral input, and against the pot they unbalance it. The fee is what the
ledger's estimate asks for
one key witness and the reference scripts it resolves, plus a margin, the
difference taken from the change, its last output, paid to @changeAddr@.
-}
declareRetraction :: PParams ConwayEra -> Map.Map T.Text ExUnits -> TxIn -> Int -> Addr -> ConwayTx
    -> Either String ConwayTx
declareRetraction pp units pot referenceScriptBytes changeAddr transaction = do
    let Redeemers purposes = transaction ^. witsTxL . rdmrsTxWitsL
        redeemers = Redeemers (Map.mapWithKey
            (\purpose (datum, current) ->
                (datum, Map.findWithDefault current (T.pack (show purpose)) units))
            purposes)
        declared = transaction
            & witsTxL . rdmrsTxWitsL .~ redeemers
            & bodyTxL . scriptIntegrityHashTxBodyL .~ computeScriptIntegrity pp redeemers
            & bodyTxL . collateralInputsTxBodyL .~ Set.singleton pot
            & bodyTxL . collateralReturnTxBodyL .~ SNothing
            & bodyTxL . totalCollateralTxBodyL .~ SNothing
        Coin before = declared ^. bodyTxL . feeTxBodyL
        Coin estimated = estimateMinFeeTx pp declared 1 0 referenceScriptBytes
        fee = estimated + 50_000
        outputs = toList (declared ^. bodyTxL . outputsTxBodyL)
    (kept, change) <- case reverse outputs of
        change : rest | change ^. addrTxOutL == changeAddr, change ^. datumTxOutL == NoDatum ->
            Right (reverse rest, change)
        _ -> Left "the retraction's last output is not its change"
    let Coin changeCoin = change ^. coinTxOutL
        rebalanced = change & coinTxOutL .~ Coin (changeCoin + before - fee)
    pure (declared
        & bodyTxL . feeTxBodyL .~ Coin fee
        & bodyTxL . outputsTxBodyL .~ StrictSeq.fromList (kept <> [rebalanced]))
