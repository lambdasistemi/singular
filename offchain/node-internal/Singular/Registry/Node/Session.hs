{- |
Module      : Singular.Registry.Node.Session
Description : Opening, holding and closing a runner's node session
License     : Apache-2.0

The owner of the session record every runner reads ('NodeSession') and
of the process's open-session state: 'withOpenSession' installs a
session for the runner body and removes it at bracket exit, normal or
exceptional, so a confirmation that escapes the session's lifetime
names its error instead of guessing a chain.

Opening a session means connecting and negotiating the magic, querying
live protocol parameters, refusing to start when the funding wallet
cannot pay, and running the body. The devnet is spawned and torn down
around the session, and followed by an indexer that answers the
session's address reads and confirmations; an external node is left
alone. Readers outside this module reach the open session only through
'sessionFor', 'scriptStakeRegistered' and 'currentTipSlot'.
-}
module Singular.Registry.Node.Session
    ( -- * Session
      NodeSession (..)
    , devnetGenesis
    , withNode
    , withNodeForPlannedFunding
    , withNodeMode
    , withNodeSocket
    , awaitConnection

      -- * Key-free reads (#299)
    , NodeReads (..)
    , withNodeReads

      -- * Open-session state
    , withOpenSession
    , sessionFor
    , scriptStakeRegistered
    , currentTipSlot
    ) where

import Control.Concurrent.Async
    ( Async
    , async
    , cancel
    , race
    , waitCatch
    )
import Control.Exception (bracket, bracket_)
import Data.Foldable (for_)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)

import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes (Network, SlotNo)
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (devnetMagic, genesisDir)
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (Submitter)
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Data.ByteString (ByteString)
import Data.Word (Word32, Word64)
import Singular.Registry.Ledger (ConwayEra, PParams)
import Singular.Registry.Node.Funding
    ( FundingFloor
    , checkFunding
    , defaultFundingFloor
    )
import Singular.Registry.Node.Indexer
    ( adaptProvider
    , followChain
    , followedProvider
    , startingAt
    , withDevnetIndexer
    )
import Singular.Registry.Node.Options
    ( ExternalNode (..)
    , NodeMode (..)
    , die
    , runMode
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
    , nsPParams :: PParams ConwayEra
    -- ^ Protocol parameters queried from the running node
    , nsScriptRegistered :: ScriptHash -> IO Bool
    -- ^ Whether this script has a registered reward account, including zero balance
    , nsTipSlot :: IO SlotNo
    -- ^ Current chain tip queried from this session
    , nsChainPoint :: IO (Maybe (Word64, ByteString))
    {- ^ The node's current chain point as slot and header hash; none at
    genesis. What a write journals just before a send, so a later reader
    can follow the chain from there.
    -}
    , nsMode :: NodeMode
    -- ^ Mode this session was opened in
    }

{- | What a key-free reader holds: ledger queries over one connection,
and the node's chain point and tip. No wallet, no funding check, no
submitter, no follower: nothing here can sign or send.
-}
data NodeReads = NodeReads
    { nrProvider :: Cage.Provider IO
    , nrChainPoint :: IO (Maybe (Word64, ByteString))
    -- ^ Slot and header hash of the node's current chain point
    , nrTipSlot :: IO SlotNo
    }

{- | Connect to an existing node by its socket and magic alone, for reads
(#299 inspect). Refuses, as 'withNodeMode' does, when the node does not
answer or carries another magic.
-}
withNodeReads :: Word32 -> FilePath -> (NodeReads -> IO a) -> IO a
withNodeReads magicWord sock k = do
    let magic = NetworkMagic magicWord
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $ \nodeThread -> do
        let n2c = mkN2CProvider lsqCh
            prov = adaptProvider n2c
        awaitConnection magic sock nodeThread prov
        k
            NodeReads
                { nrProvider = prov
                , nrChainPoint =
                    fmap (\(Indexer.SlotNo slot, Indexer.BlockHash h) -> (slot, h))
                        . startingAt
                        . N2C.ledgerChainPoint
                        <$> N2C.queryLedgerSnapshot n2c
                , nrTipSlot = N2C.ledgerTipSlot <$> N2C.queryLedgerSnapshot n2c
                }

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
withNodeMode = withNodeModeAndFunding (Just defaultFundingFloor)

{- | The lifecycle runners calculate their complete funding plans from the
live parameters before submitting. A fixed 100 ADA floor here would reject
wallets that can afford those plans, and would block read-only estimates.
-}
withNodeForPlannedFunding :: (NodeSession -> IO a) -> IO a
withNodeForPlannedFunding = withNodeModeAndFunding Nothing runMode

withNodeModeAndFunding
    :: Maybe FundingFloor -> NodeMode -> (NodeSession -> IO a) -> IO a
withNodeModeAndFunding fundingFloor mode k = case mode of
    Devnet -> do
        gDir <- genesisDir
        withCardanoNode gDir $ \sock _startMs ->
            withDevnetIndexer sock (connect devnetMagic sock)
    External e -> connect (NetworkMagic (extMagic e)) (extSocket e)
  where
    connect magic sock = do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $
            \nodeThread -> do
                let n2c = mkN2CProvider lsqCh
                awaitConnection magic sock nodeThread (adaptProvider n2c)
                case mode of
                    Devnet -> session magic sock n2c ltxsCh
                    External _ -> do
                        tip <- N2C.ledgerChainPoint <$> N2C.queryLedgerSnapshot n2c
                        followChain magic publicByronEpochSlots (startingAt tip) sock $
                            session magic sock n2c ltxsCh
    session magic sock n2c ltxsCh = do
        wallet <- walletForMode mode
        let nodeProv = adaptProvider n2c
            submitter =
                boundedSubmitter submissionBound (mkN2CSubmitter ltxsCh)
        pp <- Cage.queryProtocolParams nodeProv
        prov <- followedProvider nodeProv submitter
        for_ fundingFloor (checkFunding prov (walletAddr wallet))
        announce mode magic sock (walletAddr wallet)
        let sess =
                NodeSession
                    { nsProvider = prov
                    , nsSubmitter = submitter
                    , nsMagic = magic
                    , nsNetwork = walletNetwork wallet
                    , nsPParams = pp
                    , nsScriptRegistered = \h -> do
                        let credential = ScriptHashObj h
                        Map.member credential
                            <$> N2C.queryStakeRewards n2c (Set.singleton credential)
                    , nsTipSlot = N2C.ledgerTipSlot <$> N2C.queryLedgerSnapshot n2c
                    , nsChainPoint =
                        fmap (\(Indexer.SlotNo slot, Indexer.BlockHash h) -> (slot, h))
                            . startingAt
                            . N2C.ledgerChainPoint
                            <$> N2C.queryLedgerSnapshot n2c
                    , nsMode = mode
                    }
        withOpenSession sess (k sess)
    -- Byron epoch length of the public networks; a follower started at
    -- the tip never decodes a Byron block, but the codec needs one.
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

-- | Registration is global to a script credential, shared by registries.
scriptStakeRegistered :: ScriptHash -> IO Bool
scriptStakeRegistered h =
    readIORef openSession
        >>= maybe
            (die "scriptStakeRegistered called outside a node session")
            (`nsScriptRegistered` h)

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

Either failure ends the client thread, so racing the first query
against that ending waits exactly as long as the connection takes
rather than a fixed settling sleep.
-}
awaitConnection
    :: (Show a)
    => NetworkMagic
    -> FilePath
    -> Async a
    -> Cage.Provider IO
    -> IO ()
awaitConnection (NetworkMagic magic) sock nodeThread prov = do
    answered <-
        race (waitCatch nodeThread) (Cage.queryProtocolParams prov)
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
                    <> show outcome
