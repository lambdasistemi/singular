{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.State.Lineage
Description : A registry's trie rebuilt from the public history of its state token
License     : Apache-2.0

The chain commits a registry's trie by its root only. This module rebuilds the
trie itself from the transactions that moved the registry's state token since
its genesis, so a folder needs nothing from the person who booked.

The lineage is read in the order the history gives it, creator before spender.
The genesis mints the token under the state policy with the seed in its
redeemer, spends that seed and writes the empty root; each fold spends the
current state output with the redeemer of a fold and writes the root of the
trie with its keys. A transaction whose bytes say it failed its scripts spent
only its collateral and is never in the lineage. After every fold the rebuilt
root must equal the root in the new state output, wherever in the transaction
that output sits.
-}
module Singular.State.Lineage
    ( Replayed (..)
    , replayRegistry
    , registryTrieState
    , registryAsset
    ) where

import Control.Monad (unless, when)
import Control.Monad.State.Strict (execState)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List (elemIndex)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))
import MPF.Backend.Pure (MPFInMemoryDB, emptyMPFInMemoryDB)
import PlutusCore.Data qualified as PLC

import Cardano.Crypto.Hash (hashFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Ledger (ConwayEra, Root (..), TxOut)
import Singular.Registry.LedgerProvider (Session (..))
import Singular.Registry.Trie.Pure (rootFromDb, stateTrie)
import Singular.Registry.TrieState
    ( Incomplete (..)
    , Mismatch (..)
    , Parting (..)
    , PublicLineage (..)
    , RegistryIdentity (..)
    , Staleness (..)
    , StatePoint (..)
    , StatePolicyId (..)
    , TrieFailure (..)
    , TrieSelection (..)
    , TrieState (..)
    , Undecodable (..)
    )
import Singular.Registry.TrieState.Core (snapshotObserved)
import Singular.Registry.TrieState.Lineage (publicHistory)
import Singular.Registry.TrieState.Types (CompleteFromCreate (..))
import Singular.Registry.TxBuilder.Internal (emptyRoot, walkEdge)
import Singular.Registry.Types (edgeInsertActive, edgeUpdateTerminal)
import Singular.State.Preimage (stateTokenName)
import Singular.State.Records
    ( Change (..)
    , decodeFoldRedeemer
    , decodeGenesisRedeemer
    , decodeStateDatum
    )

-- | A replay that reached the selected state output from the genesis.
data Replayed = Replayed
    { replayedSeed :: TxIn
    -- ^ The seed the genesis spent
    , replayedGenesis :: TxId
    , replayedFolds :: [TxId]
    -- ^ Every fold from the genesis to the selected output, in chain order
    , replayedKeys :: [ByteString]
    -- ^ The distinct keys the folds registered, ascending
    }
    deriving stock (Eq, Show)

{- | Rebuild the registry's trie from the history of its state token up to the
selected state output, and check every root on the way against the root the
chain recorded.
-}
replayRegistry
    :: (Monad m)
    => Session w m
    -> TrieSelection
    -> m (Either TrieFailure (Replayed, MPFInMemoryDB))
replayRegistry session selection
    | pointSession point /= sessionId session
        || pointBinding point /= sessionBinding session =
        pure (Left (StaleState who Nothing NoSelection))
    | otherwise = do
        history <- publicHistory session who
        pure (history >>= walk who selection . snd)
  where
    who = trieSelectionIdentity selection
    point = trieSelectionPoint selection

-- | The registry's trie as a capability, for the registries of this line.
registryTrieState :: (Monad m) => Session w m -> TrieState m
registryTrieState session =
    TrieState
        { withTrieState = \selection use ->
            replayRegistry session selection >>= \case
                Left failure -> pure (Left failure)
                Right (replayed, nodes) ->
                    Right
                        <$> use
                            ( snapshotObserved
                                (const (pure ()))
                                selection
                                nodes
                                (CompleteFromCreate (length (replayedFolds replayed)))
                                (Just (lineageOf replayed))
                            )
        , acceptObservedFold = \_ -> pure (Right ())
        }

lineageOf :: Replayed -> PublicLineage
lineageOf replayed =
    PublicLineage
        (replayedGenesis replayed)
        (replayedFolds replayed)
        (replayedKeys replayed)

-- | Where the walk stands: the current state output, its root, the trie and what was folded.
data Standing = Standing
    { standingOutput :: TxIn
    , standingRoot :: Root
    , standingNodes :: MPFInMemoryDB
    , standingFolds :: [TxId]
    -- ^ Newest first
    , standingKeys :: Set.Set ByteString
    }

walk
    :: RegistryIdentity
    -> TrieSelection
    -> [ConwayTx]
    -> Either TrieFailure (Replayed, MPFInMemoryDB)
walk who selection transactions = do
    (genesis, later) <- case break (mintsToken who) valid of
        (_, created : after) -> Right (created, after)
        (_, []) -> Left (HistoryIncomplete who Nothing MissingTransaction)
    (seed, start) <- checkGenesis who genesis
    reached <- go seed start later
    let current = standingOutput reached
        TxIn selectedId (TxIx selectedIx) = selected
        isState =
            or
                [ holdsToken who out
                | tx <- valid
                , txIdTx tx == selectedId
                , out <- take 1 (drop (fromIntegral selectedIx) (outputsOf tx))
                ]
    unless (current == selected) $
        Left
            ( if isState
                then StaleState who Nothing (StaleOutput selected current)
                else WrongRegistry who (Just selectedId) SelectionNotState
            )
    unless (standingRoot reached == trieSelectionRoot selection) $
        Left
            ( StaleState
                who
                Nothing
                (StaleRoot (trieSelectionRoot selection) (standingRoot reached))
            )
    pure
        ( Replayed
            { replayedSeed = seed
            , replayedGenesis = txIdTx genesis
            , replayedFolds = reverse (standingFolds reached)
            , replayedKeys = Set.toAscList (standingKeys reached)
            }
        , standingNodes reached
        )
  where
    selected = pointOutput (trieSelectionPoint selection)
    valid = filter (\tx -> tx ^. isValidTxL == IsValid True) transactions
    go seed standing remaining
        | standingOutput standing == selected = Right standing
        | otherwise = case remaining of
            [] -> Right standing
            tx : more
                | standingOutput standing `elem` spendingInputs tx ->
                    foldStep who seed standing tx >>= \next -> go seed next more
                | touchesToken who tx ->
                    Left (HistoryIncomplete who (Just (txIdTx tx)) OutsideLineage)
                | otherwise -> go seed standing more

-- | The genesis: the seed it names and the state it leaves.
checkGenesis
    :: RegistryIdentity -> ConwayTx -> Either TrieFailure (TxIn, Standing)
checkGenesis who@(RegistryIdentity _ name) tx = do
    policy <-
        maybe
            (Left (WrongRegistry who (Just tid) UnknownRegistry))
            Right
            (policyOf who)
    let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
        quantity =
            Map.findWithDefault
                0
                name
                (Map.findWithDefault Map.empty policy minted)
    unless (quantity == 1) $
        Left (WrongRegistry who (Just tid) CreateMint)
    policyIx <-
        maybe
            (Left (WrongRegistry who (Just tid) CreateMint))
            Right
            (elemIndex policy (Map.keys minted))
    datum <-
        maybe
            (Left (UndecodableRequest who (Just tid) MissingRedeemer))
            Right
            (redeemerAt (ConwayMinting (AsIx (fromIntegral policyIx))) tx)
    seed <-
        maybe
            ( Left
                ( UndecodableRequest
                    who
                    (Just tid)
                    (UnreadableRecord "the mint redeemer is not a genesis")
                )
            )
            Right
            (decodeGenesisRedeemer datum)
    unless (seed `elem` spendingInputs tx) $
        Left (WrongRegistry who (Just tid) SeedNotSpent)
    unless (stateTokenName seed == name) $
        Left (WrongRegistry who (Just tid) SeedName)
    (output, root, address) <- stateOutput who tx
    unless (isStateAddress policy address) $
        Left (WrongRegistry who (Just tid) CreateOutput)
    unless (root == emptyRoot) $
        Left
            ( RootDoesNotChain
                who
                (Just tid)
                (RootsPart (Root emptyRoot) (Root root))
            )
    pure
        ( seed
        , Standing output (Root root) emptyMPFInMemoryDB [] Set.empty
        )
  where
    tid = txIdTx tx

-- | One fold: the redeemer of the state input, the keys it registers, the new state output.
foldStep
    :: RegistryIdentity
    -> TxIn
    -> Standing
    -> ConwayTx
    -> Either TrieFailure Standing
foldStep who seed standing tx = do
    let tid = txIdTx tx
        undecodable = Left . UndecodableRequest who (Just tid)
    index <-
        maybe
            (Left (HistoryIncomplete who (Just tid) NoStateInput))
            Right
            (elemIndex (standingOutput standing) (spendingInputs tx))
    datum <-
        maybe
            (undecodable MissingRedeemer)
            Right
            (redeemerAt (ConwaySpending (AsIx (fromIntegral index))) tx)
    (named, changes) <-
        maybe
            (undecodable (UnreadableRecord "the spend redeemer is not a fold"))
            Right
            (decodeFoldRedeemer datum)
    unless (named == seed) $ Left (WrongRegistry who (Just tid) SeedName)
    let edges = map changed changes
        keys = map fst edges
    (output, root, _) <- stateOutput who tx
    let nodes = foldl applyEdge (standingNodes standing) edges
        rebuilt = rootFromDb nodes
    when (rebuilt /= Root root) $
        Left (RootDoesNotChain who (Just tid) (RootsPart rebuilt (Root root)))
    pure
        Standing
            { standingOutput = output
            , standingRoot = Root root
            , standingNodes = nodes
            , standingFolds = tid : standingFolds standing
            , standingKeys = foldr Set.insert (standingKeys standing) keys
            }
  where
    changed = \case
        Register{changeKey} -> (changeKey, edgeInsertActive)
        Terminate{changeKey} -> (changeKey, edgeUpdateTerminal)
    applyEdge nodes (key, edge) =
        execState (walkEdge stateTrie key edge) nodes

{- | The one output of the transaction that holds the state token, with the
root its inline datum carries and the address it sits at.
-}
stateOutput
    :: RegistryIdentity
    -> ConwayTx
    -> Either TrieFailure (TxIn, ByteString, Addr)
stateOutput who tx = case holders of
    [(ix, out)] -> do
        root <-
            maybe
                (Left (UndecodableRequest who (Just tid) UndecodableStateOutput))
                Right
                (inlineDatum out >>= decodeStateDatum)
        pure (TxIn tid (TxIx ix), root, out ^. addrTxOutL)
    _ -> Left (UndecodableRequest who (Just tid) UndecodableStateOutput)
  where
    tid = txIdTx tx
    holders =
        [ (ix, out)
        | (ix, out) <- zip [0 ..] (outputsOf tx)
        , holdsToken who out
        ]

-- | The inline datum of an output.
inlineDatum :: TxOut ConwayEra -> Maybe PLC.Data
inlineDatum out = case out ^. datumTxOutL of
    Datum binary -> Just (getPlutusData (binaryDataToData binary))
    _ -> Nothing

-- | Whether the address is the one of the state script of this policy.
isStateAddress :: PolicyID -> Addr -> Bool
isStateAddress (PolicyID hash) = \case
    Addr _ (ScriptHashObj h) _ -> h == hash
    _ -> False

{- | The state token of a registry as a ledger asset, when its policy is a
script hash.
-}
registryAsset :: RegistryIdentity -> Maybe (PolicyID, AssetName)
registryAsset who@(RegistryIdentity _ name) = (,name) <$> policyOf who

policyOf :: RegistryIdentity -> Maybe PolicyID
policyOf (RegistryIdentity (StatePolicyId bytes) _) =
    PolicyID . ScriptHash <$> hashFromBytes bytes

mintsToken :: RegistryIdentity -> ConwayTx -> Bool
mintsToken who tx = case registryAsset who of
    Nothing -> False
    Just (policy, name) ->
        let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
        in  Map.findWithDefault
                0
                name
                (Map.findWithDefault Map.empty policy minted)
                /= 0

holdsToken :: RegistryIdentity -> TxOut ConwayEra -> Bool
holdsToken who out = case registryAsset who of
    Nothing -> False
    Just (policy, name) ->
        let MaryValue _ (MultiAsset assets) = out ^. valueTxOutL
        in  Map.findWithDefault
                0
                name
                (Map.findWithDefault Map.empty policy assets)
                == 1

touchesToken :: RegistryIdentity -> ConwayTx -> Bool
touchesToken who tx = mintsToken who tx || any (holdsToken who) (outputsOf tx)

outputsOf :: ConwayTx -> [TxOut ConwayEra]
outputsOf tx = toList (tx ^. bodyTxL . outputsTxBodyL)

-- | The spending inputs in ledger order.
spendingInputs :: ConwayTx -> [TxIn]
spendingInputs tx = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)

-- | A redeemer of the transaction, as data.
redeemerAt
    :: ConwayPlutusPurpose AsIx ConwayEra -> ConwayTx -> Maybe PLC.Data
redeemerAt purpose tx = do
    let Redeemers declared = tx ^. witsTxL . rdmrsTxWitsL
    (datum, _) <- Map.lookup purpose declared
    pure (getPlutusData datum)
