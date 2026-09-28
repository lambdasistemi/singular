{- |
Module      : Journey.Malformations
Description : Single-defect rewrites of a valid fold transaction
License     : Apache-2.0

Pure functions, each deriving from the valid oracle update a
transaction that is wrong in exactly ONE intended way and still
well-formed for ledger phase 1 — the value, size and addresses are
untouched, and where a redeemer changes the script-integrity hash is
re-stamped — so only the on-chain validator stands between it and the
ledger:

* 'forgeContributeStateRef' — the request's Contribute redeemer names a
  forged state reference;
* 'tamperStateOutputRoot' with 'tamperRoot' — the new state output keeps
  its datum shape but carries the byte complement of the certified root;
* 'dropModifyProof' — the Modify action loses its Merkle proof witness.

Which validator must refuse each one, and why, is "Journey.Controls".
-}
module Journey.Malformations (
    tamperRoot,
    forgeContributeStateRef,
    tamperStateOutputRoot,
    dropModifyProof,
    decodeUpdateRedeemer,
) where

import Data.Bits (complement)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Lens.Micro ((%~), (&), (.~), (^.))

import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    outputsTxBodyL,
    scriptIntegrityHashTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (datumTxOutL)
import Cardano.Ledger.Api.Tx.Wits (
    Redeemers (..),
    rdmrsTxWitsL,
 )
import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (FromData (..))

import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.TxBuilder.Internal (
    computeScriptIntegrity,
    extractCageDatum,
    mkInlineDatum,
    toLedgerData,
    toPlcData,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
    RequestAction (Update),
    UpdateRedeemer (..),
 )

-- | A same-shaped but wrong root: the byte complement.
tamperRoot :: OnChainRoot -> OnChainRoot
tamperRoot (OnChainRoot bs) = OnChainRoot (BS.map complement bs)

{- | Rewrite the request spend's Contribute redeemer so it
names a forged state reference, and re-stamp the script
integrity hash so ledger phase 1 stays valid. Everything
else — inputs, outputs, fees — is untouched.
-}
forgeContributeStateRef ::
    PParams ConwayEra ->
    OnChainTxOutRef ->
    ConwayTx ->
    ConwayTx
forgeContributeStateRef pp forgedRef tx =
    tx
        & witsTxL . rdmrsTxWitsL .~ newRedeemers
        & bodyTxL . scriptIntegrityHashTxBodyL .~ integrity
  where
    Redeemers rdmrMap = tx ^. witsTxL . rdmrsTxWitsL
    newRedeemers = Redeemers (Map.map swapContribute rdmrMap)
    swapContribute pair = case decodeUpdateRedeemer (fst pair) of
        Just (Contribute _) -> (toLedgerData (Contribute forgedRef), snd pair)
        _ -> pair
    integrity = computeScriptIntegrity pp newRedeemers

-- | Decode a redeemer payload as an 'UpdateRedeemer'.
decodeUpdateRedeemer :: Data ConwayEra -> Maybe UpdateRedeemer
decodeUpdateRedeemer (Data d) = fromBuiltinData (BuiltinData d)

{- | Replace the root inside the new state output's inline
datum: correct 'StateDatum' shape, wrong content. The value,
size and address are untouched, so fee and min-UTxO rules
still hold.
-}
tamperStateOutputRoot :: OnChainRoot -> OnChainRoot -> ConwayTx -> ConwayTx
tamperStateOutputRoot expected tampered tx =
    tx & bodyTxL . outputsTxBodyL %~ fmap fixOutput
  where
    fixOutput out = case extractCageDatum out of
        Just (StateDatum s)
            | stateRoot s == expected ->
                out
                    & datumTxOutL
                        .~ mkInlineDatum
                            (toPlcData (StateDatum s{stateRoot = tampered}))
        _ -> out

{- | Drop the Merkle proof witness from the Modify action, keeping
the action shape: `UpdateAction` with an empty proof list. The
value, size discipline and addresses are untouched (shrinking a
redeemer only lowers the fee the body already covers), the
script-integrity hash is re-stamped so ledger phase 1 stays valid,
and only the on-chain proof verification stands between the
transaction and the ledger.
-}
dropModifyProof ::
    PParams ConwayEra ->
    ConwayTx ->
    ConwayTx
dropModifyProof pp tx =
    tx
        & witsTxL . rdmrsTxWitsL .~ newRedeemers
        & bodyTxL . scriptIntegrityHashTxBodyL .~ integrity
  where
    Redeemers rdmrMap = tx ^. witsTxL . rdmrsTxWitsL
    newRedeemers = Redeemers (Map.map dropProof rdmrMap)
    dropProof pair = case decodeUpdateRedeemer (fst pair) of
        Just (Modify _) -> (toLedgerData (Modify [Update []]), snd pair)
        _ -> pair
    integrity = computeScriptIntegrity pp newRedeemers
