{- |
Module      : Singular.Application.OpenDatum.Book
Description : What the open-datum application gives its bookings
License     : Apache-2.0

The values the registry's shared booking builders are given for an open-datum
booking; the builders do the rest and decide no application rule.

- A registration names this script's address as its destination and carries
  the envelope itself as the datum the delivered output holds (#419), so any
  wallet folds the key's active token to an output carrying the envelope
  inline. The application's mint is given @BookInsert { key, owner, address,
  envelope }@, which the mint checks against the actual registry state, and
  the controller signs.
- A termination names no destination. The key's live output, its custody, is
  spent through the application's own @BookTermination { ordinary_added }@
  arm: the whole of it enters the request and the controller signs. No
  application approval is minted.
-}
module Singular.Application.OpenDatum.Book
    ( -- * Destinations
      insertDestination

      -- * Redeemers
    , bookInsertRedeemer
    , bookTerminationRedeemer
    ) where

import Data.ByteString (ByteString)
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.BaseTypes (Network)
import Data.ByteString.Short qualified as SBS

import Singular.Application.OpenDatum.Envelope
    ( Envelope
    , envelopeToData
    )
import Singular.Application.OpenDatum.Script (openDatumAddressBytes)

{- | A registration's destination: this script's enterprise address and the
envelope itself, the datum the delivered output carries.
-}
insertDestination
    :: Network
    -> SBS.ShortByteString
    -> Envelope
    -> (ByteString, Maybe PLC.Data)
insertDestination net applied e =
    (openDatumAddressBytes net applied, Just (envelopeToData e))

{- | The redeemer @BookInsert { key, owner, address, envelope }@, the first
constructor of @OpenDatumMint@.
-}
bookInsertRedeemer
    :: ByteString -> ByteString -> ByteString -> Envelope -> PLC.Data
bookInsertRedeemer key owner address e =
    PLC.Constr 0 [PLC.B key, PLC.B owner, PLC.B address, envelopeToData e]

{- | The redeemer @BookTermination { ordinary_added }@, the third constructor
of @OpenDatumSpend@: the custody is spent into a termination request that
holds its lovelace and the requester's ordinary addition.
-}
bookTerminationRedeemer :: Integer -> PLC.Data
bookTerminationRedeemer added = PLC.Constr 2 [PLC.I added]
