{-# LANGUAGE LambdaCase #-}

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
    , ProtectedControl (..)
    , RegistrationData (..)
    , configurationDatum
    , decodeConfiguration
    , registrationDatum
    , decodeRegistration
    , liveDatum
    , decodeLiveDatum

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

import Codec.Serialise (serialise)
import Crypto.Hash (Blake2b_256 (..), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import PlutusCore.Data qualified as PLC
import PlutusLedgerApi.V1 qualified as PV1
import PlutusLedgerApi.V3 qualified as PV3
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (FromData (..), ToData (..))

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network, TxIx (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value (AssetName (..), PolicyID (..))
import Cardano.Ledger.Plutus.TxInfo (transAddr)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , registrationPreimage
    , seedData
    )

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

-- | The immutable control of a live holding in the current datum wire.
data ProtectedControl = ProtectedControl
    { controlRegistry :: RegistryIdentity
    , controlActiveAsset :: (PolicyID, AssetName)
    , controlKey :: ByteString
    , controlController :: ByteString
    , controlDeposit :: Integer
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
configurationDatum p =
    PLC.Constr
        0
        [ PLC.Constr
            0
            ( map
                PLC.I
                [ rpRegistrationCost p
                , rpMinimumTip p
                , rpProcessTime p
                , rpRetractTime p
                , rpBookingWidth p
                ]
            )
        ]

-- | The parameters a configuration datum carries.
decodeConfiguration :: PLC.Data -> Maybe RequestParameters
decodeConfiguration = \case
    PLC.Constr
        0
        [ PLC.Constr
                0
                [ PLC.I cost
                    , PLC.I tipped
                    , PLC.I process
                    , PLC.I retract
                    , PLC.I width
                    ]
            ] -> Just (RequestParameters cost tipped process retract width)
    _ -> Nothing

{- | The datum of a pending registration; nothing when an address has no
Plutus form.
-}
registrationDatum :: RegistrationData -> Maybe PLC.Data
registrationDatum r = do
    refund <- addressData (rdRefundAddress r)
    holding <- addressData (rdHoldingAddress r)
    pure $
        PLC.Constr
            1
            [ PLC.Constr
                0
                [ registryData (rdRegistry r)
                , PLC.B (rdKey r)
                , PLC.B (rdController r)
                , refund
                , holding
                , rdInitialDatum r
                , PLC.I (rdDeposit r)
                , PLC.I (rdBookedAt r)
                , PLC.I (rdProcessDeadline r)
                , PLC.I (rdReclaimEnd r)
                ]
            ]

{- | The registration a pending registration's datum carries; the network
completes the addresses, which the datum holds without one.
-}
decodeRegistration :: Network -> PLC.Data -> Maybe RegistrationData
decodeRegistration net = \case
    PLC.Constr
        1
        [ PLC.Constr
                0
                [ PLC.Constr 0 [PLC.B policy, PLC.B name]
                    , PLC.B key
                    , PLC.B controller
                    , refund
                    , holding
                    , initial
                    , PLC.I deposit
                    , PLC.I booked
                    , PLC.I process
                    , PLC.I reclaim
                    ]
            ] -> do
            refundAddress <- ledgerAddress net refund
            holdingAddress <- ledgerAddress net holding
            pure
                RegistrationData
                    { rdRegistry =
                        RegistryIdentity
                            (StatePolicyId policy)
                            (AssetName (SBS.toShort name))
                    , rdKey = key
                    , rdController = controller
                    , rdRefundAddress = refundAddress
                    , rdHoldingAddress = holdingAddress
                    , rdInitialDatum = initial
                    , rdDeposit = deposit
                    , rdBookedAt = booked
                    , rdProcessDeadline = process
                    , rdReclaimEnd = reclaim
                    }
    _ -> Nothing

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
liveDatum registry@(RegistryIdentity (StatePolicyId policy) _) key controller deposit payload =
    PLC.Constr
        2
        [ PLC.Constr
            0
            [ registryData registry
            , PLC.Constr
                0
                [PLC.B policy, PLC.B (assetBytes (activeTokenName registry key))]
            , PLC.B key
            , PLC.B controller
            , PLC.I deposit
            ]
        , payload
        ]

-- | Decode the current live datum, retaining its protected control and payload.
decodeLiveDatum :: PLC.Data -> Maybe (ProtectedControl, PLC.Data)
decodeLiveDatum = \case
    PLC.Constr
        2
        [ PLC.Constr
                0
                [ PLC.Constr 0 [PLC.B policy, PLC.B name]
                    , PLC.Constr 0 [PLC.B activePolicy, PLC.B activeName]
                    , PLC.B key
                    , PLC.B controller
                    , PLC.I deposit
                    ]
            , payload
            ] | deposit >= 0 -> do
            active <- PolicyID . ScriptHash <$> hashFromBytes activePolicy
            pure
                ( ProtectedControl
                    (RegistryIdentity (StatePolicyId policy) (AssetName (SBS.toShort name)))
                    (active, AssetName (SBS.toShort activeName))
                    key
                    controller
                    deposit
                , payload
                )
    _ -> Nothing

-- | The hash a registration approval commits for an initial datum.
initialDatumHash :: PLC.Data -> ByteString
initialDatumHash datum =
    BA.convert (hashWith Blake2b_256 (BL.toStrict (serialise datum)))

-- | The name of the approval token of a registration.
approvalNameOf :: RegistrationData -> Maybe AssetName
approvalNameOf r = do
    holding <- transAddr (rdHoldingAddress r)
    pure $
        approvalName $
            registrationPreimage
                (rdKey r)
                (rdRegistry r)
                holding
                ( PV3.DatumHash
                    (BuiltinByteString (initialDatumHash (rdInitialDatum r)))
                )
                (PV3.Lovelace (rdDeposit r))

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
    | -- | Book termination from the holding input into this output.
      BookTermination TxIn Integer
    deriving stock (Eq, Show)

-- | The redeemer of the request validator's mint: its actions, in order.
mintRedeemer :: [MintAction] -> PLC.Data
mintRedeemer = PLC.List . map action
  where
    action = \case
        ConfigurationCreate registry (TxIn (TxId seed) (TxIx index)) output ->
            let RegistryIdentity (StatePolicyId policy) (AssetName name) = registry
            in  PLC.Constr
                    0
                    [ PLC.B policy
                    , PLC.B (SBS.fromShort name)
                    , PLC.Constr
                        0
                        [ PLC.B (hashToBytes (extractHash seed))
                        , PLC.I (toInteger index)
                        ]
                    , PLC.I output
                    ]
        BookRegistration output -> PLC.Constr 1 [PLC.I output]
        ApprovalBurn -> PLC.Constr 2 []
        BookTermination reference output -> PLC.Constr 3 [seedData reference, PLC.I output]

-- | The actions of the request validator's spend of a pending registration.
data SpendAction
    = -- | Fold into the holding at this output index.
      RegistrationFold Integer
    | -- | The refund address takes everything back.
      OwnerReclaim
    | -- | Anyone returns the deposit after the window.
      ExpiredCleanup
    | -- | Recreate a live holding at this output index with a new payload.
      LiveUpdate Integer
    | -- | Move the active token into a termination request at this output.
      TerminationBook Integer
    | -- | Fold a booked termination for this registry and key.
      TerminationFold RegistryIdentity ByteString
    deriving stock (Eq, Show)

-- | The redeemer of one spend action.
spendRedeemer :: SpendAction -> PLC.Data
spendRedeemer = \case
    RegistrationFold output -> PLC.Constr 0 [PLC.I output]
    OwnerReclaim -> PLC.Constr 1 []
    ExpiredCleanup -> PLC.Constr 2 []
    LiveUpdate output -> PLC.Constr 3 [PLC.I output]
    TerminationBook output -> PLC.Constr 4 [PLC.I output]
    TerminationFold (RegistryIdentity (StatePolicyId policy) name) key ->
        PLC.Constr 5 [PLC.B policy, PLC.B (assetBytes name), PLC.B key]

-- | Plutus Data handed to the transaction builder as it is.
newtype AsData = AsData PLC.Data

instance ToData AsData where
    toBuiltinData (AsData d) = BuiltinData d

-- | A registry identity: the state policy and the state token name.
registryData :: RegistryIdentity -> PLC.Data
registryData (RegistryIdentity (StatePolicyId policy) name) =
    PLC.Constr 0 [PLC.B policy, PLC.B (assetBytes name)]

assetBytes :: AssetName -> ByteString
assetBytes (AssetName name) = SBS.fromShort name

{- | An address as the validator reads it: the ledger's own translation of
it for a script.
-}
addressData :: Addr -> Maybe PLC.Data
addressData address = do
    translated <- transAddr address
    let BuiltinData d = toBuiltinData translated
    pure d

{- | The ledger address a Plutus address stands for on a network; nothing for
a pointer address or for hashes that are not 28 bytes.
-}
ledgerAddress :: Network -> PLC.Data -> Maybe Addr
ledgerAddress net datum = do
    PV1.Address payment staking <- fromBuiltinData (BuiltinData datum)
    Addr net <$> credential payment <*> stakeReference staking
  where
    credential = \case
        PV1.PubKeyCredential (PV1.PubKeyHash (BuiltinByteString h)) ->
            KeyHashObj . KeyHash <$> hashFromBytes h
        PV1.ScriptCredential (PV1.ScriptHash (BuiltinByteString h)) ->
            ScriptHashObj . ScriptHash <$> hashFromBytes h
    stakeReference = \case
        Nothing -> Just StakeRefNull
        Just (PV1.StakingHash c) -> StakeRefBase <$> credential c
        Just PV1.StakingPtr{} -> Nothing
