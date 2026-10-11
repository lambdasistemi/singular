{- |
Module      : Singular.Application.OpenDatum.Release
Description : What a registry fold needs from the open-datum application
License     : Apache-2.0

A fold of an open-datum registry runs the registry's own duties
('Singular.Registry.TxBuilder.Update.updateTokenWithDuties'); the
application adds one thing to the context it folds with. An insertion's
request carries its envelope (#419), so the delivery needs nothing from
here.

- **Releases.** A termination burns the key's active token from its live
  output at this script. 'releases' reads each live output's inline
  envelope and returns how the fold spends it — the @Release@ redeemer
  and this script — and what the spend owes: the protected deposit, to
  the controller's key, summed by the fold with every deposit it returns
  there. A live output that carries no envelope, or not exactly one of
  its key's token, is refused here, naming it.

No validator or fold rule is decided here: the registry decides what
the fold owes, the script decides whether the spend is valid; this
module only supplies what the application knows.
-}
module Singular.Application.OpenDatum.Release
    ( releaseOf
    , releases
    , withApplication
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
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeFromData
    )
import Singular.Registry.Ledger (ConwayEra, TxIn)
import Singular.Registry.TxBuilder.Internal
    ( policyIdFromPin
    , scriptFromBytes
    )
import Singular.Registry.TxBuilder.Update
    ( HolderRelease (..)
    , RegistryContext (..)
    )

-- | The envelope a live output carries inline, or why it carries none.
liveEnvelope :: TxOut ConwayEra -> Either String Envelope
liveEnvelope out = case out ^. datumTxOutL of
    Datum bd ->
        let Data d = binaryDataToData bd
        in  envelopeFromData d
    _ -> Left "the live output carries no inline datum"

{- | How the fold spends one live output and what it releases: the
@Release@ redeemer (constructor 1 of @OpenDatumSpend@) under the applied
script, the protected deposit to the controller.
-}
releaseOf
    :: SBS.ShortByteString
    -- ^ The applied open-datum script
    -> (TxIn, TxOut ConwayEra)
    -> Either String (TxIn, HolderRelease)
releaseOf applied (txIn, out) = do
    e <- liveEnvelope out
    let c = envControl e
        held = heldOf c out
    if held /= 1
        then
            Left
                ( "the live output "
                    <> show txIn
                    <> " holds "
                    <> show held
                    <> " of its key's active token, not exactly one"
                )
        else
            Right
                ( txIn
                , HolderRelease
                    { hrRedeemer = PLC.Constr 1 []
                    , hrScript = scriptFromBytes "open-datum" applied
                    , hrRecipient = ctlController c
                    , hrReleased = ctlDeposit c
                    }
                )

-- | Every live output this fold may release.
releases
    :: SBS.ShortByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> Either String (Map.Map TxIn HolderRelease)
releases applied = fmap Map.fromList . mapM (releaseOf applied)

{- | The fold context with the application's part added: the live outputs
as the burn sources a termination draws from, how each is released, and the output carrying the applied
script as a reference script, so a release spend resolves its script
beside the registry's own references. Without that output the fold
attaches the script instead.
-}
withApplication
    :: SBS.ShortByteString
    -> Maybe (TxIn, TxOut ConwayEra)
    -- ^ The applied script's published reference output
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ The live outputs at the applied script
    -> RegistryContext
    -> Either String RegistryContext
withApplication applied reference live ctx = do
    released <- releases applied live
    pure
        ctx
            { rcHolderUtxos = rcHolderUtxos ctx <> live
            , rcHolderReleases = Map.union (rcHolderReleases ctx) released
            , rcRefUtxos = rcRefUtxos ctx <> maybe [] pure reference
            }

-- | How many of its own key's active token a live output holds.
heldOf :: Control -> TxOut ConwayEra -> Integer
heldOf c out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) ->
        maybe
            0
            (Map.findWithDefault 0 (AssetName (SBS.toShort (ctlKey c))))
            (Map.lookup (policyIdFromPin (SBS.toShort (ctlActivePolicy c))) m)
