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

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import PlutusLedgerApi.V3 (Address, DatumHash, Lovelace)

import Cardano.Ledger.Mary.Value (AssetName (..))
import Cardano.Ledger.TxIn (TxIn)

import Singular.Registry.TrieState (RegistryIdentity)

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
encodePreimage _ = BS.empty

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
approvalName _ = AssetName mempty
