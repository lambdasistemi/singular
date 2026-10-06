{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.ContractNode
Description : #326 — the contract's harnesses over a development node
License     : Apache-2.0

The node adapter and the indexer adapter on a real development node,
each opened exactly as a @singular@ write opens them: a socket path, a
network magic and a funded signing-key file handed to the session
constructor the CLI composes ('withNodeModeOn'), under the backend the
CLI's @--backend@ names. Two legs differ only in who started the node:

* generated — the suite starts a node for each case, and funds a fresh
  key from the genesis key so that the key's outputs are in blocks;
* external — the node, its magic and a funded key are given on the
  command line; the suite starts nothing.

A chain change is a payment from the funded key to a fresh address,
built and observed through a second connection of its own and submitted
from another thread, so nothing the view under test holds is used to
make or to see it.

The generated leg also holds the session's connection guard to account
on a real node: a one-shot query and a submission issued from inside a
view fail by name, and the same calls outside the view answer.
-}
module Singular.Registry.ContractNode
    ( -- * Legs
      Leg (..)
    , nodeHarness
    , phaseLogOnDevnet

      -- * The session's connection guard on a real node
    , guardOnDevnet
    ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, wait, withAsync)
import Control.Exception (bracket, onException, throwIO, try)
import Control.Monad (unless, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import System.Directory
    ( copyFile
    , createDirectoryIfMissing
    , doesFileExist
    , getTemporaryDirectory
    )
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (..), hClose, openFile)
import System.IO.Temp (createTempDirectory, withSystemTempDirectory)
import System.Posix.Files (ownerReadMode, setFileMode)
import System.Process
    ( CreateProcess (..)
    , StdStream (..)
    , createProcess
    , proc
    , terminateProcess
    , waitForProcess
    )
import System.Random.Stateful (globalStdGen, uniformByteStringM)
import System.Timeout (timeout)
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Node.Client.E2E.Setup
    ( genesisDir
    , genesisSignKey
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Tx.Ledger (ConwayTx)
import Ouroboros.Network.Magic (NetworkMagic (..))

import Singular.PhaseLogFixture
    ( logObjects
    , phaseLines
    , queryNames
    , withLogEnv
    , withLogFile
    )
import Singular.Registry.ContractSuite
    ( AdapterHarness (..)
    , Case (..)
    , Chain (..)
    , EvidenceClass (..)
    , unsupportedControl
    )
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeReads (..)
    , NodeSession (..)
    , Wallet (..)
    , loadWallet
    , withNodeReads
    )
import Singular.Registry.Node.Options (Backend (..))
import Singular.Registry.Node.RawView (rawNodeProvider)
import Singular.Registry.Node.Session
    ( NodeCallInView (..)
    , withNodeModeOn
    )
import Singular.Registry.Node.Submit (signTx, signedTx)
import Singular.Registry.Node.View (nodeProvider)
import Singular.Registry.Provider (Provider (..), View (..))
import Singular.Registry.Services qualified as Services
import Singular.Registry.TimeMaterial (loadTimeMaterial)
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    )

-- | Who started the node the harness reaches.
data Leg
    = -- | The suite starts a node for each case.
      Generated
    | -- | A node started outside the suite: socket, magic, funded key file.
      Outside FilePath Word32 FilePath

-- | The node or the indexer adapter over a development node.
nodeHarness :: Leg -> Backend -> AdapterHarness
nodeHarness leg backend =
    AdapterHarness
        { ahAdapter = adapterName <> " (" <> legName <> " devnet)"
        , ahEvidence = DevNet
        , ahNotSupported = Map.fromList (indexRows <> legRows <> originRow)
        , ahChain = \k -> case leg of
            Generated -> withGeneratedNode $ \sock kill ->
                withFundedKey sock $ \skey ->
                    sessionChain sock devnetMagicWord skey (Just kill) k
            Outside sock magic skey -> sessionChain sock magic skey Nothing k
        }
  where
    adapterName = case backend of
        NodeBackend -> "node"
        IndexerBackend -> "indexer"
    legName = case leg of
        Generated -> "generated"
        Outside{} -> "external"
    indexRows = case backend of
        NodeBackend ->
            [ (c, "the node adapter reads the node's own state; it has no index")
            | c <- [IndexLag, IndexFork, IndexRestoring, IndexDisconnected]
            ]
        IndexerBackend ->
            [ ( c
              , "a live follower cannot be held behind, forked, restoring or \
                \disconnected from outside its session; provoked on the \
                \indexer adapter over the in-memory node"
              )
            | c <- [IndexLag, IndexFork, IndexRestoring, IndexDisconnected]
            ]
    legRows = case leg of
        Generated -> []
        Outside{} ->
            [
                ( ConnectionLost
                , "the node was started outside the suite, which does not stop it"
                )
            ]
    originRow = case (leg, backend) of
        (Generated, NodeBackend) -> []
        (Outside{}, _) ->
            [(AtOrigin, "the node was handed over past its origin")]
        (Generated, IndexerBackend) ->
            [
                ( AtOrigin
                , "the indexer session waits a chain out of its origin before \
                  \its first view; the node adapter's origin refusal is the \
                  \one the index rests on"
                )
            ]

    sessionChain sock magic skey kill k = do
        wallet <- loadWallet magic skey
        watched <- freshAddress
        unregistered <- freshScriptHash
        withNodeModeOn backend (External (ExternalNode sock magic skey)) $ \sess ->
            k
                Chain
                    { chProvider = nsProvider sess
                    , chNetwork = magic
                    , chWatched = watched
                    , chUnregistered = unregistered
                    , chChange =
                        payAside sock magic wallet watched (nsSubmitter sess)
                    , chLoseConnection =
                        fromMaybe (unsupportedControl "losing the connection") kill
                    , chAtOrigin = \use -> case (leg, backend) of
                        (Generated, NodeBackend) -> atOrigin use
                        _ -> unsupportedControl "a chain at its origin"
                    , chProvoke = unsupportedControl . show
                    }

-- ---------------------------------------------------------
-- Chain changes
-- ---------------------------------------------------------

{- | Pay two ada from the wallet to an address, from another thread, and
return once a second connection of its own sees the output there.
-}
payAside
    :: FilePath -> Word32 -> Wallet -> Addr -> Submitter IO -> IO ()
payAside sock magic wallet to submitter =
    withAsync go wait
  where
    go = withNodeReads magic sock $ \reads' -> do
        let side = nrProvider reads'
        held <- withView side (`viewUTxOsAt` to)
        tx <- payment side wallet to 2_000_000
        submitTx submitter tx >>= \case
            Submitted _ -> pure ()
            Rejected reason -> fail ("contract: payment rejected: " <> show reason)
        landed <-
            timeout 120_000_000 $
                let poll = do
                        now <- withView side (`viewUTxOsAt` to)
                        unless (length now > length held) $
                            threadDelay 200_000 >> poll
                in  poll
        maybe
            (fail "contract: the payment did not land within two minutes")
            pure
            landed

{- | A payment of @lovelace@ from the wallet's largest output to an address,
change back to the wallet, signed by the wallet's key.
-}
payment :: Provider IO -> Wallet -> Addr -> Integer -> IO ConwayTx
payment side wallet to lovelace = do
    utxos <- withView side (`viewUTxOsAt` walletAddr wallet)
    (txIn, out) <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
        (u : _) -> pure u
        [] -> fail "contract: the funded key holds nothing"
    let fee = 1_000_000
        Coin held = out ^. coinTxOutL
        change = held - lovelace - fee
        body =
            mkBasicTxBody
                & inputsTxBodyL .~ Set.singleton txIn
                & outputsTxBodyL
                    .~ StrictSeq.fromList
                        [ mkBasicTxOut to (MaryValue (Coin lovelace) mempty)
                        , mkBasicTxOut (walletAddr wallet) (MaryValue (Coin change) mempty)
                        ]
                & feeTxBodyL .~ Coin fee
    unless (change > 1_000_000) $
        fail "contract: the funded key's largest output cannot pay"
    pure (signedTx (signTx (walletSignKey wallet) (mkBasicTx body)))

freshAddress :: IO Addr
freshAddress =
    addrFromKeyHashBytes Testnet <$> uniformByteStringM 28 globalStdGen

freshScriptHash :: IO ScriptHash
freshScriptHash =
    computeScriptHash . SBS.toShort <$> uniformByteStringM 16 globalStdGen

-- ---------------------------------------------------------
-- A generated node
-- ---------------------------------------------------------

devnetMagicWord :: Word32
devnetMagicWord = 42

{- | Start a development node whose chain begins a few seconds from now,
hand over its socket and an action that stops it, and stop it after.
-}
withGeneratedNode :: (FilePath -> IO () -> IO a) -> IO a
withGeneratedNode k = withDevnetNode True 5 $ \sock stop -> do
    waitForSocket sock
    k sock stop

{- | Fund a fresh payment key from the genesis key with outputs in blocks,
through the session constructor, and hand over the key file.
-}
withFundedKey :: FilePath -> (FilePath -> IO a) -> IO a
withFundedKey sock k = withSystemTempDirectory "contract-key" $ \dir -> do
    let genesisKey = dir </> "genesis.skey"
        fundedKey = dir </> "funded.skey"
    BS.writeFile
        genesisKey
        (B16.encode (rawSerialiseSignKeyDSIGN genesisSignKey))
    BS.writeFile fundedKey . B16.encode
        =<< uniformByteStringM 32 globalStdGen
    funded <- loadWallet devnetMagicWord fundedKey
    genesisWallet <- loadWallet devnetMagicWord genesisKey
    let genesisNode = External (ExternalNode sock devnetMagicWord genesisKey)
    withNodeModeOn NodeBackend genesisNode $ \sess -> do
        tx <-
            payment
                (nsProvider sess)
                genesisWallet
                (walletAddr funded)
                1_000_000_000
        let side = nsProvider sess
        submitTx (nsSubmitter sess) tx >>= \case
            Submitted _ -> pure ()
            Rejected reason -> fail ("contract: funding rejected: " <> show reason)
        landed <-
            timeout 120_000_000 $
                let poll = do
                        held <- withView side (`viewUTxOsAt` walletAddr funded)
                        when (null held) $ threadDelay 200_000 >> poll
                in  poll
        maybe
            (fail "contract: funding did not land within two minutes")
            pure
            landed
    k fundedKey

{- | The node adapter over a node whose chain has not begun: it runs
without the block producer's keys, so no block is ever made and its
chain stays at the origin.
-}
atOrigin :: (Provider IO -> IO a) -> IO a
atOrigin use = withDevnetNode False 1 $ \sock _ -> do
    waitForSocket sock
    let magic = NetworkMagic devnetMagicWord
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $ \_ ->
        do
            material <- loadTimeMaterial devnetMagicWord (takeDirectory sock)
            use (nodeProvider magic material (rawNodeProvider lsqCh))

{- | A development node from the pinned genesis, its start @offset@ seconds
ahead, in a directory of its own, producing blocks or not; the action that stops it is handed
over and run again, harmlessly, at the end.
-}
withDevnetNode
    :: Bool -> Integer -> (FilePath -> IO () -> IO a) -> IO a
withDevnetNode producing offset k = do
    src <- genesisDir
    tmp <- getTemporaryDirectory
    dir <- createTempDirectory tmp "contract-devnet"
    start <- addUTCTime (fromInteger offset) <$> getCurrentTime
    mapM_
        (\f -> copyFile (src </> f) (dir </> f))
        [ "alonzo-genesis.json"
        , "conway-genesis.json"
        , "dijkstra-genesis.json"
        , "node-config.json"
        , "topology.json"
        ]
    shelley <- BS.readFile (src </> "shelley-genesis.json")
    BS.writeFile (dir </> "shelley-genesis.json") $
        replace
            "PLACEHOLDER"
            (BC.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" start))
            shelley
    byron <- BS.readFile (src </> "byron-genesis.json")
    BS.writeFile (dir </> "byron-genesis.json") $
        replace
            "\"startTime\": 0"
            ( "\"startTime\": "
                <> BC.pack (show (floor (utcTimeToPOSIXSeconds start) :: Integer))
            )
            byron
    createDirectoryIfMissing True (dir </> "delegate-keys")
    createDirectoryIfMissing True (dir </> "db")
    mapM_
        ( \f -> do
            copyFile
                (src </> "delegate-keys" </> f)
                (dir </> "delegate-keys" </> f)
            setFileMode (dir </> "delegate-keys" </> f) ownerReadMode
        )
        ["delegate1.kes.skey", "delegate1.vrf.skey", "delegate1.opcert"]
    logH <- openFile (dir </> "node.log") AppendMode
    let sock = dir </> "node.sock"
        args =
            [ "run"
            , "--config"
            , dir </> "node-config.json"
            , "--topology"
            , dir </> "topology.json"
            , "--database-path"
            , dir </> "db"
            , "--socket-path"
            , sock
            ]
                <> if producing then producer else []
        producer =
            [ "--shelley-kes-key"
            , dir </> "delegate-keys" </> "delegate1.kes.skey"
            , "--shelley-vrf-key"
            , dir </> "delegate-keys" </> "delegate1.vrf.skey"
            , "--shelley-operational-certificate"
            , dir </> "delegate-keys" </> "delegate1.opcert"
            ]
    bracket
        ( do
            (_, _, _, ph) <-
                createProcess
                    (proc "cardano-node" args)
                        { std_out = UseHandle logH
                        , std_err = UseHandle logH
                        }
            pure ph
        )
        (\ph -> terminateProcess ph >> waitForProcess ph >> hClose logH)
        ( \ph ->
            k sock (terminateProcess ph >> void (waitForProcess ph))
                `onException` (BS.readFile (dir </> "node.log") >>= BC.putStrLn . lastLines)
        )
  where
    lastLines = BC.unlines . reverse . take 40 . reverse . BC.lines
    replace needle new hay =
        let (front, back) = BS.breakSubstring needle hay
        in  if BS.null back
                then hay
                else front <> new <> BS.drop (BS.length needle) back

waitForSocket :: FilePath -> IO ()
waitForSocket sock = do
    found <- timeout 60_000_000 poll
    maybe
        (throwIO (userError ("contract: no node socket at " <> sock)))
        pure
        found
  where
    poll = do
        exists <- doesFileExist sock
        unless exists (threadDelay 100_000 >> poll)

-- ---------------------------------------------------------
-- The connection guard on a real node
-- ---------------------------------------------------------

{- | A session on a generated node: a one-shot query and a submission
issued from inside a view fail as 'NodeCallInView' within ten seconds —
an unguarded call waits forever for the view to end — and the same calls
outside the view answer.
-}
guardOnDevnet :: Spec
guardOnDevnet =
    describe
        "no node call inside a view by another route, on a generated devnet node (#326)"
        $ it
            "a one-shot query and a submission inside a view fail as \
            \NodeCallInView; outside the view the query answers and the \
            \node accepts the submission"
        $ withGeneratedNode
        $ \sock _ -> withFundedKey sock $ \skey -> do
            wallet <- loadWallet devnetMagicWord skey
            to <- freshAddress
            let node = External (ExternalNode sock devnetMagicWord skey)
            withNodeModeOn NodeBackend node $ \sess -> do
                tx <- payment (nsProvider sess) wallet to 2_000_000
                (tip, sent) <- withView (nsProvider sess) $ \_ -> do
                    tip <- timeout 10_000_000 (try (nsTipSlot sess))
                    sent <- timeout 10_000_000 (try (submitTx (nsSubmitter sess) tx))
                    pure (tip, sent)
                fmap (either Left (const (Right ()))) tip
                    `shouldBe` Just (Left (NodeCallInView "queryLedgerSnapshot"))
                fmap (either Left (const (Right ()))) sent
                    `shouldBe` Just (Left (NodeCallInView "submitTx"))
                _ <- nsTipSlot sess
                submitTx (nsSubmitter sess) tx >>= \case
                    Submitted _ -> pure ()
                    Rejected reason ->
                        expectationFailure ("rejected outside the view: " <> show reason)

{- | The phase log, through the sessions a @singular@ command opens (#363):
the write session, the key-free reader and the indexer backend, each on a
generated development node. What is logged is what a command's provider and
tip reads go through, so a constructor that stopped installing the logged
provider fails here.
-}
phaseLogOnDevnet :: Spec
phaseLogOnDevnet =
    describe
        "the phase log of the sessions a command opens, on a generated devnet node (#363)"
        $ do
            it
                "a write session logs how long it took to open, each view it \
                \acquires and each read and tip read through it"
                $ withGeneratedNode
                $ \sock _ -> withFundedKey sock $ \skey -> do
                    wallet <- loadWallet devnetMagicWord skey
                    let node = External (ExternalNode sock devnetMagicWord skey)
                    withLogFile $ \path -> do
                        answer <- withNodeModeOn NodeBackend node $ \sess -> do
                            utxos <-
                                withView (nsProvider sess) $ \v ->
                                    viewUTxOsAt v (walletAddr wallet)
                            _ <- nsTipSlot sess
                            pure utxos
                        objects <- logObjects path
                        length (phaseLines "session-open" objects) `shouldBe` 1
                        length (filter (== "tipSlot") (queryNames objects)) `shouldBe` 1
                        -- the funding check's read and ours, each its own line
                        length (filter (== "utxosAt") (queryNames objects))
                            `shouldSatisfy` (>= 2)
                        length answer `shouldSatisfy` (> 0)
                        queryNames objects `shouldSatisfy` elem "protocolParams"
                        queryNames objects `shouldSatisfy` elem "ledgerSnapshot"
                        -- every acquisition reads its snapshot and parameters once; the
                        -- one snapshot beyond them is the follower's start point
                        length (filter (== "ledgerSnapshot") (queryNames objects))
                            `shouldBe` 1 + length (filter (== "protocolParams") (queryNames objects))
                        length (phaseLines "view" objects)
                            `shouldSatisfy` (>= length (phaseLines "view-release" objects))
                    -- unset: the same session leaves no file behind
                    withLogEnv Nothing $
                        withNodeModeOn NodeBackend node $ \sess ->
                            void (nsTipSlot sess)
            it "a key-free reader, as preview opens one, logs its views and reads" $
                withGeneratedNode $ \sock _ -> withFundedKey sock $ \_ ->
                    withLogFile $ \path -> do
                        _ <-
                            withNodeReads devnetMagicWord sock $ \r ->
                                withView (nrProvider r) $ \v -> do
                                    start <- Services.slotStart v 0
                                    Services.floorSlot v start
                        objects <- logObjects path
                        length (phaseLines "session-open" objects) `shouldBe` 1
                        length (filter (== "posixMsToSlot") (queryNames objects))
                            `shouldBe` 1
                        length (phaseLines "view" objects) `shouldSatisfy` (>= 1)
            it "the indexer backend logs the index's admission and its reads" $
                withGeneratedNode $ \sock _ -> withFundedKey sock $ \skey -> do
                    wallet <- loadWallet devnetMagicWord skey
                    let node = External (ExternalNode sock devnetMagicWord skey)
                    withLogFile $ \path -> do
                        _ <- withNodeModeOn IndexerBackend node $ \sess ->
                            withView (nsProvider sess) $ \v ->
                                viewUTxOsAt v (walletAddr wallet)
                        objects <- logObjects path
                        length (filter (== "indexAdmit") (queryNames objects))
                            `shouldSatisfy` (>= 1)
                        length (filter (== "utxosAt") (queryNames objects))
                            `shouldSatisfy` (>= 1)

                        -- the index starts from the origin: no start-point read
                        length (filter (== "ledgerSnapshot") (queryNames objects))
                            `shouldBe` length (filter (== "protocolParams") (queryNames objects))
