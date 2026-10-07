{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

{- |
Module      : Singular.Registry.E2E.NodeSpec
Description : Shipping HTTP startup, explicit wallets and independent private probes
License     : Apache-2.0

The provider receives HTTP settings and a caller-loaded wallet. A separate
private LSQ connection checks parameters and complete outputs. The original
socket/atomic-view statements remain uncovered with their original wording;
separate raw-session cases retain funding, signing, exact-output confirmation
and ReleasedSession without asserting a snapshot. These are private devnet
requirements, not public-chain acceptance.
-}
module Singular.Registry.E2E.NodeSpec (spec, walletSpec) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (Network (Testnet), TxIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.State (UTxO (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Network.NodeToClient.Version
    ( NodeToClientVersion (NodeToClientV_23)
    )
import Cardano.Node.Client.E2E.Setup
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , genesisSignKey
    , mkSignKey
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.LocalStateQuery
    ( queryAcquiredLSQ
    , withAcquiredLSQ
    )
import Cardano.Node.Client.N2C.Types (LSQChannel)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (ErrorCall (..), finally, throwIO, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text.Encoding (decodeUtf8)
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Consensus.Cardano.Block
    ( pattern QueryIfCurrentConway
    )
import Ouroboros.Consensus.Cardano.Node ()
import Ouroboros.Consensus.Ledger.Query
    ( Query (BlockQuery, GetChainPoint)
    )
import Ouroboros.Consensus.Protocol.Praos.Header ()
import Ouroboros.Consensus.Shelley.Ledger.NetworkProtocolVersion ()
import Ouroboros.Consensus.Shelley.Ledger.Query
    ( pattern GetUTxOByAddress
    )
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Protocol.Handshake.Type
    ( HandshakeProtocolError (HandshakeError)
    , RefuseReason (Refused)
    )
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.E2E.Fixture
    ( keepPrivateValue
    , withDevnetSource
    , withRecordedWrites
    )
import Singular.Registry.Evidence (NoWitness, SessionBinding (..))
import Singular.Registry.LedgerProvider
    ( Outputs
    , ReadFailure (..)
    , Session (..)
    , SubmitResult (..)
    )
import Singular.Registry.Private.Facade (Facade (..))
import Singular.Registry.Private.RawFacts
    ( RawFacts (..)
    , withRawFacts
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Signing (SignedTx, signTx, signedTx)
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , loadWallet
    )
import System.Directory (getTemporaryDirectory, removeFile)
import System.FilePath ((</>))
import System.IO (hClose, hPutStr, openTempFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Random.Stateful (globalStdGen, uniformByteStringM)
import System.Timeout (timeout)
import Test.Hspec

type Context =
    (ProviderSettings, FilePath, Wallet, Capabilities NoWitness IO)

spec :: Spec
spec = aroundAll withSource $ do
    describe "Original node and atomic-view requirements (unsupported)" $ do
        unsupported
            "opens a session over a supplied socket, magic and key file, and queries live protocol parameters"
        unsupported
            "confirms a submission without asking the node for an address's UTxO set"
        unsupported
            "refuses a magic the node does not run, naming the magic and the socket"
        unsupported
            "refuses a magic the node does not run for key-free reads, naming the magic and the socket"
        unsupported
            "names the network, era, slot and block hash it was acquired at"
        unsupported
            "keeps a transaction confirmed after acquisition out of that view, while a fresh acquisition sees it"
        unsupported "refuses a view read after its scope as ViewOutOfScope"
    describe "Shipping HTTP capabilities on a private development ledger" $ do
        it
            "queries full live parameters and wallet outputs against a separate private connection"
            $ \(settings, socket, _, _) -> withSkeyFile genesisSignKey $ \key -> do
                wallet <- loadWallet (providerMagic settings) key
                withPrivateConnection socket $ \oracle ->
                    withRecordedWrites settings wallet $ \caps ->
                        Services.withLatest (capReads caps) $ \session -> do
                            parameters <- Services.parameters session
                            expectedParameters <- withRawFacts oracle factParameters
                            keepPrivateValue
                                "e2e-independent-parameters"
                                ( object
                                    [ "privateSource" .= ("separate LSQ connection" :: String)
                                    , "bytes"
                                        .= decodeUtf8
                                            (B16.encode (serialize' (eraProtVerHigh @ConwayEra) expectedParameters))
                                    ]
                                )
                            shouldBe parameters expectedParameters
                            shouldSatisfy (parameters ^. ppMaxTxSizeL) (> 0)
                            actual <- Services.outputsAt session (walletAddr wallet)
                            expected <- privateOutputs oracle (walletAddr wallet)
                            shouldBe actual expected
                            shouldSatisfy actual (not . null)
                            shouldBe (sessionBinding session) Unbound
        it
            "funds and spends the address derived from a fresh caller key file, distinct from genesis"
            $ \(settings, socket, genesisWallet, caps) -> withFreshWallet $ \wallet -> do
                shouldSatisfy (walletAddr wallet) (/= walletAddr genesisWallet)
                held <- Services.withLatest (capReads caps) $ \session ->
                    Services.outputsAt session (walletAddr genesisWallet)
                let transaction = fundingPayment genesisWallet held (walletAddr wallet)
                submitAndConfirm caps transaction
                withPrivateConnection socket $ \oracle ->
                    withRecordedWrites settings wallet $ \joinerCaps ->
                        Services.withLatest (capReads joinerCaps) $ \session -> do
                            actual <- Services.outputsAt session (walletAddr wallet)
                            expected <- privateOutputs oracle (walletAddr wallet)
                            shouldBe actual expected
                            shouldSatisfy actual (not . null)
                            let spend = selfPayment wallet actual
                            submitAndConfirm joinerCaps spend
                            spent <- Services.outputsAt session (walletAddr wallet)
                            confirmed <- privateOutputs oracle (walletAddr wallet)
                            shouldBe spent confirmed
                            shouldSatisfy
                                (map fst spent)
                                (elem (TxIn (txIdTx (signedTx spend)) (TxIx 0)))
        it
            "refuses an unfunded wallet before any transaction, naming the address, the amounts and the faucet"
            $ \(settings, _, _, _) -> withSkeyFile unfundedKey $ \key -> do
                wallet <- loadWallet (providerMagic settings) key
                ran <- newIORef False
                result <-
                    try @ErrorCall
                        (withRecordedWrites settings wallet (\_ -> writeIORef ran True))
                shouldReturn (readIORef ran) False
                case result of
                    Right () -> fail "a run started with an unfunded caller wallet"
                    Left (ErrorCall message) -> do
                        shouldSatisfy message (isInfixOf (bech32Address (walletAddr wallet)))
                        shouldSatisfy message (isInfixOf "faucet")
                        shouldSatisfy message (isInfixOf "100000000 lovelace")
        it
            "confirms an exact transaction output without an address query, then compares full readback to the independent ledger"
            $ \(_, socket, wallet, caps) -> do
                held <- Services.withLatest (capReads caps) $ \session ->
                    Services.outputsAt session (walletAddr wallet)
                let transaction = selfPayment wallet held
                    body = signedTx transaction
                    created = TxIn (txIdTx body) (TxIx 0)
                submitOnly caps transaction
                traceBefore <- capTrace caps
                shouldSatisfy (addressReads traceBefore) (> 0)
                capConfirm caps body
                traceAfter <- capTrace caps
                shouldBe (addressReads traceAfter) (addressReads traceBefore)
                shouldSatisfy (length traceAfter) (> length traceBefore)
                withPrivateConnection socket $ \oracle ->
                    Services.withLatest (capReads caps) $ \session -> do
                        actual <- Services.outputsAt session (walletAddr wallet)
                        expected <- privateOutputs oracle (walletAddr wallet)
                        shouldBe actual expected
                        shouldSatisfy (map fst actual) (elem created)
        it
            "an Unbound session observes a confirmed change without inheriting an atomic-view promise"
            $ \(_, socket, wallet, caps) -> withPrivateConnection socket $ \oracle ->
                Services.withLatest (capReads caps) $ \session -> do
                    shouldBe (sessionBinding session) Unbound
                    original <- Services.outputsAt session (walletAddr wallet)
                    let transaction = selfPayment wallet original
                        created = TxIn (txIdTx (signedTx transaction)) (TxIx 0)
                    submitAndConfirm caps transaction
                    during <- Services.outputsAt session (walletAddr wallet)
                    expected <- privateOutputs oracle (walletAddr wallet)
                    shouldBe during expected
                    shouldSatisfy (map fst during) (elem created)
                    shouldSatisfy during (/= original)
        it
            "a released raw session refuses readback as ReleasedSession with its actual identity"
            $ \(_, _, _, caps) -> do
                escaped <- Services.withLatest (capReads caps) pure
                result <- try @ReadFailure (Services.outputsAt escaped zeroAddr)
                shouldBe result (Left (ReleasedSession (sessionId escaped)))
        it
            "a separate private connection refuses wrong magic after the same socket answered on magic42"
            $ \(_, socket, _, _) -> do
                withPrivateConnection socket $ \oracle -> do
                    parameters <- withRawFacts oracle factParameters
                    shouldSatisfy (parameters ^. ppMaxTxSizeL) (> 0)
                query <- newLSQChannel 16
                unusedSubmit <- newLTxSChannel 16
                let expectedRefusal =
                        "version data mismatch: NodeToClientVersionData "
                            <> "{networkMagic = NetworkMagic {unNetworkMagic = 42}, "
                            <> "query = False} /= NodeToClientVersionData "
                            <> "{networkMagic = NetworkMagic {unNetworkMagic = 999}, "
                            <> "query = False}"
                result <-
                    try @(HandshakeProtocolError NodeToClientVersion) $
                        timeout 10_000_000 $
                            runNodeClient (NetworkMagic 999) socket query unusedSubmit
                                >>= either throwIO pure
                case result of
                    Left (HandshakeError (Refused NodeToClientV_23 reason))
                        | reason == expectedRefusal -> pure ()
                    Left failure -> throwIO failure
                    Right (Just ()) -> fail "wrong private magic accepted a connection"
                    Right Nothing -> fail "wrong private magic did not end within ten seconds"
  where
    unsupported text = it text $ \_ ->
        pendingWith
            "The public node/socket and atomic-view API is retired. Generic HTTP, funding, confirmation and released-session requirements are stated separately."

withSource :: (Context -> IO ()) -> IO ()
withSource action = withDevnetSource $ \_ facade wallet caps ->
    action (facadeSettings facade, facadeSocket facade, wallet, caps)

-- | Test-only second connection; the shipping capability never receives it.
withPrivateConnection :: FilePath -> (LSQChannel -> IO a) -> IO a
withPrivateConnection socket action = do
    oracle <- newLSQChannel 16
    unusedSubmit <- newLTxSChannel 16
    withAsync
        ( runNodeClient (NetworkMagic 42) socket oracle unusedSubmit
            >>= either throwIO (const (fail "E2E private oracle connection closed"))
        )
        $ \connection -> do
            link connection
            action oracle

privateOutputs :: LSQChannel -> Addr -> IO Outputs
privateOutputs oracle address = withAcquiredLSQ oracle $ \handle -> do
    point <- queryAcquiredLSQ handle GetChainPoint
    result <-
        queryAcquiredLSQ
            handle
            ( BlockQuery
                (QueryIfCurrentConway (GetUTxOByAddress (Set.singleton address)))
            )
    UTxO outputs <-
        either
            (const (fail "E2E independent oracle is not in Conway"))
            pure
            result
    keepPrivateValue
        "e2e-independent-outputs"
        ( object
            [ "privateSource" .= ("separate LSQ connection" :: String)
            , "point" .= show point
            , "address" .= show address
            , "outputs"
                .= [ object
                        [ "reference" .= show reference
                        , "bytes"
                            .= decodeUtf8
                                (B16.encode (serialize' (eraProtVerHigh @ConwayEra) output))
                        ]
                   | (reference, output) <- Map.toAscList outputs
                   ]
            ]
        )
    pure (Map.toAscList outputs)

addressReads :: [Value] -> Int
addressReads =
    length
        . filter
            ( \case
                Object fields -> KeyMap.lookup "call" fields == Just (String "address_utxos")
                _ -> False
            )

submitOnly :: Capabilities NoWitness IO -> SignedTx -> IO ()
submitOnly caps transaction =
    capSubmit caps transaction >>= \case
        SubmitAccepted identity ->
            unless
                (identity == txIdTx (signedTx transaction))
                (fail "E2E accepted identity differs from signed transaction")
        SubmitRefused reason -> fail ("E2E transaction refused: " <> show reason)
        SubmitFailed reason -> fail ("E2E submission failed: " <> show reason)
        SubmitWrongNetwork configured wanted ->
            fail ("E2E submission network differs: " <> show (configured, wanted))

submitAndConfirm :: Capabilities NoWitness IO -> SignedTx -> IO ()
submitAndConfirm caps transaction = do
    submitOnly caps transaction
    capConfirm caps (signedTx transaction)

withFreshWallet :: (Wallet -> IO a) -> IO a
withFreshWallet action = withSystemTempDirectory "e2e-joiner" $ \directory -> do
    let key = directory </> "caller.skey"
    BS.writeFile key . B16.encode =<< uniformByteStringM 32 globalStdGen
    loadWallet 42 key >>= action

-- | Retain the original full-input self-payment and its one-ada fee.
selfPayment :: Wallet -> Outputs -> SignedTx
selfPayment wallet held = signTx (walletSignKey wallet) (mkBasicTx body)
  where
    fee = Coin 1_000_000
    value = foldMap ((^. valueTxOutL) . snd) held
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList (map fst held)
            & outputsTxBodyL
                .~ StrictSeq.singleton
                    (mkBasicTxOut (walletAddr wallet) (value <-> inject fee))
            & feeTxBodyL .~ fee

fundingPayment :: Wallet -> Outputs -> Addr -> SignedTx
fundingPayment wallet held destination =
    signTx (walletSignKey wallet) (mkBasicTx body)
  where
    fee = Coin 1_000_000
    amount = Coin 1_000_000_000
    value = foldMap ((^. valueTxOutL) . snd) held
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList (map fst held)
            & outputsTxBodyL
                .~ StrictSeq.fromList
                    [ mkBasicTxOut destination (inject amount)
                    , mkBasicTxOut
                        (walletAddr wallet)
                        (value <-> inject amount <-> inject fee)
                    ]
            & feeTxBodyL .~ fee

-- | Wallet decoding checks use local files and never connect to a node.
walletSpec :: Spec
walletSpec = describe "Loading a wallet from its signing key" $ do
    it
        "derives the address from the key file alone, envelope or \
        \bare hex"
        $ withSkeyFile genesisSignKey
        $ \skey -> do
            fromEnvelope <- loadWallet 42 skey
            tmp <- getTemporaryDirectory
            (barePath, h) <- openTempFile tmp "joiner-bare.skey"
            hPutStr
                h
                (BC.unpack (B16.encode (rawSerialiseSignKeyDSIGN genesisSignKey)))
            hClose h
            fromHex <- loadWallet 42 barePath
            removeFile barePath
            bech32Address (walletAddr fromHex)
                `shouldBe` bech32Address (walletAddr fromEnvelope)

{- | A signing key file in the @cardano-cli@ text-envelope form — the
file a joiner produces with @cardano-cli address key-gen@.
-}
withSkeyFile
    :: SignKeyDSIGN Ed25519DSIGN -> (FilePath -> IO a) -> IO a
withSkeyFile sk k = do
    tmp <- getTemporaryDirectory
    (path, h) <- openTempFile tmp "joiner.skey"
    hPutStr h envelope
    hClose h
    finally (k path) (removeFile path)
  where
    envelope =
        "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\
        \\"description\":\"Payment Signing Key\",\"cborHex\":\"5820"
            <> BC.unpack (B16.encode (rawSerialiseSignKeyDSIGN sk))
            <> "\"}"

-- | A key with no history on any chain, and therefore no funds.
unfundedKey :: SignKeyDSIGN Ed25519DSIGN
unfundedKey = mkSignKey "e2e-unfunded-joiner-key-00000001"

-- | An address no key on the devnet controls.
zeroAddr :: Addr
zeroAddr = addrFromKeyHashBytes Testnet (BS.replicate 28 0)
