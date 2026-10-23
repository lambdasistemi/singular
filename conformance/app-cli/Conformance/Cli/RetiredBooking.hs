{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Conformance.Cli.RetiredBooking
Description : The booking certifications and release helpers the producers removed, kept for the rows that still book the retired way
License     : Apache-2.0

The open-datum producers no longer export an approval for a booking, the
terminate destination or the release helpers: a registration or a termination
is a tagged request now, booked through the registration and termination
builders. The conformance backend's hand-built rows (the ones that book
through 'bookEdgeWith', the legacy edge builder) still need the shapes of the
retired law to build the transactions they hand to a node. They are kept here,
unchanged in meaning and renamed so no producer entry point is named, so that
the backend compiles and the rows are listed as what they are: rows on the
retired booking, not told on the tagged-request law. The checkpoint that moves
the remaining legacy callers to the tagged path removes this module with them.
-}
module Conformance.Cli.RetiredBooking
    ( retiredInsertApproval
    , retiredTerminateApproval
    , retiredTerminateDestination
    , retiredLiveEnvelope
    , retiredHeldOf
    , retiredWithApplication
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network, TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data
    ( Data (..)
    , Datum (..)
    , binaryDataToData
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Book (insertDestination)
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeFromData
    , envelopeToData
    )
import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Edges (BookingApproval (..))
import Singular.Registry.TxBuilder.Internal
    ( approvalDestination
    , approvalName
    , policyIdFromPin
    , scriptFromBytes
    )
import Singular.Registry.TxBuilder.Update
    ( HolderRelease (..)
    , RegistryContext (..)
    )
import Singular.Registry.Types (edgeInsertActive, edgeUpdateTerminal)

-- | A termination delivers nothing: the retired law's @r.output = 0@.
retiredTerminateDestination :: (ByteString, Maybe PLC.Data)
retiredTerminateDestination = (BS.empty, Nothing)

-- | The retired redeemer @BookInsert { key, owner, address, envelope }@.
retiredBookInsertRedeemer
    :: ByteString -> ByteString -> ByteString -> Envelope -> PLC.Data
retiredBookInsertRedeemer key owner address e =
    PLC.Constr 0 [PLC.B key, PLC.B owner, PLC.B address, envelopeToData e]

-- | The retired redeemer @BookTerminate { key, owner, holding }@.
retiredBookTerminateRedeemer
    :: ByteString -> ByteString -> TxIn -> PLC.Data
retiredBookTerminateRedeemer key owner (TxIn (TxId h) (TxIx ix)) =
    PLC.Constr
        1
        [ PLC.B key
        , PLC.B owner
        , PLC.Constr
            0
            [PLC.B (hashToBytes (extractHash h)), PLC.I (fromIntegral ix)]
        ]

retiredApprovalOf
    :: SBS.ShortByteString
    -> ByteString
    -> PLC.Data
    -> Set.Set TxIn
    -> BookingApproval
retiredApprovalOf applied name redeemer references =
    BookingApproval
        { baAsset =
            MultiAsset
                ( Map.singleton
                    (PolicyID (hashScript script))
                    (Map.singleton (AssetName (SBS.toShort name)) 1)
                )
        , baRedeemer = redeemer
        , baScript = script
        , baScriptReference = Nothing
        , baReferenceInputs = references
        }
  where
    script = scriptFromBytes "open-datum" applied

-- | The retired approval of an insertion, reading the registry state at @state@.
retiredInsertApproval
    :: Network
    -> SBS.ShortByteString
    -> TxIn
    -> Envelope
    -> BookingApproval
retiredInsertApproval net applied state e =
    retiredApprovalOf
        applied
        ( approvalName
            edgeInsertActive
            key
            owner
            (approvalDestination destination)
        )
        (retiredBookInsertRedeemer key owner (fst destination) e)
        (Set.singleton state)
  where
    key = ctlKey (envControl e)
    owner = ctlController (envControl e)
    destination = insertDestination net applied e

-- | The retired approval of a termination, reading the state and the live output.
retiredTerminateApproval
    :: SBS.ShortByteString
    -> TxIn
    -> TxIn
    -> ByteString
    -> ByteString
    -> BookingApproval
retiredTerminateApproval applied state holding key owner =
    retiredApprovalOf
        applied
        ( approvalName
            edgeUpdateTerminal
            key
            owner
            (approvalDestination retiredTerminateDestination)
        )
        (retiredBookTerminateRedeemer key owner holding)
        (Set.fromList [state, holding])

-- | The envelope a live output carries inline, or why it carries none.
retiredLiveEnvelope :: TxOut ConwayEra -> Either String Envelope
retiredLiveEnvelope out = case out ^. datumTxOutL of
    Datum bd ->
        let Data d = binaryDataToData bd
        in  envelopeFromData d
    _ -> Left "the live output carries no inline datum"

-- | How many of its own key's active token a live output holds.
retiredHeldOf :: Control -> TxOut ConwayEra -> Integer
retiredHeldOf c out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) ->
        maybe
            0
            (Map.findWithDefault 0 (AssetName (SBS.toShort (ctlKey c))))
            (Map.lookup (policyIdFromPin (SBS.toShort (ctlActivePolicy c))) m)

-- | The retired release of one live output: the @Release@ redeemer, the script, the deposit to the controller.
retiredReleaseOf
    :: SBS.ShortByteString
    -> (TxIn, TxOut ConwayEra)
    -> Either String (TxIn, HolderRelease)
retiredReleaseOf applied (txIn, out) = do
    e <- retiredLiveEnvelope out
    let c = envControl e
        held = retiredHeldOf c out
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

-- | The fold context with the retired release of every live output added.
retiredWithApplication
    :: SBS.ShortByteString
    -> Maybe (TxIn, TxOut ConwayEra)
    -> [(TxIn, TxOut ConwayEra)]
    -> RegistryContext
    -> Either String RegistryContext
retiredWithApplication applied reference live ctx = do
    released <- fmap Map.fromList (mapM (retiredReleaseOf applied) live)
    pure
        ctx
            { rcHolderUtxos = rcHolderUtxos ctx <> live
            , rcHolderReleases = Map.union (rcHolderReleases ctx) released
            , rcRefUtxos = rcRefUtxos ctx <> maybe [] pure reference
            }
