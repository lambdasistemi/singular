{-# LANGUAGE RankNTypes #-}

{- | Shared capability representations. Certificate and proof constructors
stay inside the implementation; the public module exposes only observers.
-}
module Singular.Registry.TrieState.Types
    ( StatePolicyId (..)
    , RegistryIdentity (..)
    , SessionId (..)
    , SessionBinding (..)
    , StatePoint (..)
    , TrieSelection (..)
    , TrieState (..)
    , TrieSnapshot (..)
    , Leaf (..)
    , leafName
    , leafBytes
    , TrieFailure (..)
    , CompleteFromCreate (..)
    , MembershipProof (..)
    , NonMembershipProof (..)
    , SpeculativeWalk (..)
    , CreateRecord (..)
    , ObservedFold (..)
    , TrieObservation (..)
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import MPF.Hashes (MPFHash)
import MPF.Proof.Exclusion (MPFExclusionProof)
import Singular.Registry.Ledger (AssetName, Root, TxIn)
import Singular.Registry.Types (ProofStep)

newtype StatePolicyId = StatePolicyId ByteString
    deriving stock (Eq, Ord, Show)
data RegistryIdentity = RegistryIdentity StatePolicyId AssetName
    deriving stock (Eq, Ord, Show)
newtype SessionId = SessionId Text deriving stock (Eq, Ord, Show)
data SessionBinding = Unbound | Bound Integer ByteString
    deriving stock (Eq, Show)
data StatePoint = StatePoint
    { pointSession :: SessionId
    , pointBinding :: SessionBinding
    , pointOutput :: TxIn
    }
    deriving stock (Eq, Show)
data TrieSelection = TrieSelection
    { trieSelectionIdentity :: RegistryIdentity
    , trieSelectionPoint :: StatePoint
    , trieSelectionRoot :: Root
    }
    deriving stock (Eq, Show)

data TrieState m = TrieState
    { withTrieState
        :: forall a
         . TrieSelection -> (TrieSnapshot m -> m a) -> m (Either TrieFailure a)
    , acceptObservedFold :: ObservedFold -> m (Either TrieFailure ())
    }
data TrieSnapshot m = TrieSnapshot
    { snapshotTrieIdentity :: RegistryIdentity
    , snapshotTriePoint :: StatePoint
    , snapshotTrieRoot :: Root
    , snapshotTrieCoverage :: CompleteFromCreate
    , snapshotLeafAt :: ByteString -> m (Either TrieFailure Leaf)
    , snapshotMembership
        :: ByteString -> Leaf -> m (Either TrieFailure MembershipProof)
    , snapshotNonMembership
        :: ByteString -> m (Either TrieFailure NonMembershipProof)
    , snapshotSpeculateEdges
        :: NonEmpty (ByteString, Integer)
        -> m (Either TrieFailure SpeculativeWalk)
    }

data Leaf = Unknown | Absent | Active | Terminal
    deriving stock (Eq, Show, Enum, Bounded)
leafName :: Leaf -> Text
leafName Unknown = "unknown"
leafName Absent = "absent"
leafName Active = "active"
leafName Terminal = "terminal"
leafBytes :: Leaf -> ByteString
leafBytes Unknown = ""
leafBytes Absent = BS.singleton 0
leafBytes Active = BS.singleton 1
leafBytes Terminal = BS.singleton 2

data TrieFailure
    = HistoryIncomplete
    | RootDoesNotChain
    | UndecodableRequest
    | WrongRegistry
    | StaleState
    | MissingProof
    deriving stock (Eq, Show)
newtype CompleteFromCreate = CompleteFromCreate {coverageTransitions :: Int}
    deriving stock (Eq, Show)
newtype MembershipProof = MembershipProof {membershipBytes :: ByteString}
    deriving stock (Eq, Show)
data NonMembershipProof
    = NonMembershipProof ByteString (MPFExclusionProof MPFHash)
data SpeculativeWalk = SpeculativeWalk {walkRoot :: Root, walkProofs :: [[ProofStep]]}
    deriving stock (Eq, Show)
data CreateRecord = CreateRecord RegistryIdentity TxIn
    deriving stock (Eq, Show)
data ObservedFold
    = ObservedFold
        TrieSelection
        TrieSelection
        (NonEmpty (ByteString, Integer))
    deriving stock (Eq, Show)

{- | Completed operations, emitted by the same engine that returned their
values or persisted their accepted nodes.
-}
data TrieObservation
    = Created TrieSelection
    | Selected TrieSelection
    | LeafRead TrieSelection ByteString Leaf
    | MemberProved TrieSelection ByteString Leaf ByteString
    | AbsenceProved TrieSelection ByteString
    | Speculated TrieSelection SpeculativeWalk
    | FoldAccepted TrieSelection TrieSelection
    deriving stock (Eq, Show)
