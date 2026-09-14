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

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll)
import Control.Exception (ErrorCall (..), bracket, throwIO)
import Data.Aeson (eitherDecodeStrict, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32)
import System.Environment (getArgs, getEnvironment)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)

import Codec.Binary.Bech32 qualified as Bech32
import Lens.Micro ((^.))
import Ouroboros.Network.Magic (NetworkMagic (..))

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network (..), SlotNo, TxIx (..))
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Hashes (ScriptHash, unsafeMakeSafeHash)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))

import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
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
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter (Submitter)
import Cardano.Tx.Ledger (ConwayTx)
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
    orElse a b = maybe b Just a
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
    , nsTxInLive :: TxIn -> IO Bool
    -- ^ Query an output by its exact transaction input reference
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
path use this; the rest use 'withNode'.
-}
withNodeSocket :: (FilePath -> IO a) -> IO a
withNodeSocket k = case runMode of
    Devnet -> do
        gDir <- genesisDir
        withCardanoNode gDir (\sock _startMs -> k sock)
    External e -> k (extSocket e)

-- | 'withNodeMode' at this process's 'runMode'.
withNode :: (NodeSession -> IO a) -> IO a
withNode = withNodeMode runMode

{- | Open a session in a named mode: connect, negotiate the magic,
query live protocol parameters, refuse to start when the funding wallet
cannot pay, and run the body. The devnet is spawned and torn down
around it; an external node is left alone.
-}
withNodeMode :: NodeMode -> (NodeSession -> IO a) -> IO a
withNodeMode = withNodeModeAndFunding (Just defaultFundingFloor)

-- | The lifecycle runners calculate their complete funding plans from the
-- live parameters before submitting. A fixed 100 ADA floor here would reject
-- wallets that can afford those plans, and would block read-only estimates.
withNodeForPlannedFunding :: (NodeSession -> IO a) -> IO a
withNodeForPlannedFunding = withNodeModeAndFunding Nothing runMode

withNodeModeAndFunding :: Maybe FundingFloor -> NodeMode -> (NodeSession -> IO a) -> IO a
withNodeModeAndFunding fundingFloor mode k = case mode of
    Devnet -> do
        gDir <- genesisDir
        withCardanoNode gDir (\sock _startMs -> connect devnetMagic sock)
    External e -> connect (NetworkMagic (extMagic e)) (extSocket e)
  where
    connect magic sock = do
        wallet <- walletForMode mode
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $
            \nodeThread -> do
                threadDelay 3_000_000
                verifyConnection magic sock nodeThread
                let prov = adaptProvider (mkN2CProvider lsqCh)
                pp <- Cage.queryProtocolParams prov
                case fundingFloor of
                    Just floorRequired -> checkFunding prov (walletAddr wallet) floorRequired
                    Nothing -> pure ()
                announce mode magic sock (walletAddr wallet)
                let sess =
                        NodeSession
                            { nsProvider = prov
                            , nsSubmitter = mkN2CSubmitter ltxsCh
                            , nsMagic = magic
                            , nsNetwork = walletNetwork wallet
                            , nsPParams = pp
                            , nsTxInLive = \i -> Map.member i <$> N2C.queryUTxOByTxIn (mkN2CProvider lsqCh) (Set.singleton i)
                            , nsScriptRegistered = \h -> do
                                let credential = ScriptHashObj h
                                Map.member credential <$> N2C.queryStakeRewards (mkN2CProvider lsqCh) (Set.singleton credential)
                            , nsTipSlot = N2C.ledgerTipSlot <$> N2C.queryLedgerSnapshot (mkN2CProvider lsqCh)
                            , nsMode = mode
                            }
                bracket
                    (writeIORef openSession (Just sess))
                    (const (writeIORef openSession Nothing))
                    (const (k sess))

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
scriptStakeRegistered h = readIORef openSession >>= maybe (die "scriptStakeRegistered called outside a node session") (\s -> nsScriptRegistered s h)

-- | Read the live tip for a transaction built in the active session.
currentTipSlot :: IO SlotNo
currentTipSlot = readIORef openSession >>= maybe (die "currentTipSlot called outside a node session") nsTipSlot

{- | Wait until a submitted transaction is visible on the chain.

A fixed sleep is a devnet assumption: the factory devnet makes a block
about every second, a public test network about every twenty, so a
five-second wait calibrated on the devnet silently becomes a race on
preprod. This polls for an output the transaction actually created —
the strongest evidence a local state query carries — and names the
transaction when it never appears.
-}
awaitTx :: ConwayTx -> IO ()
awaitTx tx = do
    ms <- readIORef openSession
    sess <- case ms of
        Just s -> pure s
        Nothing ->
            die
                "awaitTx was called outside a node session; a runner must \
                \wait for confirmation inside withNode"
    addr <- case toList (tx ^. bodyTxL . outputsTxBodyL) of
        (out : _) -> pure (out ^. addrTxOutL)
        [] ->
            die
                ( "cannot confirm transaction "
                    <> show txid
                    <> ": it creates no output to observe"
                )
    go (nsProvider sess) addr confirmationAttempts
  where
    txid = txIdTx tx
    go _ _ 0 =
        die
            ( "transaction "
                <> show txid
                <> " was accepted by the node but has not appeared in a \
                   \block after "
                <> show (confirmationAttempts * confirmationPollSeconds)
                <> " seconds"
            )
    go prov addr n = do
        utxos <- Cage.queryUTxOs prov addr
        if any (\(TxIn i _, _) -> i == txid) utxos
            then pure ()
            else do
                threadDelay (confirmationPollSeconds * 1_000_000)
                go prov addr (n - 1)

{- | Confirm a just-submitted transaction by observing output zero.
Call before a dependent transaction spends that output. This supports
journey helpers that retain a transaction id but not the complete body.
-}
awaitTxId :: String -> IO ()
awaitTxId txid = do
    raw <- either (const (die "awaitTxId: transaction id is not hex")) pure (B16.decode (BC.pack txid))
    h <- maybe (die "awaitTxId: transaction id is not 32 bytes") pure (hashFromBytes raw)
    sess <- readIORef openSession >>= maybe (die "awaitTxId called outside a node session") pure
    let wanted = TxIn (TxId (unsafeMakeSafeHash h)) (TxIx 0)
    awaitChain ("transaction " <> txid <> " output 0") $ do
        live <- nsTxInLive sess wanted
        pure (if live then Just () else Nothing)

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

{- | Name the two ways a fresh connection fails: the node is not there,
and the node runs a different network than the magic asserted.
-}
verifyConnection ::
    (Show e) =>
    NetworkMagic ->
    FilePath ->
    Async (Either e ()) ->
    IO ()
verifyConnection (NetworkMagic magic) sock nodeThread = do
    status <- poll nodeThread
    case status of
        Nothing -> pure ()
        Just outcome ->
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

-- | The cage provider over an N2C provider.
adaptProvider :: N2C.Provider IO -> Cage.Provider IO
adaptProvider p =
    Cage.Provider
        { Cage.queryUTxOs = N2C.queryUTxOs p
        , Cage.queryProtocolParams = N2C.queryProtocolParams p
        , Cage.evaluateTx = N2C.evaluateTx p
        , Cage.posixMsToSlot = N2C.posixMsToSlot p
        , Cage.posixMsCeilSlot = N2C.posixMsCeilSlot p
        }

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
