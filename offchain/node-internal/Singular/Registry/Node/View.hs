{- |
Module      : Singular.Registry.Node.View
Description : The read interface over a node's acquired LocalStateQuery state
License     : Apache-2.0

The node adapter: one 'withView' is one upstream @withAcquired@ of the
pinned node client, so every read through the view — UTxOs,
registration, raw time and resolved inputs — is answered from the one
LocalStateQuery state the node acquired at entry. Common services compute
time conversions and script evaluation from those captured facts. The view's chain
point is that state's own point and era; the protocol parameters are
read once, inside it.

The chain origin has no block and is refused as 'AcquiredAtOrigin'. A
connection the upstream client reports lost (@ConnectionLost@) while
acquiring or reading is 'ViewConnectionLost'. The upstream one-shot
queries, each its own acquisition, are never used.

DevNet and an external node reach the interface through this same
adapter; they differ only in the socket and magic they are opened with.
-}
module Singular.Registry.Node.View
    ( nodeProvider
    , chainPointOf
    ) where

import Control.Exception (handle, throwIO)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set

import Cardano.Ledger.Credential (Credential (..))
import Cardano.Node.Client.N2C.Types (ConnectionLost (..))
import Cardano.Node.Client.Provider qualified as N2C
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))

import Singular.Registry.NetworkTime
    ( NetworkTimeFailure (..)
    , networkSystemStart
    )
import Singular.Registry.Node.PhaseLog (phaseLogFromEnv, queryPhase)
import Singular.Registry.Node.RawView (RawProvider (..), RawView (..))
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider
    , View (..)
    , ViewFailure (..)
    , scopedProvider
    )
import Singular.Registry.TimeMaterial (TimeMaterial, timeFromRaw)

-- | Raw facts and immutable time material from one held acquisition.
nodeProvider
    :: NetworkMagic -> TimeMaterial -> RawProvider IO -> Provider IO
nodeProvider magic@(NetworkMagic magicWord) material raw = scopedProvider $ \action ->
    lost $ withRawView raw $ \h -> do
        lg <- phaseLogFromEnv
        snapshot <- queryPhase lg "ledgerSnapshot" (const 1) (rawSnapshot h)
        point <-
            maybe (throwIO AcquiredAtOrigin) pure (chainPointOf magic snapshot)
        pp <- queryPhase lg "protocolParams" (const 1) (rawParameters h)
        start <- queryPhase lg "systemStart" (const 1) (rawSystemStart h)
        history <- queryPhase lg "eraHistory" (const 1) (rawEraHistory h)
        context <-
            either
                throwIO
                pure
                ( timeFromRaw
                    magicWord
                    "held private-devnet LSQ history"
                    material
                    start
                    history
                )
        let view =
                View
                    { viewPoint = point
                    , viewProtocolParams = pp
                    , viewTimeContext = lost $ do
                        -- The context stays immutable. The held raw read also
                        -- detects connection loss before a local computation.
                        observed <- queryPhase lg "systemStart" (const 1) (rawSystemStart h)
                        if observed == networkSystemStart context
                            then pure context
                            else throwIO (TimeSourceMismatch "held system start changed")
                    , viewResolvedOutputs = lost . rawUTxOsByRefs h
                    , viewPhaseLog = lg
                    , viewUTxOsAt = lost . rawUTxOsAt h
                    , viewScriptRegistered = \sh -> lost $ do
                        let credential = ScriptHashObj sh
                        Map.member credential <$> rawRewards h (Set.singleton credential)
                    }
        action view

{- | The chain point of an acquired snapshot under the session's magic;
nothing at the chain origin.
-}
chainPointOf :: NetworkMagic -> N2C.LedgerSnapshot -> Maybe ChainPoint
chainPointOf (NetworkMagic magic) snapshot =
    case N2C.ledgerChainPoint snapshot of
        Chain.GenesisPoint -> Nothing
        Chain.BlockPoint slot (OneEraHash h) ->
            Just
                ChainPoint
                    { cpNetwork = magic
                    , cpEra = N2C.ledgerCurrentEra snapshot
                    , cpSlot = slot
                    , cpBlockHash = SBS.fromShort h
                    }

-- | Name a connection the upstream client reports lost.
lost :: IO a -> IO a
lost = handle (\ConnectionLost -> throwIO ViewConnectionLost)
