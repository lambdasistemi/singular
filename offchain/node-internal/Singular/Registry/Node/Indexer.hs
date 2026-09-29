{-# LANGUAGE LambdaCase #-}

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
module Singular.Registry.Node.Indexer
    ( -- * Follower state
      Following (..)
    , withFollowing
    , currentFollower

      -- * Following a chain
    , withDevnetIndexer
    , followChain
    , startingAt

      -- * Indexed confirmation
    , awaitIndexed
    , awaitIndexedWithin

      -- * Provider adaptation
    , followedProvider
    , adaptProvider

      -- * Funding-read guard
    , markFundingIndexed

      -- * Address reads
    , nodeAddressReads

      -- * Pacing
    , confirmationPollSeconds
    , confirmationAttempts
    ) where

import Control.Concurrent.Async (link)
import Control.Exception (bracket_)
import Control.Monad (unless, when)
import Control.Tracer (nullTracer)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Word (Word64)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic)

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (SlotNo (..), TxIx (..))
import Cardano.Ledger.Binary (decodeFull')
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Hashes (extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Node.Client.E2E.Setup
    ( addKeyWitness
    , devnetMagic
    )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter
    , submitTx
    )
import Cardano.Node.Client.Types (BlockPoint)
import Cardano.Node.Client.UTxOIndexer.Follower
    ( ChainSyncConfig (..)
    , FollowerHandle (..)
    , InterestSet (..)
    , withChainSyncFollower
    )
import Cardano.Node.Client.UTxOIndexer.Indexer
    ( IndexerHandle (..)
    , withInMemoryIndexer
    )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.Node.Options (NodeMode (..), die)
import Singular.Registry.Node.Wallet
    ( Wallet (..)
    , bech32Address
    , walletForMode
    )
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

{- | Follow the devnet at a socket from its origin for the duration of
an action: 'awaitIndexed' returns on the block that carries a
transaction, and 'followedProvider' answers address reads. The
factory devnet's origin is minutes old.
-}
withDevnetIndexer :: FilePath -> IO a -> IO a
withDevnetIndexer = followChain devnetMagic 42 Nothing

{- | Follow the chain of the node at a socket with an in-memory UTxO
indexer for the duration of an action, from a named block or, given
none, from the chain's origin. A public network's origin is its whole
history, so a session there starts at the node's tip: every
transaction it submits lands in a later block. A follower failure is
re-thrown in the calling thread.
-}
followChain
    :: NetworkMagic
    -> Word64
    -> Maybe (Indexer.SlotNo, Indexer.BlockHash)
    -> FilePath
    -> IO a
    -> IO a
followChain magic byronEpochSlots start sock action =
    withInMemoryIndexer $ \idx ->
        withChainSyncFollower nullTracer follow idx $ \follower -> do
            link (fhAsync follower)
            withFollowing
                Following
                    { followingIndexer = idx
                    , followingFromOrigin = isNothing start
                    }
                action
  where
    follow =
        ChainSyncConfig
            { csRelaySocket = sock
            , csNetworkMagic = magic
            , csByronEpochSlots = byronEpochSlots
            , csStartPoint = start
            , csReadyThresholdSlots = 60
            , csSecurityParamK = 2160
            , csReconnectPolicy = defaultReconnectPolicy
            , csProbeConfig = defaultProbeConfig
            , csInterestSet = IndexAll
            }

-- | The block a follower starting at a chain point names; none at origin.
startingAt :: BlockPoint -> Maybe (Indexer.SlotNo, Indexer.BlockHash)
startingAt = \case
    Chain.GenesisPoint -> Nothing
    Chain.BlockPoint (SlotNo s) (OneEraHash h) ->
        Just (Indexer.SlotNo s, Indexer.BlockHash (SBS.fromShort h))

{- | Wait until the followed chain's indexer has applied the block
carrying a submitted transaction, observed as the transaction's first
output, or fail within the named window (in seconds).
-}
awaitIndexedWithin :: Int -> ConwayTx -> IO ()
awaitIndexedWithin _window = awaitIndexed

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

{- | The provider a runner reads the chain through.

Where an indexer has followed the chain from its origin (the devnet),
address reads are answered by that indexer rather than by the node's
@GetUTxOByAddress@, which filters the node's whole UTxO set on every
call. Elsewhere — a public network followed from its tip, whose older
outputs the indexer never saw — the node's provider is returned
unchanged.

The indexer sees only what blocks carry, and the funding wallet's
genesis outputs are in the ledger's initial state, not in any block.
So this first reads the funding wallet from the node — the run's one
node address read — and spends every output the indexer does not know
into one output a block carries. From then on the node and the indexer
agree on that address, and 'adaptProvider' refuses any further node
address read for as long as the indexer runs.
-}
followedProvider
    :: Cage.Provider IO -> Submitter IO -> IO (Cage.Provider IO)
followedProvider node submit =
    currentFollower >>= \case
        Just Following{followingIndexer = idx, followingFromOrigin = True} -> do
            indexFunding idx node submit
            markFundingIndexed
            pure node{Cage.queryUTxOs = indexedUTxOs idx}
        _ -> pure node

-- | Every output at an address as the indexer holds it, in the node's order.
indexedUTxOs :: IndexerHandle -> Addr -> IO [(TxIn, TxOut ConwayEra)]
indexedUTxOs idx addr = do
    rows <- snapshotAt idx (Indexer.Address (serialiseAddr addr))
    Map.toList . Map.fromList <$> traverse decodeRow rows
  where
    decodeRow (Indexer.TxIn tid ix, Indexer.TxOut bytes) = do
        h <-
            maybe
                (bad tid "the transaction id is not 32 bytes")
                pure
                (hashFromBytes tid)
        out <-
            either
                (bad tid . show)
                pure
                (decodeFull' (eraProtVerLow @ConwayEra) bytes)
        pure
            (TxIn (TxId (unsafeMakeSafeHash h)) (TxIx (fromIntegral ix)), out)
    bad tid why =
        die
            ( "an indexed output of transaction "
                <> BC.unpack (B16.encode tid)
                <> " does not decode: "
                <> why
            )

{- | Read the devnet's genesis wallet — the one that funds a devnet run —
from the node and spend the outputs the indexer has not seen into one
self-payment, confirmed through the indexer. On the factory devnet
that is the single genesis output.
-}
indexFunding
    :: IndexerHandle -> Cage.Provider IO -> Submitter IO -> IO ()
indexFunding idx node submit = do
    wallet <- walletForMode Devnet
    let addr = walletAddr wallet
        key = walletSignKey wallet
    held <- Cage.queryUTxOs node addr
    known <- map fst <$> indexedUTxOs idx addr
    let unseen = filter ((`notElem` known) . fst) held
        value = foldMap ((^. valueTxOutL) . snd) unseen
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.fromList (map fst unseen)
                & outputsTxBodyL
                    .~ StrictSeq.singleton
                        (mkBasicTxOut addr (value <-> inject sweepFee))
                & feeTxBodyL .~ sweepFee
        tx = addKeyWitness key (mkBasicTx body)
    unless (null unseen) $
        submitTx submit tx >>= \case
            Submitted _ -> do
                awaitIndexed tx
                hPutStrLn stderr $
                    "node: "
                        <> show (length unseen)
                        <> " funding output(s) outside any block moved into one"
            Rejected reason ->
                die
                    ( "moving the funding wallet's genesis outputs into a \
                      \block was refused: "
                        <> BC.unpack reason
                    )
  where
    -- Above the minimum fee of a key-witnessed self-payment with a
    -- handful of inputs; the devnet's genesis wallet has one.
    sweepFee = Coin 1_000_000

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
