{-# LANGUAGE OverloadedStrings #-}

-- | The ledger derivations for the genuine insert flow (issue #77): the
-- insert-approval asset name bound at mint and recomputed at fold, and
-- the representative asset name the fold mints under the representative
-- policy.
--
-- Both mirror validator code in
-- @naming-onchain/validators/application.ak@ (@insert_approval_name@,
-- @representative_name@); the agreement executes on every insert fold —
-- a Haskell/Aiken mismatch fails phase-2 validation — and is pinned by
-- the fixture vectors in @Naming.RegisterSpec@.
module Naming.Register
  ( insertApprovalDomain
  , insertApprovalName
  , representativePrefix
  , freshIncarnation
  , registryAssetId
  , representativeName
  , overMarkerFor
  ) where

import Crypto.Hash (Blake2b_224, Blake2b_256, Digest, hash)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word8)

-- | Domain separator of the insert-approval hash, in the style of the
-- next-control commitment's own domain.
insertApprovalDomain :: ByteString
insertApprovalDomain = "singular/naming/insert-approval/v1"

-- | The insert-approval asset name:
-- @BLAKE2b-256(domain || 0x00 || control || commitment)@ — 32 bytes, so
-- never a canonical address and never confusable with a withdraw
-- approval. @control@ is the record's control-address bytes and
-- @commitment@ its 32-byte next-control commitment.
insertApprovalName :: ByteString -> ByteString -> ByteString
insertApprovalName control commitment =
    convert
        ( hash
            ( insertApprovalDomain
                <> BS.singleton 0x00
                <> control
                <> commitment
            ) :: Digest Blake2b_256
        )

-- | Representative-name prefix: ASCII @Rep@.
representativePrefix :: ByteString
representativePrefix = "Rep"

-- | The incarnation fresh inserts carry: @0x00@.
freshIncarnation :: Word8
freshIncarnation = 0x00

-- | The registry asset identity (NOTE-007/008/009): the FULL native asset
-- identity — state policy id bytes (28, fixed) followed by cage token name
-- bytes (variable) — concatenated with no framing and no textual hex step
-- (the same bytes the ledger pairs in every `Value`; fixed 28-byte policy
-- prefix keeps the parse unambiguous for hashing). The ONE place the
-- identity bytes are formed off chain; `representative_name`'s Aiken mirror
-- (`application.ak:registry_asset_id`) is the other. Widths enforced below,
-- not assumed: policy and control must be 28 bytes or this fails loudly.
registryAssetId :: ByteString -> ByteString -> ByteString
registryAssetId policyBytes tokenName
    | BS.length policyBytes == 28 = policyBytes <> tokenName
    | otherwise = error "registryAssetId: state policy bytes must be 28"

-- | The representative asset name: @Rep ‖ blake2b_224(registry ‖ control) ‖
-- incarnation@ — 32 bytes, so never a canonical address. Mirrors
-- `application.ak:representative_name` byte-for-byte (NOTE-008 byte
-- contract): prefix, digest over `registryAssetId` then control hash, then
-- incarnation. Control must be 28 bytes (payment-key hash); enforced here
-- as on chain (`bytearray.length` expects there).
representativeName :: ByteString -> ByteString -> ByteString -> Word8 -> ByteString
representativeName keyHash policyBytes tokenName incarnation
    | BS.length keyHash == 28 =
        representativePrefix
            <> convert
                ( hash
                    ( registryAssetId policyBytes tokenName <> keyHash
                    ) :: Digest Blake2b_224
                )
            <> BS.singleton incarnation
    | otherwise = error "representativeName: control key hash must be 28 bytes"

-- | The Over marker for a burned representative (NOTE-031): the Update
-- value a genuine retirement request writes. Mirrors
-- `naming.over_marker_for` byte-for-byte: constant "over" prefix
-- (distinct from insert values, which are bare representative names)
-- committing to the exact held asset.
overMarkerFor :: ByteString -> ByteString
overMarkerFor rep = "over" <> rep
