{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}

{- |
Module      : Singular.Registry.Replay
Description : A registry's trie rebuilt from the public history of its state token
License     : Apache-2.0

The chain commits a registry's trie by its root only. This module rebuilds
the trie itself from the transactions that moved the registry's state
token since @create@, so a reader needs nobody's local copy.

The lineage is chained by spends, never by the order the transactions are
given in: @create@ mints the token under @Minting(seed)@, and each fold
spends the previous state output. A transaction whose bytes say it failed
its scripts (@isValid = false@) spent only its collateral and is never in
the lineage, whatever its body's inputs name. Every fold applies its
requests the way the state validator does
(@onchain\/validators\/registry\/fold.ak@): the spending inputs in ledger
order, an inline 'RequestDatum' naming this registry's token takes the
next action of the state input's @Modify@ redeemer, 'Rejected' leaves the
trie as it is and 'Update' walks the request's edge with 'walkEdge'. After
every fold the rebuilt root must equal the root in that fold's state datum.

The answer is the trie rebuilt into the caller's 'Trie', or one named
'TrieFailure'. On a refusal the caller's trie holds a partial replay and must
be discarded.
-}
module Singular.Registry.Replay
    ( replayLineage
    , Replayed (..)
    ) where

import Control.Monad (foldM, forM_, unless, void, when)
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data (getPlutusData)
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL, valueTxOutL)
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx (FromData (..))
import PlutusTx.Builtins.Internal
    ( BuiltinByteString (..)
    , BuiltinData (..)
    )

import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Ledger (ConwayEra, Root (..))
import Singular.Registry.Trie (Trie (..))
import Singular.Registry.TrieState
    ( Incomplete (..)
    , Mismatch (..)
    , RegistryIdentity (..)
    , Staleness (..)
    , StatePolicyId (..)
    , TrieFailure (..)
    , Undecodable (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( emptyRoot
    , extractCageDatum
    , scriptHashBytes
    , txInToRef
    , walkEdge
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , MintRedeemer (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , OnChainTokenId (..)
    , OnChainTokenState (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    )

-- | A replay that reached the selected state output from @create@.
data Replayed = Replayed
    { replayedCreate :: TxId
    -- ^ The transaction that minted the state token
    , replayedFolds :: [TxId]
    -- ^ Every fold from @create@ to the selected output, in chain order
    }
    deriving stock (Eq, Show)

{- | Rebuild the registry's trie into the given trie, from the history of its
state token up to the selected state output.

The history is the ledger's own transactions, in any order; a transaction
whose bytes say it failed its scripts (@isValid = false@) is left out before
anything else reads the history, since it spent only its collateral. The
map resolves every input they spend or reference. The selection is a state
output and the root the caller expects there.
-}
replayLineage
    :: (Monad m)
    => Trie m
    -- ^ An empty trie the replay fills
    -> RegistryIdentity
    -> TxIn
    -- ^ The selected state output
    -> Root
    -- ^ The root the selection expects at that output
    -> Map TxIn (TxOut ConwayEra)
    -- ^ Resolved spent and reference outputs
    -> [ConwayTx]
    -- ^ The state token's history
    -> m (Either TrieFailure Replayed)
replayLineage trie token selected selection resolved history =
    case lineageOf token selected selection resolved history of
        Left failure -> pure (Left failure)
        Right lineage -> replayFolds trie token lineage

-- ---------------------------------------------------------
-- The lineage, from the selection back to create
-- ---------------------------------------------------------

-- | The chain from @create@ to the selected state output.
data Lineage = Lineage
    { lineageCreate :: TxId
    , lineageCreateRoot :: Root
    , lineageFolds :: [Fold]
    -- ^ In chain order
    , lineageResolve :: TxIn -> Either Incomplete (TxOut ConwayEra)
    }

-- | One fold of the lineage: the transaction, the state output it spends and the root it records.
data Fold = Fold
    { foldId :: TxId
    , foldTx :: ConwayTx
    , foldStateInput :: TxIn
    , foldRoot :: Root
    }

{- | Chain the history by spends from the selected output back to @create@,
then refuse a history that forks a state output, touches the token outside
the lineage, or a selection whose root is not the one at its output.
-}
lineageOf
    :: RegistryIdentity
    -> TxIn
    -> Root
    -> Map TxIn (TxOut ConwayEra)
    -> [ConwayTx]
    -> Either TrieFailure Lineage
lineageOf token selected@(TxIn selectedId selectedIx) selection resolved history = do
    byId <- distinct token (filter passedScripts history)
    let refuse = failWith token
        produced i@(TxIn tid ix) =
            Map.lookup tid byId >>= \tx -> outputAt tx ix >>= \o -> Just (i, o)
        resolve i = case (produced i, Map.lookup i resolved) of
            (Just (_, o), Just o')
                | o /= o' -> Left (ConflictingResolution i)
            (Just (_, o), _) -> Right o
            (Nothing, Just o) -> Right o
            (Nothing, Nothing) -> Left (UnresolvedInput i)
        holds = holdsToken token
        walk tx tid folds
            | mintsToken token tx = do
                createRoot <- checkCreate token tid tx
                pure (tid, createRoot, folds)
            | otherwise = do
                spent <-
                    traverse
                        ( \i ->
                            either
                                (refuse tid . because HistoryIncomplete)
                                (pure . (i,))
                                (resolve i)
                        )
                        (spendingInputs tx)
                root <- stateRootOf token tid tx
                case [i | (i, o) <- spent, holds o] of
                    [stateIn@(TxIn previousId _)] -> do
                        previous <-
                            maybe
                                (refuse previousId (because HistoryIncomplete MissingTransaction))
                                pure
                                (Map.lookup previousId byId)
                        unless (stateIn == firstOutput previousId) $
                            refuse previousId (because UndecodableRequest UndecodableStateOutput)
                        walk previous previousId (Fold tid tx stateIn root : folds)
                    _ -> refuse tid (because HistoryIncomplete NoStateInput)
    selectedTx <-
        maybe
            (refuse selectedId (because HistoryIncomplete MissingTransaction))
            pure
            (Map.lookup selectedId byId)
    let selectsState =
            selectedIx == TxIx 0
                && maybe False holds (outputAt selectedTx selectedIx)
    unless selectsState $
        refuse selectedId (because WrongRegistry SelectionNotState)
    (createId, createRoot, folds) <- walk selectedTx selectedId []
    let chain = createId : map foldId folds
        spenders = spentBy byId
        stateOutputs = map firstOutput (init chain)
    -- Every state output of the lineage is spent by its next fold only.
    forM_ (zip stateOutputs (drop 1 chain)) $ \(output, next) ->
        case filter (/= next) (Map.findWithDefault [] output spenders) of
            [] -> pure ()
            other : _ ->
                refuse other (because HistoryIncomplete (ForkedStateOutput output))
    -- Past the selection, the history may run ahead along one chain.
    ahead <- descendants refuse spenders byId token selected
    let known = Set.fromList (chain <> ahead)
        touching tid tx =
            Set.notMember tid known
                && ( mintsToken token tx
                        || any holds (outputs tx)
                        || any (either (const False) holds . resolve) (spendingInputs tx)
                   )
    case [tid | (tid, tx) <- Map.toAscList byId, touching tid tx] of
        [] -> pure ()
        stray : _ -> refuse stray (because HistoryIncomplete OutsideLineage)
    recorded <- stateRootOf token selectedId selectedTx
    when (recorded /= selection) $
        refuse selectedId (because StaleState (StaleRoot selection recorded))
    pure
        Lineage
            { lineageCreate = createId
            , lineageCreateRoot = createRoot
            , lineageFolds = folds
            , lineageResolve = resolve
            }

-- | The history by transaction identifier; two different transactions under one identifier refuse.
distinct
    :: RegistryIdentity
    -> [ConwayTx]
    -> Either TrieFailure (Map TxId ConwayTx)
distinct token = foldM add Map.empty
  where
    add acc tx =
        let tid = txIdTx tx
        in  case Map.lookup tid acc of
                Just seen
                    | seen /= tx ->
                        failWith token tid (because HistoryIncomplete ConflictingCopies)
                _ -> Right (Map.insert tid tx acc)

{- | The transactions that continue the chain past the selected output: each
spends the previous state output, one at a time. Two spenders of one output
there refuse, naming the larger identifier: neither is on the lineage.
-}
descendants
    :: (TxId -> Refuse -> Either TrieFailure [TxId])
    -> Map TxIn [TxId]
    -> Map TxId ConwayTx
    -> RegistryIdentity
    -> TxIn
    -> Either TrieFailure [TxId]
descendants refuse spenders byId token = go
  where
    go output = case Map.findWithDefault [] output spenders of
        [] -> pure []
        [next] -> case Map.lookup next byId of
            Just tx
                | maybe False (holdsToken token) (outputAt tx (TxIx 0)) ->
                    (next :) <$> go (firstOutput next)
            _ -> pure [next]
        _ : other : _ ->
            refuse other (because HistoryIncomplete (ForkedStateOutput output))

-- | Which transactions of the history spend each output.
spentBy :: Map TxId ConwayTx -> Map TxIn [TxId]
spentBy byId =
    Map.fromListWith
        (flip (<>))
        [(i, [tid]) | (tid, tx) <- Map.toAscList byId, i <- spendingInputs tx]

{- | @create@: it mints exactly one of the token under @Minting(seed)@, spends
the seed, names the token @assetName(seed)@, and its first output is the
state address holding the token. Answers the root its state datum records.
-}
checkCreate
    :: RegistryIdentity -> TxId -> ConwayTx -> Either TrieFailure Root
checkCreate token@(RegistryIdentity _ (AssetName name)) tid tx = do
    let refuse = failWith token tid . because WrongRegistry
        MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
    unless (quantityIn token minted == 1) $ refuse CreateMint
    seed <- case List.findIndex (isPolicyOf token) (Map.keys minted) of
        Just ix
            | Just (Minting seed) <-
                redeemerAt (ConwayMinting (AsIx (fromIntegral ix))) tx ->
                pure seed
        _ -> refuse CreateMint
    unless (any ((== seed) . txInToRef) (spendingInputs tx)) $
        refuse SeedNotSpent
    unless (deriveAssetName seed == SBS.fromShort name) $ refuse SeedName
    case outputAt tx (TxIx 0) of
        Just o
            | holdsToken token o
            , Addr _ (ScriptHashObj h) _ <- o ^. addrTxOutL
            , isPolicyOf token (PolicyID h) ->
                pure ()
        _ -> refuse CreateOutput
    stateRootOf token tid tx

-- ---------------------------------------------------------
-- Replaying the folds
-- ---------------------------------------------------------

{- | Check @create@'s root against the empty trie, then apply each fold's
actions in chain order and check its root. The first mismatch refuses.
-}
replayFolds
    :: (Monad m)
    => Trie m
    -> RegistryIdentity
    -> Lineage
    -> m (Either TrieFailure Replayed)
replayFolds trie token Lineage{..} = do
    start <- getRoot trie
    if start /= emptyTrieRoot || lineageCreateRoot /= emptyTrieRoot
        then
            pure $
                failWith
                    token
                    lineageCreate
                    (chained start lineageCreateRoot)
        else go lineageFolds
  where
    go [] = pure (Right (Replayed lineageCreate (map foldId lineageFolds)))
    go (fold@Fold{foldId, foldRoot} : rest) =
        case pairing token lineageResolve fold of
            Left failure -> pure (Left failure)
            Right pairs -> do
                mapM_ (uncurry apply) pairs
                rebuilt <- getRoot trie
                if rebuilt /= foldRoot
                    then pure (failWith token foldId (chained rebuilt foldRoot))
                    else go rest
    apply OnChainRequest{requestKey, requestEdge} = \case
        Update _ -> void (walkEdge trie requestKey requestEdge)
        Rejected -> pure ()

{- | The fold's actions paired with its requests, as the validator pairs them:
the state input's @Modify@ redeemer, and every spending input in ledger
order whose inline datum is a request naming this registry's token.
-}
pairing
    :: RegistryIdentity
    -> (TxIn -> Either Incomplete (TxOut ConwayEra))
    -> Fold
    -> Either TrieFailure [(OnChainRequest, RequestAction)]
pairing token resolve Fold{foldId, foldTx, foldStateInput} = do
    let refuse = failWith token foldId
        inputs = spendingInputs foldTx
    actions <- case List.elemIndex foldStateInput inputs of
        Nothing -> refuse (because HistoryIncomplete NoStateInput)
        Just ix -> case redeemerAt (ConwaySpending (AsIx (fromIntegral ix))) foldTx of
            Nothing -> refuse (because UndecodableRequest MissingRedeemer)
            Just (Modify actions) -> pure actions
            Just _ -> refuse (because UndecodableRequest NotModify)
    resolvedInputs <-
        traverse
            (either (refuse . because HistoryIncomplete) pure . resolve)
            inputs
    let requests =
            [ request
            | o <- resolvedInputs
            , Just (RequestDatum request) <- [extractCageDatum o]
            , requestNames token request
            ]
    unless (length requests == length actions) $
        refuse
            ( because
                UndecodableRequest
                (ActionCount (length actions) (length requests))
            )
    pure (zip requests actions)

-- ---------------------------------------------------------
-- Reading transactions
-- ---------------------------------------------------------

{- | Whether the transaction's own bytes say its scripts passed. One with
@isValid = false@ spent only its collateral: the inputs its body names,
a state output among them, were not spent, so it is not in the lineage.
-}
passedScripts :: ConwayTx -> Bool
passedScripts tx = tx ^. isValidTxL == IsValid True

-- | A refusal about one transaction of the registry's history.
type Refuse = RegistryIdentity -> Maybe TxId -> TrieFailure

failWith :: RegistryIdentity -> TxId -> Refuse -> Either TrieFailure a
failWith token tid refusal = Left (refusal token (Just tid))

-- | A refusal of the given class, for the given reason.
because
    :: (RegistryIdentity -> Maybe TxId -> r -> TrieFailure) -> r -> Refuse
because refusal why token tid = refusal token tid why

-- | A rebuilt root that is not the recorded one: rebuilt, recorded.
chained :: Root -> Root -> Refuse
chained rebuilt recorded token tid = RootDoesNotChain token tid rebuilt recorded

-- | The spending inputs in ledger order.
spendingInputs :: ConwayTx -> [TxIn]
spendingInputs tx = Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)

outputs :: ConwayTx -> [TxOut ConwayEra]
outputs tx = toList (tx ^. bodyTxL . outputsTxBodyL)

outputAt :: ConwayTx -> TxIx -> Maybe (TxOut ConwayEra)
outputAt tx (TxIx ix) = case drop (fromIntegral ix) (outputs tx) of
    o : _ -> Just o
    [] -> Nothing

firstOutput :: TxId -> TxIn
firstOutput tid = TxIn tid (TxIx 0)

-- | The root in the transaction's first output's inline state datum, which must hold the token.
stateRootOf
    :: RegistryIdentity -> TxId -> ConwayTx -> Either TrieFailure Root
stateRootOf token tid tx = case outputAt tx (TxIx 0) of
    Just o
        | holdsToken token o
        , Just (StateDatum state) <- extractCageDatum o ->
            pure (Root (unOnChainRoot (stateRoot state)))
    _ ->
        failWith token tid (because UndecodableRequest UndecodableStateOutput)

holdsToken :: RegistryIdentity -> TxOut ConwayEra -> Bool
holdsToken token o =
    let MaryValue _ (MultiAsset assets) = o ^. valueTxOutL
    in  quantityIn token assets == 1

mintsToken :: RegistryIdentity -> ConwayTx -> Bool
mintsToken token tx =
    let MultiAsset minted = tx ^. bodyTxL . mintTxBodyL
    in  quantityIn token minted /= 0

quantityIn
    :: RegistryIdentity -> Map PolicyID (Map AssetName Integer) -> Integer
quantityIn token@(RegistryIdentity _ name) assets =
    sum
        [ Map.findWithDefault 0 name names
        | (policy, names) <- Map.toList assets
        , isPolicyOf token policy
        ]

-- | Whether a policy is the registry's state policy.
isPolicyOf :: RegistryIdentity -> PolicyID -> Bool
isPolicyOf (RegistryIdentity (StatePolicyId policy) _) (PolicyID h) =
    scriptHashBytes h == policy

-- | Whether a request names this registry's token, as the validator compares it.
requestNames :: RegistryIdentity -> OnChainRequest -> Bool
requestNames (RegistryIdentity _ (AssetName name)) request =
    let OnChainTokenId (BuiltinByteString named) = requestToken request
    in  named == SBS.fromShort name

-- | A redeemer of the transaction, decoded.
redeemerAt
    :: (FromData a)
    => ConwayPlutusPurpose AsIx ConwayEra -> ConwayTx -> Maybe a
redeemerAt purpose tx = do
    let Redeemers redeemers = tx ^. witsTxL . rdmrsTxWitsL
    (datum, _) <- Map.lookup purpose redeemers
    fromBuiltinData (BuiltinData (getPlutusData datum))

-- | The root of the empty trie, which @create@ records.
emptyTrieRoot :: Root
emptyTrieRoot = Root emptyRoot
