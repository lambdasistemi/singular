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
    , TrieSnapshot (..)
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
