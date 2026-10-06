{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Application proofs for one registry's independently selected state.
Unbound selections record observations without promising an atomic ledger
snapshot. Coverage is checked from create and reproduced trie-changing roots.
-}
module Singular.Registry.TrieState
    ( StatePolicyId (..)
    , RegistryIdentity (..)
    , SessionId (..)
    , SessionBinding (..)
    , StatePoint (..)
    , TrieSelection (..)
    , TrieState (..)
    , TrieSnapshot
    , trieIdentity
    , triePoint
    , trieRoot
    , trieCoverage
    , leafAt
    , membership
    , nonMembership
    , speculateEdges
    , Leaf (..)
    , leafName
    , TrieFailure (..)
    , Parting (..)
    , Incomplete (..)
    , Undecodable (..)
    , Mismatch (..)
    , Staleness (..)
    , Missing (..)
    , failureRegistry
    , failureTransaction
    , trieFailureName
    , trieFailureFields
    , CompleteFromCreate
    , coverageTransitions
    , MembershipProof
    , membershipBytes
    , NonMembershipProof
    , verifyNonMembership
    , SpeculativeWalk
    , walkRoot
    , walkProofs
    , CreateRecord (..)
    , ObservedFold (..)
    , TrieObservation (..)
    ) where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Text qualified as T

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))

import Singular.Registry.Deployment.Manifest (renderOutRef)
import Singular.Registry.Ledger (AssetName (..), Root (..))
import Singular.Registry.Trie.Pure (verifyExclusion)
import Singular.Registry.TrieState.Types

{- | The proof's key is the one the backend actually queried. Its constructor
is private; changing either the requested key or selected root fails.
-}
verifyNonMembership
    :: NonMembershipProof -> Root -> ByteString -> Bool
verifyNonMembership (NonMembershipProof provenKey proof) (Root root) key =
    key == provenKey && verifyExclusion proof root

-- Public observers are functions, not exported record labels. A caller cannot
-- construct a snapshot or copy a certificate into another selection.
trieIdentity :: TrieSnapshot m -> RegistryIdentity
trieIdentity = snapshotTrieIdentity
triePoint :: TrieSnapshot m -> StatePoint
triePoint = snapshotTriePoint
trieRoot :: TrieSnapshot m -> Root
trieRoot = snapshotTrieRoot
trieCoverage :: TrieSnapshot m -> CompleteFromCreate
trieCoverage = snapshotTrieCoverage
leafAt :: TrieSnapshot m -> ByteString -> m (Either TrieFailure Leaf)
leafAt = snapshotLeafAt
membership
    :: TrieSnapshot m
    -> ByteString
    -> Leaf
    -> m (Either TrieFailure MembershipProof)
membership = snapshotMembership
nonMembership
    :: TrieSnapshot m
    -> ByteString
    -> m (Either TrieFailure NonMembershipProof)
nonMembership = snapshotNonMembership
speculateEdges
    :: TrieSnapshot m
    -> NonEmpty (ByteString, Integer)
    -> m (Either TrieFailure SpeculativeWalk)
speculateEdges = snapshotSpeculateEdges

-- | The registry a refusal is about.
failureRegistry :: TrieFailure -> RegistryIdentity
failureRegistry = \case
    HistoryIncomplete who _ _ -> who
    RootDoesNotChain who _ _ -> who
    UndecodableRequest who _ _ -> who
    WrongRegistry who _ _ -> who
    StaleState who _ _ -> who
    MissingProof who _ -> who

-- | The transaction a refusal is about, where one is known.
failureTransaction :: TrieFailure -> Maybe TxId
failureTransaction = \case
    HistoryIncomplete _ tx _ -> tx
    RootDoesNotChain _ tx _ -> tx
    UndecodableRequest _ tx _ -> tx
    WrongRegistry _ tx _ -> tx
    StaleState _ tx _ -> tx
    MissingProof _ _ -> Nothing

-- | The refusal's name, as a command prints it.
trieFailureName :: TrieFailure -> Text
trieFailureName = \case
    HistoryIncomplete{} -> "HistoryIncomplete"
    RootDoesNotChain{} -> "RootDoesNotChain"
    UndecodableRequest{} -> "UndecodableRequest"
    WrongRegistry{} -> "WrongRegistry"
    StaleState{} -> "StaleState"
    MissingProof{} -> "MissingProof"

{- | The receipt field a command prints beside the refusal's name: one
@trieRefusal@ object holding the registry, the transaction where one is
known, and the cause. Held under one key, it never overwrites a field the
command's receipt already carries.
-}
trieFailureFields :: TrieFailure -> [(Text, Value)]
trieFailureFields failure = [("trieRefusal", object [(Key.fromText k, v) | (k, v) <- payload])]
  where
    payload =
        ("registry", registryJson (failureRegistry failure))
            : maybe
                []
                (\tx -> [("transaction", toJSON (txIdText tx))])
                (failureTransaction failure)
                <> reasonFields
    reasonFields = case failure of
        HistoryIncomplete _ _ why -> case why of
            MissingTransaction -> reason "missing-transaction"
            ProviderHistoryFailure providerFailure ->
                reason "provider-history-failure"
                    <> [("providerFailure", toJSON (show providerFailure))]
            UnresolvedInput i -> reason "unresolved-input" <> output i
            ConflictingResolution i -> reason "conflicting-resolution" <> output i
            ConflictingCopies -> reason "conflicting-copies"
            NoStateInput -> reason "no-state-input"
            ForkedStateOutput i -> reason "forked-state-output" <> output i
            OutsideLineage -> reason "outside-lineage"
        RootDoesNotChain _ _ (UnreadableRoot what) ->
            reason "unreadable-root" <> [("record", toJSON what)]
        RootDoesNotChain _ _ (RootsPart rebuilt recorded) ->
            reason "roots-part"
                <> [ ("rebuiltRoot", rootJson rebuilt)
                   , ("recordedRoot", rootJson recorded)
                   ]
        UndecodableRequest _ _ why -> case why of
            UndecodableStateOutput -> reason "undecodable-state-output"
            MissingRedeemer -> reason "missing-redeemer"
            NotModify -> reason "not-modify"
            ActionCount given found ->
                reason "action-count"
                    <> [("actions", toJSON given), ("requests", toJSON found)]
            EdgeOutOfRange edge -> reason "edge-out-of-range" <> [("edge", toJSON edge)]
            UnreadableRecord what -> reason "unreadable-record" <> [("record", toJSON what)]
        WrongRegistry _ _ why -> case why of
            SelectionNotState -> reason "selection-not-state"
            CreateMint -> reason "create-mint"
            SeedNotSpent -> reason "seed-not-spent"
            SeedName -> reason "seed-name"
            CreateOutput -> reason "create-output"
            OtherRegistry other ->
                reason "other-registry" <> [("otherRegistry", registryJson other)]
            UnknownRegistry -> reason "unknown-registry"
        StaleState _ _ why -> case why of
            StaleRoot selected current ->
                reason "stale-root"
                    <> [ ("selectedRoot", rootJson selected)
                       , ("currentRoot", rootJson current)
                       ]
            StaleSelection selected held ->
                reason "stale-selection"
                    <> [("selected", selectionJson selected), ("held", selectionJson held)]
            StaleOutput selected made ->
                reason "stale-output"
                    <> [ ("selectedOutput", toJSON (renderOutRef selected))
                       , ("madeOutput", toJSON (renderOutRef made))
                       ]
            NoSelection -> reason "no-selection"
        MissingProof _ why -> case why of
            NoProofFor key -> reason "no-proof" <> [("key", toJSON (hexText key))]
            NoLocalTrie -> reason "no-local-trie"
    reason :: Text -> [(Text, Value)]
    reason r = [("cause", toJSON r)]
    output i = [("output", toJSON (renderOutRef i))]

registryJson :: RegistryIdentity -> Value
registryJson (RegistryIdentity (StatePolicyId policy) (AssetName name)) =
    object
        ["policy" .= hexText policy, "name" .= hexText (SBS.fromShort name)]

selectionJson :: TrieSelection -> Value
selectionJson TrieSelection{trieSelectionPoint, trieSelectionRoot} =
    object
        [ "output" .= renderOutRef (pointOutput trieSelectionPoint)
        , "root" .= unRootHex trieSelectionRoot
        ]

rootJson :: Root -> Value
rootJson = toJSON . unRootHex

unRootHex :: Root -> Text
unRootHex (Root r) = hexText r

txIdText :: TxId -> Text
txIdText (TxId h) = hexText (hashToBytes (extractHash h))

hexText :: ByteString -> Text
hexText = T.pack . BC.unpack . B16.encode
