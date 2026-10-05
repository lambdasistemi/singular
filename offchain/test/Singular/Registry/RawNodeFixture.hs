{- | Deterministic raw-node fixture over existing acquisition controls.
The time material is explicitly synthetic, never a captured live source.
-}
module Singular.Registry.RawNodeFixture
    ( rawFixture
    , recordingRawFixture
    , syntheticMaterial
    ) where

import Cardano.Node.Client.Provider qualified as N2C
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Singular.Registry.NetworkTime (networkSystemStart)
import Singular.Registry.Node.RawView (RawProvider (..), RawView (..))
import Singular.Registry.SyntheticTime
    ( syntheticHistory
    , syntheticTime
    )
import Singular.Registry.TimeMaterial (TimeMaterial (..))

syntheticMaterial :: TimeMaterial
syntheticMaterial = PackagedTime syntheticTime

rawFixture :: N2C.Provider IO -> RawProvider IO
rawFixture = recordingRawFixture (const (pure ()))

recordingRawFixture
    :: (Text -> IO ()) -> N2C.Provider IO -> RawProvider IO
recordingRawFixture note node = RawProvider $ \action ->
    N2C.withAcquired node $ \h ->
        action
            RawView
                { rawSnapshot = N2C.queryLedgerSnapshotH h
                , rawParameters = N2C.queryProtocolParamsH h
                , rawUTxOsAt = N2C.queryUTxOsH h
                , rawUTxOsByRefs = fmap Map.toAscList . N2C.queryUTxOByTxInH h
                , rawRewards = N2C.queryStakeRewardsH h
                , rawSystemStart =
                    note "h:systemStart" >> pure (networkSystemStart syntheticTime)
                , rawEraHistory = note "h:eraHistory" >> pure syntheticHistory
                }
