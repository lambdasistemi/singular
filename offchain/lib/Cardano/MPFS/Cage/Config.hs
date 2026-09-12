{- |
Module      : Cardano.MPFS.Cage.Config
Description : Configuration for cage transaction builders
License     : Apache-2.0

Configuration record for the cage transaction
builders. Holds the global state PlutusV3 script
bytes, the unapplied request validator bytes, the
state script hash, the seed @OutputReference@ used
by boot minting, default token parameters, and
network.
-}
module Cardano.MPFS.Cage.Config (
    -- * Configuration
    CageConfig (..),
    bootStateFromCfg,
) where

import Data.ByteString.Short (ShortByteString)
import Data.ByteString.Short qualified as SBS

import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Hashes (ScriptHash)

import Cardano.MPFS.Cage.Ledger (Coin (..))
import Cardano.MPFS.Cage.Types (
    OnChainRoot (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
 )
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

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
    , cfgRepPolicy :: !ShortByteString
    -- ^ Expected representative minting policy (28 raw bytes) written
    -- into the bootstrapped `State` datum (issue #77, E-001 repair).
    -- Naming journeys pass the honest applied representative hash derived
    -- from the blueprints; MPFS-only cages pass 28 zero bytes (no naming
    -- validator reads it there). Preserved immutable across every `Modify`.
    , network :: !Network
    -- ^ Target network (Mainnet or Testnet)
    }

{- | Initial `State` datum from a cage configuration (issue #77, E-001
repair): empty trie root, configured economics, and the expected
representative policy carried by `cfgRepPolicy`. Single construction site
for bootstrapped states — every journey boots through here or an
identical local copy kept in sync by `cage-tests`/`TypesSpec` vectors.
-}
bootStateFromCfg :: CageConfig -> OnChainRoot -> OnChainTokenState
bootStateFromCfg cfg root =
    OnChainTokenState
        { stateRoot = root
        , stateMaxFee =
            let Coin c = defaultTip cfg in c
        , stateProcessTime = defaultProcessTime cfg
        , stateRetractTime = defaultRetractTime cfg
        , stateRepPolicy =
            BuiltinByteString (SBS.fromShort (cfgRepPolicy cfg))
        }
