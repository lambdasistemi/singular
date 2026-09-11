{- |
Module      : Conformance.Authenticate
Description : The consumer's canonical-registry authentication (issue #69)

cardano-keri's ruling gives the registry to identity uniqueness, and
epic 16 executed the correction: a permissionless ledger cannot
prohibit a rival registry (naming-correspondence.md, "What t50
settled"). Canonical identity is therefore a /derivation the
consumer authenticates/, not a refusal the chain performs: the
canonical registry token's name is SHA-256 of the canonical seed's
outRef, that seed can never be spent twice, and a rival from another
seed can never carry that name.

This module is the pure decision core the devnet rows execute. It
never talks to the chain; the runner feeds it assets read back from
chain UTxOs at the derived address. Two decisions exist on purpose:

* 'authenticate' — the consumer's check: exact policy, the derived
  name, quantity one.
* 'authenticateWeak' — the CA03 control: policy only (the address
  leg is the query itself). It is designed to accept a consistent
  rival, which is what makes CA02's rejection attributable to the
  name check and nothing else. A control that could not accept would
  prove nothing.
-}
module Conformance.Authenticate (
    -- * Decisions
    AuthDecision (..),
    AuthReject (..),
    authenticate,
    authenticateWeak,
    -- * Chain-shaped input
    Assets,
) where

import Data.ByteString (ByteString)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

-- | One output's token assets, as the ledger reports them:
-- policy-id bytes @->@ asset-name bytes @->@ quantity.
type Assets = Map ByteString (Map ByteString Integer)

-- | The authentication verdict for one output.
data AuthDecision
    = AuthAccept
    | AuthReject AuthReject
    deriving stock (Show, Eq)

-- | Why an output failed canonical authentication. The failing leg
-- is named so a rejection is attributable, the same discipline the
-- refusal matcher applies to node reasons.
data AuthReject
    = -- | No asset at all under the canonical policy: whatever this
      -- output is, it is not a registry (the CA05 forgery).
      PolicyAbsent
    | -- | The policy is present but the derived name is not: a rival
      -- registry from another seed (the CA02 rival).
      NameMismatch
    | -- | The canonical name with a quantity other than one.
      QuantityNotOne Integer
    deriving stock (Show, Eq)

{- | Canonical authentication: the exact policy, the name derived
from the published seed, quantity one. Every leg must hold.
-}
authenticate :: ByteString -> ByteString -> Assets -> AuthDecision
authenticate policy name assets = case Map.lookup policy assets of
    Nothing -> AuthReject PolicyAbsent
    Just underPolicy -> case Map.lookup name underPolicy of
        Nothing -> AuthReject NameMismatch
        Just 1 -> AuthAccept
        Just q -> AuthReject (QuantityNotOne q)

{- | The CA03 control: policy only. The address leg is the query
itself (the runner reads UTxOs at the derived address), so the weak
check is exactly @policy present@. It accepts a consistent rival by
design — that acceptance is the observation that makes CA02's
rejection attributable to the derived name.
-}
authenticateWeak :: ByteString -> Assets -> AuthDecision
authenticateWeak policy assets = case Map.lookup policy assets of
    Nothing -> AuthReject PolicyAbsent
    Just _ -> AuthAccept
