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
) where

import Data.ByteString.Short (ShortByteString)

import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Hashes (ScriptHash)

import Cardano.MPFS.Cage.Ledger (Coin)
import Cardano.MPFS.Cage.Types (OnChainTxOutRef)

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

When 'cfgStakeScript' is @Just (bytes, hash)@, the
boot datum carries @stake_script = Some(hash)@, and
every Modify\/End transaction must include a
withdraw-zero from the corresponding staking
credential.
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
    , network :: !Network
    -- ^ Target network (Mainnet or Testnet)
    , cfgStakeScript :: !(Maybe (ShortByteString, ScriptHash))
    {- ^ Optional staking script: bytes + hash.
    When set, boot stores the hash in
    @stake_script@ and Modify\/End include a
    withdraw-zero from the staking credential.
    -}
    }
