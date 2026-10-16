{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Registry.ChainedView
Description : Chain reads answered as if staged transactions had landed
License     : Apache-2.0

A run that stages a whole bundle before anything is signed or sent builds
its later transactions against a chain that does not hold the earlier ones
yet. This module supplies that view: every output query, the asset history
and the mint record are answered as the chain would answer them after a
list of staged transactions had landed in build order — their outputs
present, the references they spend absent — while the tip, the protocol
parameters, the network time, script registration and the session's own
identity and binding stay the chain's.

The answers are pure functions of the staged list and the chain's own
answers; 'chainedSession' is the only effect here. It reads the staged
list once, at acquisition, and decorates one real session with those
answers, so one view stays consistent while the list grows. It knows
ledger transactions and provider reads, nothing of registries, journals
or signers: the staged list's owner is the run that holds it.
-}
module Singular.Registry.ChainedView
    ( StagedTransaction (..)
    , chainedAnswer
    , chainedHistory
    , chainedHistoryStream
    , chainedMintRecord
    , chainedSession
    ) where

import Cardano.Ledger.Alonzo.Tx (IsValid (..))
import Cardano.Ledger.Api.Tx (bodyTxL, isValidTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mintTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (serialize)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (eraProtVerHigh, hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Control.Monad (foldM)
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Word (Word64)
import Lens.Micro ((^.))
import Singular.Registry.Evidence (Evidenced (..))
import Singular.Registry.LedgerProvider
    ( Asset
    , HistoricalTransaction (..)
    , HistoryBlock (..)
    , HistoryFailure (..)
    , HistoryRange (..)
    , HistoryStream (..)
    , MintRecord (..)
    , OutputQuery (..)
    , Outputs
    , ReadFailure (..)
    , Session (..)
    , TipObservation (..)
    )

{- | One transaction staged over a session, with the resolution of every
input it spends and references, against the outputs live before it: the
chain's, plus what earlier staged transactions created, minus what they
spent. The body is the unsigned body as built; its identity is the body's
own hash, fixed before any signature.
-}
data StagedTransaction = StagedTransaction
    { stagedBody :: ConwayTx
    , stagedSpentOutputs :: Outputs
    , stagedReferenceOutputs :: Outputs
    }
    deriving stock (Eq)

-- | How a compound query combines its sub-answers.
data Composed = Union | Intersect

{- | The merge the provider's own compound branch applies before union or
intersection: one map, refusing the moment two sub-answers return the same
reference with different outputs.
-}
mergeOutputs
    :: Outputs -> Either ReadFailure (Map TxIn (TxOut ConwayEra))
mergeOutputs = foldM step Map.empty
  where
    step known (reference, output) = case Map.lookup reference known of
        Just other
            | other /= output -> Left (ConflictingOutput reference)
        _ -> Right (Map.insert reference output known)

{- | The outputs the chain would answer to the query after the staged
transactions landed, given the chain's own answer to the part of the
query the staged transactions do not serve: a reference a staged body
creates is answered without asking the chain, and one a staged body
spends is answered exactly as the chain answers a spent exact reference.
AnyOf and AllOf compose as the real providers compose them — the union of
the sub-answers, and the references present in every sub-answer — with a
refused sub-answer refusing the whole query. Pure in its own right: it
reads nothing and is deterministic given the chain's answers, which
arrive as the @chainAnswer@ argument.
-}
chainedAnswer
    :: (Monad m)
    => [StagedTransaction]
    -> OutputQuery
    -> (OutputQuery -> m (Either ReadFailure Outputs))
    -> m (Either ReadFailure Outputs)
chainedAnswer staged query chainAnswer = answerOver query
  where
    created = createdMap staged
    spent = spentSet staged
    answerOver asked = case asked of
        AtTxIn reference
            | Set.member reference spent ->
                pure (Left (MissingOutput reference))
            | otherwise -> case Map.lookup reference created of
                Just out -> pure (Right [(reference, out)])
                Nothing -> chainAnswer asked
        AnyOf queries -> compose Union queries
        AllOf queries -> compose Intersect queries
        leaf -> do
            chain <- chainAnswer leaf
            pure (fmap (overlaid leaf) chain)
    overlaid leaf found =
        Map.toAscList
            ( Map.union
                (Map.fromList made)
                (Map.fromList kept)
            )
      where
        kept =
            [ pair
            | pair@(reference, _) <- found
            , not (Set.member reference spent)
            ]
        made =
            [ pair
            | pair@(reference, out) <- Map.toAscList created
            , not (Set.member reference spent)
            , selects leaf out
            ]
    compose how queries = go (NE.toList queries) []
      where
        go [] answers = pure (combined answers)
        go (asked : rest) answers = do
            answer <- answerOver asked
            case answer of
                Left failure -> pure (Left failure)
                Right found -> go rest (found : answers)
        combined answers = do
            merged <- mergeOutputs (concat answers)
            pure $ case how of
                Union -> Map.toAscList merged
                Intersect ->
                    [ pair
                    | pair@(reference, _) <- Map.toAscList merged
                    , all (elem reference . map fst) answers
                    ]
    selects which output = case which of
        AtAddress address -> output ^. addrTxOutL == address
        HoldingAsset asset -> holds asset output
        CarryingReferenceScript script ->
            case output ^. referenceScriptTxOutL of
                SJust carried -> hashScript carried == script
                SNothing -> False
        _ -> False

{- | The asset's history blocks followed by one block per staged
transaction that spends or creates an output holding that asset, in
staged order — numbered after the held view's tip height, never after
the visible part of a range-limited answer — and returned only while
their heights fall inside the requested inclusive bounds, each carrying
the material the trie replay needs: the transaction, its bytes, the
outputs it spends, the reference outputs it reads, the outputs it
creates, and whether its scripts passed. Pure.
-}
chainedHistory
    :: [StagedTransaction]
    -> Asset
    -> Word64
    -- ^ the held view's tip height
    -> HistoryRange
    -> [HistoryBlock]
    -> [HistoryBlock]
chainedHistory staged asset tipHeight range chainBlocks =
    chainBlocks
        <> filter (inRange . blockHeight) stagedBlocks
  where
    stagedBlocks = stagedBlocksFrom asset tipHeight staged
    inRange height =
        maybe True (height >=) (fromHeight range)
            && maybe True (height <=) (throughHeight range)

{- | 'chainedHistory' over a deferred stream, honouring the read's range
over the whole decorated history: the chain's own range-limited blocks
as the chain yields them, then the staged blocks — numbered after the
held view's tip height — returned only while their heights fall inside
the requested inclusive bounds. An upstream that ends because of the
range is not a licence to append out-of-range blocks, and a range that
hides the chain's tail never renumbers the staged blocks after it.
-}
chainedHistoryStream
    :: (Monad m)
    => [StagedTransaction]
    -> Asset
    -> Word64
    -- ^ the held view's tip height
    -> HistoryRange
    -> HistoryStream m
    -> HistoryStream m
chainedHistoryStream staged asset tipHeight range = follow
  where
    follow stream = HistoryStream $ do
        step <- nextBlock stream
        pure $ case step of
            Left failure -> Left failure
            Right Nothing -> Right afterChain
            Right (Just (block, rest)) ->
                Right (Just (block, follow rest))
    afterChain =
        case filter (inRange . blockHeight) blocks of
            [] -> Nothing
            first : rest -> Just (first, listStream rest)
    blocks = stagedBlocksFrom asset tipHeight staged
    inRange height =
        maybe True (height >=) (fromHeight range)
            && maybe True (height <=) (throughHeight range)
    listStream = \case
        [] -> HistoryStream (pure (Right Nothing))
        block : rest ->
            HistoryStream (pure (Right (Just (block, listStream rest))))

{- | The mint record of the asset: from the staged transaction that mints
it, when one does — its identity, the inputs it spends, and the supply
after it, counting what the chain already minted — and the chain's own
record for every other asset. Pure.
-}
chainedMintRecord
    :: [StagedTransaction] -> Asset -> Maybe MintRecord -> Maybe MintRecord
chainedMintRecord staged asset chainRecord = case staged of
    [] -> chainRecord
    _ -> case [tx | tx <- staged, minted asset (stagedBody tx) /= 0] of
        [] -> chainRecord
        minting -> Just (recordOf (last minting))
  where
    recordOf mintTx =
        MintRecord
            { mintTransaction = txIdTx (stagedBody mintTx)
            , mintSpentInputs =
                Set.toAscList
                    (stagedBody mintTx ^. bodyTxL . inputsTxBodyL)
            , mintSupply =
                maybe 0 mintSupply chainRecord
                    + sum (map (minted asset . stagedBody) staged)
            }

{- | A session whose reads answer as if the staged transactions read by
@stagedNow@ at acquisition had landed. The staged list is read once, when
this decorator is acquired, so one view stays consistent while the list
grows; every read the staged list does not change goes to the wrapped
session unchanged — the tip, the protocol parameters, the network time,
script registration, the tracer, the session's identity and binding, and
what the local evaluator records. The decorated answers carry no witness:
the chain's witness never covers outputs the chain does not hold. The
only effect in this module.
-}
chainedSession
    :: (Monad m) => m [StagedTransaction] -> Session w m -> m (Session w m)
chainedSession stagedNow session = do
    staged <- stagedNow
    let answering query = do
            found <-
                chainedAnswer
                    staged
                    query
                    (fmap (fmap value) . outputs session)
            pure (fmap (`Evidenced` Nothing) found)
        recording asset = do
            chain <- mintRecord session asset
            pure
                ( fmap
                    ( \evidenced ->
                        Evidenced (chainedMintRecord staged asset (value evidenced)) Nothing
                    )
                    chain
                )
        streaming asset range = do
            tip <- tipObservation session
            supplied <- history session asset range
            pure $ case (tip, supplied) of
                (Left failure, _) -> Left (HistoryReadFailure failure)
                (_, Left failure) -> Left failure
                (Right tipFact, Right stream) ->
                    Right
                        ( chainedHistoryStream
                            staged
                            asset
                            (observedHeight (value tipFact))
                            range
                            stream
                        )
    pure
        session
            { outputs = answering
            , mintRecord = recording
            , history = streaming
            }

-- ---------------------------------------------------------
-- The overlay the answers are computed over
-- ---------------------------------------------------------

createdMap :: [StagedTransaction] -> Map TxIn (TxOut ConwayEra)
createdMap =
    foldr
        (Map.union . Map.fromList . createdOf)
        Map.empty

spentSet :: [StagedTransaction] -> Set TxIn
spentSet =
    foldr
        ( \staged soFar ->
            Set.union (stagedBody staged ^. bodyTxL . inputsTxBodyL) soFar
        )
        Set.empty

createdOf :: StagedTransaction -> Outputs
createdOf staged =
    zipWith
        (\ix out -> (TxIn (txIdTx (stagedBody staged)) (TxIx ix), out))
        [0 ..]
        (toList (stagedBody staged ^. bodyTxL . outputsTxBodyL))

{- | The staged blocks after the chain's last one, one per staged
transaction that spends or creates an output holding the asset, in staged
order, their heights ascending from the chain's last.
-}
stagedBlocksFrom
    :: Asset -> Word64 -> [StagedTransaction] -> [HistoryBlock]
stagedBlocksFrom asset startHeight staged =
    [ HistoryBlock height (stagedRecord stagedTx :| [])
    | (height, stagedTx) <- zip [startHeight + 1 ..] staged
    , touches asset stagedTx
    ]

stagedRecord :: StagedTransaction -> HistoricalTransaction
stagedRecord staged =
    HistoricalTransaction
        { historicalId = txIdTx body
        , historicalCbor =
            BL.toStrict (serialize (eraProtVerHigh @ConwayEra) body)
        , historicalTx = body
        , spentOutputs = stagedSpentOutputs staged
        , referenceOutputs = stagedReferenceOutputs staged
        , createdOutputs = createdOf staged
        , scriptValid = body ^. isValidTxL == IsValid True
        }
  where
    body = stagedBody staged

touches :: Asset -> StagedTransaction -> Bool
touches asset staged =
    any (holds asset . snd) (stagedSpentOutputs staged)
        || any (holds asset . snd) (createdOf staged)

holds :: Asset -> TxOut ConwayEra -> Bool
holds (policy, name) output = case output ^. valueTxOutL of
    MaryValue _ (MultiAsset assets) ->
        maybe
            False
            ((/= 0) . Map.findWithDefault 0 name)
            (Map.lookup policy assets)

minted :: Asset -> ConwayTx -> Integer
minted (policy, name) tx = case tx ^. bodyTxL . mintTxBodyL of
    MultiAsset assets ->
        maybe
            0
            (Map.findWithDefault 0 name)
            (Map.lookup policy assets)
