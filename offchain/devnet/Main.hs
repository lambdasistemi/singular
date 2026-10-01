{-# LANGUAGE LambdaCase #-}

{- |
Module      : Main
Description : A devnet that outlives the process that needed it
License     : Apache-2.0

Every runner spawns its own devnet and takes it down again, which is
right when the registry it boots dies with the run. A deployment does
not: it is booted once and attached to by later runs, so proving that
attachment works needs one chain that several processes can reach.

This spawns that chain, prints the socket path on standard output, and
waits until it is killed. Everything else — deploying, attaching,
counting what changed — happens in other processes against the socket
it printed, through the same external-node path a joiner's own node is
reached by.

@--fund-skey FILE --fund-outputs N --fund-lovelace L@ (#299): before the
socket is printed, pay @N@ outputs of @L@ lovelace from the genesis key
to the address of the payment key in @FILE@, and wait until they are on
chain. A caller wallet generated for a test then holds several ordinary
outputs, as a real wallet does, so a seed it chooses is one of them
rather than the genesis output itself. The key file is read, never
printed; only its public address is reported, on standard error.

@devnet probe --node-socket PATH [--network-magic N] [--tx-in TXID#IX]...@
(#325) spawns nothing: it asks the node at @PATH@, from one acquired
ledger state, for its chain tip and which of the named outputs are
unspent, and prints one JSON object,
@{"tip":{"slot":N,"hash":HEX},"live":[...],"spent":[...]}@. A control
that rolls a development node back reads the node's own answer through
it, never the answer of the command under test.
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (bracket)
import Control.Monad (forever, unless)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.ByteString.Short qualified as SBS
import Data.List (isPrefixOf, partition, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text qualified as T
import Lens.Micro ((&), (.~), (^.))
import System.Directory (getTemporaryDirectory)
import System.Environment (getArgs)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO
    ( BufferMode (..)
    , hPutStrLn
    , hSetBuffering
    , stderr
    , stdout
    )
import Text.Read (readMaybe)

import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL, mkBasicTxOut)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( addKeyWitness
    , genesisAddr
    , genesisDir
    , genesisSignKey
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Node.Client.N2C.Connection
    ( newLSQChannel
    , newLTxSChannel
    , runNodeClient
    )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.Provider qualified as N2C
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import Ouroboros.Network.Magic (NetworkMagic (..))

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeSession (..)
    , Wallet (..)
    , adaptProvider
    , awaitConnection
    , awaitTx
    , bech32Address
    , loadWallet
    , withNodeMode
    )
import Singular.Registry.Provider qualified as Cage

-- | The optional funding a caller asked for.
data Funding = Funding
    { fundKey :: FilePath
    , fundOutputs :: Int
    , fundLovelace :: Integer
    }

main :: IO ()
main = do
    hSetBuffering stdout LineBuffering
    args <- getArgs
    case args of
        ("probe" : rest) -> probe rest
        _ -> spawn args

-- | Spawn the chain, fund what was asked, print the socket, wait.
spawn :: [String] -> IO ()
spawn args = do
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        mapM_ (fund sock) (fundingFrom args)
        putStrLn sock
        forever (threadDelay 3_600_000_000)

{- | Read the funding flags: every @--fund-skey@ given (it may repeat, one
wallet each), all paid the same @--fund-outputs@ of @--fund-lovelace@.
None when any of the three is absent.
-}
fundingFrom :: [String] -> [Funding]
fundingFrom args = fromMaybe [] $ do
    outputs <- flag "--fund-outputs" args >>= readMaybe
    lovelace <- flag "--fund-lovelace" args >>= readMaybe
    pure [Funding key outputs lovelace | key <- every "--fund-skey" args]

-- | Every value a repeatable flag was given.
every :: String -> [String] -> [String]
every name = \case
    (a : v : rest) | a == name -> v : every name rest
    (a : rest)
        | (name <> "=") `isPrefixOf` a ->
            drop (length name + 1) a : every name rest
        | otherwise -> every name rest
    [] -> []

-- | The first value a flag was given.
flag :: String -> [String] -> Maybe String
flag name = \case
    (a : rest)
        | a == name -> case rest of
            (v : _) -> Just v
            [] -> Nothing
        | (name <> "=") `isPrefixOf` a -> Just (drop (length name + 1) a)
        | otherwise -> flag name rest
    [] -> Nothing

{- | Ask an existing node, from one acquired ledger state, for its tip
and which of the named outputs are unspent, and print both as one JSON
object.
-}
probe :: [String] -> IO ()
probe args = do
    sock <-
        maybe (die "devnet probe: --node-socket is required") pure $
            flag "--node-socket" args
    magicWord <-
        maybe (die "devnet probe: --network-magic is not a number") pure $
            readMaybe (fromMaybe "42" (flag "--network-magic" args))
    txIns <-
        either (die . ("devnet probe: " <>)) pure $
            traverse (parseOutRef . T.pack) (every "--tx-in" args)
    let magic = NetworkMagic magicWord
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    bracket (async (runNodeClient magic sock lsqCh ltxsCh)) cancel $ \thread -> do
        let n2c = mkN2CProvider lsqCh
        awaitConnection magic sock thread (adaptProvider magic n2c)
        (snapshot, unspent) <- N2C.withAcquired n2c $ \h ->
            (,)
                <$> N2C.queryLedgerSnapshotH h
                <*> N2C.queryUTxOByTxInH h (Set.fromList txIns)
        let (live, spent) = partition (`Map.member` unspent) txIns
            tip = case N2C.ledgerChainPoint snapshot of
                Chain.GenesisPoint -> Aeson.Null
                Chain.BlockPoint (SlotNo slot) (OneEraHash h) ->
                    object
                        [ "slot" .= slot
                        , "hash" .= BC.unpack (B16.encode (SBS.fromShort h))
                        ]
        BL8.putStrLn $
            Aeson.encode $
                object
                    [ "tip" .= tip
                    , "live" .= map renderOutRef live
                    , "spent" .= map renderOutRef spent
                    ]

{- | Pay the requested outputs from the genesis key and wait for them,
through the same external-node session a joiner's node is reached by.
-}
fund :: FilePath -> Funding -> IO ()
fund sock f = do
    tmp <- getTemporaryDirectory
    let genesisKey = tmp </> "devnet-genesis.skey"
    BS.writeFile
        genesisKey
        (B16.encode (rawSerialiseSignKeyDSIGN genesisSignKey))
    target <- walletAddr <$> loadWallet 42 (fundKey f)
    withNodeMode (External (ExternalNode sock 42 genesisKey)) $ \sess -> do
        utxos <-
            Cage.withView (nsProvider sess) (`Cage.viewUTxOsAt` genesisAddr)
        (txIn, out) <- case sortOn (Down . (^. coinTxOutL) . snd) utxos of
            (u : _) -> pure u
            [] -> fail "devnet: the genesis address holds nothing to fund from"
        let fee = 1_000_000
            Coin held = out ^. coinTxOutL
            paid = fromIntegral (fundOutputs f) * fundLovelace f
            change = held - paid - fee
            pay n = mkBasicTxOut n (MaryValue (Coin (fundLovelace f)) mempty)
        unless (change > 1_000_000) $
            fail "devnet: the genesis output cannot pay the requested funding"
        let body =
                mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton txIn
                    & outputsTxBodyL
                        .~ StrictSeq.fromList
                            ( replicate (fundOutputs f) (pay target)
                                <> [mkBasicTxOut genesisAddr (MaryValue (Coin change) mempty)]
                            )
                    & feeTxBodyL .~ Coin fee
            signed = addKeyWitness genesisSignKey (mkBasicTx body)
        result <- submitTx (nsSubmitter sess) signed
        case result of
            Submitted _ -> pure ()
            Rejected reason -> fail ("devnet: funding rejected: " <> show reason)
        awaitTx signed
        hPutStrLn stderr $
            "devnet: funded "
                <> bech32Address target
                <> " with "
                <> show (fundOutputs f)
                <> " outputs of "
                <> show (fundLovelace f)
                <> " lovelace"
