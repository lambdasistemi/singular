-- | The genuine script-free mintless anchor body (NOTE-048.2). Creating
-- an output at a script address executes no script, so the forged-anchor
-- setup body must carry NO script-integrity / protocol-parameters-view
-- hash: the ledger expects SNothing, and the erroneous supplied hash is
-- exactly what caused the released run's PPViewHashesDontMatch phase-1
-- rejection. Pure construction on the same library path as the driver.
module RivalMintlessBody
  ( mkMintlessAnchorBody
  )
where

import Cardano.Ledger.Alonzo.Core (TopTx, TxBody)
import Cardano.Ledger.Api.Tx.Body (
    feeTxBodyL,
    inputsTxBodyL,
    mkBasicTxBody,
    outputsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.In (TxIn (..))
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))

-- | Build the genuine mintless anchor body: exactly one seed input, the
-- anchor output, an exact-remainder fee, and no script-integrity hash.
mkMintlessAnchorBody ::
    TxIn ->
    Coin ->
    TxOut ConwayEra ->
    TxBody TopTx ConwayEra
mkMintlessAnchorBody seedIn (Coin avail) anchorOut =
    mkBasicTxBody
        & inputsTxBodyL .~ Set.fromList [seedIn]
        & outputsTxBodyL .~ StrictSeq.singleton anchorOut
        & feeTxBodyL .~ Coin (avail - anchorCoin)
  where
    anchorCoin = case anchorOut ^. coinTxOutL of
        Coin c -> c
