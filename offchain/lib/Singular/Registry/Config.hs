{- |
Module      : Singular.Registry.Config
Description : Configuration for shared registry adapters
License     : Apache-2.0

Configuration record for shared registry identity and history adapters. Holds the global state PlutusV3 script
bytes, the unapplied request validator bytes, the
state script hash, the seed @OutputReference@ used
by boot minting, default token parameters, and
network.
-}
module Singular.Registry.Config
    ( -- * Configuration
      CageConfig (..)
    , bootStateFromCfg
    ) where

import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS

import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Hashes (ScriptHash)

import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Types
    ( OnChainRoot (..)
    , OnChainTokenState (..)
    , OnChainTxOutRef
    )

{- | Configuration for the shared registry adapters.

The 'cageScriptBytes' field holds the raw
flat-encoded global state UPLC script. The
'requestScriptBytes' field holds the raw
flat-encoded request validator before applying
@(statePolicyId, cageToken)@. The 'cfgScriptHash'
is the state script hash and therefore the state
policy ID. The 'cageSeed' records the
@OutputReference@ consumed by boot minting.
(Ownerless registry, ruling NOTE-028/A-003: no staking
surface remains; the former @cfgStakeScript@ hook is
gone with the owner role.)
-}
data CageConfig = CageConfig
    { cageScriptBytes :: !ShortByteString
    -- ^ PlutusV3 state script bytes
    , requestScriptBytes :: !ShortByteString
    -- ^ Unapplied PlutusV3 request script bytes
    , cfgScriptHash :: !ScriptHash
    -- ^ Hash of the state PlutusV3 script
    , cageSeed :: !OnChainTxOutRef
    -- ^ Seed @OutputReference@ consumed by boot
    , defaultProcessTime :: !Integer
    -- ^ Phase 1 window (ms) for oracle processing
    , defaultRetractTime :: !Integer
    -- ^ Phase 2 window (ms) for requester retract
    , defaultTip :: !Coin
    -- ^ Default oracle tip for newly booted tokens
    , cfgApplicationPolicy :: !ShortByteString
    {- ^ The application policy the registry pins (28 raw bytes, #157 tree-edge-admission-by-approval,
    genesis-policy-pins): the hash of the application script the registry was booted
    with, for the registry identity this boot creates, as compiled
    or with the application's validator applied to that identity
    ("Singular.Registry.Config.Application" derives and re-derives it).
    It certifies every request that changes the trie. Never a literal.
    -}
    , cfgActivePolicy :: !ShortByteString
    {- ^ The active-token policy (28 raw bytes, #157 C5/C7, genesis-policy-pins): the
    applied hash of `witness(1, registry)`. Renamed from the
    representative policy it became. Derived, never a literal.
    -}
    , cfgConsumerScript :: !ShortByteString
    {- ^ Applied consumer script bytes (the witness every consuming
    `Modify` attaches for its hook withdrawal). Builders refuse to
    build consuming batches when empty (loud, fail-closed).
    -}
    , network :: !Network
    -- ^ Target network (Mainnet or Testnet)
    }

{- | Initial `State` datum from a cage configuration (#157 state-datum-fields, genesis-policy-pins):
empty trie root, configured economics, and the two pinned policies the
six-field datum carries. Each of the two comes from the config, which
derives it from the two partitions' `script-identity.json` for the registry
identity this boot is about to create — the application policy from the
supplied application script, the active witness policy from
`witness(kind, registry)` applied at kind 1. Nothing here is a
literal or a placeholder, and the conformance rows round-trip both
through this datum.

Single construction site for bootstrapped states — every journey boots
through here or an identical local copy kept in sync by
`cage-tests`/`TypesSpec` vectors.
-}
bootStateFromCfg :: CageConfig -> OnChainRoot -> OnChainTokenState
bootStateFromCfg cfg root =
    OnChainTokenState
        { stateRoot = root
        , stateMaxFee =
            let Coin c = defaultTip cfg in c
        , stateProcessTime = defaultProcessTime cfg
        , stateRetractTime = defaultRetractTime cfg
        , stateAppPolicy =
            BuiltinByteString (SBS.fromShort (cfgApplicationPolicy cfg))
        , stateActivePolicy =
            BuiltinByteString (SBS.fromShort (cfgActivePolicy cfg))
        }
