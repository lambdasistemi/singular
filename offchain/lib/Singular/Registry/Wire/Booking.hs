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

import Data.ByteString (ByteString)
import PlutusTx.Builtins.Internal (BuiltinByteString)
import Singular.Registry.Wire.Request (OnChainRegistrationRequest)

{- | The application tag name of a registration.

Not implemented yet: answers the empty name.
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
applicationTagName _ _ _ _ = mempty

{- | The trie-ready tag name of a registration.

Not implemented yet: answers the empty name.
-}
trieReadyTagName :: OnChainRegistrationRequest -> ByteString
trieReadyTagName _ = mempty
