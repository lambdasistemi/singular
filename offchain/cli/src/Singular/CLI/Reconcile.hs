{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.Reconcile
Description : The next command reconciles an interrupted local commit from chain evidence
License     : Apache-2.0

A write whose process stopped between the node's answer and its local
commit leaves its journal saying how far it got: an answer that never
arrived, an acceptance never confirmed, a confirmation whose mirror,
@state.json@ or observation was never written. The next ordinary
command — any write, or @inspect@ — runs 'reconcile' first, in three
steps, reading the chain through one acquired view and submitting
nothing:

1. __Inclusion.__ An unresolved transaction whose saved body is the one
   its @prepared@ line names (same byte hash, same derived id) and whose
   first output is live was included: journalled @confirmed@ if it was
   not already. A spent first output, a passed validity window or an
   absent input shows nothing either way; the transaction stays
   unresolved.
2. __Mirror and state.__ An included fold's journalled edge is applied
   to the mirror only from its journalled root before and only when the
   ledger holds its journalled root after ('mirrorDecision'), so at most
   once; the walk must reach the ledger's root. Then, when the mirror
   commits to the ledger's root, @state.json@ follows it.
3. __Observation.__ An included transaction is journalled @observed@
   when the after-state its @prepared@ line names is read back now: a
   reference output carrying its script, the state output, the request
   output, or — for the key the step concerns, whichever key the current
   command targets — the leaf proven against the ledger's root and the
   holding the step was to leave.

Every line is appended; no prior line or saved body is rewritten.
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
import Control.Exception (IOException, SomeException, try)
import Control.Monad (forM, forM_, void)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.ByteString.Short qualified as SBS
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Core (eraProtVerHigh, hashScript)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Envelope
    ( Envelope (..)
    , envelopeHash
    )
import Singular.CLI.Live
    ( Mirror (..)
    , Saved (..)
    , attachLive
    , liveOutputFor
    , liveOutputs
    , mirrorRoot
    , observedRoot
    , openMirror
    , saveOpenMirror
    )
import Singular.CLI.Proof (AuthError, Leaf (..), authenticatedLeaf)
import Singular.CLI.Proof qualified as Proof
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
import Singular.CLI.Recovery (MirrorDecision (..), mirrorDecision)
import Singular.CLI.Registry
    ( LocalState (..)
    , hexT
    , readLocalState
    , writeLocalState
    )
import Singular.CLI.Session (failWith, failWithFields)
import Singular.Registry.Ledger
    ( AssetName (..)
    , ConwayEra
    , TokenId (..)
    )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (TrieManager (..))
import Singular.Registry.TxBuilder.Internal
    ( extractCageDatum
    , scriptHashBytes
    , walkEdge
    )
import Singular.Registry.Types (CageDatum (..))

-- | What one reconciliation found and did.
data Reconciliation = Reconciliation
    { rcRecovered :: [Recovery]
    -- ^ Every transaction that was unresolved when it started
    , rcApplied :: [Text]
    -- ^ The folds whose journalled edge it applied to the mirror
    , rcStateFollowed :: Bool
    -- ^ Whether it rewrote @state.json@ to the mirror's root
    , rcObserved :: [Text]
    -- ^ The transactions it journalled @observed@
    , rcRemaining :: Maybe (JournalEntry, SubmissionCase)
    -- ^ The first transaction still unresolved, with its case
    }

-- | What inclusion evidence showed for one unresolved transaction.
data Recovery = Recovery
    { recTx :: Text
    , recStep :: Text
    , recIncluded :: Bool
    -- ^ Its first output is live: the transaction was included
    , recNote :: Text
    , recPrepared :: Maybe JournalEntry
    , recFirstOutput :: Maybe (TxOut ConwayEra)
    , recLast :: JournalEntry
    }

{- | Reconcile a saved registry's journal against one view of the chain,
on behalf of the named command, which the lines it appends carry.
-}
reconcile
    :: Text -> FilePath -> Saved -> Cage.View IO -> IO Reconciliation
reconcile command dir saved view = do
    recovered <- recoverInclusion command dir view
    live <- attachLive view saved
    root <- either (failWith Partial) pure (observedRoot live)
    mirror <- openMirror saved
    applied <- advanceMirror saved mirror root recovered
    local <- mirrorRoot saved mirror
    followed <-
        if local == root
            then followState dir saved local
            else pure False
    tries <- mirrorDump mirror
    outs <- liveOutputs view saved
    let readKey key = do
            leaf <- case Map.lookup (savedToken saved) tries of
                Nothing ->
                    pure (Left (Proof.ProofInconsistent "the mirror holds no trie"))
                Just db -> authenticatedLeaf db key root
            pure (leaf, liveOutputFor saved key outs)
    observedNow <- observe command dir (Just readKey) recovered
    remaining <- remainingOf <$> readJournal dir
    pure
        Reconciliation
            { rcRecovered = recovered
            , rcApplied = applied
            , rcStateFollowed = followed
            , rcObserved = observedNow
            , rcRemaining = remaining
            }

{- | Reconcile the journal of a create that stopped before saving its
registry: inclusion and the after-states that need no key; there is no
mirror or @state.json@ yet.
-}
reconcileIncomplete
    :: Text -> FilePath -> Cage.View IO -> IO Reconciliation
reconcileIncomplete command dir view = do
    recovered <- recoverInclusion command dir view
    observedNow <- observe command dir Nothing recovered
    remaining <- remainingOf <$> readJournal dir
    pure
        Reconciliation
            { rcRecovered = recovered
            , rcApplied = []
            , rcStateFollowed = False
            , rcObserved = observedNow
            , rcRemaining = remaining
            }

remainingOf :: [JournalEntry] -> Maybe (JournalEntry, SubmissionCase)
remainingOf entries = do
    e <- unresolved entries
    c <- submissionCase entries (journalTxId e)
    pure (e, c)

{- | A write stops before building anything on a transaction that
reconciliation left unresolved, naming its case and id: @partial@ while
its outcome is unknown, acknowledged or timed out; @stale-state@ when it
was included but its journalled edge does not take the mirror to the
ledger's root. Nothing is resubmitted.
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
        [ "recovery" .= recoveryJson (rcRecovered r)
        , "applied" .= rcApplied r
        , "stateFollowed" .= rcStateFollowed r
        , "observed" .= rcObserved r
        ]

-- | Each unresolved transaction and what inclusion evidence showed.
recoveryJson :: [Recovery] -> Value
recoveryJson recovered =
    toJSON
        [ object
            [ "tx" .= recTx r
            , "step" .= recStep r
            , "included" .= recIncluded r
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
-- 1. Inclusion
-- ---------------------------------------------------------

{- | Positive inclusion evidence for each unresolved transaction, from its
saved body bound to its @prepared@ line; journals @confirmed@ for an
included one that lacked it.
-}
recoverInclusion :: Text -> FilePath -> Cage.View IO -> IO [Recovery]
recoverInclusion command dir view = do
    entries <- readJournal dir
    let lastOf t = last [e | e <- entries, journalTxId e == t]
        settled = ["observed", "rejected", "excluded"]
        open =
            [ lastOf t
            | t <- nub (map journalTxId entries)
            , journalEvent (lastOf t) `notElem` settled
            ]
    forM open $ \e -> do
        let txid = journalTxId e
            prepared =
                listToMaybe
                    [ p
                    | p <- entries
                    , journalTxId p == txid
                    , journalEvent p == "prepared"
                    ]
            base =
                Recovery
                    { recTx = txid
                    , recStep = journalStep e
                    , recIncluded = False
                    , recNote = ""
                    , recPrepared = prepared
                    , recFirstOutput = Nothing
                    , recLast = e
                    }
            miss why = pure base{recNote = why}
        case prepared of
            Just p
                | Just path <- journalBody p
                , Just wantHash <- journalBodyHash p -> do
                    stored <- try (BS.readFile path)
                    case stored of
                        Left (_ :: IOException) -> miss "the saved body is missing"
                        Right hexBytes -> case B16.decode (BC.filter (not . isSpace) hexBytes) of
                            Left _ -> miss "the saved body is not hex"
                            Right raw
                                | hexT (hashToBytes (hashWith @Blake2b_256 id raw)) /= wantHash ->
                                    miss "the saved body's hash differs from its prepared line"
                                | otherwise ->
                                    case decodeFullAnnotator
                                        (eraProtVerHigh @ConwayEra)
                                        "transaction"
                                        decCBOR
                                        (BL.fromStrict raw) of
                                        Left _ -> miss "the saved body does not decode"
                                        Right (tx :: ConwayTx)
                                            | txIdHexOf tx /= txid ->
                                                miss "the saved body is another transaction"
                                            | otherwise -> case toList (tx ^. bodyTxL . outputsTxBodyL) of
                                                [] -> miss "the saved body has no outputs"
                                                (out0 : _) -> do
                                                    liveAt <- Cage.viewUTxOsAt view (out0 ^. addrTxOutL)
                                                    case [o | (i, o) <- liveAt, i == TxIn (txIdTx tx) (TxIx 0)] of
                                                        (o : _) -> do
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
                                                                    , recFirstOutput = Just o
                                                                    }
                                                        [] -> miss "its first output is not live; inclusion is unknown"
            _ -> miss "no prepared line names a saved body"

-- ---------------------------------------------------------
-- 2. Mirror and state
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
                        withTrie (mirrorTries mirror) (savedToken saved) $ \t ->
                            void (walkEdge t key edge)
                        now <- mirrorRoot saved mirror
                        if now /= root
                            then
                                failWith
                                    StaleState
                                    "the journalled edge does not take the mirror to the ledger's root"
                            else do
                                saveOpenMirror saved mirror
                                pure [recTx r]
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
-- 3. Observation
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

txIdHexOf :: ConwayTx -> Text
txIdHexOf tx = let TxId h = txIdTx tx in hexT (hashToBytes (extractHash h))
