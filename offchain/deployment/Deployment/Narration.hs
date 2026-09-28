{- |
Module      : Deployment.Narration
Description : How @deployment@ reports progress, failure and identities
License     : Apache-2.0

Every line the command prints on standard output is one 'emit': a step
name and what was then observed, prefixed @deployment @. Every refusal is
'failWith', an 'IOError' the entry point reports as
@deployment: FAILED: user error (...)@ with exit status 1. The rendering
helpers spell identities the way the manifest and the narration do:
lowercase hex.
-}
module Deployment.Narration (
    emit,
    failWith,
    hexT,
    tokenText,
    txText,
) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.In (TxId (..))
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.Mary.Value (AssetName (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (TokenId (..))

-- | One narration line: what was done and what was then observed.
emit :: String -> String -> IO ()
emit step detail = putStrLn ("deployment " <> step <> ": " <> detail)

-- | Refuse, naming why.
failWith :: String -> IO a
failWith msg = ioError (userError msg)

-- | Lowercase hex.
hexT :: BS.ByteString -> Text
hexT = T.pack . BC.unpack . B16.encode

-- | A registry token's name, in hex.
tokenText :: TokenId -> Text
tokenText (TokenId (AssetName n)) = hexT (SBS.fromShort n)

-- | A transaction's id, in hex.
txText :: ConwayTx -> Text
txText tx = let TxId h = txIdTx tx in hexT (hashToBytes (extractHash h))
