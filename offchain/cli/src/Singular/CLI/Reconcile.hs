{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.Reconcile
Description : The next command reconciles the journal with the chain
License     : Apache-2.0

A write whose process stopped between the node's answer and its local
commit leaves its journal saying how far it got: an answer that never
arrived, an acceptance never confirmed, a confirmation whose mirror,
@state.json@ or observation was never written. And a transaction the
journal saw included can leave the chain again. The next ordinary
command — any write, or @inspect@ — runs 'reconcile' first, reading the
chain through one acquired view and submitting nothing:

1. __Rollback.__ A transaction whose latest journalled case is included
   ('Singular.CLI.Recovery.rollbackEvidence') is journalled
   @rolled-back@ when its first output is not live and an input it
   spends is live again: a transaction on the chain consumes every input
   it spends. The line names the chain point read, the inputs found live
   and, for a fold, the root the mirror returns to; the observation it
   supersedes stays. The transaction is unresolved again.
2. __Inclusion and exclusion.__ An unresolved transaction whose saved
   body is the one its @prepared@ line names (same byte hash, same
   derived id) and whose first output is live was included: journalled
   @confirmed@ if it was not already. One a live input shows off the
   chain, whose validity upper bound the view's tip has reached, can
   never be included: journalled @excluded@, which settles it. Anything
   else shows nothing either way; it stays unresolved.
3. __Rewind.__ After a fold rolled back, the mirror returns to the root
   before the earliest rolled-back fold, rebuilt from the empty trie by
   replaying the folds still on the chain ('Singular.CLI.Recovery.rewindOf'),
   and @state.json@ follows.
4. __Mirror and state.__ An included fold's journalled edge is applied
   to the mirror only from its journalled root before and only when the
   ledger holds its journalled root after ('mirrorDecision'), so at most
   once; the walk must reach the ledger's root. Then, when the mirror
   commits to the ledger's root, @state.json@ follows it.
5. __Observation.__ An included transaction is journalled @observed@
   when the after-state its @prepared@ line names is read back now: a
   reference output carrying its script, the state output, the request
   output, or — for the key the step concerns, whichever key the current
   command targets — the leaf proven against the ledger's root and the
   holding the step was to leave.

Every line is appended; no prior line or saved body is rewritten, and
the mirror and @state.json@ are replaced whole by their own writers.
What remains unresolved is returned with the case it met, and a write
stops on it before building anything ('refuseUnreconciled').
-}
module Singular.CLI.Reconcile
    ( -- * Reconciling
      Reconciliation (..)
    , Recovery (..)
    , reconcile
    , reconcileIncomplete
    , refuseUnreconciled

      -- * Receipts
    , reconciledJson
    , recoveryJson
    , renderPoint
    ) where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust, listToMaybe)
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

import Singular.Application.OpenDatum.Envelope
    ( Envelope (..)
    , envelopeHash
    )
import Singular.CLI.Live
    ( Mirror
    , Saved (..)
    , attachLive
    , liveOutputFor
    , liveOutputs
    , mirrorLeaf
    , mirrorRoot
    , observedRoot
    , openMirror
    , recoverMirrorFold
    , rewindMirrorTo
    , selectMirror
    , txInText
    )
import Singular.CLI.Proof (AuthError, Leaf (..))
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , SubmissionCase (..)
    , appendJournal
    , caseName
    , readJournal
    , submissionCase
    , unresolved
    )
import Singular.CLI.ReceiptBody (boundBody)
import Singular.CLI.Recovery
    ( Inclusion (..)
    , MirrorDecision (..)
    , Rewind (..)
    , excludedAt
    , inclusionOf
    , mirrorDecision
    , rewindOf
    , rollbackEvidence
    )
import Singular.CLI.Registry
    ( LocalState (..)
    , hexT
    , readLocalState
    , writeLocalState
    )
import Singular.CLI.Session (failWith, failWithFields, harnessHoldAt)
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger
    ( Addr
    , AssetName (..)
    , ConwayEra
    , SlotNo (..)
    , TokenId (..)
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , mkInlineDatum
    , scriptHashBytes
    , toPlcData
    , txInToRef
    )
import Singular.Registry.Types (CageDatum (..))

-- | What one reconciliation found and did.
data Reconciliation = Reconciliation
    { rcRolledBack :: [Text]
    -- ^ The transactions it journalled @rolled-back@
    , rcRecovered :: [Recovery]
    -- ^ Every transaction that was unresolved once rollbacks were journalled
    , rcExcluded :: [Text]
    -- ^ The transactions it journalled @excluded@
    , rcRewound :: Maybe Text
    -- ^ The root it returned the mirror to after a rollback, hex
    , rcApplied :: [Text]
    -- ^ The folds whose journalled edge it applied to the mirror
    , rcStateFollowed :: Bool
    -- ^ Whether it rewrote @state.json@ to the mirror's root
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
    :: Text -> FilePath -> Saved -> Cage.View IO -> IO Reconciliation
reconcile command dir saved view = do
    liveAt <- liveReader view
    rolled <- rollBack command dir view liveAt
    recovered <- recoverInclusion command dir view liveAt
    rewound <- rewindMirror dir saved
    live <- attachLive view saved
    root <- either (failWith Partial) pure (observedRoot live)
    mirror <- openMirror saved
    applied <- advanceMirror saved mirror root recovered
    local <- mirrorRoot saved mirror
    followed <-
        if local == root
            then followState dir saved local
            else pure False
    _ <- selectMirror saved live mirror
    outs <- liveOutputs view saved
    let readKey key = do
            leaf <- mirrorLeaf mirror key root
            pure (leaf, liveOutputFor saved key outs)
    observedNow <- observe command dir (Just readKey) recovered
    remaining <- remainingOf <$> readJournal dir
    pure
        Reconciliation
            { rcRolledBack = rolled
            , rcRecovered = recovered
            , rcExcluded = excludedOf recovered
            , rcRewound = rewound
            , rcApplied = applied
            , rcStateFollowed = followed
            , rcObserved = observedNow
            , rcRemaining = remaining
            }

{- | Reconcile the journal of a create that stopped before saving its
registry: rollback, inclusion, exclusion and the after-states that need
no key; there is no mirror or @state.json@ yet.
-}
reconcileIncomplete
    :: Text -> FilePath -> Cage.View IO -> IO Reconciliation
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
            , rcRewound = Nothing
            , rcApplied = []
            , rcStateFollowed = False
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
the mirror to the ledger's root. Nothing is resubmitted.
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
                            ": its journalled edge does not take the mirror \
                            \to the ledger's root"
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
        , "mirrorRewound" .= rcRewound r
        , "applied" .= rcApplied r
        , "stateFollowed" .= rcStateFollowed r
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
renderPoint :: Cage.ChainPoint -> Text
renderPoint p =
    T.pack (show (Cage.unSlotNo (Cage.cpSlot p)))
        <> "."
        <> hexT (Cage.cpBlockHash p)

-- ---------------------------------------------------------
-- 1 and 2. Rollback, inclusion and exclusion
-- ---------------------------------------------------------

-- | The outputs live at an address, read once per address per view.
type LiveAt = Addr -> IO (Set TxIn)

liveReader :: Cage.View IO -> IO LiveAt
liveReader view = do
    cache <- newIORef Map.empty
    pure $ \addr -> do
        known <- Map.lookup addr <$> readIORef cache
        case known of
            Just found -> pure found
            Nothing -> do
                found <-
                    Set.fromList . map fst <$> Cage.viewUTxOsAt view addr
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
rollBack :: Text -> FilePath -> Cage.View IO -> LiveAt -> IO [Text]
rollBack command dir view liveAt = do
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
                        let returnsTo = prepared >>= journalRootBefore
                            isFold = isJust (prepared >>= journalEdge)
                        appendJournal
                            dir
                            ( recoveryLine
                                command
                                (lastOf entries t)
                                "rolled-back"
                                ( "its first output is not live and "
                                    <> T.pack (show (length found))
                                    <> " input(s) it spends are live again: it is no longer on the chain"
                                    <> (if isFold then "; the mirror returns to its root before" else "")
                                )
                            )
                                { journalChainPoint = Just (renderPoint (Cage.viewPoint view))
                                , journalInputs = Just (map txInText found)
                                , journalRootBefore = if isFold then returnsTo else Nothing
                                }
                        pure (Just t)

{- | Inclusion evidence for each unresolved transaction, from its saved
body bound to its @prepared@ line: journals @confirmed@ for an included
one that lacked it, and @excluded@ for one that can never be included.
-}
recoverInclusion
    :: Text -> FilePath -> Cage.View IO -> LiveAt -> IO [Recovery]
recoverInclusion command dir view liveAt = do
    entries <- readJournal dir
    let settled = ["observed", "rejected", "excluded"]
        open =
            [ lastOf entries t
            | t <- nub (map journalTxId entries)
            , journalEvent (lastOf entries t) `notElem` settled
            ]
        tip = Cage.cpSlot (Cage.viewPoint view)
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
                                    { journalChainPoint = Just (renderPoint (Cage.viewPoint view))
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

-- ---------------------------------------------------------
-- 3. Rewind
-- ---------------------------------------------------------

{- | After a fold rolled back, return the mirror to the root before the
earliest rolled-back fold, rebuilt from the empty trie by replaying the
folds still on chain, and bring @state.json@ along. Returns the root
when the mirror was rewritten; a replay that does not reach that root
is stale local state, refused and never written.
-}
rewindMirror :: FilePath -> Saved -> IO (Maybe Text)
rewindMirror dir saved = do
    entries <- readJournal dir
    case rewindOf entries of
        Nothing -> pure Nothing
        Just rw -> do
            target <-
                either
                    ( const
                        (failWith StaleState "a rolled-back fold's root before is not hex")
                    )
                    pure
                    (B16.decode (BC.pack (T.unpack (rewindRoot rw))))
            current <- openMirror saved >>= mirrorRoot saved
            rewritten <-
                if current == target
                    then pure Nothing
                    else do
                        harnessHoldAt "SINGULAR_HARNESS_HOLD_BEFORE_REWIND" Nothing
                        mirror <- openMirror saved
                        rewindMirrorTo saved mirror target
                        pure (Just (rewindRoot rw))
            harnessHoldAt "SINGULAR_HARNESS_HOLD_BEFORE_REWIND_STATE" Nothing
            _ <- followState dir saved target
            pure rewritten

-- ---------------------------------------------------------
-- 4. Mirror and state
-- ---------------------------------------------------------

{- | Apply each included fold's journalled edge to the mirror when
'mirrorDecision' says so, and require the result to be the ledger's
root. Returns the folds applied.
-}
advanceMirror
    :: Saved -> Mirror -> ByteString -> [Recovery] -> IO [Text]
advanceMirror saved mirror root recovered = fmap concat . forM recovered $ \r ->
    case recPrepared r of
        Just p
            | recIncluded r
            , Just keyHex <- journalKey p
            , Just edge <- journalEdge p
            , Right key <- B16.decode (BC.pack (T.unpack keyHex)) -> do
                local <- mirrorRoot saved mirror
                case mirrorDecision (hexT local) (hexT root) p of
                    ApplyEdge -> do
                        tx <-
                            maybe
                                (failWith StaleState "the included fold has no bound signed body")
                                pure
                                (recBody r)
                        recoverMirrorFold saved mirror key edge local root tx
                        now <- mirrorRoot saved mirror
                        if now /= root
                            then
                                failWith
                                    StaleState
                                    "the journalled edge does not take the mirror to the ledger's root"
                            else pure [recTx r]
                    _ -> pure []
        _ -> pure []

{- | Rewrite @state.json@ to the mirror's root when it commits to another
one; the mirror already equals the ledger's root here. Its last
transaction is the latest fold journalled to commit to that root.
-}
followState :: FilePath -> Saved -> ByteString -> IO Bool
followState dir saved local = do
    current <- try @SomeException (readLocalState dir)
    case current of
        Right s | localRoot s == hexT local -> pure False
        _ -> do
            entries <- readJournal dir
            let lastFold =
                    listToMaybe
                        ( reverse
                            [ journalTxId e
                            | e <- entries
                            , journalEvent e == "prepared"
                            , journalRootAfter e == Just (hexT local)
                            ]
                        )
                kept = either (\(_ :: SomeException) -> Nothing) localLastTx current
            writeLocalState
                dir
                LocalState
                    { localVersion = 1
                    , localToken =
                        let TokenId (AssetName n) = savedToken saved
                        in  hexT (SBS.fromShort n)
                    , localRoot = hexT local
                    , localLastTx = lastFold <|> kept
                    , localLastSlot = Nothing
                    }
            pure True

-- ---------------------------------------------------------
-- 5. Observation
-- ---------------------------------------------------------

-- | A key's proven leaf and its holding at the application, read now.
type KeyRead =
    ByteString
    -> IO
        ( Either AuthError Leaf
        , Either String ((TxIn, TxOut ConwayEra), Envelope)
        )

{- | Journal @observed@ for each included transaction whose prepared
after-state is read back now. A key-bound after-state is read for the
key its own @prepared@ line names; without a key reader none is.
-}
observe
    :: Text -> FilePath -> Maybe KeyRead -> [Recovery] -> IO [Text]
observe command dir readKey recovered = do
    found <-
        fmap catMaybes . forM recovered $ \r ->
            case (recIncluded r, recPrepared r, recFirstOutput r) of
                (True, Just p, Just out0) -> fmap (r,) <$> holds p out0
                _ -> pure Nothing
    forM_ found $ \(r, what) ->
        appendJournal dir (recoveryLine command (recLast r) "observed" what)
    pure (map (recTx . fst) found)
  where
    keyOf p =
        journalKey p
            >>= either (const Nothing) Just . B16.decode . BC.pack . T.unpack
    withKey p k = case (readKey, keyOf p) of
        (Just reader, Just key) -> k key <$> reader key
        _ -> pure Nothing
    holds p out0 = case T.breakOn ":" <$> journalExpect p of
        Just ("reference", h)
            | SJust sc <- out0 ^. referenceScriptTxOutL
            , ":" <> hexT (scriptHashBytes (hashScript sc)) == h ->
                pure
                    (Just (command <> ": the reference output is live carrying its script"))
        Just ("state", _)
            | Just (StateDatum _) <- extractCageDatum out0 ->
                pure (Just (command <> ": the state output is live"))
        Just ("request", _)
            | Just (RequestDatum _) <- extractCageDatum out0 ->
                pure (Just (command <> ": the request output is live"))
        Just ("reclaim", h)
            | Right request <- parseOutRef (T.drop 1 h)
            , Just inputs <- journalInputs p
            , txInText request `elem` inputs
            , out0 ^. datumTxOutL == mkInlineDatum (toPlcData (txInToRef request)) ->
                pure (Just (command <> ": the request-bound return output is live"))
        Just ("active", h) -> withKey p $ \key -> \case
            (Right Active, Right (_, e))
                | ":" <> hexT (envelopeHash e) == h ->
                    Just
                        ( command
                            <> ": key 0x"
                            <> hexT key
                            <> " Active against the ledger's root and its one holding carries the envelope"
                        )
            _ -> Nothing
        Just ("payload", h) -> withKey p $ \key -> \case
            (Right Active, Right (_, e))
                | ":" <> hexT (envelopeHash e) == h ->
                    Just
                        ( command
                            <> ": key 0x"
                            <> hexT key
                            <> "'s one holding carries the updated envelope"
                        )
            _ -> Nothing
        Just ("terminal", _) -> withKey p $ \key -> \case
            (Right Terminal, Left _) ->
                Just
                    ( command
                        <> ": key 0x"
                        <> hexT key
                        <> " Terminal against the ledger's root and no holding of it is live"
                    )
            _ -> Nothing
        _ -> pure Nothing

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
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        }
