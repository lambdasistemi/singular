{- |
Module      : Singular.Registry.FoldAll
Description : Drain pending requests using measured, confirmed batches
License     : Apache-2.0
-}
module Singular.Registry.FoldAll (
    FoldAllArgs (..),
    FoldEvent (..),
    FoldResult (..),
    foldAll,
    renderFoldEvent,
) where

import Control.Exception (throwIO, try)
import Control.Monad (unless)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set

import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.Submitter (SubmitResult (..), Submitter (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Ledger (ConwayEra, Root (..), TokenId)
import Singular.Registry.Node (awaitChain)
import Singular.Registry.Provider (Provider (..))
import Singular.Registry.Trie (Trie (..), TrieManager (..))
import Singular.Registry.TxBuilder.ConnectedFold (
    ConnectedFoldArgs (..),
    FoldBuildFailure (..),
    connectedFoldTx,
    syncFoldedRequests,
 )
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    extractCageDatum,
    findRequestUtxos,
    findStateUtxo,
    requestAddrFromCfg,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainRoot (..),
    OnChainTokenState (..),
 )

{- | A batch attempt and its observable outcome. Only confirmed batches
advance the mirror. Skipped inputs remain on chain for other actions.
-}
data FoldEvent
    = Trying [TxIn]
    | Refused [TxIn] String
    | Confirmed [TxIn] String Root
    | Skipped TxIn String
    deriving stock (Show)

{- | One log line per attempt, with the batch size and transaction identity
when one exists. Build refusals have no transaction to submit.
-}
renderFoldEvent :: FoldEvent -> String
renderFoldEvent event =
    "fold-all: " <> case event of
        Trying is -> "size=" <> show (length is) <> " outcome=trying tx=none"
        Refused is reason -> "size=" <> show (length is) <> " outcome=refused " <> reason
        Confirmed is txid root ->
            "size=" <> show (length is) <> " outcome=confirmed tx=" <> txid <> " root=" <> show root
        Skipped i reason -> "size=1 outcome=skipped input=" <> show i <> " reason=" <> reason

-- | The confirmed transactions and singleton refusals, in processing order.
data FoldResult = FoldResult
    { foldedTransactions :: [ConwayTx]
    , skippedRequests :: [(TxIn, String)]
    }

{- | Chain access and application-specific transaction construction.
The preparer supplies fresh funding and attached actions for exactly the
selected batch. The loop supplies the state, inputs, and proof manager,
and always enables real node evaluation. The signer must preserve the body.
-}
data FoldAllArgs = FoldAllArgs
    { foldConfig :: CageConfig
    , foldProvider :: Provider IO
    , foldTrie :: TrieManager IO
    , foldToken :: TokenId
    , prepareFold ::
        (TxIn, TxOut ConwayEra) ->
        [(TxIn, TxOut ConwayEra)] ->
        IO ConnectedFoldArgs
    , signFold :: ConwayTx -> ConwayTx
    , foldSubmitter :: Submitter IO
    , reportFold :: FoldEvent -> IO ()
    , persistFold :: IO ()
    -- ^ Save the updated mirror after each confirmed batch.
    }

{- | Drain the live queue in input-reference order. Start with all pending
requests, halve a refused batch, then keep the last successful size.
A refused singleton is recorded once and excluded for this invocation.
Provider, funding, signing, confirmation and mirror errors abort the run;
only explicit build/evaluation and node submission refusals are split.
-}
foldAll :: FoldAllArgs -> IO FoldResult
foldAll args = go Nothing Nothing Set.empty [] []
  where
    cfg = foldConfig args
    prov = foldProvider args
    tm = foldTrie args
    tok = foldToken args
    emit = reportFold args
    stateAddr = cageAddrFromCfg cfg (network cfg)
    requestAddr = requestAddrFromCfg cfg tok (network cfg)
    state = do
        us <- queryUTxOs prov stateAddr
        maybe (fail "fold-all: registry state not found") pure $
            findStateUtxo (cagePolicyIdFromCfg cfg) tok us
    rootOf (_, out) = case extractCageDatum out of
        Just (StateDatum s) -> pure (Root (unOnChainRoot (stateRoot s)))
        _ -> fail "fold-all: invalid registry state datum"
    checkRoot u = do
        chain <- rootOf u
        mirror <- withTrie tm tok getRoot
        unless (mirror == chain) $
            fail "fold-all: mirror root differs from confirmed chain root"
    go lastSize retrySize skipped txs failures = do
        current <- state
        checkRoot current
        pending <- sortOn fst . findRequestUtxos tok <$> queryUTxOs prov requestAddr
        let remaining = filter (\(i, _) -> Set.notMember i skipped) pending
            size = fromMaybe (fromMaybe (length remaining) lastSize) retrySize
            batch = take size remaining
            inputs = map fst batch
            refuse reason = do
                emit (Refused inputs reason)
                case inputs of
                    [i] -> do
                        emit (Skipped i reason)
                        go lastSize Nothing (Set.insert i skipped) txs ((i, reason) : failures)
                    [] -> throwIO (FoldBuildFailure "fold-all: empty batch")
                    _ -> go lastSize (Just (max 1 (length inputs `div` 2))) skipped txs failures
        if null remaining
            then pure (FoldResult (reverse txs) (reverse failures))
            else do
                emit (Trying inputs)
                prepared <- prepareFold args current batch
                built <-
                    try @FoldBuildFailure $
                        connectedFoldTx
                            prepared
                                { cfaCfg = cfg
                                , cfaProvider = prov
                                , cfaTrie = tm
                                , cfaToken = tok
                                , cfaStateUtxo = current
                                , cfaReqUtxos = batch
                                , cfaSkipEval = False
                                , cfaAdjustRoot = id
                                }
                case built of
                    Left (FoldBuildFailure reason) -> refuse ("tx=none reason=" <> reason)
                    Right (unsigned, expectedRoot) -> do
                        let signed = signFold args unsigned
                            txid = txIdTx signed
                        result <- submitTx (foldSubmitter args) signed
                        case result of
                            Rejected reason -> refuse ("tx=" <> show txid <> " reason=" <> show reason)
                            Submitted _ -> do
                                confirmed <- awaitChain ("fold-all: confirmation " <> show txid) $ do
                                    us <- queryUTxOs prov stateAddr
                                    pure $ do
                                        u@(TxIn actual _, _) <-
                                            findStateUtxo (cagePolicyIdFromCfg cfg) tok us
                                        if actual == txid then Just u else Nothing
                                actualRoot <- rootOf confirmed
                                unless (actualRoot == expectedRoot) $
                                    fail "fold-all: confirmed root differs from built root"
                                syncFoldedRequests tm tok batch
                                checkRoot confirmed
                                persistFold args
                                emit (Confirmed inputs (show txid) actualRoot)
                                go (Just (length batch)) Nothing skipped (signed : txs) failures
