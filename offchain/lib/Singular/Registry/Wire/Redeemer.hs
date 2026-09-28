{- |
Module      : Singular.Registry.Wire.Redeemer
Description : Mint, update, and pinned-hook consumer redeemers
License     : Apache-2.0

What the registry scripts read as redeemers: the migration parameters,
the minting redeemer, the per-request actions inside a modify, the
spending redeemer — and the pinned-hook consumer redeemer, which is
encode-only by construction. Reads "Singular.Registry.Wire.Primitive"
and "Singular.Registry.Wire.Proof"; nothing here is importable by a
caller — the public surface is the "Singular.Registry.Types" facade.
-}
module Singular.Registry.Wire.Redeemer
    ( -- * On-chain datum / redeemer wrappers
      Migration (..)
    , MintRedeemer (..)
    , RequestAction (..)
    , UpdateRedeemer (..)

      -- * Pinned-hook consumer redeemer (NOTE-021)
    , ConsumerRedeemer (..)
    ) where

import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    )
import PlutusTx.IsData.Class
    ( FromData (..)
    , ToData (..)
    , UnsafeFromData (..)
    )
import Singular.Registry.Wire.Primitive
    ( OnChainTokenId (..)
    , OnChainTxOutRef (..)
    , bbsFromD
    , bbsToD
    , mkD
    , unD
    )
import Singular.Registry.Wire.Proof
    ( ProofStep (..)
    )

{- | Migration parameters. Matches Aiken
@types\/Migration@.
-}
data Migration = Migration
    { migrationOldPolicy :: !BuiltinByteString
    -- ^ Policy ID of the old cage validator
    , migrationTokenId :: !OnChainTokenId
    -- ^ Token being migrated to the new policy
    }
    deriving stock (Show, Eq)

{- | Minting redeemer. Matches Aiken
@types\/MintRedeemer@.

The seed @OutputReference@ that authorizes a fresh
mint and derives the asset name is carried by the
redeemer because the state validator is global and
unparameterized.
-}
data MintRedeemer
    = -- | Mint a new cage token (Constr 0)
      Minting !OnChainTxOutRef
    | -- | Migrate from old validator (Constr 1)
      Migrating !Migration
    | -- | Burn a cage token (Constr 2)
      Burning !OnChainTokenId
    deriving stock (Show, Eq)

{- | Per-request action in a 'Modify' redeemer.
Matches Aiken @types\/RequestAction@.
-}
data RequestAction
    = -- | Update with Merkle proof (Constr 0)
      Update ![ProofStep]
    | -- | Reject expired request (Constr 1)
      Rejected
    deriving stock (Show, Eq)

{- | Spending redeemer. Matches Aiken
@types\/UpdateRedeemer@.

@Sweep stateRef@ is refused for every party (operator ruling
NOTE-028/A-003); the constructor stays for the wire shape.
-}
data UpdateRedeemer
    = -- | End the token (Constr 0)
      End
    | -- | Link a request to a state UTxO (Constr 1)
      Contribute !OnChainTxOutRef
    | -- | Process requests with mixed actions (Constr 2)
      Modify ![RequestAction]
    | -- | Reclaim a pending request (Constr 3)
      Retract !OnChainTxOutRef
    | {- | Reclaim a non-legitimate UTxO at the cage's
      address (Constr 4). Owner-signed.
      -}
      Sweep !OnChainTxOutRef
    deriving stock (Show, Eq)

{- | Pinned-hook consumer redeemer (NOTE-021): a nullary hook. The
consumer authenticates the batch from the transaction's own evidence
(spent state, request datums, naming claims, mint field) — the redeemer
carries nothing because nothing caller-supplied is trusted. Encodes as
@Constr 0 []@.
-}
data ConsumerRedeemer
    = Hook
    deriving stock (Show, Eq)

-- ---------------------------------------------------------
-- ToData / FromData instances
-- ---------------------------------------------------------

instance ToData Migration where
    toBuiltinData Migration{..} =
        mkD $
            Constr
                0
                [ bbsToD migrationOldPolicy
                , unD
                    (toBuiltinData migrationTokenId)
                ]

instance FromData Migration where
    fromBuiltinData bd = case unD bd of
        Constr 0 [pol, tid] -> do
            migrationOldPolicy <- bbsFromD pol
            migrationTokenId <-
                fromBuiltinData (mkD tid)
            Just Migration{..}
        _ -> Nothing

instance UnsafeFromData Migration where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [B pol, tid] ->
            Migration
                { migrationOldPolicy =
                    BuiltinByteString pol
                , migrationTokenId =
                    unsafeFromBuiltinData (mkD tid)
                }
        _ ->
            error
                "unsafeFromBuiltinData: Migration"

instance ToData MintRedeemer where
    toBuiltinData (Minting ref) =
        mkD $ Constr 0 [unD (toBuiltinData ref)]
    toBuiltinData (Migrating m) =
        mkD $ Constr 1 [unD (toBuiltinData m)]
    toBuiltinData (Burning tokenId) =
        mkD $ Constr 2 [unD (toBuiltinData tokenId)]

instance FromData MintRedeemer where
    fromBuiltinData bd = case unD bd of
        Constr 0 [d] -> Minting <$> fromBuiltinData (mkD d)
        Constr 1 [d] ->
            Migrating <$> fromBuiltinData (mkD d)
        Constr 2 [d] -> Burning <$> fromBuiltinData (mkD d)
        _ -> Nothing

instance UnsafeFromData MintRedeemer where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [d] ->
            Minting $
                unsafeFromBuiltinData (mkD d)
        Constr 1 [d] ->
            Migrating $
                unsafeFromBuiltinData (mkD d)
        Constr 2 [d] ->
            Burning $
                unsafeFromBuiltinData (mkD d)
        _ ->
            error
                "unsafeFromBuiltinData: MintRedeemer"

instance ToData RequestAction where
    toBuiltinData (Update steps) =
        mkD $
            Constr
                0
                [ List $
                    map (unD . toBuiltinData) steps
                ]
    toBuiltinData Rejected = mkD $ Constr 1 []

instance FromData RequestAction where
    fromBuiltinData bd = case unD bd of
        Constr 0 [List steps] ->
            Update
                <$> traverse
                    (fromBuiltinData . mkD)
                    steps
        Constr 1 [] -> Just Rejected
        _ -> Nothing

instance UnsafeFromData RequestAction where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [List steps] ->
            Update $
                map
                    (unsafeFromBuiltinData . mkD)
                    steps
        Constr 1 [] -> Rejected
        _ ->
            error
                "unsafeFromBuiltinData:\
                \ RequestAction"

instance ToData UpdateRedeemer where
    toBuiltinData End = mkD $ Constr 0 []
    toBuiltinData (Contribute ref) =
        mkD $ Constr 1 [unD (toBuiltinData ref)]
    toBuiltinData (Modify actions) =
        mkD $
            Constr
                2
                [ List $
                    map (unD . toBuiltinData) actions
                ]
    toBuiltinData (Retract ref) =
        mkD $ Constr 3 [unD (toBuiltinData ref)]
    toBuiltinData (Sweep ref) =
        mkD $ Constr 4 [unD (toBuiltinData ref)]

instance FromData UpdateRedeemer where
    fromBuiltinData bd = case unD bd of
        Constr 0 [] -> Just End
        Constr 1 [d] ->
            Contribute <$> fromBuiltinData (mkD d)
        Constr 2 [List as] ->
            Modify
                <$> traverse
                    (fromBuiltinData . mkD)
                    as
        Constr 3 [d] ->
            Retract <$> fromBuiltinData (mkD d)
        Constr 4 [d] ->
            Sweep <$> fromBuiltinData (mkD d)
        _ -> Nothing

instance UnsafeFromData UpdateRedeemer where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [] -> End
        Constr 1 [d] ->
            Contribute $
                unsafeFromBuiltinData (mkD d)
        Constr 2 [List as] ->
            Modify $
                map
                    (unsafeFromBuiltinData . mkD)
                    as
        Constr 3 [d] ->
            Retract $
                unsafeFromBuiltinData (mkD d)
        Constr 4 [d] ->
            Sweep $
                unsafeFromBuiltinData (mkD d)
        _ ->
            error
                "unsafeFromBuiltinData:\
                \ UpdateRedeemer"

instance ToData ConsumerRedeemer where
    toBuiltinData Hook = mkD $ Constr 0 []
