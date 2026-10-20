{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.TxBuilder.Update
Description : Update token transaction — the public fold facade
License     : Apache-2.0

Builds the oracle update transaction that folds the registry's booked
requests: every one the library settles, or a chosen non-empty set of them
('updateTokenSelected'). It consumes the State UTxO and exactly the settled
requests, states one proof per request through the trie, burns the
trie-ready tags, delivers each registration's carrier and donates what the
model owes the treasury; its validity upper bound is the earliest deadline
among the registrations it folds.

Every entry point composes the same three owners, in this order:

- discovery of the pending requests by the request policy, through the
  acquired session ('pendingByTag'): a request is an output the policy
  vouches for and whose own datum its tag commits to, nothing is discovered
  by reading the request address, and a legacy untagged request is no member;
- the library's tagged selection ('selectTaggedFold'), which judges each
  pending request against the processing window and the leaf of its key and
  leaves the others pending;
- the lawful fold ('connectedFoldAt'), whose proofs come from the trie the
  entry point names: a manager's speculative trie, or an authenticated
  snapshot whose identity, point and root are checked against the state the
  fold spends.

The fold carries the mints the model owes its members (a registration burns
its application tag and creates its key's singular tag, a termination burns
its key's singular tag) and the scripts those policies pin, found in the
caller's context. Attached business that is the caller's own (a naming claim,
a record output) is built with 'connectedFoldTx' directly.

This module is the fold's public orchestration and its compatibility
surface: the exports every caller imports are re-exported, and the work is
divided among the three owners (#267):

- "Singular.Registry.TxBuilder.Update.Context" — the registry context, its
  queries, the selection and the guard on the built window;
- "Singular.Registry.TxBuilder.Update.Duties" — what the fold's requests owe
  (mints and the scripts they run under);
- "Singular.Registry.TxBuilder.Update.Build" — the evaluation adapter.

No algorithm lives here; each decision has exactly one owner above.
-}
module Singular.Registry.TxBuilder.Update
    ( updateTokenImpl
    , updateTokenWithDuties
    , updateTokenWithTrieState
    , updateTokenSelected
    , emptyRegistryContext
    , RegistryDuties (..)
    , RegistryContext (..)
    , HolderRelease (..)
    , registryDuties
    , NoCtx
    , mkEvalTx
    ) where

import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (TxOut, referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config
    ( CageConfig (..)
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.FoldSelection (Leaf (..))
import Singular.Registry.Ledger
    ( ConwayEra
    , Root (..)
    , TokenId (..)
    , TxIn
    )
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Trie
    ( TrieManager (..)
    )
import Singular.Registry.Trie qualified as Trie
import Singular.Registry.TrieState qualified as TS
import Singular.Registry.TxBuilder.ConnectedFold
    ( ConnectedFoldArgs (..)
    , ConnectedMint (..)
    , FoldProofs
    , bookedMove
    , connectedFoldAt
    , managerProofs
    )
import Singular.Registry.TxBuilder.Internal.Edges
    ( leafAbsent
    , leafActive
    , leafTerminal
    )
import Singular.Registry.TxBuilder.Internal.Identity
import Singular.Registry.TxBuilder.Internal.Lookup
    ( BookedRequest (..)
    , bookedRequestOf
    )
import Singular.Registry.TxBuilder.Update.Build
    ( NoCtx
    , mkEvalTx
    )
import Singular.Registry.TxBuilder.Update.Context
    ( FoldLeaf
    , FoldPlan (..)
    , HolderRelease (..)
    , RegistryContext (..)
    , checkPending
    , emptyRegistryContext
    , guardBuiltWindow
    , planFold
    , queryContext
    )
import Singular.Registry.TxBuilder.Update.Duties
    ( RegistryDuties (..)
    , registryDuties
    , taggedMints
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRegistrationRequest (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )

-- | Build an update-token transaction (fair fee).
updateTokenImpl
    :: CageConfig
    -> Session NoWitness IO
    -> TrieManager IO
    -> TokenId
    -> Addr
    -> IO ConwayTx
updateTokenImpl cfg view tm tid addr =
    updateTokenWithDuties cfg view tm tid addr emptyRegistryContext

{- | Fold the pending requests the library settles, with the mints the model
owes them. The proofs come from the manager's speculative trie.
-}
updateTokenWithDuties
    :: CageConfig
    -> Session NoWitness IO
    -> TrieManager IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> IO ConwayTx
updateTokenWithDuties cfg view tm tid addr ctx0 =
    updateTokenUsing cfg view tid addr ctx0 Nothing (managerSource tm tid)

{- | The current command path obtains its consumed proof bytes and new root
from the selected capability snapshot. Transaction duties and provider reads
remain in the same shared builder as the retained lower-level adapters.
-}
updateTokenWithTrieState
    :: CageConfig
    -> Session NoWitness IO
    -> TS.TrieSnapshot IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> IO ConwayTx
updateTokenWithTrieState = updateTokenFrom Nothing

-- | The snapshot fold over the chosen pending requests, or over every one the library settles.
updateTokenFrom
    :: Maybe (NE.NonEmpty TxIn)
    -> CageConfig
    -> Session NoWitness IO
    -> TS.TrieSnapshot IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> IO ConwayTx
updateTokenFrom selected cfg view snap tid addr ctx0 =
    updateTokenUsing
        cfg
        view
        tid
        addr
        ctx0
        selected
        (snapshotSource cfg tid snap)

{- | Fold the chosen pending requests and no other, from the selected
capability snapshot; the validity upper bound is the earliest deadline among
them.
-}
updateTokenSelected
    :: CageConfig
    -> Session NoWitness IO
    -> TS.TrieSnapshot IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> NE.NonEmpty TxIn
    -> IO ConwayTx
updateTokenSelected cfg view snap tid addr ctx0 selected =
    updateTokenFrom (Just selected) cfg view snap tid addr ctx0

{- | Where a fold's trie facts come from: the leaf of each key the selection
judges and the proofs the fold states, both from the same trie, and the check
that this trie speaks for the state output the fold spends.
-}
data TrieSource = TrieSource
    { admitState :: (TxIn, TxOut ConwayEra) -> IO ()
    , leavesOf :: [ByteString] -> IO (Map.Map ByteString FoldLeaf)
    , proofsOf :: FoldProofs
    , trieHandle :: TrieManager IO
    -- ^ What 'ConnectedFoldArgs' names; read by nothing when the proofs are supplied
    }

{- | A manager's speculative trie: whatever is done to it is discarded. The
trie says whether it holds a key but not the leaf it holds, so the leaf is
the model's leaf that replaces itself without moving the root.
-}
managerSource :: TrieManager IO -> TokenId -> TrieSource
managerSource tm tid =
    TrieSource
        { admitState = const (pure ())
        , leavesOf = \keys ->
            withSpeculativeTrie tm tid $ \trie ->
                Map.fromList <$> traverse (\key -> (,) key <$> leafIn trie key) keys
        , proofsOf = managerProofs tm tid
        , trieHandle = tm
        }
  where
    leafIn trie key =
        Trie.lookup trie key >>= \case
            Nothing -> pure LeafUnknown
            Just _ -> do
                before <- Trie.getRoot trie
                let holds (leaf, bytes) rest = do
                        _ <- Trie.delete trie key
                        after <- Trie.insert trie key bytes
                        if after == before then pure leaf else rest
                holds (LeafActive, leafActive) $
                    holds (LeafTerminal, leafTerminal) $
                        holds (LeafAbsent, leafAbsent) $
                            error "updateToken: a key's leaf is none the model writes"

{- | An authenticated snapshot: it must be this registry's, taken at the state
output the fold spends, with the root that output carries; its proofs are the
speculative walk of the settled requests' edges.
-}
snapshotSource
    :: CageConfig -> TokenId -> TS.TrieSnapshot IO -> TrieSource
snapshotSource cfg (TokenId name) snap =
    TrieSource
        { admitState = \(stateIn, stateOut) -> do
            when
                (TS.trieIdentity snap /= expected)
                (error "TrieState WrongRegistry")
            when
                (TS.pointOutput (TS.triePoint snap) /= stateIn)
                (error "TrieState StaleState")
            case extractCageDatum stateOut of
                Just (StateDatum state)
                    | unOnChainRoot (stateRoot state) == unRoot (TS.trieRoot snap) ->
                        pure ()
                _ -> error "TrieState StaleState"
        , leavesOf = fmap Map.fromList . traverse leafOfKey
        , proofsOf = \booked -> case NE.nonEmpty (map (bookedMove . snd) booked) of
            Nothing -> error "TrieState UndecodableRequest"
            Just moves ->
                TS.speculateEdges snap moves
                    >>= either
                        (error . ("TrieState " <>) . show)
                        (\walked -> pure (TS.walkProofs walked, TS.walkRoot walked))
        , trieHandle = refusingManager
        }
  where
    expected =
        TS.RegistryIdentity
            (TS.StatePolicyId (scriptHashBytes (cfgScriptHash cfg)))
            name
    leafOfKey key = do
        got <- TS.leafAt snap key
        case got of
            Left why -> error ("TrieState " <> show why)
            Right leaf -> pure (key, leafOfSnapshot leaf)
    leafOfSnapshot TS.Unknown = LeafUnknown
    leafOfSnapshot TS.Absent = LeafAbsent
    leafOfSnapshot TS.Active = LeafActive
    leafOfSnapshot TS.Terminal = LeafTerminal

-- | A manager that serves nothing: the snapshot supplies the proofs.
refusingManager :: TrieManager IO
refusingManager =
    TrieManager
        { withTrie = \_ _ -> refused
        , withSpeculativeTrie = \_ _ -> refused
        , createTrie = const refused
        , deleteTrie = const refused
        , hideTrie = const refused
        , unhideTrie = const refused
        }
  where
    refused :: IO a
    refused =
        ioError
            ( userError
                "updateToken: the snapshot supplies the proofs, no trie manager is read"
            )

updateTokenUsing
    :: CageConfig
    -> Session NoWitness IO
    -> TokenId
    -> Addr
    -> RegistryContext
    -> Maybe (NE.NonEmpty TxIn)
    -- ^ The pending requests to fold; every one the library settles when absent
    -> TrieSource
    -> IO ConwayTx
updateTokenUsing cfg view tid addr ctx0 selected source = do
    (stateUtxo, pending, feeUtxo) <- queryContext cfg view tid addr
    -- the refusals that need no trie come first, as they always did
    checkPending selected pending
    admitState source stateUtxo
    observed <- Services.tip view
    oldState <- case extractCageDatum (snd stateUtxo) of
        Just (StateDatum state) -> pure state
        _ ->
            error
                "updateToken: invalid \
                \state datum"
    plan <-
        planFold
            cfg
            tid
            view
            observed
            (stateProcessTime oldState)
            (leavesOf source)
            selected
            pending
    let settled = planSettled plan
        booked =
            [ (ref, request)
            | (ref, out) <- settled
            , Just request <- [bookedRequestOf cfg tid out]
            ]
    mints <-
        either
            (error . ("updateToken: " <>))
            pure
            (taggedMints cfg ctx0 booked)
    let references = rcRefUtxos ctx0
        carried =
            [ hashScript s
            | (_, o) <- references
            , SJust s <- [o ^. referenceScriptTxOutL]
            ]
        -- with reference outputs every purpose resolves through them; a
        -- script none of them carries is attached, so every purpose resolves
        uncarried =
            [ cmScript m
            | not (null references)
            , m <- mints
            , hashScript (cmScript m) `notElem` carried
            ]
    (tx, _) <-
        connectedFoldAt
            observed
            (proofsOf source)
            ConnectedFoldArgs
                { cfaCfg = cfg
                , cfaSession = view
                , cfaTrie = trieHandle source
                , cfaToken = tid
                , cfaFeeAddr = addr
                , cfaStateUtxo = stateUtxo
                , cfaReqUtxos = settled
                , cfaFeeUtxo = feeUtxo
                , cfaSpends = []
                , cfaMints = mints
                , cfaOutputs = []
                , cfaSigners = []
                , cfaRefUtxos = references
                , cfaAttachScripts = uncarried
                , cfaSkipEval = False
                , cfaAdjustRoot = id
                }
    guardBuiltWindow
        "updateToken"
        view
        (stateProcessTime oldState)
        [(ref, regSubmittedAt r) | (ref, BookedRegistration r) <- booked]
        tx
