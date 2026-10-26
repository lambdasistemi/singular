{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.CLI.Promise
Description : What the first output of a transaction of the state line must hold once it is on the chain
License     : Apache-2.0

A transaction is journalled with the after-state its first output promises, as
a line of text, so that a later command can decide from the chain alone that an
unresolved transaction was included. The commands of the state line promise one
of three things: a reference script they published, a token they made, or
ADA they paid to an address. The same function reads the promise back when the
command that sent the transaction checks its own result and when a later
command reconciles the journal.
-}
module Singular.CLI.Promise
    ( Promise (..)
    , matchesOutput
    , paidTo
    , renderPromise
    , parsePromise
    , promiseKept
    , describePromise
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Core (eraProtVerLow, hashScript)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )

import Singular.Registry.Ledger (Addr, ConwayEra, TxOut)
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Wallet (bech32Address)

-- | What a first output must hold.
data Promise
    = -- | A reference script with this hash, published by the transaction
      CarriesScript ScriptHash
    | -- | Exactly this token, once, and nothing else but ADA
      HoldsToken PolicyID AssetName
    | -- | ADA alone at the address with this bech32 spelling
      PaidTo Text
    | -- | The complete public output, encoded at the supported ledger version.
      MatchesOutput ByteString
    deriving stock (Eq, Show)

-- | Bind recovery to the full output: address, value, datum and reference script.
matchesOutput :: TxOut ConwayEra -> Promise
matchesOutput = MatchesOutput . serialize' (eraProtVerLow @ConwayEra)

-- | ADA alone at this address.
paidTo :: Addr -> Promise
paidTo = PaidTo . T.pack . bech32Address

-- | The line of text the journal keeps for a promise.
renderPromise :: Promise -> Text
renderPromise = \case
    CarriesScript hash -> "reference:" <> hexOf (scriptHashBytes hash)
    HoldsToken (PolicyID policy) (AssetName name) ->
        "holds:"
            <> hexOf (scriptHashBytes policy)
            <> "."
            <> hexOf (SBS.fromShort name)
    PaidTo address -> "paid:" <> address
    MatchesOutput bytes -> "output:" <> hexOf bytes

{- | The promise a journalled line is: the part before its colon, and the rest
with its colon, as the reconciliation reads a line.
-}
parsePromise :: Text -> Text -> Maybe Promise
parsePromise tag colonRest = case tag of
    "reference" -> CarriesScript . ScriptHash <$> (decoded 28 body >>= hashFromBytes)
    "holds" -> do
        let (policyHex, dotName) = T.breakOn "." body
        policy <- decoded 28 policyHex >>= hashFromBytes
        name <- decoded 32 (T.drop 1 dotName)
        pure
            ( HoldsToken
                (PolicyID (ScriptHash policy))
                (AssetName (SBS.toShort name))
            )
    "paid" -> Just (PaidTo body)
    "output" -> case B16.decode (BC.pack (T.unpack body)) of
        Right bytes | not (BC.null bytes) -> Just (MatchesOutput bytes)
        _ -> Nothing
    _ -> Nothing
  where
    body = T.drop 1 colonRest
    decoded size text = case B16.decode (BC.pack (T.unpack text)) of
        Right bytes | BC.length bytes == size -> Just bytes
        _ -> Nothing

-- | Whether an output keeps a promise.
promiseKept :: Promise -> TxOut ConwayEra -> Bool
promiseKept promise out = case promise of
    CarriesScript hash -> case out ^. referenceScriptTxOutL of
        SJust carried -> hashScript carried == hash
        SNothing -> False
    HoldsToken policy name ->
        let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
        in  assets == Map.singleton policy (Map.singleton name 1)
    MatchesOutput bytes -> matchesOutput out == MatchesOutput bytes
    PaidTo address ->
        T.pack (bech32Address (out ^. addrTxOutL)) == address
            && adaOnlyOut out

-- | What a kept promise says, for a journal line.
describePromise :: Promise -> Text
describePromise = \case
    CarriesScript _ -> "the first output is live carrying its reference script"
    HoldsToken{} -> "the first output is live holding the token alone"
    MatchesOutput _ ->
        "the first output matches the complete output prepared by the command"
    PaidTo _ ->
        "the first output is live, ada only, at the address it was paid to"

hexOf :: ByteString -> Text
hexOf = T.pack . BC.unpack . B16.encode
