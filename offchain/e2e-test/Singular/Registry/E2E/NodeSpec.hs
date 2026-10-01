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

And one view is one acquired ledger state of the node (#323): a view
names the network, era, slot and block hash it was acquired at; a
transaction confirmed while a view is held stays out of that view
(control: a fresh acquisition sees it); a view read after its scope is
refused by name rather than answered.
-}
module Singular.Registry.E2E.NodeSpec (spec, walletSpec) where

import Control.Exception (ErrorCall (..), try)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import System.Directory (getTemporaryDirectory, removeFile)
import System.IO (hClose, hPutStr, openTempFile)

import Lens.Micro ((&), (.~), (^.))
import Test.Hspec
    ( Spec
    , aroundAll
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.PParams (ppMaxTxSizeL)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, mkBasicTxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , SlotNo (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , addKeyWitness
    , genesisDir
    , genesisSignKey
    , mkSignKey
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeReads (..)
    , NodeSession (..)
    , Wallet (..)
    , awaitTx
    , bech32Address
    , loadWallet
    , nodeAddressReads
    , walletForMode
    , withNodeMode
    , withNodeReads
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal (addrFromKeyHashBytes)

spec :: Spec
spec = aroundAll withDevnetSocket $ do
    describe "Connecting through a supplied node socket" $ do
        it
            "opens a session over a supplied socket, magic and key file, \
            \and queries live protocol parameters"
            $ \sock -> withSkeyFile genesisSignKey $ \skey -> do
                let mode = External (ExternalNode sock 42 skey)
                seen <- newIORef Nothing
                withNodeMode mode $ \sess -> do
                    wallet <- walletForMode mode
                    (maxTxSize, utxos) <-
                        Cage.withView (nsProvider sess) $ \v ->
                            (,) (Cage.viewProtocolParams v ^. ppMaxTxSizeL)
                                <$> Cage.viewUTxOsAt v (walletAddr wallet)
                    writeIORef seen (Just (maxTxSize, length utxos))
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
                        Cage.withView (nsProvider sess) (`Cage.viewUTxOsAt` walletAddr wallet)
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
                        Cage.withView (nsProvider sess) (`Cage.viewUTxOsAt` walletAddr wallet)
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

    -- #323: one view is one acquired ledger state of the real node.
    describe "Reading the node through one acquired view" $ do
        it
            "names the network, era, slot and block hash it was \
            \acquired at"
            $ \sock -> withSkeyFile genesisSignKey $ \skey -> do
                let mode = External (ExternalNode sock 42 skey)
                withNodeMode mode $ \sess -> do
                    point <-
                        Cage.withView (nsProvider sess) (pure . Cage.viewPoint)
                    tip <- nsTipSlot sess
                    Cage.cpNetwork point `shouldBe` 42
                    Cage.cpEra point `shouldBe` "Conway"
                    BS.length (Cage.cpBlockHash point) `shouldBe` 32
                    Cage.cpSlot point `shouldSatisfy` (> SlotNo 0)
                    Cage.cpSlot point `shouldSatisfy` (<= tip)

        it
            "keeps a transaction confirmed after acquisition out of that \
            \view, while a fresh acquisition sees it"
            $ \sock -> withSkeyFile genesisSignKey $ \skey -> do
                let mode = External (ExternalNode sock 42 skey)
                withNodeMode mode $ \sess -> withNodeReads 42 sock $ \nr -> do
                    wallet <- walletForMode mode
                    let addr = walletAddr wallet
                        reads' = nrProvider nr
                    (before, during, fresh, tx) <-
                        Cage.withView reads' $ \held -> do
                            before <- Cage.viewUTxOsAt held addr
                            let tx = selfPayment wallet before
                            submitTx (nsSubmitter sess) tx >>= \case
                                Submitted _ -> pure ()
                                Rejected why ->
                                    fail
                                        ( "the self-payment was refused: "
                                            <> BC.unpack why
                                        )
                            -- Confirmed through the session's own
                            -- connection while the view stays held.
                            awaitTx tx
                            fresh <-
                                Cage.withView
                                    (nsProvider sess)
                                    (`Cage.viewUTxOsAt` addr)
                            during <- Cage.viewUTxOsAt held addr
                            pure (before, during, fresh, tx)
                    let created = TxIn (txIdTx tx) (TxIx 0)
                    -- Reached control: the change is on the chain.
                    map fst fresh `shouldSatisfy` elem created
                    -- The held view is the state it acquired.
                    map fst during `shouldBe` map fst before
                    map fst during `shouldSatisfy` notElem created
                    after <- Cage.withView reads' (`Cage.viewUTxOsAt` addr)
                    map fst after `shouldSatisfy` elem created

        it
            "refuses a view read after its scope as ViewOutOfScope"
            $ \sock -> withNodeReads 42 sock $ \nr -> do
                escaped <- Cage.withView (nrProvider nr) pure
                r <- try (Cage.viewUTxOsAt escaped zeroAddr)
                case r of
                    Left Cage.ViewOutOfScope -> pure ()
                    Left other -> fail ("another failure: " <> show other)
                    Right utxos ->
                        fail
                            ( "a view read after its scope answered "
                                <> show (length utxos)
                                <> " outputs"
                            )

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

-- | An address no key on the devnet controls.
zeroAddr :: Addr
zeroAddr = addrFromKeyHashBytes Testnet (BS.replicate 28 0)
