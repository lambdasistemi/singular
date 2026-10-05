{-# LANGUAGE PatternSynonyms #-}

{- | Explicit synthetic model material for the deterministic memory adapter.
It retains the old epoch size, genesis and one-second slots. The finite range
ends at epoch 10,000 (2106); this is never claimed as a live node recording.
-}
module Singular.Registry.SyntheticTime (syntheticTime, syntheticHistory) where

import Cardano.Slotting.Slot (EpochNo (..), EpochSize (..))
import Cardano.Slotting.Time (mkSlotLength)
import Codec.Serialise (serialise)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (convert)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Ouroboros.Consensus.Block (GenesisWindow (..))
import Ouroboros.Consensus.HardFork.History.EraParams
    ( EraParams (..)
    , SafeZone (..)
    , pattern NoPerasEnabled
    )
import Ouroboros.Consensus.HardFork.History.Summary
    ( Bound (..)
    , EraEnd (..)
    , EraSummary (..)
    , initBound
    , mkUpperBound
    )
import Singular.Registry.NetworkTime
    ( NetworkTime
    , NetworkTimeManifest (..)
    , validateNetworkTime
    )

syntheticTime :: NetworkTime
syntheticTime =
    either (error . ("synthetic time material: " <>) . show) id $
        validateNetworkTime 42 manifest genesis history
  where
    genesis = "{\"networkMagic\":42,\"systemStart\":\"1970-01-01T00:00:00Z\"}"
    history = syntheticHistory
    manifest =
        NetworkTimeManifest
            { timeNetworkMagic = 42
            , timeSystemStartMs = 0
            , timeGenesisSha256 = digest genesis
            , timeEraHistorySha256 = digest history
            , timeHorizonSlot = boundSlot end
            , timeSourceIdentity =
                "synthetic memory model: epoch 0 through 10000, one-second slots"
            }
    digest :: BS.ByteString -> BS.ByteString
    digest bytes = convert (hash bytes :: Digest SHA256)

-- | Actual serialized finite summary for the synthetic raw-node fixture.
syntheticHistory :: BS.ByteString
syntheticHistory = LBS.toStrict (serialise [EraSummary initBound (EraEnd end) params])
  where
    params =
        EraParams
            { eraEpochSize = EpochSize 432_000
            , eraSlotLength = mkSlotLength 1
            , eraSafeZone = StandardSafeZone 432_000
            , eraGenesisWin = GenesisWindow 432_000
            , eraPerasRoundLength = NoPerasEnabled
            }
    end = mkUpperBound params initBound (EpochNo 10_000)
