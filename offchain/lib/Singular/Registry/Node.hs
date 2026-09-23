{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.Node
Description : Node and funding-wallet entry point for every runner
License     : Apache-2.0

The single place where a runner acquires a node connection and the
wallet that funds it.

Two modes, chosen once per process from the command line and the
environment:

* __devnet__ (the default, unchanged behaviour): spawn a private
  @cardano-node@ over the checked-in genesis, magic 42, and fund every
  actor from the genesis UTxO key.
* __external__ (@--node-socket@, @--network-magic@, @--wallet-skey@, or
  the @SINGULAR_NODE_SOCKET@, @SINGULAR_NETWORK_MAGIC@,
  @SINGULAR_WALLET_SKEY@ environment variables): connect to a node the
  joiner already runs and fund every actor from the joiner's own
  signing key.

Both modes build the same N2C provider and submitter over a socket, so
external mode is not a second implementation of the runners — it is the
same code reached with a different socket and a different wallet.

Every session follows its chain with an in-memory UTxO indexer: the
devnet from its origin, an external node from its tip when the session
opens. Confirmations are the indexer's on both. Address reads are the
indexer's on the devnet and the node's on an external chain, whose
older outputs the indexer never saw.

The network magic is verified by the node-to-client handshake itself:
'runNodeClient' negotiates the requested magic and a node running
another network rejects the connection. 'withNodeMode' turns that
rejection into a named diagnostic instead of a bare protocol error.

Key material is read from the joiner's file and never printed; only the
derived (public) address is reported.
-}
module Singular.Registry.Node (
    -- * Mode
    NodeMode (..),
    ExternalNode (..),
    nodeModeFromArgs,
    nodeModeFromEnvironment,
    runMode,

    -- * Wallet
    Wallet (..),
    loadWallet,
    walletForMode,
    funderAddr,
    funderSignKey,
    sessionMagic,
    bech32Address,

    -- * Session
    NodeSession (..),
    awaitChain,
    currentTipSlot,
    scriptStakeRegistered,
    awaitTx,
    awaitTxId,
    awaitTxWindow,
    withDevnetIndexer,
    awaitIndexed,
    adaptProvider,
    followedProvider,
    nodeAddressReads,
    awaitConnection,
    confirmDeadline,
    txUpperBoundSlot,
    nodeIsExternal,
    echoKoios,
    confirmationDelay,
    withNode,
    withNodeForPlannedFunding,
    withNodeMode,
    withNodeSocket,
    devnetGenesis,

    -- * Funding
    FundingFloor (..),
    defaultFundingFloor,
    checkFunding,
) where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, link, race, waitCatch)
import Control.Exception (ErrorCall (..), SomeException, bracket, bracket_, displayException, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson (eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Char (isSpace)
import Data.Foldable (for_, toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isNothing)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word32, Word64)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getEnvironment)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (readProcess)
import Text.Read (readMaybe)

import Codec.Binary.Bech32 qualified as Bech32
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras (OneEraHash (..))
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, inputsTxBodyL, mkBasicTxBody, outputsTxBodyL, vldtTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network (..), SlotNo (..), StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (decodeFull')
import Cardano.Ledger.Core (eraProtVerLow)
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash, extractHash, unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))

import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Ledger.Val (inject, (<->))

import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
    addKeyWitness,
    devnetMagic,
    genesisDir,
    genesisSignKey,
    keyHashFromSignKey,
    rawDeserialiseSignKeyDSIGN,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Node.Client.Types (BlockPoint)
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    FollowerHandle (..),
    InterestSet (..),
    withChainSyncFollower,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Types qualified as Indexer
import Cardano.Tx.Ledger (ConwayTx)
import Control.Tracer (nullTracer)
import Singular.Registry.Ledger (Coin (..), ConwayEra, PParams)
import Singular.Registry.Provider qualified as Cage

-- ---------------------------------------------------------
-- Mode
-- ---------------------------------------------------------

-- | A node the joiner already runs, with the key that funds the run.
data ExternalNode = ExternalNode
    { extSocket :: FilePath
    -- ^ Path of the node's node-to-client socket
    , extMagic :: Word32
    -- ^ Network magic the joiner asserts the node carries
    , extSkeyFile :: FilePath
    -- ^ Payment signing key file funding every actor
    }
    deriving (Eq, Show)

-- | How this process reaches a chain.
data NodeMode
    = -- | Spawn a private devnet and use its genesis key (the default)
      Devnet
    | -- | Connect to the joiner's node and use the joiner's key
      External ExternalNode
    deriving (Eq, Show)

-- | Mainnet's network magic — the one value external mode refuses.
mainnetMagic :: Word32
mainnetMagic = 764824073

{- | Resolve the mode from a command line and an environment.

Pure, so precedence and the partial-configuration diagnostic are
testable without a process: flags win over environment variables,
unknown arguments are ignored (runners take their own), and naming any
one of the three settings selects external mode and requires the other
two.
-}
nodeModeFromArgs ::
    [String] ->
    [(String, String)] ->
    Either String NodeMode
nodeModeFromArgs args env
    | null (catMaybes [mSock, mMagic, mSkey]) = Right Devnet
    | otherwise = do
        sock <- need "--node-socket" "SINGULAR_NODE_SOCKET" mSock
        magicS <- need "--network-magic" "SINGULAR_NETWORK_MAGIC" mMagic
        skey <- need "--wallet-skey" "SINGULAR_WALLET_SKEY" mSkey
        magic <- case readMaybe magicS of
            Just n -> Right n
            Nothing -> Left ("network magic is not a number: " <> magicS)
        if magic == mainnetMagic
            then
                Left
                    "external-node mode refuses network magic 764824073 \
                    \(mainnet): these runners submit live transactions and \
                    \are for test networks only"
            else
                Right . External $
                    ExternalNode
                        { extSocket = sock
                        , extMagic = magic
                        , extSkeyFile = skey
                        }
  where
    mSock = flag "--node-socket" `orElse` lookup "SINGULAR_NODE_SOCKET" env
    mMagic = flag "--network-magic" `orElse` lookup "SINGULAR_NETWORK_MAGIC" env
    mSkey = flag "--wallet-skey" `orElse` lookup "SINGULAR_WALLET_SKEY" env
    orElse a b = a <|> b
    need f e = maybe (Left (missing f e)) Right
    missing f e =
        "external-node mode is partially configured: "
            <> f
            <> " (or "
            <> e
            <> ") is missing. All three of --node-socket, --network-magic \
               \and --wallet-skey are required together; give none of them \
               \to run the factory devnet."
    flag name = go args
      where
        go (a : rest)
            | a == name = case rest of
                (v : _) -> Just v
                [] -> Nothing
            | (name <> "=") `isPrefixOf` a = Just (drop (length name + 1) a)
            | otherwise = go rest
        go [] = Nothing

-- | 'nodeModeFromArgs' applied to this process.
nodeModeFromEnvironment :: IO NodeMode
nodeModeFromEnvironment = do
    args <- getArgs
    env <- getEnvironment
    either die pure (nodeModeFromArgs args env)

{- | This process's mode, resolved once.

A process-level constant: it depends only on the command line and the
environment, both fixed for the lifetime of the process, so no ordering
between this and any other action can change what it reads.
-}
runMode :: NodeMode
runMode = unsafePerformIO nodeModeFromEnvironment
{-# NOINLINE runMode #-}

{- | Whether this process runs against an external (public) node.
Diagnostics that only make sense off the factory devnet gate on it.
-}
nodeIsExternal :: Bool
nodeIsExternal = case runMode of
    Devnet -> False
    External _ -> True

{- | Preprod diagnostic: POST the same transaction bytes to Koios's
public submittx endpoint and write its verbatim answer next to the
transaction's retained evidence. The node this process talks to
remains the only verdict; a Koios refusal, a transport error or a
missing curl is recorded and never raised. Devnet runs keep no Koios
echo — the factory devnet has no public endpoint.
-}
echoKoios :: FilePath -> String -> ByteString -> IO ()
echoKoios evDir tag raw = case runMode of
    Devnet -> pure ()
    External _ -> do
        let cborPath = evDir </> ("tx-" <> tag <> ".cbor")
            koiosPath = evDir </> ("tx-" <> tag <> ".koios.txt")
        createDirectoryIfMissing True evDir
        BS.writeFile cborPath raw
        r <-
            try
                ( readProcess
                    "curl"
                    [ "-sS"
                    , "--max-time"
                    , "30"
                    , "-X"
                    , "POST"
                    , "-H"
                    , "Content-Type: application/cbor"
                    , "--data-binary"
                    , "@" <> cborPath
                    , "https://preprod.koios.rest/api/v1/submittx"
                    ]
                    ""
                ) ::
                IO (Either SomeException String)
        case r of
            Right body -> writeFile koiosPath body
            Left err -> writeFile koiosPath (displayException err)

-- ---------------------------------------------------------
-- Wallet
-- ---------------------------------------------------------

-- | The wallet funding every actor of a run.
data Wallet = Wallet
    { walletAddr :: Addr
    -- ^ Enterprise payment address derived from the signing key
    , walletSignKey :: SignKeyDSIGN Ed25519DSIGN
    -- ^ Signing key; read from the joiner's file, never printed
    , walletNetwork :: Network
    -- ^ Network the address is built for
    }

{- | Load a payment signing key from a file and derive its enterprise
address for the given magic.

Accepts the @cardano-cli@ text envelope (a JSON object with a
@cborHex@ field holding the CBOR byte string @5820\<32 bytes\>@), the
same value as bare hex, and the 32 raw key bytes. The key is never
logged.
-}
loadWallet :: Word32 -> FilePath -> IO Wallet
loadWallet magic path = do
    raw <- BS.readFile path
    keyBytes <- either (die . prefix) pure (signKeyBytes raw)
    sk <- case rawDeserialiseSignKeyDSIGN keyBytes of
        Just sk -> pure sk
        Nothing ->
            die (prefix "the 32 bytes are not a valid Ed25519 signing key")
    let net = if magic == mainnetMagic then Mainnet else Testnet
    pure
        Wallet
            { walletAddr =
                Addr net (KeyHashObj (keyHashFromSignKey sk)) StakeRefNull
            , walletSignKey = sk
            , walletNetwork = net
            }
  where
    prefix msg = "wallet signing key " <> path <> ": " <> msg

-- | The 32 raw key bytes carried by a signing-key file.
signKeyBytes :: ByteString -> Either String ByteString
signKeyBytes raw
    | BS.length trimmed == 32, not (isTextual trimmed) = Right trimmed
    | Just h <- envelopeHex trimmed = unwrap =<< decodeHex h
    | otherwise = unwrap =<< decodeHex trimmed
  where
    trimmed = BC.dropWhile isSpace (BC.dropWhileEnd isSpace raw)
    isTextual = BS.all (\w -> w >= 0x20 && w < 0x7f)
    envelopeHex b
        | BC.take 1 b == "{" = case eitherDecodeStrict b of
            Right v ->
                BC.pack . T.unpack
                    <$> parseMaybe (withObject "skey" (.: "cborHex")) v
            Left _ -> Nothing
        | otherwise = Nothing
    decodeHex b = case B16.decode b of
        Right bytes -> Right bytes
        Left _ ->
            Left
                "not a text envelope with a cborHex field, not hex, and not \
                \32 raw bytes"
    unwrap bytes
        | BS.length bytes == 34
        , BS.take 2 bytes == BS.pack [0x58, 0x20] =
            Right (BS.drop 2 bytes)
        | BS.length bytes == 32 = Right bytes
        | otherwise =
            Left ("expected 32 key bytes, found " <> show (BS.length bytes))

{- | The wallet a mode funds from: the devnet genesis key, or the
joiner's key loaded from the file they named.
-}
walletForMode :: NodeMode -> IO Wallet
walletForMode Devnet =
    pure
        Wallet
            { walletAddr =
                Addr
                    Testnet
                    (KeyHashObj (keyHashFromSignKey genesisSignKey))
                    StakeRefNull
            , walletSignKey = genesisSignKey
            , walletNetwork = Testnet
            }
walletForMode (External e) = loadWallet (extMagic e) (extSkeyFile e)

-- | This process's funding wallet, resolved once from 'runMode'.
processWallet :: Wallet
processWallet = unsafePerformIO (walletForMode runMode)
{-# NOINLINE processWallet #-}

{- | The address every actor of this run is funded from: the devnet
genesis address by default, the joiner's address in external mode.
-}
funderAddr :: Addr
funderAddr = walletAddr processWallet

-- | The signing key matching 'funderAddr'.
funderSignKey :: SignKeyDSIGN Ed25519DSIGN
funderSignKey = walletSignKey processWallet

-- | The network magic this run negotiates with its node.
sessionMagic :: NetworkMagic
sessionMagic = case runMode of
    Devnet -> devnetMagic
    External e -> NetworkMagic (extMagic e)

-- ---------------------------------------------------------
-- Session
-- ---------------------------------------------------------

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
    , nsMode :: NodeMode
    -- ^ Mode this session was opened in
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
        withCardanoNode gDir (\sock _startMs -> withDevnetIndexer sock (k sock))
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

withNodeModeAndFunding :: Maybe FundingFloor -> NodeMode -> (NodeSession -> IO a) -> IO a
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
            submitter = mkN2CSubmitter ltxsCh
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
                        Map.member credential <$> N2C.queryStakeRewards n2c (Set.singleton credential)
                    , nsTipSlot = N2C.ledgerTipSlot <$> N2C.queryLedgerSnapshot n2c
                    , nsMode = mode
                    }
        bracket_
            (writeIORef openSession (Just sess))
            (writeIORef openSession Nothing)
            (k sess)
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

-- | Registration is global to a script credential, shared by registries.
scriptStakeRegistered :: ScriptHash -> IO Bool
scriptStakeRegistered h = readIORef openSession >>= maybe (die "scriptStakeRegistered called outside a node session") (`nsScriptRegistered` h)

-- | Read the live tip for a transaction built in the active session.
currentTipSlot :: IO SlotNo
currentTipSlot = readIORef openSession >>= maybe (die "currentTipSlot called outside a node session") nsTipSlot

{- | Wait until a submitted transaction is visible on the chain.

A fixed sleep is a devnet assumption: the factory devnet makes a block
about every second, a public test network about every twenty, so a
five-second wait calibrated on the devnet silently becomes a race on
preprod. This waits for the transaction's first output — the strongest
evidence the chain carries — and names the transaction when it never
appears.

The wait is bounded by the transaction's own validity upper bound plus
a two-minute margin, not by a fixed poll count: a transaction that is
still valid can still land, and a fixed five-minute window declared a
healthy preprod fold lost while eight minutes of its validity remained
(2026-09-14, registry request for spelling "alice"). A transaction
with no upper bound cannot expire, so the historical fixed window
stays its only bound.
-}
awaitTx :: ConwayTx -> IO ()
awaitTx tx = do
    sess <- sessionFor "awaitTx"
    case toList (tx ^. bodyTxL . outputsTxBodyL) of
        _ : _ -> pure ()
        [] ->
            die
                ( "cannot confirm transaction "
                    <> show (txIdTx tx)
                    <> ": it creates no output to observe"
                )
    deadline <- windowDeadlineFor sess tx
    confirmOutputZero sess (show (txIdTx tx)) (txIdTx tx) deadline

{- | Confirm a just-submitted transaction by observing output zero.
Call before a dependent transaction spends that output. This supports
journey helpers that retain a transaction id but not the complete body.

Prefer 'awaitTxWindow' wherever the runner still holds the transaction:
there the wait is bounded by the transaction's own validity window
rather than by this fixed window.
-}
awaitTxId :: String -> IO ()
awaitTxId txid = do
    sess <- sessionFor "awaitTxId"
    wanted <- txIdFromHex "awaitTxId" txid
    deadline <- fixedWindowDeadline (nsProvider sess)
    confirmOutputZero sess txid wanted deadline

{- | Confirm a just-submitted transaction by observing output zero,
until the transaction's own validity upper bound plus a two-minute
margin. The runner holds the transaction it just built and signed, so
the wait can be exactly as long as the transaction can still land —
and the failure names the expired window instead of a fixed poll
count. A transaction with no upper bound cannot expire; the fixed
window of 'awaitTxId' stays its bound.
-}
awaitTxWindow :: ConwayTx -> String -> IO ()
awaitTxWindow tx txid = do
    sess <- sessionFor "awaitTxWindow"
    deadline <- windowDeadlineFor sess tx
    wanted <- txIdFromHex "awaitTxWindow" txid
    confirmOutputZero sess txid wanted deadline

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

-- | A transaction id from its hex rendering.
txIdFromHex :: String -> String -> IO TxId
txIdFromHex what txid = do
    raw <- either (const (die (what <> ": transaction id is not hex"))) pure (B16.decode (BC.pack txid))
    h <- maybe (die (what <> ": transaction id is not 32 bytes")) pure (hashFromBytes raw)
    pure (TxId (unsafeMakeSafeHash h))

{- | Wait until the indexer following the session's chain reports the
block that carries output zero of a transaction, or the chain's tip
passes the deadline. The node is asked only for its tip, and only
while the output has not appeared.
-}
confirmOutputZero :: NodeSession -> String -> TxId -> SlotNo -> IO ()
confirmOutputZero sess label tid deadline =
    readIORef chainFollower
        >>= maybe
            (die (label <> ": no indexer follows this session's chain"))
            (indexed . followingIndexer)
  where
    indexed idx = do
        let TxId h = tid
        seen <-
            awaitTxIn
                idx
                (Indexer.TxIn (hashToBytes (extractHash h)) 0)
                (Just confirmationPollSeconds)
        case seen of
            Just _ -> pure ()
            Nothing -> do
                tip <- nsTipSlot sess
                whenExpired label tip deadline (indexed idx)

{- | The poll-until deadline for a transaction: its own validity upper
bound plus a two-minute margin; the historical fixed window when it
carries no upper bound. The margin is measured in slots through the
node's own time-to-slot conversion, so it means two minutes on every
network. If that conversion fails the run is dying anyway; the fixed
window restated in slots keeps the deadline total.
-}
windowDeadlineFor :: NodeSession -> ConwayTx -> IO SlotNo
windowDeadlineFor sess tx = do
    r <- try (confirmDeadline (nsProvider sess) tx) :: IO (Either SomeException SlotNo)
    case r of
        Right d -> pure d
        Left _ -> do
            tip <- nsTipSlot sess
            pure (tip + fromIntegral (confirmationAttempts * confirmationPollSeconds))

-- | Two minutes expressed in slots of the chain the provider talks to.
twoMinutesInSlots :: Cage.Provider IO -> IO SlotNo
twoMinutesInSlots prov = do
    now <- getCurrentTime
    let nowMs = round (utcTimeToPOSIXSeconds now * 1000) :: Integer
    s0 <- Cage.posixMsToSlot prov nowMs
    s1 <- Cage.posixMsToSlot prov (nowMs + 120_000)
    pure (s1 - s0)

{- | The slot after which a submitted transaction can no longer land:
its validity upper bound plus a two-minute margin. A transaction with
no upper bound never expires, so the historical fixed window
('confirmationAttempts' polls) stays its deadline.
-}
confirmDeadline :: Cage.Provider IO -> ConwayTx -> IO SlotNo
confirmDeadline prov tx =
    case txUpperBoundSlot tx of
        Just bound -> (bound +) <$> twoMinutesInSlots prov
        Nothing -> fixedWindowDeadline prov

-- | The slot the historical fixed confirmation window ends at, from now.
fixedWindowDeadline :: Cage.Provider IO -> IO SlotNo
fixedWindowDeadline prov = do
    now <- getCurrentTime
    let nowMs = round (utcTimeToPOSIXSeconds now * 1000) :: Integer
    Cage.posixMsToSlot prov (nowMs + fromIntegral (confirmationAttempts * confirmationPollSeconds) * 1000)

{- | The validity upper bound a transaction carries, if any. The fold,
update and retract builders pin one (request deadline, phase-2 end);
registration, request and boot transactions leave it open.
-}
txUpperBoundSlot :: ConwayTx -> Maybe SlotNo
txUpperBoundSlot tx =
    let vldt = tx ^. bodyTxL . vldtTxBodyL
     in case invalidHereafter vldt of
            SJust bound -> Just bound
            SNothing -> Nothing

-- | Die once the chain's tip passes the deadline; run the retry otherwise.
whenExpired :: (Show a, Ord a) => String -> a -> a -> IO () -> IO ()
whenExpired txid tip deadline retry
    | tip >= deadline =
        die
            ( "transaction "
                <> txid
                <> " was accepted by the node but has not appeared in a block: \
                   \its confirmation window (the transaction's validity upper \
                   \bound plus a two-minute polling margin) closed at slot "
                <> show deadline
            )
    | otherwise = retry

{- | Retry a chain observation until it yields, then return it; name
what never appeared when it does not.

Every "read back what the last transaction created" in a runner is one
of these. On the factory devnet the first read succeeds, because a
block lands about every second; on a public test network the same read
is a race against a twenty-second block, and a one-shot query turns a
healthy run into a spurious failure. The observation itself is the
confirmation — there is no separate notion of "confirmed" here beyond
the node reporting the output.
-}
awaitChain :: String -> IO (Maybe a) -> IO a
awaitChain what observe = go confirmationAttempts
  where
    go 0 =
        die
            ( what
                <> " (still not observable after "
                <> show (confirmationAttempts * confirmationPollSeconds)
                <> " seconds of polling the node)"
            )
    go n = do
        seen <- observe
        case seen of
            Just a -> pure a
            Nothing -> do
                threadDelay (confirmationPollSeconds * 1_000_000)
                go (n - 1)

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
followChain ::
    NetworkMagic ->
    Word64 ->
    Maybe (Indexer.SlotNo, Indexer.BlockHash) ->
    FilePath ->
    IO a ->
    IO a
followChain magic byronEpochSlots start sock action =
    withInMemoryIndexer $ \idx ->
        withChainSyncFollower nullTracer follow idx $ \follower -> do
            link (fhAsync follower)
            bracket_
                ( writeIORef chainFollower $
                    Just
                        Following
                            { followingIndexer = idx
                            , followingFromOrigin = isNothing start
                            }
                )
                ( do
                    writeIORef chainFollower Nothing
                    writeIORef fundingIndexed False
                )
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
followedProvider :: Cage.Provider IO -> Submitter IO -> IO (Cage.Provider IO)
followedProvider node submit =
    readIORef chainFollower >>= \case
        Just Following{followingIndexer = idx, followingFromOrigin = True} -> do
            indexFunding idx node submit
            writeIORef fundingIndexed True
            pure node{Cage.queryUTxOs = indexedUTxOs idx}
        _ -> pure node

{- | Whether the followed devnet's funding read is done, after which a
node address read is a defect: the indexer answers every one.
-}
fundingIndexed :: IORef Bool
fundingIndexed = unsafePerformIO (newIORef False)
{-# NOINLINE fundingIndexed #-}

-- | Every output at an address as the indexer holds it, in the node's order.
indexedUTxOs :: IndexerHandle -> Addr -> IO [(TxIn, TxOut ConwayEra)]
indexedUTxOs idx addr = do
    rows <- snapshotAt idx (Indexer.Address (serialiseAddr addr))
    Map.toList . Map.fromList <$> traverse decodeRow rows
  where
    decodeRow (Indexer.TxIn tid ix, Indexer.TxOut bytes) = do
        h <- maybe (bad tid "the transaction id is not 32 bytes") pure (hashFromBytes tid)
        out <- either (bad tid . show) pure (decodeFull' (eraProtVerLow @ConwayEra) bytes)
        pure (TxIn (TxId (unsafeMakeSafeHash h)) (TxIx (fromIntegral ix)), out)
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
indexFunding :: IndexerHandle -> Cage.Provider IO -> Submitter IO -> IO ()
indexFunding idx node submit = do
    Wallet{walletAddr = addr, walletSignKey = key} <- walletForMode Devnet
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

{- | The settling wait a runner takes after a submission it does not
carry the transaction for.

Named residual: where a runner holds the submitted transaction,
'awaitTx' observes it and this constant is not used. Where it holds
only a label, there is nothing to observe and the wait is calibrated
per network instead — one second is a devnet block, twenty is a public
test network's. The assertions that follow such a wait go through
'awaitChain', so a wait that is still too short retries rather than
failing the run.
-}
confirmationDelay :: Int
confirmationDelay = case runMode of
    Devnet -> 5_000_000
    External _ -> 30_000_000

-- | Seconds between confirmation polls.
confirmationPollSeconds :: Int
confirmationPollSeconds = 2

{- | How many polls before a submitted transaction is declared lost.
Five minutes covers a public test network's block time with room for a
slow epoch boundary; the devnet returns on the first or second poll.
-}
confirmationAttempts :: Int
confirmationAttempts = 150

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
awaitConnection ::
    (Show a) =>
    NetworkMagic ->
    FilePath ->
    Async a ->
    Cage.Provider IO ->
    IO ()
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

-- | How many @GetUTxOByAddress@ this process has sent to a node.
nodeAddressReads :: IO Int
nodeAddressReads = readIORef addressReads

addressReads :: IORef Int
addressReads = unsafePerformIO (newIORef 0)
{-# NOINLINE addressReads #-}

-- ---------------------------------------------------------
-- Funding
-- ---------------------------------------------------------

{- | What the funding wallet must hold before the first transaction is
built. A floor, not a guarantee: it catches the empty and the
nearly-empty wallet at the start of a run rather than inside a balance
exception halfway through one.
-}
data FundingFloor = FundingFloor
    { floorTotal :: Integer
    -- ^ Total lovelace the address must hold
    , floorCollateral :: Integer
    -- ^ Lovelace in one ada-only UTxO, to serve as collateral
    }
    deriving (Eq, Show)

-- | 100 ada held, with 5 ada of it in an ada-only output.
defaultFundingFloor :: FundingFloor
defaultFundingFloor =
    FundingFloor
        { floorTotal = 100_000_000
        , floorCollateral = 5_000_000
        }

{- | Refuse to start when the funding wallet cannot pay, naming the
address, what is required, what is there, and the faucet step.
-}
checkFunding :: Cage.Provider IO -> Addr -> FundingFloor -> IO ()
checkFunding prov addr fl = do
    utxos <- Cage.queryUTxOs prov addr
    let values = map (\(_, out) -> out ^. valueTxOutL) utxos
        total = sum [c | MaryValue (Coin c) _ <- values]
        adaOnly = [c | MaryValue (Coin c) (MultiAsset m) <- values, Map.null m]
        bestCollateral = if null adaOnly then 0 else maximum adaOnly
    if total >= floorTotal fl && bestCollateral >= floorCollateral fl
        then pure ()
        else
            die . unlines $
                [ "the funding wallet cannot pay for this run."
                , "  address            : " <> bech32Address addr
                , "  lovelace held      : "
                    <> ada total
                    <> " across "
                    <> show (length utxos)
                    <> " UTxO(s)"
                , "  lovelace required  : " <> ada (floorTotal fl)
                , "  ada-only UTxO held : "
                    <> ada bestCollateral
                    <> " (the collateral input)"
                , "  collateral required: " <> ada (floorCollateral fl)
                , "  Fund this address, then rerun. On preprod the faucet is"
                , "    https://docs.cardano.org/cardano-testnets/tools/faucet"
                , "  It pays a single output; send one self-payment \
                  \afterwards so the"
                , "  wallet also holds an ada-only output to spend as \
                  \collateral."
                ]

-- | Lovelace as @N lovelace (X.YYYYYY ada)@.
ada :: Integer -> String
ada l =
    show l
        <> " lovelace ("
        <> show (l `div` 1_000_000)
        <> "."
        <> pad (show (l `mod` 1_000_000))
        <> " ada)"
  where
    pad s = replicate (6 - length s) '0' <> s

{- | Bech32 rendering of an address, the form a faucet and an explorer
accept (CIP-5: @addr_test@ on a test network, @addr@ on mainnet).
Shelley addresses exceed bech32's 90-character limit, so the lenient
encoder is the correct one here.
-}
bech32Address :: Addr -> String
bech32Address a =
    T.unpack (Bech32.encodeLenient hrp (Bech32.dataPartFromBytes bytes))
  where
    bytes = serialiseAddr a
    hrp = case a of
        Addr Mainnet _ _ -> unsafeHrp "addr"
        Addr Testnet _ _ -> unsafeHrp "addr_test"
        AddrBootstrap _ -> unsafeHrp "addr"
    unsafeHrp t = case Bech32.humanReadablePartFromText t of
        Right h -> h
        Left err -> error ("bech32Address: bad prefix: " <> show err)

-- | Fail with a named diagnostic, never a bare exception.
die :: String -> IO a
die = throwIO . ErrorCall
