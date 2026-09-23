{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.NodeSpec
Description : External-node mode against a node this test spawns
License     : Apache-2.0

External-node mode reaches a node by socket path and network magic and
funds the run from a signing key file. This spec spawns a devnet and
then reaches it /through that same external path/ — the socket and the
magic are handed to 'withNodeMode' as configuration, exactly as a
joiner's preprod node is. Nothing here calls the devnet path, so a
divergence between the two would fail it.

Four claims, each with the control that shows the check can fail:

* a session opens over a supplied socket and magic and queries live
  protocol parameters (control: the wrong magic is refused by name);
* the run is funded from the key file the joiner named, not from a
  genesis constant (the file carries the key, the address is derived);
* an unfunded key is refused before any transaction, by a diagnostic
  that names the address and the faucet (control: the funded key in the
  first claim reaches the body).
* a submission is confirmed without the node being asked for an
  address's UTxO set (control: the confirmed output is then read back
  from the node).
-}
module Singular.Registry.E2E.NodeSpec (spec) where

import Control.Exception (ErrorCall (..), try)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, hPutStr, openTempFile)

import Lens.Micro ((&), (.~), (^.))
import Test.Hspec (
    Spec,
    aroundAll,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, inputsTxBodyL, mkBasicTxBody, outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
    addKeyWitness,
    genesisDir,
    genesisSignKey,
    mkSignKey,
    rawSerialiseSignKeyDSIGN,
 )
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node (
    ExternalNode (..),
    NodeMode (..),
    NodeSession (..),
    Wallet (..),
    awaitTx,
    bech32Address,
    loadWallet,
    nodeAddressReads,
    walletForMode,
    withNodeMode,
 )
import Singular.Registry.Provider qualified as Cage

{- | A signing key file in the @cardano-cli@ text-envelope form — the
file a joiner produces with @cardano-cli address key-gen@.
-}
withSkeyFile :: SignKeyDSIGN Ed25519DSIGN -> (FilePath -> IO a) -> IO a
withSkeyFile sk k = do
    tmp <- getTemporaryDirectory
    (path, h) <- openTempFile tmp "joiner.skey"
    hPutStr h envelope
    hClose h
    r <- k path
    removeFile path
    pure r
  where
    envelope =
        "{\"type\":\"PaymentSigningKeyShelley_ed25519\",\
        \\"description\":\"Payment Signing Key\",\"cborHex\":\"5820"
            <> BC.unpack (B16.encode (rawSerialiseSignKeyDSIGN sk))
            <> "\"}"

-- | Spawn a devnet and hand its socket over as if it were a joiner's.
withDevnetSocket :: (FilePath -> IO ()) -> IO ()
withDevnetSocket k = do
    gDir <- genesisDir
    withCardanoNode gDir (\sock _startMs -> k sock)

-- | Every output the wallet holds, paid back to it in one output.
selfPayment :: Wallet -> [(TxIn, TxOut ConwayEra)] -> ConwayTx
selfPayment wallet held =
    addKeyWitness (walletSignKey wallet) (mkBasicTx body)
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

-- | A key with no history on any chain, and therefore no funds.
unfundedKey :: SignKeyDSIGN Ed25519DSIGN
unfundedKey = mkSignKey "e2e-unfunded-joiner-key-00000001"

spec :: Spec
spec = aroundAll withDevnetSocket $
    describe "external-node mode" $ do
        it
            "opens a session over a supplied socket, magic and key file, \
            \and queries live protocol parameters"
            $ \sock -> withSkeyFile genesisSignKey $ \skey -> do
                let mode = External (ExternalNode sock 42 skey)
                seen <- newIORef Nothing
                withNodeMode mode $ \sess -> do
                    wallet <- walletForMode mode
                    utxos <-
                        Cage.queryUTxOs (nsProvider sess) (walletAddr wallet)
                    writeIORef
                        seen
                        ( Just
                            ( nsPParams sess ^. ppMaxTxSizeL
                            , length utxos
                            )
                        )
                observed <- readIORef seen
                -- The body ran, the parameters came from the node (a
                -- positive maximum transaction size is a value only a
                -- real ledger state carries), and the address derived
                -- from the key file holds the funds the run spends.
                observed `shouldSatisfy` \case
                    Just (maxTxSize, utxoCount) ->
                        maxTxSize > 0 && utxoCount > 0
                    Nothing -> False

        it
            "confirms a submission without asking the node for an \
            \address's UTxO set"
            $ \sock -> withSkeyFile genesisSignKey $ \skey -> do
                let mode = External (ExternalNode sock 42 skey)
                withNodeMode mode $ \sess -> do
                    wallet <- walletForMode mode
                    held <-
                        Cage.queryUTxOs (nsProvider sess) (walletAddr wallet)
                    let tx = selfPayment wallet held
                    submitTx (nsSubmitter sess) tx >>= \case
                        Submitted _ -> pure ()
                        Rejected why ->
                            fail ("the self-payment was refused: " <> BC.unpack why)
                    before <- nodeAddressReads
                    awaitTx tx
                    after <- nodeAddressReads
                    after `shouldBe` before
                    landed <-
                        Cage.queryUTxOs (nsProvider sess) (walletAddr wallet)
                    map fst landed
                        `shouldSatisfy` elem (TxIn (txIdTx tx) (TxIx 0))

        it
            "refuses a magic the node does not run, naming the magic and \
            \the socket"
            $ \sock -> withSkeyFile genesisSignKey $ \skey -> do
                let mode = External (ExternalNode sock 999 skey)
                r <- try (withNodeMode mode (\_ -> pure ()))
                case r of
                    Right () ->
                        fail
                            "a node-to-client handshake for magic 999 \
                            \succeeded against a devnet running magic 42"
                    Left (ErrorCall msg) -> do
                        msg `shouldSatisfy` isInfixOf "network magic 999"
                        msg `shouldSatisfy` isInfixOf sock

        it
            "refuses an unfunded wallet before any transaction, naming \
            \the address, the amounts and the faucet"
            $ \sock -> withSkeyFile unfundedKey $ \skey -> do
                wallet <- loadWallet 42 skey
                let mode = External (ExternalNode sock 42 skey)
                r <- try (withNodeMode mode (\_ -> pure ()))
                case r of
                    Right () ->
                        fail
                            "a run started with an unfunded joiner wallet"
                    Left (ErrorCall msg) -> do
                        msg
                            `shouldSatisfy` isInfixOf
                                (bech32Address (walletAddr wallet))
                        msg `shouldSatisfy` isInfixOf "faucet"
                        msg `shouldSatisfy` isInfixOf "100000000 lovelace"

        it
            "derives the address from the key file alone, envelope or \
            \bare hex"
            $ \_sock -> withSkeyFile genesisSignKey $ \skey -> do
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
