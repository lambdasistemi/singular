{- |
Module      : Singular.Registry.Wire.Booking
Description : The two tag names a registration booking mints
License     : Apache-2.0

A registration booking mints two tags in the same transaction: an
application tag under the registry's application policy, and a trie-ready
tag under its request policy. Each name is the BLAKE2b-256 hash of the data
encoding of a list of the fields it commits to, in the order the model
hashes them. Neither name commits to the delivered datum, the registry or
the booked time. Reads "Singular.Registry.Wire.Request"; nothing here is
importable by a caller — the public surface is the
"Singular.Registry.Types" facade.
-}
module Singular.Registry.Wire.Booking
    ( applicationTagName
    , trieReadyTagName
    ) where

import Cardano.Crypto.Hash (Blake2b_256, hashToBytes, hashWith)
import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins qualified as Builtins
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )
import Singular.Registry.Wire.Request
    ( OnChainRegistrationRequest (..)
    )

{- | The name a list of data fields hashes to: BLAKE2b-256 of the data
encoding of the list, by the same builtin a script's @serialise_data@ runs.
Integers stay integers and byte strings stay byte strings, so the encoding
separates its fields.
-}
nameOf :: [Data] -> ByteString
nameOf fields =
    case Builtins.serialiseData (BuiltinData (List fields)) of
        BuiltinByteString encoded ->
            hashToBytes (hashWith @Blake2b_256 id encoded)

{- | The application tag name of a registration: the hash of the list
@[0, 1, key, refund_address, destination, nonce]@, the list the model hashes.
-}
applicationTagName
    :: ByteString
    -- ^ The registry key
    -> BuiltinByteString
    -- ^ The refund address (payment key hash)
    -> ByteString
    -- ^ The destination address bytes
    -> Integer
    -- ^ The nonce
    -> ByteString
applicationTagName key (BuiltinByteString refund) destination nonce =
    nameOf [I 0, I 1, B key, B refund, B destination, I nonce]

{- | The trie-ready tag name of a registration: the hash of the list
@[1, 0, key, refund_address, destination, cost, tip, carrier, nonce]@.
-}
trieReadyTagName :: OnChainRegistrationRequest -> ByteString
trieReadyTagName OnChainRegistrationRequest{..} =
    nameOf
        [ I 1
        , I 0
        , B regKey
        , B refund
        , B regDestination
        , I regRegistrationCost
        , I regDeclaredTip
        , I regCarrierAda
        , I regNonce
        ]
  where
    BuiltinByteString refund = regRefundAddress
