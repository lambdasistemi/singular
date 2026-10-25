{- |
Module      : Singular.Application.OpenDatum.Requests.Booking
Description : Book the registration of a key
License     : Apache-2.0

Booking a registration puts its request at the address of the request
validator, holding an approval token that commits the change, and the
request value. The validator accepts the mint when the output carries the ten
fields of the registration, the controller signs, the clock fixes the
deadlines from the registry's configuration record read by reference, and the
output holds at least the deposit.
-}
module Singular.Application.OpenDatum.Requests.Booking
    ( Booking (..)
    , buildBookRegistration
    ) where

import Data.ByteString (ByteString)
import PlutusCore.Data qualified as PLC

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Coin (Coin)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Application.OpenDatum.Requests.Script (RequestScript)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.TrieState (RegistryIdentity)

-- | What a booking asks for.
data Booking = Booking
    { bookRegistry :: RegistryIdentity
    , bookKey :: ByteString
    , bookPayload :: PLC.Data
    -- ^ The payload the key's holding starts with
    , bookDeposit :: Coin
    -- ^ What the holding keeps; committed in the approval
    , bookTip :: Coin
    {- ^ The request value above the deposit: what the folder takes. The
    request holds the deposit and the tip, raised to the ledger's minimum
    ADA of the request output when that is more.
    -}
    , bookRefund :: Addr
    -- ^ Where a reclaim or a cleanup returns the value
    }
    deriving stock (Eq, Show)

{- | Build the booking transaction. The payer funds it and signs it; its
payment key is the controller of the registration.
-}
buildBookRegistration
    :: Session NoWitness IO
    -> RequestScript
    -> Booking
    -> Addr
    -- ^ The payer: fee, collateral and change, and the controller's key
    -> IO (Either Refusal ConwayTx)
buildBookRegistration _ _ _ _ = pure (Left (BuildFailed "not built"))
