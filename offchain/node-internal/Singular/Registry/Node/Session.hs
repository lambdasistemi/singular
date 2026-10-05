{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.Node.Session
Description : Opening, holding and closing a runner's node session
License     : Apache-2.0

The owner of the session record every runner reads ('NodeSession') and
of the process's open-session state: 'withOpenSession' installs a
session for the runner body and removes it at bracket exit, normal or
exceptional, so a confirmation that escapes the session's lifetime
names its error instead of guessing a chain.

Opening a session means connecting and negotiating the magic, waiting
for the chain to leave its origin, refusing to start when the funding wallet
cannot pay, and running the body. The devnet is spawned and torn down
around the session, and followed by an indexer that answers the
session's address reads and confirmations. An external node is left
running as it is; its address reads are its own, or, under the indexer
backend, an index's that follows it from its origin. Readers outside
this module reach the open session only through 'sessionFor' and
'currentTipSlot'.
-}
module Singular.Registry.Node.Session
    ( -- * Session
      NodeSession (..)
    , devnetGenesis
    , withNode
    , withNodeForPlannedFunding
    , withNodeMode
    , withNodeModeOn
    , withNodeSocket
    , awaitConnection
    , firstViewWithin

      -- * Key-free reads (#299)
    , NodeReads (..)
    , withNodeReads
    , withNodeReadsOn
    , readsOf
    , assembleSession
    , followerStart
    , serveSession

      -- * Open-session state
    , withOpenSession
    , sessionFor
    , currentTipSlot

      -- * No node call inside a view (#326)
    , NodeCallInView (..)
    , guardConnection
    , guardNodeConnection
    , guardRawConnection
    ) where

import Control.Concurrent (ThreadId, myThreadId, threadDelay)
import Control.Concurrent.Async
    ( Async
    , async
    , cancel
    , race
    , waitCatch
    , withAsync
    )
import Control.Concurrent.MVar
    ( newEmptyMVar
    , putMVar
    , takeMVar
    , tryPutMVar
    )
import Control.Exception
    ( Exception
    , SomeException
    , bracket
    , bracket_
    , throwIO
    , try
    )
import Control.Monad (void)
import Data.Aeson ((.=))
import Data.Foldable (for_)
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.Set (Set)
import Data.Set qualified as Set
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes (Network, SlotNo)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (devnetMagic, genesisDir)
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.N2C.Types (ConnectionLost (..), LSQChannel)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (Submitter (..))
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Data.Word (Word32, Word64)
import Singular.Registry.Node.Funding
    ( FundingFloor
    , checkFunding
    , defaultFundingFloor
    )
import Singular.Registry.Node.Indexer
    ( adaptProvider
    , followChain
    , followedProvider
    , originProvider
    , startingAt
    , withDevnetIndexer
    )
import Singular.Registry.Node.Options
    ( Backend (..)
    , ExternalNode (..)
    , NodeMode (..)
    , die
    , runMode
    )
import Singular.Registry.Node.PhaseLog
    ( PhaseLog
    , logPhase
    , loggedProvider
    , phaseLogFromEnv
    , queryPhase
    , startTimer
    )
import Singular.Registry.Node.RawView
    ( RawProvider (..)
    , RawView (..)
    , rawNodeProvider
    )
import Singular.Registry.Node.Wait
    ( boundedSubmitter
    , submissionBound
    )
import Singular.Registry.Node.Wallet
    ( Wallet (..)
    , bech32Address
    , walletForMode
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Services qualified as Services
import Singular.Registry.TimeMaterial (loadTimeMaterial)
import System.FilePath (takeDirectory)

-- | Everything a runner needs from the chain it runs against.
data NodeSession = NodeSession
    { nsProvider :: Cage.Provider IO
    -- ^ Queries, over the connected node
    , nsSubmitter :: Submitter IO
    -- ^ Transaction submission, over the same connection
    , nsMagic :: NetworkMagic
    -- ^ Magic the handshake negotiated
    , nsNetwork :: Network
    -- ^ Network the funding address is built for
    , nsTipSlot :: IO SlotNo
    {- ^ Current chain tip, for confirmation deadlines; never a read an
    operation builds from (those go through a view of 'nsProvider')
    -}
    , nsTipTime :: IO Integer
    -- ^ Latest observed block start in POSIX milliseconds, for local waits
    , nsMode :: NodeMode
    -- ^ Mode this session was opened in
    }

{- | What a key-free reader holds: the read interface over one
connection. No wallet, no funding check, no submitter, no follower:
nothing here can sign or send.
-}
newtype NodeReads = NodeReads
    { nrProvider :: Cage.Provider IO
    }

{- | Connect to an existing node by its socket and magic alone, for reads
(#299 inspect). Refuses, as 'withNodeMode' does, when the node does not
answer or carries another magic.
-}
withNodeReads :: Word32 -> FilePath -> (NodeReads -> IO a) -> IO a
withNodeReads = withNodeReadsOn NodeBackend

{- | 'withNodeReads' with its address reads from a backend: the node's own,
or, for 'IndexerBackend', an in-process index following the node's chain
from its origin for as long as the reader runs ('originProvider').
-}
withNodeReadsOn
    :: Backend -> Word32 -> FilePath -> (NodeReads -> IO a) -> IO a
withNodeReadsOn backend magicWord sock k = do
    lg <- phaseLogFromEnv
    opened <- startTimer
    let magic = NetworkMagic magicWord
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $ \nodeThread -> do
        (_, _, raw) <-
            guardRawConnection
                nodeThread
                (mkN2CProvider lsqCh)
                (mkN2CSubmitter ltxsCh)
                (rawNodeProvider lsqCh)
        awaitRawConnection magic sock nodeThread lsqCh
        material <- loadTimeMaterial magicWord (takeDirectory sock)
        let prov = adaptProvider magic material raw
        awaitConnection magic sock nodeThread (loggedProvider lg prov)
        case backend of
            NodeBackend -> do
                sessionOpened lg opened
                k (readsOf lg prov)
            IndexerBackend ->
                followChain magic publicByronEpochSlots Nothing sock $ do
                    indexed <- originProvider prov Nothing
                    sessionOpened lg opened
                    k (readsOf lg indexed)

-- | The devnet genesis directory, or 'Nothing' in external mode.
devnetGenesis :: IO (Maybe FilePath)
devnetGenesis = case runMode of
    Devnet -> Just <$> genesisDir
    External _ -> pure Nothing

{- | Hand a runner the socket of a node: the devnet this spawns, or the
one the joiner named. Callers that build their own client from a socket
path use this; the rest use 'withNode'. The devnet is followed by
'withDevnetIndexer' for the whole run, so its submissions confirm
through 'awaitIndexed'.
-}
withNodeSocket :: (FilePath -> IO a) -> IO a
withNodeSocket k = case runMode of
    Devnet -> do
        gDir <- genesisDir
        withCardanoNode
            gDir
            (\sock _startMs -> withDevnetIndexer sock (k sock))
    External e -> k (extSocket e)

-- | 'withNodeMode' at this process's 'runMode'.
withNode :: (NodeSession -> IO a) -> IO a
withNode = withNodeMode runMode

{- | Open a session in a named mode: connect, negotiate the magic,
query live protocol parameters, refuse to start when the funding wallet
cannot pay, and run the body. The devnet is spawned and torn down
around it, and followed by an indexer that answers the session's
address reads and confirmations; an external node is left alone.
-}
withNodeMode :: NodeMode -> (NodeSession -> IO a) -> IO a
withNodeMode = withNodeModeOn NodeBackend

{- | 'withNodeMode' with an external node's address reads from a backend:
the node's own, or, for 'IndexerBackend', an in-process index following
the node's chain from its origin ('originProvider'), which must cover the
funding wallet. A devnet session reads through its indexer either way.
-}
withNodeModeOn :: Backend -> NodeMode -> (NodeSession -> IO a) -> IO a
withNodeModeOn = withNodeModeAndFunding (Just defaultFundingFloor)

{- | The lifecycle runners calculate their complete funding plans from the
live parameters before submitting. A fixed 100 ADA floor here would reject
wallets that can afford those plans, and would block read-only estimates.
-}
withNodeForPlannedFunding :: (NodeSession -> IO a) -> IO a
withNodeForPlannedFunding = withNodeModeAndFunding Nothing NodeBackend runMode

withNodeModeAndFunding
    :: Maybe FundingFloor
    -> Backend
    -> NodeMode
    -> (NodeSession -> IO a)
    -> IO a
withNodeModeAndFunding fundingFloor backend mode k = case mode of
    Devnet -> do
        gDir <- genesisDir
        withCardanoNode gDir $ \sock _startMs ->
            withDevnetIndexer sock (connect devnetMagic sock)
    External e -> connect (NetworkMagic (extMagic e)) (extSocket e)
  where
    middle (_, submitter, _) = submitter
    connect magic sock = do
        lg <- phaseLogFromEnv
        opened <- startTimer
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $
            \nodeThread -> do
                connection <-
                    guardRawConnection
                        nodeThread
                        (mkN2CProvider lsqCh)
                        (boundedSubmitter submissionBound (mkN2CSubmitter ltxsCh))
                        (rawNodeProvider lsqCh)
                let (n2c, _, raw) = connection
                awaitRawConnection magic sock nodeThread lsqCh
                material <-
                    loadTimeMaterial (unNetworkMagic magic) (takeDirectory sock)
                awaitConnection
                    magic
                    sock
                    nodeThread
                    (loggedProvider lg (adaptProvider magic material raw))
                case mode of
                    Devnet ->
                        serveSession
                            lg
                            opened
                            fundingFloor
                            backend
                            mode
                            magic
                            sock
                            (adaptProvider magic material raw)
                            (n2c, middle connection)
                            k
                    External _ -> do
                        start <- followerStart lg backend n2c
                        followChain magic publicByronEpochSlots start sock $
                            serveSession
                                lg
                                opened
                                fundingFloor
                                backend
                                mode
                                magic
                                sock
                                (adaptProvider magic material raw)
                                (n2c, middle connection)
                                k

{- | A session over a connected node client and its submitter: the wallet
the mode names, the provider its backend reads through (the index, where
that is asked for, covering the wallet before the first view is handed out),
the session record, the funding check and the announcement. The part of
opening a session after the connection, taking the connected client as a
value.
-}
serveSession
    :: PhaseLog
    -> IO Double
    -> Maybe FundingFloor
    -> Backend
    -> NodeMode
    -> NetworkMagic
    -> FilePath
    -> Cage.Provider IO
    -> (N2C.Provider IO, Submitter IO)
    -> (NodeSession -> IO a)
    -> IO a
serveSession lg opened fundingFloor backend mode magic sock nodeProv (n2c, submitter) k = do
    wallet <- walletForMode mode
    -- A devnet session reads addresses through its indexer; an external
    -- node through the node adapter, or through the indexer backend
    -- when that is the backend asked for.
    prov <- case (mode, backend) of
        (Devnet, _) -> followedProvider nodeProv submitter
        (External _, NodeBackend) -> pure nodeProv
        (External _, IndexerBackend) ->
            originProvider nodeProv (Just (walletAddr wallet))
    let sess =
            assembleSession
                lg
                mode
                magic
                (walletNetwork wallet)
                prov
                submitter
                n2c
    for_ fundingFloor (checkFunding (nsProvider sess) (walletAddr wallet))
    announce mode magic sock (walletAddr wallet)
    sessionOpened lg opened
    withOpenSession sess (k sess)

{- | The block an external node's follower starts at: under the node backend
the node's own chain point, read by a direct query (one line); under the
index backend none, because the index follows from the origin and the
node is not asked.
-}
followerStart
    :: PhaseLog
    -> Backend
    -> N2C.Provider IO
    -> IO (Maybe (Indexer.SlotNo, Indexer.BlockHash))
followerStart lg NodeBackend n2c =
    startingAt . N2C.ledgerChainPoint
        <$> queryPhase lg "ledgerSnapshot" (const 1) (N2C.queryLedgerSnapshot n2c)
followerStart _ IndexerBackend _ = pure Nothing

{- | The reads a key-free reader holds over a provider: the provider, logged.
The one place a reader's provider is built, so that a reader of any
backend reads through the phase log.
-}
readsOf :: PhaseLog -> Cage.Provider IO -> NodeReads
readsOf lg prov = NodeReads{nrProvider = loggedProvider lg prov}

{- | The session record over the provider a command reads through, the
submitter and the upstream node client: its provider logged, and its tip
read (a direct query of the node, outside any view) one line each. The one
place a session is built.
-}
assembleSession
    :: PhaseLog
    -> NodeMode
    -> NetworkMagic
    -> Network
    -> Cage.Provider IO
    -> Submitter IO
    -> N2C.Provider IO
    -> NodeSession
assembleSession lg mode magic network prov submitter n2c =
    NodeSession
        { nsProvider = loggedProvider lg prov
        , nsSubmitter = submitter
        , nsMagic = magic
        , nsNetwork = network
        , nsTipSlot =
            queryPhase
                lg
                "tipSlot"
                (const 1)
                (N2C.ledgerTipSlot <$> N2C.queryLedgerSnapshot n2c)
        , nsTipTime = Cage.withView (loggedProvider lg prov) $ \view ->
            Services.slotStart view (Cage.cpSlot (Cage.viewPoint view))
        , nsMode = mode
        }

{- | The line that says how long opening the session took: connecting, the
handshake, the first view and, for a write, the funding check — what a
command spends before its own first phase.
-}
sessionOpened :: PhaseLog -> IO Double -> IO ()
sessionOpened lg opened = do
    ms <- opened
    logPhase lg "session-open" ["duration_ms" .= ms]

{- | Byron epoch length of the public networks. A follower started at the
tip never decodes a Byron block, and the development network has none,
but the codec needs one.
-}
publicByronEpochSlots :: Word64
publicByronEpochSlots = 21_600

{- | The session this process currently has open, installed by
'withNodeMode'. 'awaitTx' is the only reader: it needs the chain the
run is against, and threading a provider through every submission site
would say nothing the session does not already know. Outside a
session it names the error rather than guessing.
-}
openSession :: IORef (Maybe NodeSession)
openSession = unsafePerformIO (newIORef Nothing)
{-# NOINLINE openSession #-}

{- | Install a session for the runner body and remove it afterwards, on
normal return and on exception alike. The single writer of the
open-session state.
-}
withOpenSession :: NodeSession -> IO a -> IO a
withOpenSession sess =
    bracket_
        (writeIORef openSession (Just sess))
        (writeIORef openSession Nothing)

-- | Read the live tip for a transaction built in the active session.
currentTipSlot :: IO SlotNo
currentTipSlot =
    readIORef openSession
        >>= maybe (die "currentTipSlot called outside a node session") nsTipSlot

-- | The open session, or name the confirmation called outside one.
sessionFor :: String -> IO NodeSession
sessionFor what =
    readIORef openSession
        >>= maybe
            ( die
                ( what
                    <> " was called outside a node session; a runner must \
                       \wait for confirmation inside withNode"
                )
            )
            pure

-- | One line naming the chain and the wallet; never the key.
announce :: NodeMode -> NetworkMagic -> FilePath -> Addr -> IO ()
announce mode (NetworkMagic magic) sock addr =
    hPutStrLn stderr $
        "node: "
            <> label
            <> " socket="
            <> sock
            <> " magic="
            <> show magic
            <> " funder="
            <> bech32Address addr
  where
    label = case mode of
        Devnet -> "devnet"
        External _ -> "external"

{- | Wait until a freshly started node client answers its first query,
or name the two ways a fresh connection fails: the node is not there,
and the node runs a different network than the magic asserted.

Either failure ends the client thread, so racing the first view
against that ending waits exactly as long as the connection takes
rather than a fixed settling sleep. A chain at its origin is waited out
until its first block, since the origin cannot be acquired.
-}
awaitConnection
    :: (Show a)
    => NetworkMagic
    -> FilePath
    -> Async a
    -> Cage.Provider IO
    -> IO ()
awaitConnection magic sock nodeThread prov =
    awaitConnectionQuery
        magic
        sock
        (show <$> waitCatch nodeThread)
        (firstViewWithin originWaitPolls sock prov)

{- | The handshake must answer before local time-source selection can refuse
the network. Query only a raw fact on this connection; the subsequent first
public view retains the origin wait and all time validation.
-}
awaitRawConnection
    :: NetworkMagic -> FilePath -> Async a -> LSQChannel -> IO ()
awaitRawConnection magic sock nodeThread channel =
    awaitConnectionQuery
        magic
        sock
        (show . void <$> waitCatch nodeThread)
        (withRawView (rawNodeProvider channel) rawSystemStart)

awaitConnectionQuery
    :: NetworkMagic -> FilePath -> IO String -> IO b -> IO ()
awaitConnectionQuery (NetworkMagic magic) sock ended query = do
    answered <-
        race
            ended
            query
    case answered of
        Right _ -> pure ()
        Left outcome ->
            die $
                "the node at "
                    <> sock
                    <> " did not accept a node-to-client connection for \
                       \network magic "
                    <> show magic
                    <> ". The magic must be the one the node itself runs \
                       \(preprod is 1, the factory devnet is 42); a node on \
                       \another network refuses the handshake. Underlying \
                       \failure: "
                    <> outcome

{- | How many tenth-of-a-second polls a fresh connection waits for a
chain at its origin to make its first block: two minutes. A devnet makes
one within seconds; a public network is never at its origin.
-}
originWaitPolls :: Int
originWaitPolls = 1_200

{- | The first view a fresh connection yields. A chain still at its
origin has no block to acquire, so the acquisition is retried every
tenth of a second, at most this many times, and then refused by name;
any other failure ends the wait with it.
-}
firstViewWithin
    :: Int -> FilePath -> Cage.Provider IO -> IO Cage.ChainPoint
firstViewWithin polls sock prov =
    try (Cage.withView prov (pure . Cage.viewPoint)) >>= \case
        Right point -> pure point
        Left Cage.AcquiredAtOrigin
            | polls > 0 ->
                threadDelay 100_000 >> firstViewWithin (polls - 1) sock prov
            | otherwise ->
                die $
                    "the chain at "
                        <> sock
                        <> " is still at its origin: no block has been made, so \
                           \no view of it can be acquired (AcquiredAtOrigin)"
        Left other -> throwIO other

-- ---------------------------------------------------------
-- No node call inside a view (#326)
-- ---------------------------------------------------------

{- | A node call issued by a thread that holds an acquired view on the same
connection, by a route other than that view: a one-shot query, a second
acquisition or a submission. The connection serves only the acquired
state until the view is released, so the call would otherwise wait for
a release that waits for it. Names the call.
-}
newtype NodeCallInView = NodeCallInView String
    deriving stock (Eq, Show)

instance Exception NodeCallInView

{- | A node connection — its LocalStateQuery provider and its submitter —
that refuses, as 'NodeCallInView', every call a thread issues while it
holds an acquired view of that connection, other than the view's own
reads; calls from threads holding no view pass through.

Every call, the view's own reads included, also ends with the client
thread: once the connection to the node has ended, a call waiting on it
fails as @ConnectionLost@ (which the node adapter names
'Cage.ViewConnectionLost') instead of waiting for an answer that cannot
come. The upstream client raises it only when the runtime finds the
waiting thread deadlocked, which it never does while another thread
holds that thread's id.
-}
guardConnection
    :: Async b
    -> N2C.Provider IO
    -> Submitter IO
    -> IO (N2C.Provider IO, Submitter IO)
guardConnection client p0 s = do
    (p, submitter, _) <-
        guardRawConnection
            client
            p0
            s
            (RawProvider (\_ -> fail "raw view not supplied"))
    pure (p, submitter)

{- | Compose a runner's existing connection into guarded upstream reads,
submission and acquired public reads. The raw adapter and exact time-source
selection stay behind the public node facade; no second connection is opened.
-}
guardNodeConnection
    :: Async b
    -> NetworkMagic
    -> FilePath
    -> LSQChannel
    -> N2C.Provider IO
    -> Submitter IO
    -> IO (N2C.Provider IO, Submitter IO, Cage.Provider IO)
guardNodeConnection client magic sock channel upstream submit = do
    (node, guardedSubmit, raw) <-
        guardRawConnection client upstream submit (rawNodeProvider channel)
    awaitRawConnection magic sock client channel
    material <-
        loadTimeMaterial (unNetworkMagic magic) (takeDirectory sock)
    pure (node, guardedSubmit, adaptProvider magic material raw)

-- | Raw and legacy routes share the same holder set and connection lifetime.
guardRawConnection
    :: Async b
    -> N2C.Provider IO
    -> Submitter IO
    -> RawProvider IO
    -> IO (N2C.Provider IO, Submitter IO, RawProvider IO)
guardRawConnection client p0 s raw = do
    let p = whileConnected client p0
    holders <- newIORef (Set.empty :: Set ThreadId)
    let outside :: String -> IO a -> IO a
        outside call act = do
            me <- myThreadId
            held <- Set.member me <$> readIORef holders
            if held then throwIO (NodeCallInView call) else act
        holding me =
            bracket_
                (atomicModifyIORef' holders (\h -> (Set.insert me h, ())))
                (atomicModifyIORef' holders (\h -> (Set.delete me h, ())))
    pure
        ( p
            { N2C.withAcquired = \k -> outside "withAcquired" $ do
                me <- myThreadId
                N2C.withAcquired p (holding me . k)
            , N2C.queryUTxOs = outside "queryUTxOs" . N2C.queryUTxOs p
            , N2C.queryUTxOByTxIn =
                outside "queryUTxOByTxIn" . N2C.queryUTxOByTxIn p
            , N2C.queryProtocolParams =
                outside "queryProtocolParams" (N2C.queryProtocolParams p)
            , N2C.queryLedgerSnapshot =
                outside "queryLedgerSnapshot" (N2C.queryLedgerSnapshot p)
            , N2C.queryStakeRewards =
                outside "queryStakeRewards" . N2C.queryStakeRewards p
            , N2C.queryRewardAccounts =
                outside "queryRewardAccounts" . N2C.queryRewardAccounts p
            , N2C.queryVoteDelegatees =
                outside "queryVoteDelegatees" . N2C.queryVoteDelegatees p
            , N2C.queryTreasury = outside "queryTreasury" (N2C.queryTreasury p)
            , N2C.queryGovernanceState =
                outside "queryGovernanceState" (N2C.queryGovernanceState p)
            , N2C.evaluateTx = outside "evaluateTx" . N2C.evaluateTx p
            , N2C.posixMsToSlot = outside "posixMsToSlot" . N2C.posixMsToSlot p
            , N2C.posixMsCeilSlot =
                outside "posixMsCeilSlot" . N2C.posixMsCeilSlot p
            , N2C.queryUpperBoundSlot =
                outside "queryUpperBoundSlot" . N2C.queryUpperBoundSlot p
            }
        , Submitter (outside "submitTx" . connected client . submitTx s)
        , RawProvider $ \k -> outside "withAcquired" $ do
            me <- myThreadId
            acquiredWhileConnected
                client
                (withRawView raw)
                (holding me . k . liveRaw)
        )
  where
    liveRaw (RawView snapshot params address refs rewards start history) =
        RawView
            (connected client snapshot)
            (connected client params)
            (connected client . address)
            (connected client . refs)
            (connected client . rewards)
            (connected client start)
            (connected client history)

{- | Each call of the provider, and each read of every view it acquires,
ends with the client.
-}
whileConnected :: Async b -> N2C.Provider IO -> N2C.Provider IO
whileConnected client p =
    N2C.Provider
        { N2C.withAcquired = \k -> acquiredWhileConnected client (N2C.withAcquired p) (k . handleOf)
        , N2C.queryUTxOs = live . N2C.queryUTxOs p
        , N2C.queryUTxOByTxIn = live . N2C.queryUTxOByTxIn p
        , N2C.queryProtocolParams = live (N2C.queryProtocolParams p)
        , N2C.queryLedgerSnapshot = live (N2C.queryLedgerSnapshot p)
        , N2C.queryStakeRewards = live . N2C.queryStakeRewards p
        , N2C.queryRewardAccounts = live . N2C.queryRewardAccounts p
        , N2C.queryVoteDelegatees = live . N2C.queryVoteDelegatees p
        , N2C.queryTreasury = live (N2C.queryTreasury p)
        , N2C.queryGovernanceState = live (N2C.queryGovernanceState p)
        , N2C.evaluateTx = live . N2C.evaluateTx p
        , N2C.posixMsToSlot = live . N2C.posixMsToSlot p
        , N2C.posixMsCeilSlot = live . N2C.posixMsCeilSlot p
        , N2C.queryUpperBoundSlot = live . N2C.queryUpperBoundSlot p
        }
  where
    live :: IO a -> IO a
    live = connected client
    handleOf h =
        N2C.mkQueryHandle
            N2C.QueryHandleBackend
                { N2C.backendQueryUTxOs = live . N2C.queryUTxOsH h
                , N2C.backendQueryUTxOsAt = live . N2C.queryUTxOsAtH h
                , N2C.backendQueryUTxOByTxIn = live . N2C.queryUTxOByTxInH h
                , N2C.backendQueryProtocolParams = live (N2C.queryProtocolParamsH h)
                , N2C.backendQueryLedgerSnapshot = live (N2C.queryLedgerSnapshotH h)
                , N2C.backendQueryStakeRewards = live . N2C.queryStakeRewardsH h
                , N2C.backendQueryRewardAccounts = live . N2C.queryRewardAccountsH h
                , N2C.backendQueryVoteDelegatees = live . N2C.queryVoteDelegateesH h
                , N2C.backendQueryTreasury = live (N2C.queryTreasuryH h)
                , N2C.backendQueryGovernanceState = live (N2C.queryGovernanceStateH h)
                , N2C.backendEvaluateTx = live . N2C.evaluateTxH h
                , N2C.backendPosixMsToSlot = live . N2C.posixMsToSlotH h
                , N2C.backendPosixMsCeilSlot = live . N2C.posixMsCeilSlotH h
                }

-- | Run a call, or fail it as @ConnectionLost@ once the client has ended.
connected :: Async b -> IO a -> IO a
connected client call =
    race (waitCatch client) call
        >>= either (const (throwIO ConnectionLost)) pure

{- | One acquisition whose body runs on the caller's thread while a helper
thread holds the acquired state: the acquisition and the release are each
waited for only while the client lives, so neither waits forever on a
connection that has ended.
-}
acquiredWhileConnected
    :: Async b -> ((h -> IO ()) -> IO ()) -> (h -> IO a) -> IO a
acquiredWhileConnected client acquire body = do
    acquired <- newEmptyMVar
    done <- newEmptyMVar
    let holding = acquire (\h -> putMVar acquired h >> takeMVar done)
    withAsync holding $ \holder -> do
        h <-
            connected client (race (waitCatch holder) (takeMVar acquired))
                >>= either (either throwIO (const (throwIO ConnectionLost))) pure
        result <- try @SomeException (body h)
        _ <- tryPutMVar done ()
        -- An ended connection has nothing left to release: the body's own
        -- outcome stands.
        _ <- race (waitCatch client) (waitCatch holder)
        either throwIO pure result
