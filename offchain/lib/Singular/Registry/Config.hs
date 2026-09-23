{- |
Module      : Singular.Registry.Config
Description : Configuration for cage transaction builders
License     : Apache-2.0

Configuration record for the cage transaction
builders. Holds the global state PlutusV3 script
bytes, the unapplied request validator bytes, the
state script hash, the seed @OutputReference@ used
by boot minting, default token parameters, and
network.
-}
module Singular.Registry.Config (
    -- * Configuration
    CageConfig (..),
    bootStateFromCfg,
) where

import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS

import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Hashes (ScriptHash)

import PlutusTx.Builtins.Internal (BuiltinByteString (..))
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Types (
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
 )

{- | Configuration for the cage script transaction
builders.

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
    {- ^ The application policy the registry pins (28 raw bytes, #157 C4,
    D-BOOT): the naming application script's applied hash, derived from
    `naming-onchain/script-identity.json` for the registry identity this
    boot creates. It certifies every request that changes the trie.
    Never a literal.
    -}
    , cfgActivePolicy :: !ShortByteString
    {- ^ The active-token policy (28 raw bytes, #157 C5/C7, D-BOOT): the
    applied hash of `witness(1, registry)`. Renamed from the
    representative policy it became. Derived, never a literal.
    -}
    , cfgAbsentPolicy :: !ShortByteString
    {- ^ The absent-token policy (28 raw bytes, D-BOOT): the applied hash
    of `witness(0, registry)`. Derived, never a literal.
    -}
    , cfgTerminalPolicy :: !ShortByteString
    {- ^ The terminal-token policy (28 raw bytes, D-BOOT): the applied hash
    of `witness(2, registry)`. Derived, never a literal.
    -}
    , cfgConsumerScript :: !ShortByteString
    {- ^ Applied consumer script bytes (the witness every consuming
    `Modify` attaches for its hook withdrawal). Builders refuse to
    build consuming batches when empty (loud, fail-closed).
    -}
    , network :: !Network
    -- ^ Target network (Mainnet or Testnet)
    }

{- | Initial `State` datum from a cage configuration (#157 C7, D-BOOT):
empty trie root, configured economics, and the four pinned policies the
eight-field datum carries. Each of the four comes from the config, which
derives it from the two partitions' `script-identity.json` for the registry
identity this boot is about to create — the application policy from the
naming application script, the three witness policies from
`witness(kind, registry)` applied at kinds 0, 1 and 2. Nothing here is a
literal or a placeholder, and the conformance rows round-trip all four
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
        , stateAbsentPolicy =
            BuiltinByteString (SBS.fromShort (cfgAbsentPolicy cfg))
        , stateTerminalPolicy =
            BuiltinByteString (SBS.fromShort (cfgTerminalPolicy cfg))
        }
