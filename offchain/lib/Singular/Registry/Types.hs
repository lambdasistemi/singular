{- |
Module      : Singular.Registry.Types
Description : PlutusData types for the registry validator
License     : Apache-2.0

The caller-importable surface of the registry wire: every datum,
redeemer, domain type, edge constant and helper that used to live in
this module, re-exported unchanged from the five focused owners of the
Singular.Registry.Wire family that now hold each definition beside its
encoding instances. The constructors, selectors, strictness and
'ToData'\/'FromData'\/'UnsafeFromData' encodings are byte-identical to
the single-module era; existing callers keep importing this facade and
should continue to. See the wire guide
("Singular.Registry.Wire.Primitive" and its siblings) for who owns
what and the dependency direction between the owners.
-}
module Singular.Registry.Types (
    -- * On-chain datum\/redeemer types
    CageDatum (..),
    MintRedeemer (..),
    Migration (..),
    UpdateRedeemer (..),
    RequestAction (..),

    -- * On-chain domain types
    OnChainTokenId (..),
    Edge,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateActive,
    edgeUpdateTerminal,
    edgeDeleteAbsent,
    edgeDeleteActive,
    edgeWitnessTerminal,
    edgeName,
    RequestPhase (..),
    requestPhase,
    OnChainRoot (..),
    OnChainRequest (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),

    -- * Proof steps (Aiken MPF proof encoding)
    ProofStep (..),
    Neighbor (..),

    -- * State helpers
    stateActivePolicyBytes,
    stateAppPolicyBytes,
    stateAbsentPolicyBytes,
    stateTerminalPolicyBytes,

    -- * Pinned-hook consumer redeemer (NOTE-021)
    ConsumerRedeemer (..),
) where

import Singular.Registry.Wire.Primitive (
    OnChainRoot (..),
    OnChainTokenId (..),
    OnChainTxOutRef (..),
 )
import Singular.Registry.Wire.Proof (
    Neighbor (..),
    ProofStep (..),
 )
import Singular.Registry.Wire.Redeemer (
    ConsumerRedeemer (..),
    Migration (..),
    MintRedeemer (..),
    RequestAction (..),
    UpdateRedeemer (..),
 )
import Singular.Registry.Wire.Request (
    Edge,
    OnChainRequest (..),
    RequestPhase (..),
    edgeDeleteAbsent,
    edgeDeleteActive,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeName,
    edgeUpdateActive,
    edgeUpdateTerminal,
    edgeWitnessTerminal,
    requestPhase,
 )
import Singular.Registry.Wire.State (
    CageDatum (..),
    OnChainTokenState (..),
    stateAbsentPolicyBytes,
    stateActivePolicyBytes,
    stateAppPolicyBytes,
    stateTerminalPolicyBytes,
 )
