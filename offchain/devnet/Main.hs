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
-}
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, unless)
import Data.List (isPrefixOf, sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Lens.Micro ((&), (.~), (^.))
import System.Directory (getTemporaryDirectory)
import System.Environment (getArgs)
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
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Singular.Registry.Ledger (Coin (..))
import Singular.Registry.Node
    ( ExternalNode (..)
    , NodeMode (..)
    , NodeSession (..)
    , Wallet (..)
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
    funding <- fundingFrom <$> getArgs
    gDir <- genesisDir
    withCardanoNode gDir $ \sock _startMs -> do
        mapM_ (fund sock) funding
        putStrLn sock
        forever (threadDelay 3_600_000_000)

{- | Read the funding flags: every @--fund-skey@ given (it may repeat, one
wallet each), all paid the same @--fund-outputs@ of @--fund-lovelace@.
None when any of the three is absent.
-}
fundingFrom :: [String] -> [Funding]
fundingFrom args = fromMaybe [] $ do
    outputs <- flag "--fund-outputs" >>= readMaybe
    lovelace <- flag "--fund-lovelace" >>= readMaybe
    pure [Funding key outputs lovelace | key <- every "--fund-skey" args]
  where
    every name = \case
        (a : v : rest) | a == name -> v : every name rest
        (a : rest)
            | (name <> "=") `isPrefixOf` a ->
                drop (length name + 1) a : every name rest
            | otherwise -> every name rest
        [] -> []
    flag name = go args
      where
        go (a : rest)
            | a == name = case rest of
                (v : _) -> Just v
                [] -> Nothing
            | (name <> "=") `isPrefixOf` a = Just (drop (length name + 1) a)
            | otherwise = go rest
        go [] = Nothing

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
