-- | Two real requests: a wrong allocation is rejected, the correct one succeeds.
module Conformance.Fold.KeyedMint (story, keyedMintFold, conjuncts) where

import Conformance.Story.Live
import Conformance.Story.Binding (Binding, mkBoundObligation)

-- | Both requests belong to the registry and recipient established by the caller.
story :: reg -> wal -> Story reg wal ins ret bat ref bat
story registry recipient = do
    linkedTo keyedMintFold conjuncts
    compareBatchAllocation registry recipient "carol" "david"

-- | The batch-allocation obligation.
keyedMintFold :: Binding
keyedMintFold =
    mkBoundObligation
        "Singular.Statements.fold_batch_claimed_mint_by_kind_key"
        "9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988"
        "265c595"

-- | Verbatim Lean anchors used by this subject.
conjuncts :: [String]
conjuncts = [ "assetKindTotal (claimedMint [b₁, b₂]) k"
          , "assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false"
          , "foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""
    ]
