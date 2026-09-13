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
    CompleteEvidence (..),
    positiveMintPolicy,
    verifyRetireEvidence,
    verifyCompletion,
) where

import Data.ByteString (ByteString)
import Data.Word (Word8)

import Naming.Register (overMarkerFor, representativeName)

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
    , reStatePolicy :: ByteString
    -- ^ Registry STATE policy bytes (state output address bytes).
    -- This is the policy the representative NAME commits to in its
    -- preimage (state-policy || token || control) — it is NOT the
    -- minting policy. The minting (representative) policy is derived
    -- separately by positiveMintPolicy over the creation mint and
    -- checked against custody; the two meet only in the creation-mint
    -- clause below (recomputed name carried at +1 UNDER the derived
    -- mint policy). Never confuse the two.
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
    -- Representative (minting) policy derived from the creation mint
    -- (never taken from the custody value being checked). The name
    -- recomputation below uses the STATE policy (reStatePolicy, the
    -- name-preimage policy) — NOT this derived mint policy; the two
    -- policies bind together only through the creation-mint clause
    -- (the state-policy-recomputed name rides at +1 under the derived
    -- mint policy) and the custody clause (same pair re-observed).
    repPolicy <- positiveMintPolicy (reCreationMint ev)
    let repComputed = representativeName (reCreationHash ev) (reStatePolicy ev) (reToken ev) (reIncarnation ev)
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

-- | One permissionless completion, fully resolved to plain evidence.
-- The representative pair comes from an already-verified retirement
-- (never re-derived here); every other field is resolved from the
-- completion transaction's own bytes.
data CompleteEvidence = CompleteEvidence
    { ceRetireTx :: String
    -- ^ Retire txid this completion closes (linkage display).
    , ceCompleteTx :: String
    -- ^ Completion txid under audit.
    , ceCustodyTxid :: String
    -- ^ Creator txid of the spent custody input (body bytes).
    , ceRequestTxid :: String
    -- ^ Creator txid of the folded request input (body bytes).
    -- Co-creation (NOTE-029): these two must be equal — the folded
    -- request is the retire's own, not one queued anywhere else.
    , ceReqOld :: ByteString
    -- ^ Folded request's old value (request datum bytes): the key's
    -- pre-update value, which must be the burned asset itself.
    , ceReqNew :: ByteString
    -- ^ Folded request's new value (request datum bytes): must be
    -- exactly the Over marker for the burned asset (NOTE-031 — the
    -- value relation scripts check on ledger).
    , ceRepPolicy :: ByteString
    -- ^ Verified representative policy (from the retire unit).
    , ceRepName :: ByteString
    -- ^ Verified representative name (from the retire unit).
    , ceCustodyPolicy :: ByteString
    -- ^ Spent custody input's asset policy (body bytes).
    , ceCustodyName :: ByteString
    -- ^ Spent custody input's asset name (body bytes).
    , ceCustodyQty :: Integer
    -- ^ Spent custody input's asset quantity (body bytes).
    , ceMint :: [(ByteString, ByteString, Integer)]
    -- ^ Completion mint triples (body bytes): exactly the burn.
    , ceBurnRedeemerOk :: Bool
    -- ^ Mint redeemer at the mint purpose is the burn shape
    -- (resolved by the caller; this module checks no redeemers).
    , ceIsModify :: Bool
    -- ^ State-spend redeemer decodes as a `Modify` (caller-resolved).
    , ceActionCount :: Int
    -- ^ Number of actions in that `Modify` (caller-resolved): exactly
    -- one. With a changed root below, singleton-ness is exactly one
    -- genuine `UpdateAction` (`Rejected` preserves the root).
    , ceRootBefore :: ByteString
    -- ^ Spent state root (state datum bytes).
    , ceRootAfter :: ByteString
    -- ^ Continuation state root (state datum bytes): must differ
    -- (a genuine transition, not Rejected-preserved).
    , ceReqSigners :: [ByteString]
    -- ^ Required signatories (body bytes): must be empty
    -- (permissionless — no approval by anybody).
    , ceWitnesses :: [ByteString]
    -- ^ Actual key witnesses (witness-set bytes).
    , ceFeeOwner :: ByteString
    -- ^ Payment hash owning the fee input (body bytes): the sole
    -- witness must be exactly this key (fee ownership, never
    -- authorization — see the Q-file on the no-signature criterion).
    , ceRouteKeys :: [ByteString]
    -- ^ Route keys that must not witness (control plus quorum).
    }
    deriving stock (Eq, Show)

-- | The full completion verdict: co-created pair, exact burn,
-- singleton-`Modify`, genuine root change, and permissionless
-- authorization (empty required signers, fee-owner-only witness
-- outside every route).
verifyCompletion :: CompleteEvidence -> Either String ()
verifyCompletion ev = do
    -- Co-creation: the folded request comes from the same creator
    -- transaction as the spent custody (a request queued anywhere
    -- else, or no request at all, refuses).
    unlessEq "folded request is not the retire's own (creator mismatch)" (ceRequestTxid ev) (ceCustodyTxid ev)
    -- Value relation: the folded Update moves the burned asset to
    -- its Over marker (what the scripts check on ledger).
    unlessEq "folded request old value is not the burned asset" (ceReqOld ev) (ceRepName ev)
    unlessEq
        "folded request does not write the Over marker"
        (ceReqNew ev)
        (overMarkerFor (ceRepName ev))
    -- Burn: the spent custody triple is the verified pair, and the
    -- mint field burns exactly it once.
    unlessEq "spent custody policy is not the verified rep policy" (ceCustodyPolicy ev) (ceRepPolicy ev)
    unlessEq "spent custody name is not the verified rep" (ceCustodyName ev) (ceRepName ev)
    unlessEq "spent custody quantity is not 1" (ceCustodyQty ev) 1
    unlessEq
        "completion mint is not exactly the burn"
        (ceMint ev)
        [(ceRepPolicy ev, ceRepName ev, -1)]
    unlessOk "mint redeemer is not the burn shape" (ceBurnRedeemerOk ev)
    -- Transition: singleton `Modify` plus a changed root (a
    -- `Rejected` action preserves the root and refuses here).
    unlessOk "state spend is not a Modify" (ceIsModify ev)
    unlessEq "Modify action is not a singleton" (ceActionCount ev) 1
    unlessNeq "registry root unchanged (no genuine transition)" (ceRootBefore ev) (ceRootAfter ev)
    -- Permissionless: nobody's approval rides the transaction; the
    -- sole witness owns the fee input and stands outside every route.
    unlessEq "required signers not empty (not permissionless)" (ceReqSigners ev) []
    unlessEq "witness is not exactly the fee owner" (ceWitnesses ev) [ceFeeOwner ev]
    unlessAbsent "route key witnessed the completion" (ceWitnesses ev) (ceRouteKeys ev)
  where
    unlessEq _ a b | a == b = Right ()
    unlessEq msg _ _ = Left msg
    unlessNeq _ a b | a /= b = Right ()
    unlessNeq msg _ _ = Left msg
    unlessOk _ True = Right ()
    unlessOk msg _ = Left msg
    unlessAbsent _ xs ys | all (`notElem` ys) xs = Right ()
    unlessAbsent msg _ _ = Left msg
