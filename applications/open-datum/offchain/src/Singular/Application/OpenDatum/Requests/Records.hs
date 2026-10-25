{- |
Module      : Singular.Application.OpenDatum.Requests.Records
Description : The records and actions of the open-datum request validator, as Plutus Data
License     : Apache-2.0

What the open-datum request validator reads and the builders write: the
configuration record, the pending registration, the live holding datum, the
actions of its mint and of its spend, each in the Plutus Data layout the
validator decodes. The layout follows the validator's types
(@application/held@, @application/mint@, @application/spend@); the compiled
blueprint carries the action types and the validator's own tests pin the rest.

A registration approval is named by the hash of a preimage that commits the
registration's fields; the name is built here with the preimage codec of the
Singular state, never re-derived.
-}
module Singular.Application.OpenDatum.Requests.Records
    ( -- * Records
      RequestParameters (..)
    , RegistrationData (..)
    , configurationDatum
    , decodeConfiguration
    , registrationDatum
    , decodeRegistration
    , liveDatum

      -- * The approval of a registration
    , initialDatumHash
    , approvalNameOf

      -- * Actions
    , MintAction (..)
    , mintRedeemer
    , SpendAction (..)
    , spendRedeemer
    , AsData (..)
    ) where

import Data.ByteString (ByteString)
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (ToData (..))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Mary.Value (AssetName)
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.TrieState (RegistryIdentity)

{- | The five request parameters of a registry, fixed when its configuration
record is created. Times are milliseconds. The registration cost and the
minimum tip are carried and enforce nothing.
-}
data RequestParameters = RequestParameters
    { rpRegistrationCost :: Integer
    , rpMinimumTip :: Integer
    , rpProcessTime :: Integer
    -- ^ How long after booking only a fold may spend the registration
    , rpRetractTime :: Integer
    -- ^ How long after that the refund address may reclaim it
    , rpBookingWidth :: Integer
    -- ^ The widest validity interval a booking may declare
    }
    deriving stock (Eq, Show)

{- | A booked registration, the record of a pending registration: the ten
fields of the model's @RegistrationData@. Addresses are ledger addresses; the
datum carries their Plutus form.
-}
data RegistrationData = RegistrationData
    { rdRegistry :: RegistryIdentity
    , rdKey :: ByteString
    , rdController :: ByteString
    -- ^ The payment key hash that signed the booking
    , rdRefundAddress :: Addr
    , rdHoldingAddress :: Addr
    , rdInitialDatum :: PLC.Data
    , rdDeposit :: Integer
    , rdBookedAt :: Integer
    , rdProcessDeadline :: Integer
    , rdReclaimEnd :: Integer
    }
    deriving stock (Eq, Show)

-- | The datum of a configuration record.
configurationDatum :: RequestParameters -> PLC.Data
configurationDatum _ = error "Requests.Records.configurationDatum: not built"

-- | The parameters a configuration datum carries.
decodeConfiguration :: PLC.Data -> Maybe RequestParameters
decodeConfiguration _ = Nothing

{- | The datum of a pending registration; nothing when an address has no
Plutus form.
-}
registrationDatum :: RegistrationData -> Maybe PLC.Data
registrationDatum _ = error "Requests.Records.registrationDatum: not built"

{- | The registration a pending registration's datum carries; the network
completes the addresses, which the datum holds without one.
-}
decodeRegistration :: Network -> PLC.Data -> Maybe RegistrationData
decodeRegistration _ _ = Nothing

{- | The datum a holding starts with: a live record whose control names the
registry, the key, the controller, the deposit and the active token of the
key, and the payload.
-}
liveDatum
    :: RegistryIdentity
    -> ByteString
    -- ^ Key
    -> ByteString
    -- ^ Controller
    -> Integer
    -- ^ Deposit
    -> PLC.Data
    -- ^ Payload
    -> PLC.Data
liveDatum _ _ _ _ _ = error "Requests.Records.liveDatum: not built"

-- | The hash a registration approval commits for an initial datum.
initialDatumHash :: PLC.Data -> ByteString
initialDatumHash _ = error "Requests.Records.initialDatumHash: not built"

-- | The name of the approval token of a registration.
approvalNameOf :: RegistrationData -> Maybe AssetName
approvalNameOf _ = Nothing

-- | The actions of the request validator's mint.
data MintAction
    = {- | Create the configuration record of a registry: the registry, the
      seed its genesis spends, and the index of the record's output.
      -}
      ConfigurationCreate RegistryIdentity TxIn Integer
    | -- | Book the registration held by the output at this index.
      BookRegistration Integer
    | -- | Burn approvals; grants nothing.
      ApprovalBurn
    deriving stock (Eq, Show)

-- | The redeemer of the request validator's mint: its actions, in order.
mintRedeemer :: [MintAction] -> PLC.Data
mintRedeemer _ = error "Requests.Records.mintRedeemer: not built"

-- | The actions of the request validator's spend of a pending registration.
data SpendAction
    = -- | Fold into the holding at this output index.
      RegistrationFold Integer
    | -- | The refund address takes everything back.
      OwnerReclaim
    | -- | Anyone returns the deposit after the window.
      ExpiredCleanup
    deriving stock (Eq, Show)

-- | The redeemer of one spend action.
spendRedeemer :: SpendAction -> PLC.Data
spendRedeemer _ = error "Requests.Records.spendRedeemer: not built"

-- | Plutus Data handed to the transaction builder as it is.
newtype AsData = AsData PLC.Data

instance ToData AsData where
    toBuiltinData (AsData d) = BuiltinData d
