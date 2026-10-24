{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.State.Preimage
Description : The hashed-name preimages of the Singular state, as bytes
License     : Apache-2.0

Every hashed name of the Singular state is the blake2b-256 hash of a preimage,
and the preimage is the Plutus Data serialisation of a structured value with
one constructor per role. The constructors are numbered as the model's
@Preimage@, so two roles never share a preimage even when they carry the same
fields.

The bytes are pinned by the vectors in
@test\/fixtures\/preimage-vectors.json@, which the on-chain functions of
@singular_state\/preimage.ak@ reproduce as well. Nothing here builds a
transaction.
-}
module Singular.State.Preimage
    ( -- * The roles
      Preimage (..)
    , encodePreimage
    , roleName

      -- * The names the line builds
    , stateTokenName
    , activeTokenName
    , registrationPreimage
    , approvalName
    ) where

import Codec.Serialise (serialise)
import Crypto.Hash (Blake2b_256 (..), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import PlutusCore.Data (Data (..))
import PlutusLedgerApi.V3
    ( Address
    , DatumHash (..)
    , Lovelace
    , getLovelace
    )
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import PlutusTx.IsData.Class (toBuiltinData)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (AssetName (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )

{- | The structured value hashed into a name, one constructor per role,
numbered as the model's @Preimage@. The configuration and termination
constructors keep that numbering; nothing builds them in this line yet.
-}
data Preimage
    = -- | The registry created by spending the seed.
      State TxIn
    | -- | The token that stands for a key in a registry.
      Active RegistryIdentity ByteString
    | -- | The registry's application configuration.
      ApplicationConfiguration RegistryIdentity
    | {- | The approval of one registration: registry, key, the address the
      holding sits at, the hash of the holding's initial datum and the deposit
      it holds.
      -}
      RegistrationApproval
        RegistryIdentity
        ByteString
        Address
        DatumHash
        Lovelace
    | -- | The approval of the termination of a key.
      TerminationApproval RegistryIdentity ByteString
    deriving stock (Eq, Show)

-- | The Plutus Data serialisation of a preimage.
encodePreimage :: Preimage -> ByteString
encodePreimage = BL.toStrict . serialise . preimageData

-- | A preimage as the value that is serialised: one constructor per role.
preimageData :: Preimage -> Data
preimageData = \case
    State seed -> Constr 0 [seedData seed]
    Active registry key -> Constr 1 [registryData registry, B key]
    ApplicationConfiguration{} -> reserved
    RegistrationApproval registry key holding hash deposit ->
        Constr
            3
            [ registryData registry
            , B key
            , addressData holding
            , datumHashData hash
            , I (getLovelace deposit)
            ]
    TerminationApproval{} -> reserved

-- | The constructors that keep the model's numbering; nothing builds them yet.
reserved :: a
reserved = error "Singular.State.Preimage: no encoding for a reserved role"

-- | An output reference: the transaction id and the output index.
seedData :: TxIn -> Data
seedData (TxIn (TxId hash) (TxIx index)) =
    Constr 0 [B (hashToBytes (extractHash hash)), I (toInteger index)]

-- | A registry identity: the state policy and the state token name.
registryData :: RegistryIdentity -> Data
registryData (RegistryIdentity (StatePolicyId policy) (AssetName name)) =
    Constr 0 [B policy, B (SBS.fromShort name)]

-- | An address, as the ledger hands it to a script.
addressData :: Address -> Data
addressData address = case toBuiltinData address of
    BuiltinData data' -> data'

-- | The hash of a datum: its 32 bytes.
datumHashData :: DatumHash -> Data
datumHashData (DatumHash (BuiltinByteString bytes)) = B bytes

-- | The name of a role: the blake2b-256 hash of its preimage.
roleName :: Preimage -> AssetName
roleName = approvalName . encodePreimage

-- | The name of the state token of the registry created by spending the seed.
stateTokenName :: TxIn -> AssetName
stateTokenName = roleName . State

-- | The name of the token that stands for a key in a registry.
activeTokenName :: RegistryIdentity -> ByteString -> AssetName
activeTokenName registry = roleName . Active registry

{- | The Plutus Data serialisation of the registration approval preimage: the
key, the registry, the address the holding sits at, the hash of the holding's
initial datum and the deposit.
-}
registrationPreimage
    :: ByteString
    -> RegistryIdentity
    -> Address
    -> DatumHash
    -> Lovelace
    -> ByteString
registrationPreimage key registry holding datumHash deposit =
    encodePreimage
        (RegistrationApproval registry key holding datumHash deposit)

-- | The name of the approval token whose preimage is the given bytes.
approvalName :: ByteString -> AssetName
approvalName = AssetName . SBS.toShort . BA.convert . hashWith Blake2b_256
