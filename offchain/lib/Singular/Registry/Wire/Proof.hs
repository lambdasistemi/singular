{- |
Module      : Singular.Registry.Wire.Proof
Description : Neighbor and proof-step values for MPF Merkle proofs
License     : Apache-2.0

The Aiken @merkle-patricia-forestry@ proof encoding: a single step in
an MPF Merkle proof and the neighbor node a fork step carries, each
with its codec. Reads only "Singular.Registry.Wire.Primitive"; nothing
here is importable by a caller — the public surface is the
"Singular.Registry.Types" facade.
-}
module Singular.Registry.Wire.Proof
    ( -- * Proof steps (Aiken MPF proof encoding)
      ProofStep (..)
    , Neighbor (..)
    ) where

import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))
import PlutusTx.IsData.Class
    ( FromData (..)
    , ToData (..)
    , UnsafeFromData (..)
    )
import Singular.Registry.Wire.Primitive
    ( bsFromD
    , bsToD
    , mkD
    , unD
    )

{- | A single step in an MPF Merkle proof, matching
the Aiken @ProofStep@ type from
@aiken-lang\/merkle-patricia-forestry@.
-}
data ProofStep
    = -- | Branch step (Constr 0)
      Branch
        { branchSkip :: !Integer
        -- ^ Number of shared nibbles to skip
        , branchNeighbors :: !ByteString
        -- ^ Concatenated neighbor hashes (4 x 32 bytes)
        }
    | -- | Fork step (Constr 1)
      Fork
        { forkSkip :: !Integer
        -- ^ Number of shared nibbles to skip
        , forkNeighbor :: !Neighbor
        -- ^ The sibling branch at the fork point
        }
    | -- | Leaf step (Constr 2)
      Leaf
        { leafSkip :: !Integer
        -- ^ Number of shared nibbles to skip
        , leafKey :: !ByteString
        -- ^ Remaining key suffix at the leaf
        , leafValue :: !ByteString
        -- ^ Value hash stored at the leaf
        }
    deriving stock (Show, Eq)

-- | Neighbor node in a fork proof step.
data Neighbor = Neighbor
    { neighborNibble :: !Integer
    -- ^ Hex digit (0-15) identifying the fork branch
    , neighborPrefix :: !ByteString
    -- ^ Common prefix nibbles of the neighbor subtree
    , neighborRoot :: !ByteString
    -- ^ Merkle root hash of the neighbor subtree
    }
    deriving stock (Show, Eq)

-- ---------------------------------------------------------
-- ToData / FromData instances
-- ---------------------------------------------------------

instance ToData Neighbor where
    toBuiltinData Neighbor{..} =
        mkD $
            Constr
                0
                [ I neighborNibble
                , bsToD neighborPrefix
                , bsToD neighborRoot
                ]

instance FromData Neighbor where
    fromBuiltinData bd = case unD bd of
        Constr 0 [I nib, pfx, rt] ->
            Neighbor nib
                <$> bsFromD pfx
                <*> bsFromD rt
        _ -> Nothing

instance UnsafeFromData Neighbor where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [I nib, B pfx, B rt] ->
            Neighbor nib pfx rt
        _ -> error "unsafeFromBuiltinData: Neighbor"

instance ToData ProofStep where
    toBuiltinData Branch{..} =
        mkD $
            Constr
                0
                [ I branchSkip
                , bsToD branchNeighbors
                ]
    toBuiltinData Fork{..} =
        mkD $
            Constr
                1
                [ I forkSkip
                , unD (toBuiltinData forkNeighbor)
                ]
    toBuiltinData Leaf{..} =
        mkD $
            Constr
                2
                [ I leafSkip
                , bsToD leafKey
                , bsToD leafValue
                ]

instance FromData ProofStep where
    fromBuiltinData bd = case unD bd of
        Constr 0 [I sk, nb] ->
            Branch sk <$> bsFromD nb
        Constr 1 [I sk, nd] ->
            Fork sk
                <$> fromBuiltinData (mkD nd)
        Constr 2 [I sk, k, v] ->
            Leaf sk <$> bsFromD k <*> bsFromD v
        _ -> Nothing

instance UnsafeFromData ProofStep where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [I sk, B nb] -> Branch sk nb
        Constr 1 [I sk, nd] ->
            Fork sk $
                unsafeFromBuiltinData (mkD nd)
        Constr 2 [I sk, B k, B v] -> Leaf sk k v
        _ ->
            error "unsafeFromBuiltinData: ProofStep"
