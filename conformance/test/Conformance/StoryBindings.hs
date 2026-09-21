{- |
Module      : Conformance.StoryBindings
Description : Slice S1 pinned obligations and conjunct inventory
License     : Apache-2.0

The single home of the slice's Lean pins: both bound obligations and
the conjunct anchors its clauses may select, quoted verbatim from
lean/Singular/Statements.lean at 265c595. One copy, reconciled on
every suite run — digests against lean/theorem-debt.json, anchors
against the Lean source itself. Nothing else in the tree pins these
values.
-}
module Conformance.StoryBindings (
    conjunctInventory,
    insertActiveRow,
    keyedMintFold,
) where

import Conformance.Story (BoundObligation, boName, mkBoundObligation)

-- | The active-registration obligation both migrated clauses bind.
insertActiveRow :: BoundObligation
insertActiveRow =
    mkBoundObligation
        "Singular.Statements.insert_active_transaction_row"
        "bfb4e3174839b649a883244b97053ea52985cb3eeea1d3eb4475bb273e841737"
        "265c595"

-- | The batch-allocation obligation the keyed-mint clause binds.
keyedMintFold :: BoundObligation
keyedMintFold =
    mkBoundObligation
        "Singular.Statements.fold_batch_claimed_mint_by_kind_key"
        "9c01e278443498d3488e6671cc1799393f565a2a1c0055c1926a8d3e559da988"
        "265c595"

-- | The conjunct anchors the slice's clauses may select, keyed by the
-- obligation that states them. Quoted verbatim; every one must appear
-- in the Lean source or the suite fails.
conjunctInventory :: [(String, [String])]
conjunctInventory =
    [ ( boName insertActiveRow
      ,
          [ "address := some r.output"
          , "assets := [((.active, r.key), 1)]"
          , "kindCount t.state .active r.key = 1"
          , "mint := [((.active, r.key), 1)]"
          , "openPolicyParameters = []"
          , "refunds := []"
          , "signers := []"
          , "lovelaceCoversTip s.config lovelace = true"
          , "destinationDatumBinds r = true"
          , "onlyRootChanged s.config t.state.config = true"
          , "txOf t.state r₂ lovelace = .error \"key-exists\""
          ]
      )
    , ( boName keyedMintFold
      ,
          [ "assetKindTotal (claimedMint [b₁, b₂]) k"
          , "assetSame (claimedMint [b₁, b₂]) (actualMint [b₁, b₂]) = false"
          , "foldBatch s [b₁, b₂] = .error \"net-mint-mismatch\""
          ]
      )
    ]
