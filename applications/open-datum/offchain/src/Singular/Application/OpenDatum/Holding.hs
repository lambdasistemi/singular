{- |
Module      : Singular.Application.OpenDatum.Holding
Description : What a registry fold needs from the open-datum application, and how a live output reads
License     : Apache-2.0

A fold of an open-datum registry runs the registry's own duties; the
application adds one thing to the context it folds with: the output that
carries its applied script as a reference script, so the burn of a
registration's application tag resolves its script beside the registry's own
references. Without that output the fold attaches the script instead.

A registration's request carries its envelope (#419), so the delivery needs
nothing from here. A termination releases nothing: the booking spent the key's
custody and moved the whole of it into the request, and the fold burns the
key's tag. This module also reads a live output: the envelope it carries and
how many of its own key's active token it holds.

No validator or fold rule is decided here: the registry decides what the fold
owes, the script decides whether a spend is valid; this module only supplies
what the application knows.
-}
module Singular.Application.OpenDatum.Holding
    ( withApplication
    , liveEnvelope
    , heldOf
    ) where

import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, valueTxOutL)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope
    , envelopeFromData
    )
import Singular.Registry.Ledger (ConwayEra, TxIn)
import Singular.Registry.TxBuilder.Internal (policyIdFromPin)
import Singular.Registry.TxBuilder.Update (RegistryContext (..))

-- | The envelope a live output carries inline, or why it carries none.
liveEnvelope :: TxOut ConwayEra -> Either String Envelope
liveEnvelope out = case out ^. datumTxOutL of
    Datum bd ->
        let Data d = binaryDataToData bd
        in  envelopeFromData d
    _ -> Left "the live output carries no inline datum"

{- | The fold context with the application's part added: the output carrying
the applied script as a reference script, when the deployment published one.
-}
withApplication
    :: SBS.ShortByteString
    -- ^ The applied open-datum script
    -> Maybe (TxIn, TxOut ConwayEra)
    -- ^ The applied script's published reference output
    -> RegistryContext
    -> Either String RegistryContext
withApplication _applied reference ctx =
    Right ctx{rcRefUtxos = rcRefUtxos ctx <> maybe [] pure reference}

-- | How many of its own key's active token a live output holds.
heldOf :: Control -> TxOut ConwayEra -> Integer
heldOf c out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) ->
        maybe
            0
            (Map.findWithDefault 0 (AssetName (SBS.toShort (ctlKey c))))
            (Map.lookup (policyIdFromPin (SBS.toShort (ctlActivePolicy c))) m)
