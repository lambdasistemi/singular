{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Reader
Description : Open datum's refinement of Singular's neutral reader
License     : Apache-2.0

Only an active answer is decoded by the application. The caller owns the
session and trace; refinement has no effects or additional observations.
The classification follows SingularApplicationHeld.refineReaderAnswer.
-}
module Singular.Application.OpenDatum.Reader
    ( ReaderAnswer (..)
    , refineReaderAnswer
    , readKey
    ) where

import Cardano.Crypto.Hash (hashFromBytes, hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Scripts.Data (Datum (..))
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))
import PlutusCore.Data qualified as PLC

import Singular.Application.OpenDatum.Requests.Assemble
    ( inlineDatumOf
    )
import Singular.Application.OpenDatum.Requests.Records
    ( ProtectedControl (..)
    , decodeLiveDatum
    )
import Singular.Reader qualified as R
import Singular.Registry.ContractTable
    ( ApplicationIdentity (..)
    , ContractTable
    , applicationOf
    )
import Singular.Registry.Ledger (ConwayEra, TxIn, TxOut)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.State.Lineage (registryAsset)
import Singular.State.Preimage
    ( activeTokenName
    , approvalName
    , terminationPreimage
    )

-- | The model's answers, with the current live control and payload decoded.
data ReaderAnswer
    = Live (TxIn, TxOut ConwayEra) ProtectedControl PLC.Data
    | PendingTermination (TxIn, TxOut ConwayEra)
    | Terminal R.ReaderState
    | NeverRegistered R.ReaderState
    | Unavailable R.ReaderReadName R.ReaderUnavailable
    | Refused R.ReaderRefusal
    deriving stock (Eq, Show)

-- | Refine only active custody, retaining every other neutral result.
refineReaderAnswer
    :: R.ReaderRequest
    -> Maybe ApplicationIdentity
    -> R.NeutralReaderAnswer
    -> ReaderAnswer
refineReaderAnswer request published = \case
    R.Active pair@(_, output) -> case published of
        Nothing -> Refused (R.UnknownStatePolicy policy)
        Just release
            | termination release output -> PendingTermination pair
            | otherwise -> case inlineDatumOf output >>= decodeLiveDatum of
                Just (control, payload)
                    | controlRegistry control == registry
                    , controlKey control == key
                    , Just (controlActiveAsset control) == active
                    , let MaryValue (Coin amount) _ = output ^. valueTxOutL
                    , controlDeposit control <= amount ->
                        Live pair control payload
                _ -> Refused R.ConflictingEvidence
    R.Terminal state -> Terminal state
    R.NeverRegistered state -> NeverRegistered state
    R.Unavailable readName why -> Unavailable readName why
    R.Refused why -> Refused why
  where
    registry@(RegistryIdentity (StatePolicyId policy) _) = R.readerRegistry request
    key = R.readerKey request
    active =
        fmap
            (\(statePolicy, _) -> (statePolicy, activeTokenName registry key))
            (registryAsset registry)
    termination release output = case ( active
                                      , PolicyID . ScriptHash <$> hashFromBytes (applicationPolicy release)
                                      ) of
        (Just (statePolicy, name), Just appPolicy) ->
            let MaryValue _ actual = output ^. valueTxOutL
                atApplication = case output ^. addrTxOutL of
                    Addr _ (ScriptHashObj (ScriptHash hash)) _ -> hashToBytes hash == applicationScript release
                    _ -> False
                wanted =
                    MultiAsset
                        ( Map.fromListWith
                            (Map.unionWith (+))
                            [ (statePolicy, Map.singleton name 1)
                            ,
                                ( appPolicy
                                , Map.singleton (approvalName (terminationPreimage key registry)) 1
                                )
                            ]
                        )
            in  atApplication && output ^. datumTxOutL == NoDatum && actual == wanted
        _ -> False

-- | Read through the neutral adapter, then interpret its application datum.
readKey
    :: (Monad m)
    => Session w m
    -> ContractTable
    -> R.ReaderRequest
    -> m ReaderAnswer
readKey session table request =
    refineReaderAnswer request (applicationOf table policy)
        <$> R.readNeutralKeyFromSession session table request
  where
    RegistryIdentity (StatePolicyId policy) _ = R.readerRegistry request
