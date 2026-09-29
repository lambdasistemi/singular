{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Application.OpenDatum.Book
Description : The open-datum application's booking certifications
License     : Apache-2.0

What an open-datum booking carries so @open_datum.open_datum.mint@
certifies it: the approval asset, the redeemer the mint arm reads, the
applied script that witnesses the mint, and the outputs the mint reads
by reference.

- An insertion names this script's address and the BLAKE2b-256 of the
  envelope's CBOR as its destination, so the fold delivers the key's
  active token to an output carrying the envelope inline. The redeemer
  carries the envelope, which the policy checks against the actual
  registry state.
- A termination names no destination. The redeemer points at the key's
  live output, which the booking reads by reference, never spends: the
  token and the deposit stay locked until the fold releases them.

The registry state is read by reference in both. Which edge an approval
certifies is the redeemer's constructor, so no third booking exists.
-}
module Singular.Application.OpenDatum.Book
    ( -- * Destinations
      insertDestination
    , terminateDestination

      -- * Certifications
    , insertApproval
    , terminateApproval

      -- * Redeemers
    , bookInsertRedeemer
    , bookTerminateRedeemer
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.BaseTypes (Network, TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , envelopeHash
    , envelopeToData
    )
import Singular.Application.OpenDatum.Script (openDatumAddressBytes)
import Singular.Registry.TxBuilder.Edges (BookingApproval (..))
import Singular.Registry.TxBuilder.Internal
    ( approvalName
    , scriptFromBytes
    )
import Singular.Registry.Types (edgeInsertActive, edgeUpdateTerminal)

{- | An insertion's destination: this script's enterprise address and the
envelope's hash.
-}
insertDestination
    :: Network -> SBS.ShortByteString -> Envelope -> (ByteString, ByteString)
insertDestination net applied e =
    (openDatumAddressBytes net applied, envelopeHash e)

-- | A termination delivers nothing: the model's @r.output = 0@.
terminateDestination :: (ByteString, ByteString)
terminateDestination = (BS.empty, BS.empty)

{- | The redeemer @BookInsert { key, owner, address, envelope }@, the
first constructor of @OpenDatumMint@.
-}
bookInsertRedeemer
    :: ByteString -> ByteString -> ByteString -> Envelope -> PLC.Data
bookInsertRedeemer key owner address e =
    PLC.Constr 0 [PLC.B key, PLC.B owner, PLC.B address, envelopeToData e]

{- | The redeemer @BookTerminate { key, owner, holding }@, the second
constructor, with the live output as an @OutputReference@.
-}
bookTerminateRedeemer :: ByteString -> ByteString -> TxIn -> PLC.Data
bookTerminateRedeemer key owner (TxIn (TxId h) (TxIx ix)) =
    PLC.Constr
        1
        [ PLC.B key
        , PLC.B owner
        , PLC.Constr
            0
            [PLC.B (hashToBytes (extractHash h)), PLC.I (fromIntegral ix)]
        ]

approvalOf
    :: SBS.ShortByteString
    -> ByteString
    -> PLC.Data
    -> Set.Set TxIn
    -> BookingApproval
approvalOf applied name redeemer references =
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

{- | Certify an insertion of the envelope's key for its controller, reading
the registry state at @state@.
-}
insertApproval
    :: Network
    -> SBS.ShortByteString
    -- ^ The applied open-datum script
    -> TxIn
    -- ^ The registry state output
    -> Envelope
    -> BookingApproval
insertApproval net applied state e =
    approvalOf
        applied
        (approvalName edgeInsertActive key owner destination)
        (bookInsertRedeemer key owner (fst destination) e)
        (Set.singleton state)
  where
    key = ctlKey (envControl e)
    owner = ctlController (envControl e)
    destination = insertDestination net applied e

{- | Certify the termination of @key@ by its controller @owner@, reading the
registry state at @state@ and the live output at @holding@.
-}
terminateApproval
    :: SBS.ShortByteString
    -> TxIn
    -- ^ The registry state output
    -> TxIn
    -- ^ The key's live output
    -> ByteString
    -- ^ Key
    -> ByteString
    -- ^ Owner: the live output's controller
    -> BookingApproval
terminateApproval applied state holding key owner =
    approvalOf
        applied
        (approvalName edgeUpdateTerminal key owner terminateDestination)
        (bookTerminateRedeemer key owner holding)
        (Set.fromList [state, holding])
