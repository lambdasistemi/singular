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

import Cardano.Ledger.Api.PParams (ppProtocolVersionL)
import Cardano.Ledger.BaseTypes (ProtVer (..))
import Cardano.Ledger.Binary (getVersion)
import Control.Exception (handle, throwIO)
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Lens.Micro ((^.))

import Cardano.Ledger.Credential (Credential (..))
import Cardano.Node.Client.N2C.Types (ConnectionLost (..))
import Cardano.Node.Client.Provider qualified as N2C
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))

import Control.Tracer (Tracer)
import Singular.Registry.NetworkTime
    ( NetworkTimeFailure (..)
    , networkSystemStart
    )
import Singular.Registry.Node.RawView (RawProvider (..), RawView (..))
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider
    , View (..)
    , ViewFailure (..)
    , scopedProvider
    )
import Singular.Registry.ProviderTrace (nodeSource)
import Singular.Registry.TimeMaterial (TimeMaterial, timeFromRaw)
import Singular.Registry.Trace (ReadEvent, tracedQuery)

-- | Raw facts and immutable time material from one held acquisition.
nodeProvider
    :: Tracer IO ReadEvent
    -> NetworkMagic
    -> TimeMaterial
    -> RawProvider IO
    -> Provider IO
nodeProvider tracer magic@(NetworkMagic magicWord) material raw = scopedProvider $ \action ->
    lost $ withRawView raw $ \h -> do
        let query :: Text -> IO a -> IO a
            query name = tracedQuery tracer nodeSource Nothing name (const (Just 1))
        snapshot <- query "ledgerSnapshot" (rawSnapshot h)
        point <-
            maybe (throwIO AcquiredAtOrigin) pure (chainPointOf magic snapshot)
        pp <- query "protocolParams" (rawParameters h)
        start <- query "systemStart" (rawSystemStart h)
        history <- query "eraHistory" (rawEraHistory h)
        context <-
            either
                throwIO
                pure
                ( timeFromRaw
                    magicWord
                    (getVersion (pvMajor (pp ^. ppProtocolVersionL)))
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
                        observed <- query "systemStart" (rawSystemStart h)
                        if observed == networkSystemStart context
                            then pure context
                            else throwIO (TimeSourceMismatch "held system start changed")
                    , viewResolvedOutputs = lost . rawUTxOsByRefs h
                    , viewTracer = tracer
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
