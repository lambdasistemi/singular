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

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (throwIO)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.ByteString.Short qualified as SBS
import Data.List (partition)
import Data.Map.Strict qualified as Map
import Data.Word (Word32)

import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))
import Singular.Registry.Ledger (TxIn)

import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Private.Source
    ( LedgerSource (..)
    , readLedgerSource
    )
import System.Timeout (timeout)

{- | Ask the node at a socket and magic, from one acquired ledger state,
for its tip and which of the named outputs are unspent, and print both
as one JSON object.
-}
probe :: FilePath -> Word32 -> [TxIn] -> IO ()
probe sock magicWord txIns = do
    let magic = NetworkMagic magicWord
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    withAsync
        ( runNodeClient magic sock lsqCh ltxsCh
            >>= either throwIO (const (fail "private probe connection ended"))
        ) $ \thread -> do
        link thread
        let observed = do
                source <- readLedgerSource lsqCh
                case sourcePoint source of
                    Chain.GenesisPoint -> threadDelay 100_000 >> observed
                    _ -> pure source
        source <-
            timeout 120_000_000 observed
                >>= maybe
                    ( fail
                        "private probe did not acquire a non-origin ledger state within120seconds"
                    )
                    pure
        let unspent = sourceOutputs source
        let (live, spent) = partition (`Map.member` unspent) txIns
            tip = case sourcePoint source of
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
