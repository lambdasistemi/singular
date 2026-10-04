{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

-- | Signed journal bodies bound by byte hash and derived transaction id.
module Singular.CLI.ReceiptBody (boundBody, txIdHexOf) where

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Char (isSpace)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Singular.CLI.Receipt (JournalEntry (..))
import Singular.CLI.Registry (hexT)
import Singular.Registry.Ledger (ConwayEra)

{- | A journalled transaction's saved body, bound to its @prepared@ line
by byte hash and derived id, or why it is not.
-}
boundBody
    :: [JournalEntry]
    -> Text
    -> IO (Maybe JournalEntry, Either Text ConwayTx)
boundBody entries txid = case prepared of
    Just p
        | Just path <- journalBody p
        , Just wantHash <- journalBodyHash p -> do
            stored <- try (BS.readFile path)
            pure . (prepared,) $ case stored of
                Left (_ :: IOException) -> Left "the saved body is missing"
                Right hexBytes -> case B16.decode (BC.filter (not . isSpace) hexBytes) of
                    Left _ -> Left "the saved body is not hex"
                    Right raw
                        | hexT (hashToBytes (hashWith @Blake2b_256 id raw)) /= wantHash ->
                            Left "the saved body's hash differs from its prepared line"
                        | otherwise ->
                            case decodeFullAnnotator
                                (eraProtVerHigh @ConwayEra)
                                "transaction"
                                decCBOR
                                (BL.fromStrict raw) of
                                Left _ -> Left "the saved body does not decode"
                                Right (tx :: ConwayTx)
                                    | txIdHexOf tx /= txid ->
                                        Left "the saved body is another transaction"
                                    | otherwise -> Right tx
    _ -> pure (prepared, Left "no prepared line names a saved body")
  where
    prepared =
        listToMaybe
            [ p
            | p <- entries
            , journalTxId p == txid
            , journalEvent p == "prepared"
            ]

txIdHexOf :: ConwayTx -> Text
txIdHexOf tx = let TxId h = txIdTx tx in hexT (hashToBytes (extractHash h))
