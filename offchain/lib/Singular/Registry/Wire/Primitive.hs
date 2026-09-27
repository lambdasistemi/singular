{- |
Module      : Singular.Registry.Wire.Primitive
Description : Primitive registry wire values, their codecs, and the shared Data helpers
License     : Apache-2.0

The leaf of the registry wire family: the token identifier, output
reference and root values every other wire module builds on, their
'ToData'\/'FromData'\/'UnsafeFromData' codecs, and the 'Data'
conversion helpers the codecs share. Depends on no sibling; nothing
here is importable by a caller — the public surface is the
"Singular.Registry.Types" facade.
-}
module Singular.Registry.Wire.Primitive (
    -- * On-chain domain types (Plutus primitives)
    OnChainTokenId (..),
    OnChainTxOutRef (..),
    OnChainRoot (..),

    -- * Helpers for manual Data construction
    mkD,
    unD,
    bsToD,
    bsFromD,
    bbsToD,
    bbsFromD,
) where

import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (
    FromData (..),
    ToData (..),
    UnsafeFromData (..),
 )

{- | On-chain token identifier (asset name as raw
bytes). Matches Aiken @lib\/TokenId@.
-}
newtype OnChainTokenId = OnChainTokenId
    { unOnChainTokenId :: BuiltinByteString
    }
    deriving stock (Show, Eq)

{- | On-chain output reference. Matches Aiken
@cardano\/transaction\/OutputReference@.
-}
data OnChainTxOutRef = OnChainTxOutRef
    { txOutRefId :: !BuiltinByteString
    -- ^ Transaction hash (32 bytes)
    , txOutRefIdx :: !Integer
    -- ^ Output index within the transaction
    }
    deriving stock (Show, Eq)

-- | On-chain MPF root hash (raw bytes).
newtype OnChainRoot = OnChainRoot
    { unOnChainRoot :: ByteString
    }
    deriving stock (Show, Eq)

-- ---------------------------------------------------------
-- Helpers for manual Data construction
-- ---------------------------------------------------------

-- | Wrap a raw 'Data' value as 'BuiltinData'.
mkD :: Data -> BuiltinData
mkD = BuiltinData

-- | Unwrap 'BuiltinData' to the raw 'Data' AST.
unD :: BuiltinData -> Data
unD (BuiltinData d) = d

-- | Lift a 'ByteString' into a 'Data' byte-literal.
bsToD :: ByteString -> Data
bsToD = B

-- | Extract a 'ByteString' from a 'Data' byte-literal.
bsFromD :: Data -> Maybe ByteString
bsFromD (B bs) = Just bs
bsFromD _ = Nothing

{- | Lift a 'BuiltinByteString' into a 'Data'
byte-literal.
-}
bbsToD :: BuiltinByteString -> Data
bbsToD (BuiltinByteString bs) = B bs

{- | Extract a 'BuiltinByteString' from a 'Data'
byte-literal.
-}
bbsFromD :: Data -> Maybe BuiltinByteString
bbsFromD (B bs) = Just (BuiltinByteString bs)
bbsFromD _ = Nothing

-- ---------------------------------------------------------
-- ToData / FromData instances
-- ---------------------------------------------------------

instance ToData OnChainTokenId where
    toBuiltinData (OnChainTokenId bbs) =
        mkD $ Constr 0 [bbsToD bbs]

instance FromData OnChainTokenId where
    fromBuiltinData bd = case unD bd of
        Constr 0 [x] ->
            OnChainTokenId <$> bbsFromD x
        _ -> Nothing

instance UnsafeFromData OnChainTokenId where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [x] -> case bbsFromD x of
            Just bbs -> OnChainTokenId bbs
            _ ->
                error
                    "unsafeFromBuiltinData: OnChainTokenId"
        _ ->
            error
                "unsafeFromBuiltinData: OnChainTokenId"

instance ToData OnChainTxOutRef where
    toBuiltinData OnChainTxOutRef{..} =
        mkD $
            Constr
                0
                [bbsToD txOutRefId, I txOutRefIdx]

instance FromData OnChainTxOutRef where
    fromBuiltinData bd = case unD bd of
        Constr 0 [tid, I idx] ->
            OnChainTxOutRef
                <$> bbsFromD tid
                <*> pure idx
        _ -> Nothing

instance UnsafeFromData OnChainTxOutRef where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [B tid, I idx] ->
            OnChainTxOutRef
                (BuiltinByteString tid)
                idx
        _ ->
            error
                "unsafeFromBuiltinData: OnChainTxOutRef"

instance ToData OnChainRoot where
    toBuiltinData (OnChainRoot bs) = mkD $ bsToD bs

instance FromData OnChainRoot where
    fromBuiltinData bd =
        OnChainRoot <$> bsFromD (unD bd)

instance UnsafeFromData OnChainRoot where
    unsafeFromBuiltinData bd = case unD bd of
        B bs -> OnChainRoot bs
        _ ->
            error
                "unsafeFromBuiltinData: OnChainRoot"
