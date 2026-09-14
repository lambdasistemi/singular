{- |
Module      : Main
Description : A devnet that outlives the process that needed it
License     : Apache-2.0

Every runner spawns its own devnet and takes it down again, which is
right when the registry it boots dies with the run. A deployment does
not: it is booted once and attached to by later runs, so proving that
attachment works needs one chain that several processes can reach.

This spawns that chain, prints the socket path on standard output, and
waits until it is killed. Everything else — deploying, attaching,
counting what changed — happens in other processes against the socket
it printed, through the same external-node path a joiner's own node is
reached by.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import System.IO (BufferMode (..), hSetBuffering, stdout)

import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (genesisDir)

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        putStrLn sock
        forever (threadDelay 3_600_000_000)
