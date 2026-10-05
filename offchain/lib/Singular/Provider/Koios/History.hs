{-# LANGUAGE LambdaCase #-}

{- | Complete blocks over the shared client's deferred pages. Asset spend
dependencies determine replay order; unrelated funding stays outside it.
-}
module Singular.Provider.Koios.History (assetHistory) where

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, valueTxOutL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Control.Monad (unless)
import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Word (Word64)
import Lens.Micro ((^.))
import Singular.Provider.Koios.Client qualified as Client
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.LedgerProvider

{- | Start only the listing's first page. Material for a complete block is
read when its continuation is consumed, with at most one lookahead page.
-}
assetHistory
    :: (Monad m)
    => Client.Koios m
    -> Asset
    -> HistoryRange
    -> m (Either HistoryFailure (HistoryStream m))
assetHistory client asset range = do
    firstPage <- uncurry (Client.assetTxsPage client) asset
    pure $
        first readFailure firstPage >>= \page ->
            Right
                (stream Set.empty [] (Client.pageRows page) (Client.nextPage page))
  where
    stream spent previous rows more = HistoryStream $ runExceptT $ do
        available <- fill rows more
        case available of
            Nothing -> pure Nothing
            Just (rows', more') -> do
                let firstRow = NE.head rows'
                    height = Wire.assetTxBlockHeight firstRow
                case previous of
                    h : _ | height <= h -> throwError (HistoryOrderMismatch h height)
                    _ -> pure ()
                if maybe False (height >) (throughHeight range)
                    then pure Nothing
                    else do
                        (blockRows, remaining, continuation) <-
                            whole height [] (NE.toList rows') more'
                        if maybe False (height <) (fromHeight range)
                            then
                                ExceptT (nextBlock (stream spent [height] remaining continuation))
                            else do
                                complete <- case NE.nonEmpty blockRows of
                                    Nothing ->
                                        throwError
                                            (HistoryMaterialMismatch (Wire.assetTxId firstRow) "empty block")
                                    Just nonempty -> pure nonempty
                                block <- reconstruct client asset height complete
                                let inputs =
                                        concatMap
                                            (map fst . spentOutputs)
                                            (filter scriptValid (NE.toList (blockTransactions block)))
                                spent' <- ExceptT . pure $ foldInputs spent inputs
                                pure (Just (block, stream spent' [height] remaining continuation))

    fill [] Nothing = pure Nothing
    fill [] (Just action) = do
        page <- ExceptT (fmap (first readFailure) action)
        fill (Client.pageRows page) (Client.nextPage page)
    fill (row : rows) more = pure (Just (row NE.:| rows, more))

    whole height acc rows more = do
        let (here, rest) = span ((== height) . Wire.assetTxBlockHeight) rows
            acc' = acc <> here
        case rest of
            _ : _ -> pure (acc', rest, more)
            [] ->
                fill [] more >>= \case
                    Nothing -> pure (acc', [], Nothing)
                    Just (nextRows, nextMore) -> whole height acc' (NE.toList nextRows) nextMore

readFailure :: Client.ClientFailure -> HistoryFailure
readFailure = HistoryReadFailure . BackendReadFailure . Text.pack . show

foldInputs
    :: Set.Set TxIn -> [TxIn] -> Either HistoryFailure (Set.Set TxIn)
foldInputs = foldl step . Right
  where
    step result input = do
        seen <- result
        if Set.member input seen
            then Left (DuplicateSpend input)
            else Right (Set.insert input seen)

reconstruct
    :: (Monad m)
    => Client.Koios m
    -> Asset
    -> Word64
    -> NE.NonEmpty Wire.AssetTx
    -> ExceptT HistoryFailure m HistoryBlock
reconstruct client asset height rows = do
    let ids = map Wire.assetTxId (NE.toList rows)
        firstId = Wire.assetTxId (NE.head rows)
    unless (length ids == Set.size (Set.fromList ids)) $
        throwError
            (HistoryMaterialMismatch firstId "duplicate transaction in listing")
    infos <- ExceptT (fmap (first readFailure) (Client.txInfo client ids))
    let known = Map.fromList [(Wire.txInfoId info, info) | info <- infos]
        dependencies info =
            [ parent
            | (TxIn parent _, output) <- Wire.txInfoInputs info
            , holds asset output
            ]
    -- Only missing asset-carrying creators are looked up. In particular a
    -- same-block funding creator without the asset causes no extra request.
    forInputs <- traverse (checkParents known dependencies) infos
    ordered <- ExceptT . pure $ topological forInputs
    cbors <-
        ExceptT
            ( fmap
                (first readFailure)
                (Client.txCbor client (map Wire.txInfoId ordered))
            )
    material <-
        ExceptT . pure $ traverse (uncurry materialOf) (zip ordered cbors)
    let allOutputs = Map.fromList (concatMap createdOutputs material)
    mapM_ (checkResolved allOutputs) material
    case NE.nonEmpty material of
        Nothing -> throwError (HistoryMaterialMismatch firstId "empty block")
        Just transactions -> pure (HistoryBlock height transactions)
  where
    checkParents known dependencies info = do
        unless (Wire.txInfoBlockHeight info == height) $
            throwError
                ( HistoryMaterialMismatch
                    (Wire.txInfoId info)
                    "listing and transaction heights disagree"
                )
        let absent =
                Set.toList (Set.fromList (dependencies info) Set.\\ Map.keysSet known)
        parents <-
            if null absent
                then pure []
                else ExceptT (fmap (first readFailure) (Client.txInfo client absent))
        mapM_
            ( \parent ->
                unless (Wire.txInfoBlockHeight parent < height) $
                    throwError
                        (MissingInBlockParent (Wire.txInfoId info) (Wire.txInfoId parent))
            )
            parents
        -- An asset-carrying creator outside this block can be outside the
        -- requested height range. Check its actual body without adding a row
        -- or fetching unrelated funding/collateral/fee creators.
        parentBodies <-
            if null absent
                then pure []
                else ExceptT (fmap (first readFailure) (Client.txCbor client absent))
        mapM_ (checkEarlierParent info) parentBodies
        pure
            ( info
            , Set.fromList (dependencies info) `Set.intersection` Map.keysSet known
            )
    checkEarlierParent info parent = do
        let key = Wire.txCborId parent
            produced =
                Map.fromList
                    ( zipWith
                        (\index output -> (TxIn key (TxIx index), output))
                        [0 ..]
                        (toList (Wire.txCborTx parent ^. bodyTxL . outputsTxBodyL))
                    )
        mapM_
            ( \(reference@(TxIn creator _), output) ->
                if creator == key && holds asset output
                    then
                        unless
                            ( Wire.txCborValid parent
                                && Map.lookup reference produced == Just output
                            )
                            $ throwError
                                ( HistoryMaterialMismatch
                                    (Wire.txInfoId info)
                                    "resolved earlier asset output"
                                )
                    else pure ()
            )
            (Wire.txInfoInputs info)

{- | Deterministic Kahn order. Hash order breaks ties only among transactions
whose selected-asset ancestors have already been emitted.
-}
topological
    :: [(Wire.TxInfo, Set.Set TxId)] -> Either HistoryFailure [Wire.TxInfo]
topological = go []
  where
    go done [] = Right (reverse done)
    go done remaining =
        case sortOn (Wire.txInfoId . fst) (filter (Set.null . snd) remaining) of
            [] ->
                Left
                    ( HistoryDependencyCycle
                        (NE.fromList (map (Wire.txInfoId . fst) remaining))
                    )
            (info, _) : _ ->
                let key = Wire.txInfoId info
                in  go
                        (info : done)
                        [ (other, Set.delete key parents)
                        | (other, parents) <- remaining
                        , Wire.txInfoId other /= key
                        ]

holds :: Asset -> TxOut ConwayEra -> Bool
holds (policy, name) output =
    let MaryValue _ (MultiAsset assets) = output ^. valueTxOutL
    in  Map.findWithDefault
            0
            name
            (Map.findWithDefault Map.empty policy assets)
            /= 0

materialOf
    :: Wire.TxInfo
    -> Wire.TxCbor
    -> Either HistoryFailure HistoricalTransaction
materialOf info cbor = do
    let tx = Wire.txCborTx cbor
        body = tx ^. bodyTxL
        key = Wire.txInfoId info
        refuse message = Left (HistoryMaterialMismatch key message)
        produced =
            zipWith
                (\index output -> (TxIn key (TxIx index), output))
                [0 ..]
                (toList (body ^. outputsTxBodyL))
        exactInputs outputs refs =
            length outputs == Set.size refs
                && Set.fromList (map fst outputs) == refs
    unless
        (key == Wire.txCborId cbor)
        (refuse "CBOR transaction identity")
    unless
        (Wire.txInfoValid info == Wire.txCborValid cbor)
        (refuse "script validity")
    unless
        (exactInputs (Wire.txInfoInputs info) (body ^. inputsTxBodyL))
        (refuse "spent input references")
    unless
        ( exactInputs
            (Wire.txInfoReferenceInputs info)
            (body ^. referenceInputsTxBodyL)
        )
        (refuse "reference input references")
    unless
        ( Map.fromList produced == Map.fromList (Wire.txInfoOutputs info)
            && length produced == length (Wire.txInfoOutputs info)
        )
        (refuse "produced outputs")
    pure
        HistoricalTransaction
            { historicalId = key
            , historicalCbor = Wire.txCborBytes cbor
            , historicalTx = tx
            , spentOutputs = Wire.txInfoInputs info
            , referenceOutputs = Wire.txInfoReferenceInputs info
            , createdOutputs = produced
            , scriptValid = Wire.txCborValid cbor
            }

checkResolved
    :: (Monad m)
    => Map.Map TxIn (TxOut ConwayEra)
    -> HistoricalTransaction
    -> ExceptT HistoryFailure m ()
checkResolved allOutputs transaction =
    mapM_ check (spentOutputs transaction <> referenceOutputs transaction)
  where
    check (reference, output) = case Map.lookup reference allOutputs of
        Just created
            | created /= output ->
                throwError
                    ( HistoryMaterialMismatch
                        (historicalId transaction)
                        "resolved in-block output"
                    )
        _ -> pure ()
