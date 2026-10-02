{- |
Module      : Singular.Registry.Node.View
Description : The read interface over a node's acquired LocalStateQuery state
License     : Apache-2.0

The node adapter: one 'withView' is one upstream @withAcquired@ of the
pinned node client, so every read through the view — UTxOs,
registration, time to slot, script evaluation — is answered from the
one LocalStateQuery state the node acquired at entry. The view's chain
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

import Singular.Registry.Node.PhaseLog (phaseLogFromEnv, queryPhase)
import Singular.Registry.Provider
    ( ChainPoint (..)
    , Provider
    , View (..)
    , ViewFailure (..)
    , scopedProvider
    )

-- | The read interface over an upstream node-to-client provider.
nodeProvider :: NetworkMagic -> N2C.Provider IO -> Provider IO
nodeProvider magic n2c = scopedProvider $ \action ->
    lost $ N2C.withAcquired n2c $ \h -> do
        lg <- phaseLogFromEnv
        snapshot <-
            queryPhase lg "ledgerSnapshot" (const 1) (N2C.queryLedgerSnapshotH h)
        point <-
            maybe
                (throwIO AcquiredAtOrigin)
                pure
                (chainPointOf magic snapshot)
        pp <-
            queryPhase lg "protocolParams" (const 1) (N2C.queryProtocolParamsH h)
        action
            View
                { viewPoint = point
                , viewProtocolParams = pp
                , viewUTxOsAt = lost . N2C.queryUTxOsH h
                , viewScriptRegistered = \sh -> lost $ do
                    let credential = ScriptHashObj sh
                    Map.member credential
                        <$> N2C.queryStakeRewardsH h (Set.singleton credential)
                , viewEvaluateTx = lost . N2C.evaluateTxH h
                , viewPosixMsToSlot = lost . N2C.posixMsToSlotH h
                , viewPosixMsCeilSlot = lost . N2C.posixMsCeilSlotH h
                }

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
