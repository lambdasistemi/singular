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
  , representativeName
  ) where

import Crypto.Hash (Blake2b_256, Digest, hash)
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

-- | The representative asset name: @Rep || keyHash || incarnation@ — 32
-- bytes for a 28-byte control key hash, so never a canonical address.
-- The registry half of @Singular.representative@'s scope lives in the
-- representative policy itself (parameterized by the application policy
-- hash); the name carries key and incarnation.
representativeName :: ByteString -> Word8 -> ByteString
representativeName keyHash incarnation =
    representativePrefix <> keyHash <> BS.singleton incarnation
