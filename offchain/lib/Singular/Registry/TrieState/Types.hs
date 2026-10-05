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
    , Parting (..)
    , Incomplete (..)
    , Undecodable (..)
    , Mismatch (..)
    , Staleness (..)
    , Missing (..)
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
import Singular.Registry.Evidence
    ( SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.Ledger (AssetName, Root, TxId, TxIn)
import Singular.Registry.Types (ProofStep)

newtype StatePolicyId = StatePolicyId ByteString
    deriving stock (Eq, Ord, Show)
data RegistryIdentity = RegistryIdentity StatePolicyId AssetName
    deriving stock (Eq, Ord, Show)
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

{- | Why a registry's trie cannot be served, naming what a person needs to
act on it: the registry, the transaction where one is known, and the
reason. A backend passes what it knows and never invents the rest.
-}
data TrieFailure
    = -- | The history does not reach the selection from @create@.
      HistoryIncomplete RegistryIdentity (Maybe TxId) Incomplete
    | -- | A rebuilt root is not the recorded one, or a recorded root cannot be read.
      RootDoesNotChain RegistryIdentity (Maybe TxId) Parting
    | -- | A fold's redeemer, actions, state output or edges cannot be read.
      UndecodableRequest RegistryIdentity (Maybe TxId) Undecodable
    | -- | The material is another registry's, or not this registry's state.
      WrongRegistry RegistryIdentity (Maybe TxId) Mismatch
    | -- | The selection is not the state the trie is served at.
      StaleState RegistryIdentity (Maybe TxId) Staleness
    | -- | No proof can be given.
      MissingProof RegistryIdentity Missing
    deriving stock (Eq, Show)

-- | How a rebuilt root parts from the recorded one.
data Parting
    = -- | The rebuilt root is not the recorded root: rebuilt, recorded.
      RootsPart Root Root
    | -- | A recorded root cannot be read; the text says which.
      UnreadableRoot Text
    deriving stock (Eq, Show)

-- | How a history falls short of the lineage.
data Incomplete
    = -- | A transaction the lineage spends through is not in the history.
      MissingTransaction
    | -- | A spent input is resolved neither by the history nor by the map.
      UnresolvedInput TxIn
    | -- | The map resolves an input differently from the transaction that made it.
      ConflictingResolution TxIn
    | -- | Two different transactions share one identifier.
      ConflictingCopies
    | -- | A transaction holds the token but spends no state output and mints none.
      NoStateInput
    | -- | A state output is spent by two different transactions.
      ForkedStateOutput TxIn
    | -- | A transaction touches the token outside the lineage.
      OutsideLineage
    deriving stock (Eq, Show)

-- | What of a fold cannot be read.
data Undecodable
    = -- | The state output carries no inline state datum, or is not first.
      UndecodableStateOutput
    | -- | The state input's spend carries no redeemer.
      MissingRedeemer
    | -- | The state input's redeemer is not @Modify@.
      NotModify
    | -- | Actions given and matching requests found differ in number.
      ActionCount Int Int
    | -- | An edge outside the seven the registry defines.
      EdgeOutOfRange Integer
    | -- | A local record the history is read from cannot be read; the text says what.
      UnreadableRecord Text
    deriving stock (Eq, Show)

-- | How the material differs from the selected registry.
data Mismatch
    = -- | The output read as the state does not hold exactly the registry's token.
      SelectionNotState
    | -- | @create@ does not mint exactly one token under @Minting(seed)@.
      CreateMint
    | -- | @create@ does not spend its seed.
      SeedNotSpent
    | -- | The token's name is not @assetName(seed)@.
      SeedName
    | -- | @create@'s first output is not the state address holding the token.
      CreateOutput
    | -- | The material names this other registry.
      OtherRegistry RegistryIdentity
    | -- | Nothing is held for the registry.
      UnknownRegistry
    deriving stock (Eq, Show)

-- | How the selection differs from the state the trie is served at.
data Staleness
    = -- | The selection's root is not the root at its output: selected, at the output.
      StaleRoot Root Root
    | -- | The selection is not the one held: selected, held.
      StaleSelection TrieSelection TrieSelection
    | -- | The selected output is not the output the history makes: selected, made.
      StaleOutput TxIn TxIn
    | -- | No selection has been made, or the live state could not be read.
      NoSelection
    deriving stock (Eq, Show)

-- | What no proof can be given for.
data Missing
    = -- | The key no proof binds under the selected root.
      NoProofFor ByteString
    | -- | No local trie is held for the registry.
      NoLocalTrie
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
