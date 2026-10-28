{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Reader
Description : Application-neutral conclusions from a registry reader's observations
License     : Apache-2.0

The classification and its order implement
@SingularApplicationHeld.readNeutralKey@. Active custody does not interpret
the application's datum. Terminal and never-registered conclusions require
a recognised state and a leaf read against that state's root.

Observations are explicit inputs. Their producer owns completeness and the
authentication of the trie root; constructing an observation asserts neither.
No network, file, clock or mutable resource is accessed by classification.
The trie library's proofs are assumed sound.
-}
module Singular.Reader
    ( ReaderRequest (..)
    , ReaderRead (..)
    , ReaderReadName (..)
    , ReaderUnavailable (..)
    , ReaderRefusal (..)
    , ReaderObservation (..)
    , ReaderState (..)
    , NeutralReaderAnswer (..)
    , readNeutralKey
    , recognizeReaderState
    ) where

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Scripts.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Lens.Micro ((^.))

import Singular.Registry.ContractTable (ApplicationIdentity (..))
import Singular.Registry.Ledger (ConwayEra, Root (..), TxIn, TxOut)
import Singular.Registry.LedgerProvider (Network)
import Singular.Registry.TrieState qualified as Trie
import Singular.State.Lineage (registryAsset)
import Singular.State.Preimage (activeTokenName)
import Singular.State.Records (decodeStateDatum)

-- | The address's network and registry identity, and the caller's key.
data ReaderRequest = ReaderRequest
    { requestedNetwork :: Network
    , readerRegistry :: Trie.RegistryIdentity
    , readerKey :: ByteString
    }
    deriving stock (Eq, Show)

-- | A complete empty answer is distinct from an unavailable observation.
data ReaderRead a
    = ReadMissing
    | ReadFailed Text
    | ReadIncomplete Text
    | Complete a
    deriving stock (Eq, Show)

-- | The observation an unavailable answer names.
data ReaderReadName
    = NetworkRead
    | ActiveOutputsRead
    | StateRead
    | TrieRead
    deriving stock (Eq, Show)

-- | The model's unavailable reasons, preserving the provider's explanation.
data ReaderUnavailable
    = Missing
    | Failed Text
    | Incomplete Text
    | StateNotFound
    | StateNotRecognized
    | TrieRootMismatch
    deriving stock (Eq, Show)

-- | Refused evidence never becomes a conclusion about absence.
data ReaderRefusal
    = WrongNetwork Network Network
    | UnknownStatePolicy ByteString
    | ForeignStatePolicy ByteString ByteString
    | TokenOutsideApplicationCustody TxIn Addr
    | ConflictingEvidence
    deriving stock (Eq, Show)

{- | The model's observations in ledger representations. The trie observation
contains its authenticated root and the result of looking up this request's
key. It is supplied only after the selected state's history has been replayed.
-}
data ReaderObservation = ReaderObservation
    { observedNetwork :: ReaderRead Network
    , observedRelease :: Maybe ApplicationIdentity
    , observedActiveOutputs :: ReaderRead [(TxIn, TxOut ConwayEra)]
    , observedState :: ReaderRead (Maybe (TxIn, TxOut ConwayEra))
    , observedTrie :: ReaderRead (Root, Trie.Leaf)
    }
    deriving stock (Eq, Show)

-- | The selected state output and the root the key was read against.
data ReaderState = ReaderState
    { readerStateOutput :: (TxIn, TxOut ConwayEra)
    , readerStateRoot :: Root
    }
    deriving stock (Eq, Show)

-- | Singular's conclusions, before the application interprets active custody.
data NeutralReaderAnswer
    = Active (TxIn, TxOut ConwayEra)
    | Terminal ReaderState
    | NeverRegistered ReaderState
    | Unavailable ReaderReadName ReaderUnavailable
    | Refused ReaderRefusal
    deriving stock (Eq, Show)

{- | Classify in the frozen model's order: network, release, active token,
then state and trie only when the complete asset answer is empty. The active
name is derived from the registry identity and key, never accepted as input.
-}
readNeutralKey
    :: ReaderRequest -> ReaderObservation -> NeutralReaderAnswer
readNeutralKey request observed =
    const (Unavailable NetworkRead Missing) $
        withRead NetworkRead (observedNetwork observed) $ \served ->
            if served /= requestedNetwork request
                then Refused (WrongNetwork (requestedNetwork request) served)
                else case observedRelease observed of
                    Nothing -> Refused (UnknownStatePolicy policyBytes)
                    Just release
                        | policyBytes /= appliedStatePolicy release ->
                            Refused (ForeignStatePolicy policyBytes (appliedStatePolicy release))
                        | otherwise ->
                            withRead ActiveOutputsRead (observedActiveOutputs observed) $ \case
                                [pair@(reference, output)]
                                    | activeQuantity output /= 1 -> Refused ConflictingEvidence
                                    | credential output /= Just (applicationScript release)
                                        || credential output == Just policyBytes ->
                                        Refused
                                            (TokenOutsideApplicationCustody reference (output ^. addrTxOutL))
                                    | otherwise -> Active pair
                                [] -> readState release
                                _ -> Refused ConflictingEvidence
  where
    registry@(Trie.RegistryIdentity (Trie.StatePolicyId policyBytes) _) = readerRegistry request
    activeQuantity output = case registryAsset registry of
        Nothing -> 0
        Just (policy, _) ->
            let MaryValue _ (MultiAsset assets) = output ^. valueTxOutL
            in  Map.findWithDefault
                    0
                    (activeTokenName registry (readerKey request))
                    (Map.findWithDefault Map.empty policy assets)
    readState release = withRead StateRead (observedState observed) $ \case
        Nothing -> Unavailable StateRead StateNotFound
        Just pair -> case recognizeReaderState release registry pair of
            Nothing -> Unavailable StateRead StateNotRecognized
            Just root -> withRead TrieRead (observedTrie observed) $ \(actualRoot, leaf) ->
                if root /= actualRoot
                    then Unavailable TrieRead TrieRootMismatch
                    else
                        let state = ReaderState pair root
                        in  case leaf of
                                Trie.Unknown -> NeverRegistered state
                                Trie.Terminal -> Terminal state
                                _ -> Refused ConflictingEvidence

{- | Recognise the state's exact script credential, policy, single unit asset
and inline root datum, as @recognizeReaderState@ in the Lean model does.
-}
recognizeReaderState
    :: ApplicationIdentity
    -> Trie.RegistryIdentity
    -> (TxIn, TxOut ConwayEra)
    -> Maybe Root
recognizeReaderState release registry@(Trie.RegistryIdentity (Trie.StatePolicyId policy) _) (_, output)
    | policy /= appliedStatePolicy release
        || credential output /= Just policy =
        Nothing
    | otherwise = do
        (pid, name) <- registryAsset registry
        let MaryValue _ assets = output ^. valueTxOutL
        if assets /= MultiAsset (Map.singleton pid (Map.singleton name 1))
            then Nothing
            else case output ^. datumTxOutL of
                Datum binary ->
                    Root <$> decodeStateDatum (getPlutusData (binaryDataToData binary))
                _ -> Nothing

credential :: TxOut ConwayEra -> Maybe ByteString
credential output = case output ^. addrTxOutL of
    Addr _ (ScriptHashObj (ScriptHash h)) _ -> Just (hashToBytes h)
    _ -> Nothing

withRead
    :: ReaderReadName
    -> ReaderRead a
    -> (a -> NeutralReaderAnswer)
    -> NeutralReaderAnswer
withRead name observed use = case observed of
    ReadMissing -> Unavailable name Missing
    ReadFailed why -> Unavailable name (Failed why)
    ReadIncomplete why -> Unavailable name (Incomplete why)
    Complete value -> use value
