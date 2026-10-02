{- |
Module      : Singular.Registry.E2E.Fixture
Description : The end-to-end suite's devnet, as capabilities
License     : Apache-2.0

Fixture startup for the end-to-end suite: spawn a devnet node over the
checked-in genesis, follow its chain with the in-memory indexer, connect
over node-to-client and hand the specs their capabilities — the read
interface (address reads answered by the indexer), the signed-only write
and the indexer's confirmation. No spec below this sees the node.
-}
module Singular.Registry.E2E.Fixture
    ( withDevnetCapabilities
    ) where

import Control.Concurrent.Async (async, cancel)

import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (genesisDir)
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Ouroboros.Network.Magic (NetworkMagic (..))

import Singular.Registry.Node
    ( Capabilities (..)
    , adaptProvider
    , awaitConnection
    , awaitIndexed
    , boundedSubmitter
    , followedProvider
    , signedSubmitter
    , submissionBound
    , withDevnetIndexer
    )

{- | Start a devnet, connect and run the body with the devnet's system
start (POSIX ms, from its genesis) and its capabilities. The connection
is closed when the body returns.
-}
withDevnetCapabilities :: (Integer -> Capabilities -> IO a) -> IO a
withDevnetCapabilities action = do
    gDir <- genesisDir
    withCardanoNode gDir $ \sock startMs -> withDevnetIndexer sock $ do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <-
            async $
                runNodeClient
                    (NetworkMagic 42)
                    sock
                    lsqCh
                    ltxsCh
        let nodeProv = adaptProvider (NetworkMagic 42) (mkN2CProvider lsqCh)
        awaitConnection (NetworkMagic 42) sock nodeThread nodeProv
        let submit = boundedSubmitter submissionBound (mkN2CSubmitter ltxsCh)
        -- Address reads from here on are the indexer's.
        prov <- followedProvider nodeProv submit
        result <-
            action
                startMs
                Capabilities
                    { capReads = prov
                    , capSubmit = signedSubmitter submit
                    , capConfirm = awaitIndexed
                    }
        cancel nodeThread
        pure result
