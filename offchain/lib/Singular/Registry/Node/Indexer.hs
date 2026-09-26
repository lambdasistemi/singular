{- |
Module      : Singular.Registry.Node.Indexer
Description : The follower state a session reads its chain through
License     : Apache-2.0

The owner of the process's chain-follower state: 'withFollowing'
installs an in-memory UTxO indexer follower for an action and removes
it — and clears the funding-read guard — at bracket exit, normal or
exceptional. Confirmations and address reads reach the follower only
through this module ('awaitIndexed', 'currentFollower',
'followedProvider', 'adaptProvider'), never a second copy of its
state.
-}
module Singular.Registry.Node.Indexer (
    -- * Follower state
    Following (..),
    withFollowing,
    currentFollower,

    -- * Indexed confirmation
    awaitIndexed,

    -- * Funding-read guard
    markFundingIndexed,

    -- * Address reads
    adaptProvider,
    nodeAddressReads,

    -- * Pacing
    confirmationPollSeconds,
    confirmationAttempts,
) where

import Control.Exception (bracket_)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node.Options (die)
import Singular.Registry.Node.Wallet (bech32Address)
import Singular.Registry.Provider qualified as Cage

{- | The indexer this process follows its chain with, installed by
'followChain'. 'awaitIndexed', 'confirmOutputZero' and
'followedProvider' are its readers, for the same reason 'openSession'
is 'awaitTx''s: every submission and every read already runs inside
the session that knows the chain.
-}
chainFollower :: IORef (Maybe Following)
chainFollower = unsafePerformIO (newIORef Nothing)
{-# NOINLINE chainFollower #-}

-- | An indexer following a chain, and where it started.
data Following = Following
    { followingIndexer :: IndexerHandle
    , followingFromOrigin :: Bool
    {- ^ Whether every block of the chain went through the indexer, so
    that its view of an address lacks only the genesis outputs
    -}
    }

{- | Install a follower for an action and remove it afterwards, on
normal return and on exception alike, clearing the funding-read guard
with it. The single writer of the follower state.
-}
withFollowing :: Following -> IO a -> IO a
withFollowing following =
    bracket_
        (writeIORef chainFollower (Just following))
        ( do
            writeIORef chainFollower Nothing
            writeIORef fundingIndexed False
        )

-- | The indexer following this process's chain, if one is installed.
currentFollower :: IO (Maybe Following)
currentFollower = readIORef chainFollower

{- | Wait until the followed chain's indexer has applied the block
carrying a submitted transaction, observed as the transaction's first
output; name the transaction when it is not indexed within the
confirmation window.
-}
awaitIndexed :: ConwayTx -> IO ()
awaitIndexed tx = do
    idx <-
        readIORef chainFollower
            >>= maybe
                ( die
                    "awaitIndexed was called outside followChain; \
                    \a runner must confirm inside the chain it follows"
                )
                (pure . followingIndexer)
    let TxId h = txIdTx tx
    seen <-
        awaitTxIn
            idx
            (Indexer.TxIn (hashToBytes (extractHash h)) 0)
            (Just window)
    case seen of
        Just _ -> pure ()
        Nothing ->
            die
                ( "transaction "
                    <> show (txIdTx tx)
                    <> " was accepted by the node but not indexed within "
                    <> show window
                    <> " seconds"
                )
  where
    window = confirmationAttempts * confirmationPollSeconds

{- | Whether the followed devnet's funding read is done, after which a
node address read is a defect: the indexer answers every one.
-}
fundingIndexed :: IORef Bool
fundingIndexed = unsafePerformIO (newIORef False)
{-# NOINLINE fundingIndexed #-}

-- | Record that the followed devnet's funding read is done.
markFundingIndexed :: IO ()
markFundingIndexed = writeIORef fundingIndexed True

-- | How many @GetUTxOByAddress@ this process has sent to a node.
nodeAddressReads :: IO Int
nodeAddressReads = readIORef addressReads

addressReads :: IORef Int
addressReads = unsafePerformIO (newIORef 0)
{-# NOINLINE addressReads #-}

{- | The cage provider over an N2C provider. Its address reads are the
node's @GetUTxOByAddress@, refused once 'followedProvider' has handed
the reads of a followed devnet to its indexer.
-}
adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = \addr -> do
            followed <- readIORef fundingIndexed
            when followed $
                die
                    ( "GetUTxOByAddress for "
                        <> bech32Address addr
                        <> " sent to the node of a followed devnet after its \
                           \funding read: read through followedProvider"
                    )
            atomicModifyIORef' addressReads (\n -> (n + 1, ()))
            N2C.queryUTxOs p addr
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

-- | Seconds between confirmation polls.
confirmationPollSeconds :: Int
confirmationPollSeconds = 2

{- | How many polls before a submitted transaction is declared lost.
Five minutes covers a public test network's block time with room for a
slow epoch boundary; the devnet returns on the first or second poll.
-}
confirmationAttempts :: Int
confirmationAttempts = 150
