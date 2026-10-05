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
    , originProvider
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
import Control.Monad (unless, void, when)
import Control.Tracer (nullTracer)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Foldable (for_)
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
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
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (SlotNo (..))
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Node.Client.E2E.Setup
    ( addKeyWitness
    , devnetMagic
    )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
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
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Node.IndexGate
    ( Coverage (..)
    , IndexGate
    , IndexedPoint (..)
    , gateCoverage
    , gatedHandle
    , holdsIndex
    , newIndexGate
    )
import Singular.Registry.Node.IndexerView
    ( IndexerReadiness (..)
    , awaitIndexerReady
    , indexedUTxOs
    , indexerProvider
    , requireCovered
    )
import Singular.Registry.Node.Options (NodeMode (..), die)
import Singular.Registry.Node.PhaseLog (phaseLogFromEnv, queryPhase)
import Singular.Registry.Node.RawView (RawProvider)
import Singular.Registry.Node.View (nodeProvider)
import Singular.Registry.Node.Wait
    ( WaitStage (..)
    , boundWaitSince
    , startWaitClock
    )
import Singular.Registry.Node.Wallet
    ( Wallet (..)
    , bech32Address
    , walletForMode
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TimeMaterial (TimeMaterial)

{- | The indexer this process follows its chain with, installed by
'followChain'. 'awaitIndexed', 'confirmOutputZero' and
'followedProvider' are its readers, for the same reason 'openSession'
is 'awaitTx''s: every submission and every read already runs inside
the session that knows the chain.
-}
chainFollower :: IORef (Maybe Following)
chainFollower = unsafePerformIO (newIORef Nothing)
{-# NOINLINE chainFollower #-}

{- | An indexer following a chain: the index its confirmations read,
the gate its follower writes it through — which carries where the
follower started — and the follower's readiness.
-}
data Following = Following
    { followingIndexer :: IndexerHandle
    , followingGate :: IndexGate
    , followingReadiness :: IndexerReadiness
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
transaction it submits lands in a later block. The follower writes the
index only through an 'IndexGate', so a view can hold the index at its
point. A follower failure is re-thrown in the calling thread.
-}
followChain
    :: NetworkMagic
    -> Word64
    -> Maybe (Indexer.SlotNo, Indexer.BlockHash)
    -> FilePath
    -> IO a
    -> IO a
followChain magic byronEpochSlots start sock action =
    withInMemoryIndexer $ \idx -> do
        gate <-
            newIndexGate
                (unNetworkMagic magic)
                Coverage
                    { coverageStart = fmap startPoint start
                    , coverageInterest = csInterestSet follow
                    }
                idx
        withChainSyncFollower nullTracer follow (gatedHandle gate) $ \follower -> do
            link (fhAsync follower)
            withFollowing
                Following
                    { followingIndexer = idx
                    , followingGate = gate
                    , followingReadiness =
                        IndexerReadiness
                            { irReadiness = fhReadiness follower
                            , irThresholdSlots = csReadyThresholdSlots follow
                            }
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
    startPoint (Indexer.SlotNo s, Indexer.BlockHash h) =
        IndexedPoint (SlotNo s) h

-- | The block a follower starting at a chain point names; none at origin.
startingAt :: BlockPoint -> Maybe (Indexer.SlotNo, Indexer.BlockHash)
startingAt = \case
    Chain.GenesisPoint -> Nothing
    Chain.BlockPoint (SlotNo s) (OneEraHash h) ->
        Just (Indexer.SlotNo s, Indexer.BlockHash (SBS.fromShort h))

{- | Wait until the followed chain's indexer has applied the block
carrying a submitted transaction, observed as the transaction's first
output; name the transaction when it is not indexed within the
window (in seconds). A wait inside a view that holds the index could
never see the block, so it is refused at once.
-}
awaitIndexedWithin :: Int -> ConwayTx -> IO ()
awaitIndexedWithin window tx = do
    clock <- startWaitClock
    following <-
        readIORef chainFollower
            >>= maybe
                ( die
                    "awaitIndexed was called outside followChain; \
                    \a runner must confirm inside the chain it follows"
                )
                pure
    held <- holdsIndex (followingGate following)
    when held $
        die
            "awaitIndexed was called inside an indexer view, which holds \
            \the index; a runner must confirm after the view has closed"
    let idx = followingIndexer following
        tid@(TxId h) = txIdTx tx
    lg <- phaseLogFromEnv
    boundWaitSince clock IndexedConfirmationWait tid window $
        void $
            queryPhase lg "awaitTxIn" (maybe 0 (const 1)) $
                awaitTxIn
                    idx
                    (Indexer.TxIn (hashToBytes (extractHash h)) 0)
                    Nothing

{- | 'awaitIndexedWithin' the production confirmation window: five
minutes, which covers a public test network's block time with room for
a slow epoch boundary.
-}
awaitIndexed :: ConwayTx -> IO ()
awaitIndexed =
    awaitIndexedWithin (confirmationAttempts * confirmationPollSeconds)

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

On the devnet each view of this provider is the indexer adapter's
("Singular.Registry.Node.IndexerView"): its address reads and its node
reads are of the one block the node view was acquired at, or the view
is refused by name within 'agreementBound'.
-}
followedProvider
    :: Cage.Provider IO -> Submitter IO -> IO (Cage.Provider IO)
followedProvider node submit =
    currentFollower >>= \case
        Just
            Following
                { followingIndexer = idx
                , followingGate = gate
                , followingReadiness = readiness
                }
                | isNothing (coverageStart (gateCoverage gate)) -> do
                    indexFunding idx node submit
                    markFundingIndexed
                    pure (indexerProvider gate readiness agreementBound node)
        _ -> pure node

{- | The indexer backend's provider over a node followed from its origin
by the follower this process installed: each view's address reads are
the index's at the node view's point. The follower is first waited for
until it has caught up with the node, within 'readinessBound', and a
funding wallet, when named, must be covered: an output the node holds
there and the index does not — one only the genesis state carries — is
refused by name rather than read as absent.
-}
originProvider
    :: Cage.Provider IO -> Maybe Addr -> IO (Cage.Provider IO)
originProvider node wallet =
    currentFollower >>= \case
        Just
            Following
                { followingGate = gate
                , followingReadiness = readiness
                }
                | isNothing (coverageStart (gateCoverage gate)) -> do
                    awaitIndexerReady readiness readinessBound
                    for_ wallet (requireCovered gate readiness agreementBound node)
                    pure (indexerProvider gate readiness agreementBound node)
        _ ->
            die
                "the indexer backend reads through an index following the \
                \node's chain from its origin, and none is installed"

{- | How long a session waits for its follower to catch up with the node,
in microseconds: two minutes. A development network's whole chain is
followed in seconds; a public network followed from its origin takes far
longer, and its session is refused as restoring.
-}
readinessBound :: Int
readinessBound = 120_000_000

{- | How long a view waits for the index to reach the node view's point,
in microseconds: ten seconds. On the devnet the index trails the node by
a block or two, applied within milliseconds; a view still unagreed after
the bound is refused rather than answered.
-}
agreementBound :: Int
agreementBound = 10_000_000

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
    held <- Cage.withView node (`Cage.viewUTxOsAt` addr)
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

{- | The node adapter over an N2C provider ("Singular.Registry.Node.View"),
its address reads being the node's @GetUTxOByAddress@ in the acquired
state, refused once 'followedProvider' has handed the reads of a
followed devnet to its indexer.
-}
adaptProvider
    :: NetworkMagic -> TimeMaterial -> RawProvider IO -> Cage.Provider IO
adaptProvider magic material p =
    Cage.Provider $ \action -> Cage.withView (nodeProvider magic material p) $ \v ->
        action
            v
                { Cage.viewUTxOsAt = \addr -> do
                    followed <- readIORef fundingIndexed
                    when followed $
                        die
                            ( "GetUTxOByAddress for "
                                <> bech32Address addr
                                <> " sent to the node of a followed devnet after its \
                                   \funding read: read through followedProvider"
                            )
                    atomicModifyIORef' addressReads (\n -> (n + 1, ()))
                    Cage.viewUTxOsAt v addr
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
