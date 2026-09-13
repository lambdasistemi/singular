{- |
Module      : Naming.Verify
Description : Pure retirement-binding verification (NOTE-024 item 3,
  NOTE-026)
License     : Apache-2.0

Pure predicates over already-resolved evidence for one retired
record. All inputs are plain bytes supplied by the caller (a reader
resolving them from transaction bodies); this module compares,
recomputes and routes — it parses nothing, trusts no constants, and
holds no keys.

The_EXE_ (retirement-verify) resolves every field below from retained
transaction CBOR plus public log mappings; the unit tests pin every
predicate here, including the wrong-policy\/same-name discrimination
(NOTE-026). Either side alone is insufficient: parsing without
predicates proves nothing, predicates without parsing check nothing.
-}
module Naming.Verify (
    RetireEvidence (..),
    positiveMintPolicy,
    verifyRetireEvidence,
) where

import Data.ByteString (ByteString)
import Data.Word (Word8)

import Naming.Register (representativeName)

-- | One retired record, fully resolved to plain evidence. Every hash
-- is raw bytes as found in bodies or public lines — never a runner
-- constant, never a key.
data RetireEvidence = RetireEvidence
    { reRecord :: String
    -- ^ Record outref under audit (@txid#idx@, linkage display).
    , reRetireTx :: String
    -- ^ Retire txid under audit.
    , reKeyHash :: ByteString
    -- ^ Retire redeemer key_hash (redeemer bytes).
    , reCreationHash :: ByteString
    -- ^ Creation control hash (claim-tx datum bytes).
    , reCreationHashLog :: ByteString
    -- ^ Creation hash as published in public creation material.
    , reCurrentControl :: ByteString
    -- ^ Control of the record as retired (creation control for LT
    -- units, rotated destination for RR units — creating-datum bytes).
    , reQuorum :: [ByteString]
    -- ^ Quorum members of the record as retired (creating datum).
    , rePolicy :: ByteString
    -- ^ Registry state policy bytes (state output address bytes).
    , reToken :: ByteString
    -- ^ Registry token name (request datum bytes).
    , reIncarnation :: Word8
    -- ^ Incarnation byte (trailing byte of the observed name).
    , reCreationMint :: [(ByteString, ByteString, Integer)]
    -- ^ Creation-tx mint triples (policy, name, quantity).
    , reCustodyPolicy :: ByteString
    -- ^ Custody output asset policy (retire-tx bytes).
    , reCustodyName :: ByteString
    -- ^ Custody output asset name (retire-tx bytes).
    , reCustodyQty :: Integer
    -- ^ Custody output asset quantity (retire-tx bytes).
    , reRepLog :: ByteString
    -- ^ Representative as published in public creation material.
    , reSigners :: [ByteString]
    -- ^ Retire-tx required signatories (body bytes).
    , reWitnesses :: [ByteString]
    -- ^ Retire-tx actual key witnesses (witness-set bytes).
    }
    deriving stock (Eq, Show)

-- | The representative mint policy of a creation fold: exactly one
-- positive-quantity policy (the approval burn is negative). Anything
-- else — none, several — fails: the derivation admits no judgment
-- calls about which policy is \"the\" representative one.
positiveMintPolicy :: [(ByteString, ByteString, Integer)] -> Either String ByteString
positiveMintPolicy triples = case [p | (p, _, q) <- triples, q > 0] of
    [p] -> Right p
    ps ->
        Left
            ( "expected exactly one positive mint policy, found "
                <> show (length ps)
            )

-- | The full binding verdict. Every clause names its own failure;
-- @Right ()@ means the retirement's key, name, custody triple,
-- creation mint, signers and witnesses all check out.
verifyRetireEvidence :: RetireEvidence -> Either String ()
verifyRetireEvidence ev = do
    -- Immutable key: redeemer, claim bytes and public log agree.
    unlessEq "retire key_hash is not the claim-derived creation hash" (reKeyHash ev) (reCreationHash ev)
    unlessEq "retire key_hash differs from public creation material" (reKeyHash ev) (reCreationHashLog ev)
    unlessEq
        "claim-derived control differs from public creation material"
        (reCreationHash ev)
        (reCreationHashLog ev)
    -- Representative policy derived from the creation mint, then used
    -- for every name check below (never taken from the custody value
    -- being checked).
    repPolicy <- positiveMintPolicy (reCreationMint ev)
    let repComputed = representativeName (reCreationHash ev) (rePolicy ev) (reToken ev) (reIncarnation ev)
    -- Creation mint binds the recomputed name at +1 under that policy.
    unlessEq
        "creation mint does not carry the recomputed rep at +1"
        [(n, q) | (p, n, q) <- reCreationMint ev, p == repPolicy]
        [(repComputed, 1)]
    -- Custody triple binds policy, name and quantity together: a
    -- same-name token under a different policy is a different asset
    -- and refuses here (NOTE-026).
    unlessEq "custody policy is not the derived rep policy" (reCustodyPolicy ev) repPolicy
    unlessEq "custody name is not the recomputed rep" (reCustodyName ev) repComputed
    unlessEq "custody quantity is not 1" (reCustodyQty ev) 1
    unlessEq "recomputed rep differs from public creation material" repComputed (reRepLog ev)
    -- Route: singleton signers must be the current control
    -- (controller route, rotated or not); larger sets must equal the
    -- quorum with the control absent (quorum route). Every expected
    -- signer must also have witnessed (declared signatories alone
    -- prove no authorization happened).
    case reSigners ev of
        [s] -> do
            unlessEq "singleton signer is not the record control" s (reCurrentControl ev)
            unlessWitnessed ev [s]
        ss -> do
            unlessEq "signer count matches neither route" (length ss) (length (reQuorum ev))
            unlessSubset "quorum-route signer outside the quorum" ss (reQuorum ev)
            unlessAbsent "quorum route signed by the controller" (reCurrentControl ev) ss
            unlessWitnessed ev ss
  where
    unlessEq _ a b | a == b = Right ()
    unlessEq msg _ _ = Left msg
    unlessSubset _ xs ys | all (`elem` ys) xs = Right ()
    unlessSubset msg _ _ = Left msg
    unlessAbsent _ x ys | x `notElem` ys = Right ()
    unlessAbsent msg _ _ = Left msg
    unlessWitnessed e ss =
        unlessSubset
            "expected signer has no witness bytes"
            ss
            (reWitnesses e)
