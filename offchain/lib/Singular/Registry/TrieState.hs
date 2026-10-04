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
    ) where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Singular.Registry.Ledger (Root (..))
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
