{- |
Module      : Devnet.Probe
Description : A node's own answer, below the read interface
License     : Apache-2.0

The devnet tool's probe asks an existing node, from one acquired ledger
state, for its chain tip and which of the named outputs are unspent. It
reads the node's raw ledger snapshot and its UTxO by output reference,
which the read interface does not answer, so it opens its own
node-to-client connection.
-}
module Devnet.Probe
    ( probe
    ) where

import Control.Concurrent.Async (async, cancel)
import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.ByteString.Short qualified as SBS
import Data.List (partition)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Word (Word32)

import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Slotting.Slot (SlotNo (..))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.Registry.Ledger (TxIn)

import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Node (adaptProvider, awaitConnection)
import Singular.Registry.Node.RawView (rawNodeProvider)
import Singular.Registry.TimeMaterial (loadTimeMaterial)
import System.FilePath (takeDirectory)

{- | Ask the node at a socket and magic, from one acquired ledger state,
for its tip and which of the named outputs are unspent, and print both
as one JSON object.
-}
probe :: FilePath -> Word32 -> [TxIn] -> IO ()
probe sock magicWord txIns = do
    let magic = NetworkMagic magicWord
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $ \thread -> do
        let n2c = mkN2CProvider lsqCh
        material <- loadTimeMaterial magicWord (takeDirectory sock)
        awaitConnection
            magic
            sock
            thread
            (adaptProvider magic material (rawNodeProvider lsqCh))
        (snapshot, unspent) <- N2C.withAcquired n2c $ \h ->
            (,)
                <$> N2C.queryLedgerSnapshotH h
                <*> N2C.queryUTxOByTxInH h (Set.fromList txIns)
        let (live, spent) = partition (`Map.member` unspent) txIns
            tip = case N2C.ledgerChainPoint snapshot of
                Chain.GenesisPoint -> Aeson.Null
                Chain.BlockPoint (SlotNo slot) (OneEraHash h) ->
                    object
                        [ "slot" .= slot
                        , "hash" .= BC.unpack (B16.encode (SBS.fromShort h))
                        ]
        BL8.putStrLn $
            Aeson.encode $
                object
                    [ "tip" .= tip
                    , "live" .= map renderOutRef live
                    , "spent" .= map renderOutRef spent
                    ]
