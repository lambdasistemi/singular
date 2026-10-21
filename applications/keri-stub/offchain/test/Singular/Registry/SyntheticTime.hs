{-# LANGUAGE PatternSynonyms #-}

{- | Explicit synthetic model material for the deterministic memory adapter.
It retains the old epoch size, genesis and one-second slots. The finite range
ends at epoch 10,000 (2106); this is never claimed as a live node recording.
-}
module Singular.Registry.SyntheticTime (syntheticTime, syntheticHistory, syntheticTimeWith) where

import Cardano.Ledger.Api.PParams (emptyPParams, ppProtocolVersionL)
import Cardano.Ledger.BaseTypes (ProtVer (..))
import Cardano.Ledger.Binary (getVersion)
import Cardano.Slotting.Slot (EpochNo (..), EpochSize (..))
import Cardano.Slotting.Time (mkSlotLength)
import Codec.Serialise (serialise)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (encode, object, (.=))
import Data.ByteArray (convert)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Word (Word64)
import Lens.Micro ((^.))
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
import Singular.Registry.Ledger (ConwayEra)
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
    genesis =
        "{\"networkMagic\":42,\"systemStart\":\"1970-01-01T00:00:00Z\",\"securityParam\":2160,\"activeSlotsCoeff\":0.05,\"epochLength\":432000}"
    history = syntheticHistory
    manifest =
        NetworkTimeManifest
            { timeNetworkMagic = 42
            , timeSystemStartMs = 0
            , timeGenesisSha256 = digest genesis
            , timeEraHistorySha256 = digest history
            , timeHorizonSlot = boundSlot syntheticEnd
            , timeProtocolMajor = syntheticMajor
            , timeSourceIdentity =
                "synthetic memory model: epoch 0 through 10000, one-second slots"
            }
    digest :: BS.ByteString -> BS.ByteString
    digest bytes = convert (hash bytes :: Digest SHA256)

-- | Actual serialized finite summary for the synthetic raw-node fixture.
syntheticHistory :: BS.ByteString
syntheticHistory =
    LBS.toStrict
        (serialise [EraSummary initBound (EraEnd syntheticEnd) syntheticParams])

syntheticParams :: EraParams
syntheticParams =
    EraParams
        { eraEpochSize = EpochSize 432_000
        , eraSlotLength = mkSlotLength 1
        , eraSafeZone = StandardSafeZone 432_000
        , eraGenesisWin = GenesisWindow 432_000
        , eraPerasRoundLength = NoPerasEnabled
        }

syntheticEnd :: Bound
syntheticEnd = mkUpperBound syntheticParams initBound (EpochNo 10_000)

{- | Independent synthetic finite material for horizon and rounding controls.
Its end is exactly one epoch of the requested number of slots.
-}
syntheticTimeWith :: Integer -> Rational -> Word64 -> NetworkTime
syntheticTimeWith startMs seconds slots =
    either (error . ("synthetic finite material: " <>) . show) id $
        validateNetworkTime 42 manifest genesis history
  where
    genesis =
        LBS.toStrict $
            encode $
                object
                    [ "networkMagic" .= (42 :: Int)
                    , "systemStart" .= posixSecondsToUTCTime (fromInteger startMs / 1000)
                    , "securityParam" .= (10 :: Int)
                    , "activeSlotsCoeff" .= (1 :: Int)
                    , "epochLength" .= slots
                    ]
    params =
        EraParams
            { eraEpochSize = EpochSize slots
            , eraSlotLength = mkSlotLength (fromRational seconds)
            , eraSafeZone = StandardSafeZone slots
            , eraGenesisWin = GenesisWindow slots
            , eraPerasRoundLength = NoPerasEnabled
            }
    end = mkUpperBound params initBound (EpochNo 1)
    history = LBS.toStrict (serialise [EraSummary initBound (EraEnd end) params])
    digest bytes = convert (hash bytes :: Digest SHA256)
    manifest =
        NetworkTimeManifest
            42
            startMs
            (digest genesis)
            (digest history)
            (boundSlot end)
            syntheticMajor
            "synthetic finite horizon control, not live network material"

-- | The synthetic parameter fixtures start from the ledger's empty parameters.
syntheticMajor :: Word64
syntheticMajor =
    getVersion (pvMajor (emptyPParams @ConwayEra ^. ppProtocolVersionL))
