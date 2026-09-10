{- |
Module      : Cardano.MPFS.Cage.AssetName
Description : Deterministic asset-name derivation
License     : Apache-2.0

Derives a unique asset name from an output reference,
matching Aiken's @lib.assetName@:

@SHA2-256(txId ++ bigEndian16(outputIndex))@
-}
module Cardano.MPFS.Cage.AssetName (
    -- * Asset-name derivation
    deriveAssetName,
) where

import Cardano.MPFS.Cage.Types (OnChainTxOutRef (..))
import Crypto.Hash (Digest, SHA256, hash)
import Data.Bits (shiftR)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word16)
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
 )

{- | Derive the asset name from an output reference,
matching Aiken's @lib.assetName@:

@SHA2-256(txId ++ bigEndian16(outputIndex))@
-}
deriveAssetName :: OnChainTxOutRef -> ByteString
deriveAssetName OnChainTxOutRef{txOutRefId, txOutRefIdx} =
    convert digest
  where
    digest :: Digest SHA256
    digest = hash (txIdBytes <> indexBytes)

    txIdBytes :: ByteString
    txIdBytes =
        let BuiltinByteString bs = txOutRefId
         in bs

    indexBytes :: ByteString
    indexBytes =
        let w16 =
                fromIntegral txOutRefIdx :: Word16
         in BS.pack
                [ fromIntegral (w16 `shiftR` 8)
                , fromIntegral w16
                ]
