{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.Types
Description : PlutusData types for the registry validator
License     : Apache-2.0

Haskell types matching the Aiken on-chain datum\/redeemer
structures and their PlutusData encoding.

These types use Plutus primitives directly (not
cardano-ledger types) because they model the exact
on-chain data layout expected by the Aiken validator.
The 'ToData'\/'FromData' instances are hand-written
(not TH-derived) to guarantee constructor indices and
field ordering match the Aiken source byte-for-byte.
-}
module Singular.Registry.Types (
    -- * On-chain datum\/redeemer types
    CageDatum (..),
    MintRedeemer (..),
    Migration (..),
    UpdateRedeemer (..),
    RequestAction (..),

    -- * On-chain domain types
    OnChainTokenId (..),
    Edge,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateActive,
    edgeUpdateTerminal,
    edgeDeleteAbsent,
    edgeDeleteActive,
    edgeWitnessTerminal,
    edgeName,
    RequestPhase (..),
    requestPhase,
    OnChainRoot (..),
    OnChainRequest (..),
    OnChainTokenState (..),
    OnChainTxOutRef (..),

    -- * Proof steps (Aiken MPF proof encoding)
    ProofStep (..),
    Neighbor (..),

    -- * State helpers
    stateActivePolicyBytes,
    stateAppPolicyBytes,
    stateAbsentPolicyBytes,
    stateTerminalPolicyBytes,

    -- * Pinned-hook consumer redeemer (NOTE-021)
    ConsumerRedeemer (..),
) where

import Cardano.Ledger.BaseTypes (SlotNo (..))
import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (
    FromData (..),
    ToData (..),
    UnsafeFromData (..),
 )

-- ---------------------------------------------------------
-- On-chain domain types (Plutus primitives)
-- ---------------------------------------------------------

{- | On-chain token identifier (asset name as raw
bytes). Matches Aiken @lib\/TokenId@.
-}
newtype OnChainTokenId = OnChainTokenId
    { unOnChainTokenId :: BuiltinByteString
    }
    deriving stock (Show, Eq)

{- | On-chain output reference. Matches Aiken
@cardano\/transaction\/OutputReference@.
-}
data OnChainTxOutRef = OnChainTxOutRef
    { txOutRefId :: !BuiltinByteString
    -- ^ Transaction hash (32 bytes)
    , txOutRefIdx :: !Integer
    -- ^ Output index within the transaction
    }
    deriving stock (Show, Eq)

-- | On-chain MPF root hash (raw bytes).
newtype OnChainRoot = OnChainRoot
    { unOnChainRoot :: ByteString
    }
    deriving stock (Show, Eq)

{- | The C2 row index a request names (#183, Lean @Request.edge@,
Aiken @lib\/edgeInsertAbsent@ … @edgeWitnessTerminal@).

An edge names its own leaf bytes, so no value bytes travel with a
request and an illegal value-byte shape is not expressible:

@
0  insertAbsent     insert 0x00
1  insertActive     insert 0x01
2  updateActive     update 0x00 -> 0x01
3  updateTerminal   update 0x01 -> 0x02
4  deleteAbsent     delete 0x00
5  deleteActive     delete 0x01
6  witnessTerminal  read   0x02
@

It is a plain 'Integer', exactly as it is a plain @Int@ on chain, so a
tag outside @0..6@ can still be encoded and sent — which is what the
cage's @edge-inadmissible@ refusal is there to answer, and what a row
that exercises that refusal needs to be able to build.
-}
type Edge = Integer

edgeInsertAbsent :: Edge
edgeInsertAbsent = 0

edgeInsertActive :: Edge
edgeInsertActive = 1

edgeUpdateActive :: Edge
edgeUpdateActive = 2

edgeUpdateTerminal :: Edge
edgeUpdateTerminal = 3

edgeDeleteAbsent :: Edge
edgeDeleteAbsent = 4

edgeDeleteActive :: Edge
edgeDeleteActive = 5

edgeWitnessTerminal :: Edge
edgeWitnessTerminal = 6

-- | The name of an admitted edge, for diagnostics and receipts.
edgeName :: Edge -> String
edgeName e = case e of
    0 -> "insertAbsent"
    1 -> "insertActive"
    2 -> "updateActive"
    3 -> "updateTerminal"
    4 -> "deleteAbsent"
    5 -> "deleteActive"
    6 -> "witnessTerminal"
    _ -> "edge-" <> show e

{- | On-chain request to modify a token's trie.
Matches Aiken @types\/Request@.
-}
data OnChainRequest = OnChainRequest
    { requestToken :: !OnChainTokenId
    -- ^ Token whose trie is being modified
    , requestOwner :: !BuiltinByteString
    -- ^ Payment key hash of the requester (28 bytes)
    , requestKey :: !ByteString
    -- ^ Trie key to operate on
    , requestEdge :: !Edge
    {- ^ The C2 row index this request names (#183). The edge names the
    trie move and its leaf bytes; no value bytes travel here.
    -}
    , requestDeposit :: !Integer
    {- ^ The deposit (lovelace) the request rides with, over and above
    the tip. Must equal the request output's lovelace less
    @state.tip@ at fold time; the fold returns it to the destination.
    -}
    , requestSubmittedAt :: !Integer
    -- ^ POSIX time (ms) when the request was submitted
    , requestDestination :: !(ByteString, ByteString)
    {- ^ Where this request's minted token goes, and the hash of the
    inline datum the receiving output must carry (#157 D-DEST;
    appended last). Encoded as a two-element list, exactly as Aiken
    encodes a tuple. Empty datum hash means a datum-less output; for
    edge 0 the address component is the refund address.
    -}
    }
    deriving stock (Show, Eq)

{- | On-chain token state. Matches Aiken @types\/State@ (#157 C7: eight
fields, replacing the six). `consumer_pin` is deleted with the pinned
consumer; `representative_policy` is renamed `active_policy`; the
application, absent and terminal policies are new. All four policies are
set at genesis and preserved by every `Modify`.
-}
data OnChainTokenState = OnChainTokenState
    { stateRoot :: !OnChainRoot
    -- ^ Current Merkle root of the token's trie
    , stateMaxFee :: !Integer
    -- ^ Oracle tip (lovelace) charged per request
    , stateProcessTime :: !Integer
    -- ^ Oracle processing window duration (ms)
    , stateRetractTime :: !Integer
    -- ^ Requester retract window duration (ms)
    , stateAppPolicy :: !BuiltinByteString
    {- ^ The application policy that certifies requests (#157 C4): a
    request whose operation changes the trie is folded only if its
    UTxO carries one asset under this policy whose name is the
    request's approval binding.
    -}
    , stateActivePolicy :: !BuiltinByteString
    {- ^ The policy that mints the ACTIVE token (renamed from the
    representative policy). Under it the asset name is the registry
    key itself (#157 D-ASSET).
    -}
    , stateAbsentPolicy :: !BuiltinByteString
    {- ^ The policy that mints the ABSENT token, held in the cage's own
    custody beside the inserter's refund address.
    -}
    , stateTerminalPolicy :: !BuiltinByteString
    {- ^ The policy that mints the TERMINAL token: a name is over,
    forever.
    -}
    }
    deriving stock (Show, Eq)

-- ---------------------------------------------------------
-- Request phase (A-002): what a request's age allows
-- ---------------------------------------------------------

{- | The action a registry request's age allows at a chain tip.

Mirrors @onchain/validators/shared.ak@: a request is foldable as
accepted while the tip is before @submitted_at + process_time@
(phase 1), retractable by its owner before @submitted_at +
process_time + retract_time@ (phase 2), and rejectable by any
permissionless fold afterwards (phase 3).
-}
data RequestPhase = PhaseAccept | PhaseRetract | PhaseReject
    deriving stock (Show, Eq)

{- | Classify a request from its two boundary slots and the live tip.

The boundaries are the slots the builders can express: the accept
fold's validity upper bound is the process deadline slot, the retract's
is the retract deadline slot. The comparison is strict, so a phase is
chosen only while the tip is inside what that phase's builder can
still build — a window already behind the tip never classifies into
the phase that would build it.
-}
requestPhase ::
    -- | Last slot an accept fold can carry (process deadline).
    SlotNo ->
    -- | Last slot a retract can carry (retract deadline).
    SlotNo ->
    -- | The live tip.
    SlotNo ->
    RequestPhase
requestPhase acceptDeadline retractDeadline tip
    | tip < acceptDeadline = PhaseAccept
    | tip < retractDeadline = PhaseRetract
    | otherwise = PhaseReject

-- ---------------------------------------------------------
-- On-chain-only types (datum / redeemer wrappers)
-- ---------------------------------------------------------

{- | Cage datum: either a pending request or a token
state. Matches Aiken @types\/CageDatum@.
-}
data CageDatum
    = -- | A pending operation request (Constr 0)
      RequestDatum !OnChainRequest
    | -- | Current token state (Constr 1)
      StateDatum !OnChainTokenState
    | {- | The cage's own custody of an absent token (Constr 2, #157
      D-CUSTODY; appended, so 0 and 1 never move): the address the
      inserter named for the refund. The registry key is the sole
      non-ADA asset carried by the output.
      -}
      AbsentCustody !ByteString
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

{- | The active-token policy as plain bytes (issue #77 E-001, renamed by
#157 C7): unwraps the `BuiltinByteString` for hex comparison in
verifiers. Named for the field it reads — no alias of the
representative policy survives.
-}
stateActivePolicyBytes :: OnChainTokenState -> ByteString
stateActivePolicyBytes st = case stateActivePolicy st of
    BuiltinByteString bs -> bs

-- | The application policy as plain bytes (#157 C4).
stateAppPolicyBytes :: OnChainTokenState -> ByteString
stateAppPolicyBytes st = case stateAppPolicy st of
    BuiltinByteString bs -> bs

-- | The absent-token policy as plain bytes (#157 C5).
stateAbsentPolicyBytes :: OnChainTokenState -> ByteString
stateAbsentPolicyBytes st = case stateAbsentPolicy st of
    BuiltinByteString bs -> bs

-- | The terminal-token policy as plain bytes (#157 C5).
stateTerminalPolicyBytes :: OnChainTokenState -> ByteString
stateTerminalPolicyBytes st = case stateTerminalPolicy st of
    BuiltinByteString bs -> bs

-- ---------------------------------------------------------
-- Helpers for manual Data construction
-- ---------------------------------------------------------

-- | Wrap a raw 'Data' value as 'BuiltinData'.
mkD :: Data -> BuiltinData
mkD = BuiltinData

-- | Unwrap 'BuiltinData' to the raw 'Data' AST.
unD :: BuiltinData -> Data
unD (BuiltinData d) = d

-- | Lift a 'ByteString' into a 'Data' byte-literal.
bsToD :: ByteString -> Data
bsToD = B

-- | Extract a 'ByteString' from a 'Data' byte-literal.
bsFromD :: Data -> Maybe ByteString
bsFromD (B bs) = Just bs
bsFromD _ = Nothing

{- | Lift a 'BuiltinByteString' into a 'Data'
byte-literal.
-}
bbsToD :: BuiltinByteString -> Data
bbsToD (BuiltinByteString bs) = B bs

{- | Extract a 'BuiltinByteString' from a 'Data'
byte-literal.
-}
bbsFromD :: Data -> Maybe BuiltinByteString
bbsFromD (B bs) = Just (BuiltinByteString bs)
bbsFromD _ = Nothing

-- ---------------------------------------------------------
-- ToData / FromData instances
-- ---------------------------------------------------------

instance ToData OnChainTokenId where
    toBuiltinData (OnChainTokenId bbs) =
        mkD $ Constr 0 [bbsToD bbs]

instance FromData OnChainTokenId where
    fromBuiltinData bd = case unD bd of
        Constr 0 [x] ->
            OnChainTokenId <$> bbsFromD x
        _ -> Nothing

instance UnsafeFromData OnChainTokenId where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [x] -> case bbsFromD x of
            Just bbs -> OnChainTokenId bbs
            _ ->
                error
                    "unsafeFromBuiltinData: OnChainTokenId"
        _ ->
            error
                "unsafeFromBuiltinData: OnChainTokenId"

instance ToData OnChainTxOutRef where
    toBuiltinData OnChainTxOutRef{..} =
        mkD $
            Constr
                0
                [bbsToD txOutRefId, I txOutRefIdx]

instance FromData OnChainTxOutRef where
    fromBuiltinData bd = case unD bd of
        Constr 0 [tid, I idx] ->
            OnChainTxOutRef
                <$> bbsFromD tid
                <*> pure idx
        _ -> Nothing

instance UnsafeFromData OnChainTxOutRef where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [B tid, I idx] ->
            OnChainTxOutRef
                (BuiltinByteString tid)
                idx
        _ ->
            error
                "unsafeFromBuiltinData: OnChainTxOutRef"

instance ToData OnChainRoot where
    toBuiltinData (OnChainRoot bs) = mkD $ bsToD bs

instance FromData OnChainRoot where
    fromBuiltinData bd =
        OnChainRoot <$> bsFromD (unD bd)

instance UnsafeFromData OnChainRoot where
    unsafeFromBuiltinData bd = case unD bd of
        B bs -> OnChainRoot bs
        _ ->
            error
                "unsafeFromBuiltinData: OnChainRoot"

instance ToData OnChainRequest where
    toBuiltinData OnChainRequest{..} =
        mkD $
            Constr
                0
                [ unD (toBuiltinData requestToken)
                , bbsToD requestOwner
                , bsToD requestKey
                , I requestEdge
                , I requestDeposit
                , I requestSubmittedAt
                , List
                    [ bsToD (fst requestDestination)
                    , bsToD (snd requestDestination)
                    ]
                ]

instance FromData OnChainRequest where
    fromBuiltinData bd = case unD bd of
        Constr
            0
            [tok, own, k, I edge, I dep, I sub, List [da, dh]] -> do
                requestToken <-
                    fromBuiltinData (mkD tok)
                requestOwner <- bbsFromD own
                requestKey <- bsFromD k
                destAddress <- bsFromD da
                destDatum <- bsFromD dh
                let requestEdge = edge
                    requestDeposit = dep
                    requestSubmittedAt = sub
                    requestDestination = (destAddress, destDatum)
                Just OnChainRequest{..}
        _ -> Nothing

instance UnsafeFromData OnChainRequest where
    unsafeFromBuiltinData bd = case unD bd of
        Constr
            0
            [tok, B own, B k, I edge, I dep, I sub, List [B da, B dh]] ->
                OnChainRequest
                    { requestToken =
                        unsafeFromBuiltinData (mkD tok)
                    , requestOwner =
                        BuiltinByteString own
                    , requestKey = k
                    , requestEdge = edge
                    , requestDeposit = dep
                    , requestSubmittedAt = sub
                    , requestDestination = (da, dh)
                    }
        _ ->
            error
                "unsafeFromBuiltinData:\
                \ OnChainRequest"

instance ToData OnChainTokenState where
    toBuiltinData OnChainTokenState{..} =
        mkD $
            Constr
                0
                [ unD (toBuiltinData stateRoot)
                , I stateMaxFee
                , I stateProcessTime
                , I stateRetractTime
                , bbsToD stateAppPolicy
                , bbsToD stateActivePolicy
                , bbsToD stateAbsentPolicy
                , bbsToD stateTerminalPolicy
                ]

instance FromData OnChainTokenState where
    fromBuiltinData bd = case unD bd of
        Constr 0 [r, I mf, I pt, I rt, ap, cp, bp, tp] -> do
            stateRoot <- fromBuiltinData (mkD r)
            stateAppPolicy <- bbsFromD ap
            stateActivePolicy <- bbsFromD cp
            stateAbsentPolicy <- bbsFromD bp
            stateTerminalPolicy <- bbsFromD tp
            let stateMaxFee = mf
                stateProcessTime = pt
                stateRetractTime = rt
            Just OnChainTokenState{..}
        _ -> Nothing

instance UnsafeFromData OnChainTokenState where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [r, I mf, I pt, I rt, ap, cp, bp, tp] ->
            case (bbsFromD ap, bbsFromD cp, bbsFromD bp, bbsFromD tp) of
                (Just appP, Just activeP, Just absentP, Just terminalP) ->
                    OnChainTokenState
                        { stateRoot =
                            unsafeFromBuiltinData (mkD r)
                        , stateMaxFee = mf
                        , stateProcessTime = pt
                        , stateRetractTime = rt
                        , stateAppPolicy = appP
                        , stateActivePolicy = activeP
                        , stateAbsentPolicy = absentP
                        , stateTerminalPolicy = terminalP
                        }
                _ ->
                    error
                        "unsafeFromBuiltinData:\
                        \ OnChainTokenState.policies"
        _ ->
            error
                "unsafeFromBuiltinData:\
                \ OnChainTokenState"

{- | Pinned-hook consumer redeemer (NOTE-021): a nullary hook. The
consumer authenticates the batch from the transaction's own evidence
(spent state, request datums, naming claims, mint field) — the redeemer
carries nothing because nothing caller-supplied is trusted. Encodes as
@Constr 0 []@.
-}
data ConsumerRedeemer
    = Hook
    deriving stock (Show, Eq)

instance ToData ConsumerRedeemer where
    toBuiltinData Hook = mkD $ Constr 0 []

instance ToData CageDatum where
    toBuiltinData (RequestDatum r) =
        mkD $
            Constr 0 [unD (toBuiltinData r)]
    toBuiltinData (StateDatum s) =
        mkD $
            Constr 1 [unD (toBuiltinData s)]
    toBuiltinData (AbsentCustody refund) =
        mkD $
            Constr 2 [bsToD refund]

instance FromData CageDatum where
    fromBuiltinData bd = case unD bd of
        Constr 0 [d] ->
            RequestDatum
                <$> fromBuiltinData (mkD d)
        Constr 1 [d] ->
            StateDatum
                <$> fromBuiltinData (mkD d)
        Constr 2 [refund] ->
            AbsentCustody <$> bsFromD refund
        _ -> Nothing

instance UnsafeFromData CageDatum where
    unsafeFromBuiltinData bd = case unD bd of
        Constr 0 [d] ->
            RequestDatum $
                unsafeFromBuiltinData (mkD d)
        Constr 1 [d] ->
            StateDatum $
                unsafeFromBuiltinData (mkD d)
        Constr 2 [B refund] -> AbsentCustody refund
        _ -> error "unsafeFromBuiltinData: CageDatum"

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
