{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Singular.CLI.Reconcile
Description : The next command reconciles the journal with the chain
License     : Apache-2.0

The next command reconciles saved signed bodies and journal phases with
an acquired session's chain reads, submitting nothing. Live spent inputs
show rollback; an unresolved transaction's live first output shows inclusion;
an expired upper bound and live input permit exclusion. These decisions
append journal lines and preserve earlier observations.

Key after-states are proved by fresh public-history replay at the live
state output. An included transaction is observed once when its prepared
after-state reads back. No mirror, saved root or journal edge supplies the
trie. Unresolved cases retain their public refusal class and transaction id.
-}
module Singular.CLI.Reconcile
    ( -- * Reconciling
      Reconciliation (..)
    , Recovery (..)
    , reconcile
    , reconcileIncomplete
    , refuseUnreconciled
    , observe
    , observeVerdicts
    , rollBack
    , recoverInclusion
    , KeyRead
    , LiveAt

      -- * Receipts
    , reconciledJson
    , recoveryJson
    , renderPoint
    ) where

import Control.Monad (forM, forM_, when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.Either (isRight, rights)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Core (hashScript)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Cardano.Slotting.Slot qualified as Cage
import Singular.CLI.Live
    ( Saved (..)
    , attachLive
    , liveOutputFor
    , liveOutputs
    , observedRoot
    , requireTrieSelection
    , trieLeaf
    , txInText
    )
import Singular.CLI.Proof (AuthError, Leaf (..))
import Singular.CLI.Receipt
    ( FoldTransition (..)
    , JournalEntry (..)
    , OutcomeClass (..)
    , SubmissionCase (..)
    , appendJournal
    , caseName
    , foldScalarsAgree
    , foldTransitions
    , readJournal
    , submissionCase
    , unresolved
    )
import Singular.CLI.ReceiptBody (boundBody)
import Singular.CLI.Recovery
    ( Inclusion (..)
    , excludedAt
    , inclusionOf
    , rollbackEvidence
    )
import Singular.CLI.Registry
    ( hexT
    )
import Singular.CLI.Session (failWith, failWithFields)
import Singular.Registry.Application
    ( Application (..)
    , DecodedHolding (..)
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Evidence qualified as Cage
import Singular.Registry.Ledger
    ( Addr
    , ConwayEra
    , SlotNo (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.TxBuilder.Edges (adaOnlyOut)
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , mkInlineDatum
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRoot (..)
    , OnChainTokenState (..)
    )
import Singular.Registry.Wallet (bech32Address)

-- | What one reconciliation found and did.
data Reconciliation = Reconciliation
    { rcRolledBack :: [Text]
    -- ^ The transactions it journalled @rolled-back@
    , rcRecovered :: [Recovery]
    -- ^ Every transaction that was unresolved once rollbacks were journalled
    , rcExcluded :: [Text]
    -- ^ The transactions it journalled @excluded@
    , rcObserved :: [Text]
    -- ^ The transactions it journalled @observed@
    , rcRemaining :: Maybe (JournalEntry, SubmissionCase)
    -- ^ The first transaction still unresolved, with its case
    }

-- | What chain evidence showed for one unresolved transaction.
data Recovery = Recovery
    { recTx :: Text
    , recStep :: Text
    , recIncluded :: Bool
    -- ^ Its first output is live: the transaction was included
    , recExcluded :: Bool
    -- ^ It can never be included: journalled @excluded@
    , recNote :: Text
    , recPrepared :: Maybe JournalEntry
    , recFirstOutput :: Maybe (TxOut ConwayEra)
    , recBody :: Maybe ConwayTx
    , recLast :: JournalEntry
    }

{- | Reconcile a saved registry's journal against one view of the chain,
on behalf of the named command, which the lines it appends carry.
-}
reconcile
    :: Application
    -> Text
    -> FilePath
    -> Saved
    -> Cage.Session Cage.NoWitness IO
    -> IO Reconciliation
reconcile app command dir saved view = do
    liveAt <- liveReader view
    rolled <- rollBack command dir view liveAt
    recovered <- recoverInclusion command dir view liveAt
    live <- attachLive view saved
    root <- either (failWith Partial) pure (observedRoot live)
    selected <- requireTrieSelection saved live
    outs <- liveOutputs app view saved
    let readKey key = do
            leaf <- trieLeaf selected key root
            pure (leaf, liveOutputFor app saved key outs)
    observedNow <- observe command dir (Just readKey) recovered
    remaining <- remainingOf <$> readJournal dir
    pure
        Reconciliation
            { rcRolledBack = rolled
            , rcRecovered = recovered
            , rcExcluded = excludedOf recovered
            , rcObserved = observedNow
            , rcRemaining = remaining
            }

{- | Reconcile the journal of a create that stopped before saving its
registry: rollback, inclusion, exclusion and the after-states that need
no key; the registry identity has not been saved yet.
-}
reconcileIncomplete
    :: Text
    -> FilePath
    -> Cage.Session Cage.NoWitness IO
    -> IO Reconciliation
reconcileIncomplete command dir view = do
    liveAt <- liveReader view
    rolled <- rollBack command dir view liveAt
    recovered <- recoverInclusion command dir view liveAt
    observedNow <- observe command dir Nothing recovered
    remaining <- remainingOf <$> readJournal dir
    pure
        Reconciliation
            { rcRolledBack = rolled
            , rcRecovered = recovered
            , rcExcluded = excludedOf recovered
            , rcObserved = observedNow
            , rcRemaining = remaining
            }

excludedOf :: [Recovery] -> [Text]
excludedOf recovered = [recTx r | r <- recovered, recExcluded r]

remainingOf :: [JournalEntry] -> Maybe (JournalEntry, SubmissionCase)
remainingOf entries = do
    e <- unresolved entries
    c <- submissionCase entries (journalTxId e)
    pure (e, c)

{- | A write stops before building anything on a transaction that
reconciliation left unresolved, naming its case and id: @partial@ while
its outcome is unknown, acknowledged, timed out or rolled back;
@stale-state@ when it was included but its journalled edge does not take
the replay to the ledger's root. Nothing is resubmitted.
-}
refuseUnreconciled :: Reconciliation -> IO ()
refuseUnreconciled r = case rcRemaining r of
    Nothing -> pure ()
    Just (e, c) ->
        failWithFields
            (if c == CaseIncluded then StaleState else Partial)
            ( "the journal holds "
                <> T.unpack (journalStep e)
                <> " transaction "
                <> T.unpack (journalTxId e)
                <> ", case "
                <> T.unpack (caseName c)
                <> " (last phase "
                <> T.unpack (journalEvent e)
                <> "), which the chain does not let this command reconcile"
                <> ( if c == CaseIncluded
                        then
                            ": its prepared after-state is not observed at the ledger's root"
                        else ""
                   )
                <> "; nothing was built or submitted, and it is never resubmitted"
            )
            [
                ( "unresolved"
                , object
                    [ "tx" .= journalTxId e
                    , "step" .= journalStep e
                    , "lastPhase" .= journalEvent e
                    , "case" .= caseName c
                    ]
                )
            , ("reconciled", reconciledJson r)
            ]

-- | What a reconciliation did, as a receipt names it.
reconciledJson :: Reconciliation -> Value
reconciledJson r =
    object
        [ "rolledBack" .= rcRolledBack r
        , "recovery" .= recoveryJson (rcRecovered r)
        , "excluded" .= rcExcluded r
        , "observed" .= rcObserved r
        ]

-- | Each unresolved transaction and what chain evidence showed.
recoveryJson :: [Recovery] -> Value
recoveryJson recovered =
    toJSON
        [ object
            [ "tx" .= recTx r
            , "step" .= recStep r
            , "included" .= recIncluded r
            , "excluded" .= recExcluded r
            , "note" .= recNote r
            ]
        | r <- recovered
        ]

-- | A chain point as the journal writes it: slot, a dot, the block hash.
renderPoint :: Cage.TipObservation -> Text
renderPoint p =
    T.pack (show (Cage.unSlotNo (Cage.observedSlot p)))
        <> "."
        <> hexT (Cage.observedHash p)

-- ---------------------------------------------------------
-- 1 and 2. Rollback, inclusion and exclusion
-- ---------------------------------------------------------

-- | The outputs live at an address, read once per address per view.
type LiveAt = Addr -> IO (Set TxIn)

{- | One address-output cache for one acquired view. The cache belongs
to the 'Cage.Session' passed in: 'reconcile' and 'reconcileIncomplete'
call 'liveReader' once per view, so two views never share entries and
nothing leaks across view lifetimes. The product is single-threaded:
lookups run in order on the calling thread, so plain 'readIORef' /
'modifyIORef'' suffice and no thread outlives the command. The
mutation is retained because the read-once behavior is required: a
second lookup for the same address must return what the view showed
the first time, not re-read the chain, keeping one view consistent
while rollback, inclusion and exclusion all consult it.
-}
liveReader :: Cage.Session Cage.NoWitness IO -> IO LiveAt
liveReader view = do
    cache <- newIORef Map.empty
    pure $ \addr -> do
        known <- Map.lookup addr <$> readIORef cache
        case known of
            Just found -> pure found
            Nothing -> do
                found <-
                    Set.fromList . map fst <$> Cage.outputsAt view addr
                modifyIORef' cache (Map.insert addr found)
                pure found

{- | What the view shows about a body: its inclusion, read over every
address its own outputs pay — the wallet's change and the registry's
script, where the inputs it spends sit — and its first output.
-}
inclusionAt
    :: LiveAt -> ConwayTx -> IO (Inclusion, Maybe (TxOut ConwayEra))
inclusionAt liveAt tx = do
    let outs = toList (tx ^. bodyTxL . outputsTxBodyL)
        spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
    live <- Set.unions <$> mapM liveAt (nub (map (^. addrTxOutL) outs))
    pure
        ( inclusionOf live (TxIn (txIdTx tx) (TxIx 0)) spent
        , listToMaybe outs
        )

{- | Journal @rolled-back@ for every transaction whose latest case is
included but which a live input now shows off the chain. Returns them.
-}
rollBack
    :: Text
    -> FilePath
    -> Cage.Session Cage.NoWitness IO
    -> LiveAt
    -> IO [Text]
rollBack command dir view liveAt = do
    observed <- Cage.tip view
    entries <- readJournal dir
    let included =
            [ t
            | t <- nub (map journalTxId entries)
            , submissionCase entries t == Just CaseIncluded
            ]
    fmap catMaybes . forM included $ \t -> do
        (prepared, body) <- boundBody entries t
        case body of
            Left _ -> pure Nothing
            Right tx -> do
                (inclusion, _) <- inclusionAt liveAt tx
                case rollbackEvidence (Just CaseIncluded) inclusion of
                    Nothing -> pure Nothing
                    Just found -> do
                        let transitions = maybe [] foldTransitions prepared
                            isFold = not (null transitions)
                            returnsTo = transitionRootBefore <$> listToMaybe transitions
                        appendJournal
                            dir
                            ( recoveryLine
                                command
                                (lastOf entries t)
                                "rolled-back"
                                ( "its first output is not live and "
                                    <> T.pack (show (length found))
                                    <> " input(s) it spends are live again: it is no longer on the chain"
                                    <> ( if isFold
                                            then
                                                "; its "
                                                    <> T.pack (show (length transitions))
                                                    <> " request(s) are pending again and the public state returns to its root before"
                                            else ""
                                       )
                                )
                            )
                                { journalChainPoint = Nothing
                                , journalObservedTip = Just (renderPoint observed)
                                , journalInputs = Just (map txInText found)
                                , journalRootBefore = if isFold then returnsTo else Nothing
                                }
                        pure (Just t)

{- | Inclusion evidence for each unresolved transaction, from its saved
body bound to its @prepared@ line: journals @confirmed@ for an included
one that lacked it, and @excluded@ for one that can never be included.
-}
recoverInclusion
    :: Text
    -> FilePath
    -> Cage.Session Cage.NoWitness IO
    -> LiveAt
    -> IO [Recovery]
recoverInclusion command dir view liveAt = do
    observed <- Cage.tip view
    entries <- readJournal dir
    let settled = ["observed", "rejected", "excluded"]
        open =
            [ lastOf entries t
            | t <- nub (map journalTxId entries)
            , journalEvent (lastOf entries t) `notElem` settled
            ]
        tip = Cage.observedSlot observed
    forM open $ \e -> do
        let txid = journalTxId e
        (prepared, body) <- boundBody entries txid
        let base =
                Recovery
                    { recTx = txid
                    , recStep = journalStep e
                    , recIncluded = False
                    , recExcluded = False
                    , recNote = ""
                    , recPrepared = prepared
                    , recFirstOutput = Nothing
                    , recBody = Nothing
                    , recLast = e
                    }
        case body of
            Left why -> pure base{recNote = why}
            Right tx -> do
                (inclusion, out0) <- inclusionAt liveAt tx
                case inclusion of
                    OnChain -> do
                        if journalEvent e == "confirmed"
                            then pure ()
                            else
                                appendJournal
                                    dir
                                    ( recoveryLine
                                        command
                                        e
                                        "confirmed"
                                        "its first output is live on the ledger"
                                    )
                        pure
                            base
                                { recIncluded = True
                                , recNote = "included: its first output is live"
                                , recFirstOutput = out0
                                , recBody = Just tx
                                }
                    _
                        | excludedAt tip (upperOf tx) (submissionCase entries txid) inclusion
                        , OffChain found <- inclusion
                        , Just (SlotNo upper) <- upperOf tx -> do
                            appendJournal
                                dir
                                ( recoveryLine
                                    command
                                    e
                                    "excluded"
                                    ( "it is not on the chain ("
                                        <> T.pack (show (length found))
                                        <> " input(s) it spends are live) and the tip's slot "
                                        <> T.pack (show (Cage.unSlotNo tip))
                                        <> " has reached its validity upper bound "
                                        <> T.pack (show upper)
                                        <> ": it can never be included"
                                    )
                                )
                                    { journalChainPoint = Nothing
                                    , journalObservedTip = Just (renderPoint observed)
                                    , journalInputs = Just (map txInText found)
                                    }
                            pure
                                base
                                    { recExcluded = True
                                    , recNote = "excluded: off the chain and past its upper bound"
                                    }
                    OffChain _ ->
                        pure
                            base
                                { recNote =
                                    "not on the chain: an input it spends is live; \
                                    \it may still be included"
                                }
                    Undetermined ->
                        pure
                            base{recNote = "its first output is not live; inclusion is unknown"}

-- | A body's validity upper bound, when it has one.
upperOf :: ConwayTx -> Maybe SlotNo
upperOf tx = case tx ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust upper) -> Just upper
    ValidityInterval _ SNothing -> Nothing

lastOf :: [JournalEntry] -> Text -> JournalEntry
lastOf entries t = last [e | e <- entries, journalTxId e == t]

-- | A key's proven leaf and its holding at the application, read now.
type KeyRead =
    ByteString
    -> IO
        ( Either AuthError Leaf
        , Either String ((TxIn, TxOut ConwayEra), DecodedHolding)
        )

{- | The readback verdicts for one included transaction's prepared
after-state: for a fold (a @prepared@ line with a non-empty
'foldTransitions'), the scalar agreement with its list, the state output
carrying the last transition's root after, and each distinct key the list
touches read against the expectation of the last transition that moves
it; for any other step, the one verdict of its single after-state.
-}
observeVerdicts
    :: Text
    -> JournalEntry
    -> TxOut ConwayEra
    -> Maybe KeyRead
    -> IO [Either Text Text]
observeVerdicts command p out0 readKey = case foldTransitions p of
    [] ->
        maybe
            [Left (command <> ": its after-state is not read back")]
            (\d -> [Right d])
            <$> holds p out0
    ts
        | not (foldScalarsAgree p) ->
            pure
                [Left (command <> ": its scalars disagree with its transition list")]
        | otherwise -> do
            keys <-
                forM (lastPerKey ts) $ \t -> case decodeKey (transitionKey t) of
                    Nothing -> pure (Left ("the key " <> transitionKey t <> " is not hex"))
                    Just key -> keyVerdict key (transitionExpect t)
            pure (rootVerdict out0 (last ts) : keys)
  where
    -- Each key the fold touches, in the order it first touches it, with
    -- the transition that moves it last: only that after-state is read.
    lastPerKey moves =
        [ last [t | t <- moves, transitionKey t == k]
        | k <- nub (map transitionKey moves)
        ]
    -- The fold's first output is the registry's new state output.
    rootVerdict out t = case extractCageDatum out of
        Just (StateDatum st)
            | hexT (unOnChainRoot (stateRoot st)) == transitionRootAfter t ->
                Right
                    ( command
                        <> ": the state output carries the fold's root after 0x"
                        <> transitionRootAfter t
                    )
        _ ->
            Left
                ( command
                    <> ": the state output does not carry the fold's root after 0x"
                    <> transitionRootAfter t
                )
    decodeKey = either (const Nothing) Just . B16.decode . BC.pack . T.unpack
    keyVerdict key expect = case readKey of
        Nothing -> pure (Left (command <> ": no key reader for key 0x" <> hexT key))
        Just reader -> do
            got <- reader key
            pure
                ( maybe
                    ( Left
                        (command <> ": key 0x" <> hexT key <> " has not reached " <> expect)
                    )
                    Right
                    (keyHolds key expect got)
                )
    -- The one check of a key against the leaf it must read back, shared
    -- by the single-key path below and every transition of a fold.
    keyHolds key expect (leafE, holdE) = case T.breakOn ":" expect of
        ("active", h) -> case (leafE, holdE) of
            (Right Active, Right (_, dh))
                | ":" <> hexT (dhDatumHash dh) == h ->
                    Just
                        ( command
                            <> ": key 0x"
                            <> hexT key
                            <> " Active against the ledger's root and its one holding carries the envelope"
                        )
            _ -> Nothing
        ("payload", h) -> case (leafE, holdE) of
            (Right Active, Right (_, dh))
                | ":" <> hexT (dhDatumHash dh) == h ->
                    Just
                        ( command
                            <> ": key 0x"
                            <> hexT key
                            <> "'s one holding carries the updated envelope"
                        )
            _ -> Nothing
        ("terminal", _) -> case (leafE, holdE) of
            (Right Terminal, Left _) ->
                Just
                    ( command
                        <> ": key 0x"
                        <> hexT key
                        <> " Terminal against the ledger's root and no holding of it is live"
                    )
            _ -> Nothing
        _ -> Nothing
    keyOf entry =
        journalKey entry
            >>= either (const Nothing) Just . B16.decode . BC.pack . T.unpack
    withKey entry expect k = case (readKey, keyOf entry) of
        (Just reader, Just key) -> k key expect <$> reader key
        _ -> pure Nothing
    holds entry out = case T.breakOn ":" <$> journalExpect entry of
        Just ("reference", h)
            | SJust sc <- out ^. referenceScriptTxOutL
            , ":" <> hexT (scriptHashBytes (hashScript sc)) == h ->
                pure
                    (Just (command <> ": the reference output is live carrying its script"))
        Just ("state", _)
            | Just (StateDatum _) <- extractCageDatum out ->
                pure (Just (command <> ": the state output is live"))
        Just ("request", _)
            | Just (RequestDatum _) <- extractCageDatum out ->
                pure (Just (command <> ": the request output is live"))
        Just ("reclaim", h)
            | Right request <- parseOutRef (T.drop 1 h)
            , Just inputs <- journalInputs entry
            , txInText request `elem` inputs
            , out ^. datumTxOutL == mkInlineDatum (toPlcData (txInToRef request)) ->
                pure (Just (command <> ": the request-bound return output is live"))
        Just ("funding", h)
            | T.pack (bech32Address (out ^. addrTxOutL)) == T.drop 1 h
            , adaOnlyOut out ->
                pure
                    ( Just
                        ( command
                            <> ": the funding output is live, ada only, at the payer's address"
                        )
                    )
        Just _
            | Just expect <- journalExpect entry ->
                withKey entry expect keyHolds
        _ -> pure Nothing

{- | Journal @observed@ for each included transaction whose prepared
after-state is read back now. A key-bound after-state is read for the
key its own @prepared@ line names; without a key reader none is.
-}
observe
    :: Text -> FilePath -> Maybe KeyRead -> [Recovery] -> IO [Text]
observe command dir readKey recovered = do
    verdicts <-
        forM
            [ (r, p, out0)
            | r <- recovered
            , recIncluded r
            , Just p <- [recPrepared r]
            , Just out0 <- [recFirstOutput r]
            ]
            $ \(r, p, out0) -> (r,) <$> observeVerdicts command p out0 readKey
    forM_ verdicts $ \(r, vs) ->
        when (not (null vs) && all isRight vs) $
            appendJournal
                dir
                ( recoveryLine
                    command
                    (recLast r)
                    "observed"
                    (T.intercalate "; " (rights vs))
                )
    pure [recTx r | (r, vs) <- verdicts, not (null vs), all isRight vs]

-- | A journal line reconciliation appends for a recovered transaction.
recoveryLine :: Text -> JournalEntry -> Text -> Text -> JournalEntry
recoveryLine command e event detail =
    e
        { journalCommand = command
        , journalEvent = event
        , journalDetail = Just detail
        , journalInputs = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalChainPoint = Nothing
        , journalSession = Nothing
        , journalObservedTip = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        , journalTransitions = Nothing
        }
