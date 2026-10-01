{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.Inspect
Description : @singular registry inspect@: a key read back, key-free, against the ledger's root
License     : Apache-2.0

Inspect takes a node socket and magic and nothing else: no signing key,
no funding, no submission. It reads the registry's state output fresh
and proves the key's leaf from the saved mirror against the root that
output commits to ("Singular.CLI.Proof"); it reads the key's holding at
the application — bound to this registry's state asset, pinned active
policy and key — and reports its envelope, payload, deposit and value;
and it labels everything with the chain point it was read at.

A leaf is printed only from a proof verified against that fresh root,
and only when the holdings agree with it: @active@ with exactly one
holding, any other leaf with none. @unknown@ means a verified exclusion
proof. Every other case prints no leaf and ends in its own outcome — the
node unusable (@node-unavailable@), the mirror or the registry's trie
missing (@proof-missing@), the mirror committing to another root
(@stale-state@), no leaf proving itself or a leaf the holdings
contradict (@proof-inconsistent@), or an unresolved journalled
submission (@partial@).

Inspect is also the journal's only resolver, in three separate steps.

1. __Inclusion.__ An unresolved transaction whose saved body is the one
   its @prepared@ line names (same byte hash, same derived id) and whose
   first output is live was included: journalled @confirmed@. A spent
   first output, a passed validity window or an absent input shows
   nothing either way; the entry stays uncertain. Negative resolution
   (an exclusion shown by a competing transaction) needs the chain
   followed from the journalled point, which this command does not do.
2. __Mirror.__ An included fold whose journalled roots authenticate the
   change — the ledger now holds its @root after@ and the mirror still
   commits to its @root before@ — has its journalled edge applied to the
   mirror, and the result must equal the ledger's root. The receipt says
   so. Nothing else ever changes the mirror here.
3. __Observation.__ An included transaction is journalled @observed@ only
   when the after-state its @prepared@ line names is read back in this
   run: a reference output carrying its script, the state output, the
   request output; or, for the key this inspect reads and only that key,
   the leaf and the holding the step was to leave. Inspecting another key
   observes nothing for it.
-}
module Singular.CLI.Inspect (runInspect) where

import Control.Exception
    ( IOException
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (forM, forM_, void, when)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
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
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((^.))
import System.Directory (doesFileExist)

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , coinTxOutL
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (eraProtVerHigh, hashScript)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , dataToJson
    , envelopeHash
    , envelopeToJson
    )
import Singular.CLI.Command
    ( InspectArgs (..)
    , Key (..)
    , NodeSettings (..)
    )
import Singular.CLI.Live
import Singular.CLI.Node (withReads)
import Singular.CLI.Proof
    ( AuthError (RootMismatch)
    , Leaf (..)
    , authenticatedLeaf
    , leafName
    , renderAuthError
    )
import Singular.CLI.Proof qualified as Proof
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , appendJournal
    , readJournal
    , unresolved
    )
import Singular.CLI.Registry
    ( LocalState (..)
    , checkNetwork
    , configPath
    , hexT
    , pendingPath
    , renderIdentityError
    , writeLocalState
    )
import Singular.CLI.Session (CommandFailure (..), failWith)
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

runInspect :: InspectArgs -> IO Value
runInspect a = do
    let dir = inspectRegistry a
        Key key = inspectKey a
        NodeSettings sock magic = inspectNode a
    complete <- doesFileExist (configPath dir)
    pending <- doesFileExist (pendingPath dir)
    if not complete && pending
        then inspectIncompleteCreate dir sock magic
        else inspectSaved dir key sock magic a

{- | A create that stopped before saving its identity: its pending identity
and journal are read, its journalled transactions are looked for on the
ledger (confirmed, and observed where their own after-state reads back),
and the outcome is @partial@ with no leaf. Create refuses the directory;
nothing is booted again or resubmitted.
-}
inspectIncompleteCreate :: FilePath -> FilePath -> Word32 -> IO Value
inspectIncompleteCreate dir sock magic = do
    identity <-
        Aeson.eitherDecodeFileStrict' (pendingPath dir)
            >>= either (failWith ClientRefusal) (pure :: Value -> IO Value)
    reached <-
        try $ withReads magic sock $ \prov -> Cage.withView prov $ \v -> do
            let point = Cage.viewPoint v
            recovered <- recoverInclusion dir v
            observedNow <-
                observe
                    dir
                    ""
                    ""
                    (Left (Proof.ProofInconsistent ""))
                    (Left "")
                    recovered
            pending <- unresolved <$> readJournal dir
            pure $
                receipt
                    "inspect"
                    Partial
                    [ ("incompleteCreate", identity)
                    ,
                        ( "chainPoint"
                        , toJSON (renderPoint point)
                        )
                    , ("recovery", recoveryJson recovered)
                    , ("observed", toJSON observedNow)
                    , ("unresolved", toJSON (journalTxId <$> pending))
                    ,
                        ( "reason"
                        , toJSON
                            ( "create did not finish: its identity is recorded but \
                              \its registry was not saved; create refuses this \
                              \directory and nothing is resubmitted"
                                :: Text
                            )
                        )
                    ]
    case reached of
        Right v -> pure v
        Left (e :: SomeException) -> case fromException e of
            Just (failure :: CommandFailure) -> throwIO failure
            Nothing ->
                failWith
                    NodeUnavailable
                    ("the node at " <> sock <> " could not be read: " <> show e)

-- | A chain point as the journal writes it: slot, a dot, the block hash.
renderPoint :: Cage.ChainPoint -> Text
renderPoint p =
    T.pack (show (Cage.unSlotNo (Cage.cpSlot p)))
        <> "."
        <> hexT (Cage.cpBlockHash p)

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

inspectSaved
    :: FilePath
    -> ByteString
    -> FilePath
    -> Word32
    -> InspectArgs
    -> IO Value
inspectSaved dir key sock magic a = do
    saved <- loadSaved dir (inspectBlueprint a)
    either
        (failWith ClientRefusal . renderIdentityError)
        pure
        (checkNetwork (savedConfig saved) magic)
    mirror <- openMirror saved
    reached <-
        try $ withReads magic sock $ \prov -> Cage.withView prov $ \v -> do
            let point = Cage.viewPoint v
            recovered <- recoverInclusion dir v
            live <- attachLive v saved
            root <- either (failWith Partial) pure (observedRoot live)
            advanced <- advanceMirror saved mirror root recovered
            tries <- mirrorDump mirror
            db <-
                maybe
                    (failWith ProofMissing "the mirror holds no trie for this registry")
                    pure
                    (Map.lookup (savedToken saved) tries)
            leaf <- authenticatedLeaf db key root
            outs <- liveOutputs v saved
            let holdings = holdingsFor saved key outs
                keyOutput = liveOutputFor saved key outs
            observedNow <- observe dir key root leaf keyOutput recovered
            pending <- unresolved <$> readJournal dir
            let chainPoint = renderPoint point
                application = case keyOutput of
                    Right ((i, o), e) ->
                        object
                            [ "output" .= txInText i
                            , "envelope" .= envelopeToJson e
                            , "payload" .= dataToJson (envPayload e)
                            , "deposit" .= ctlDeposit (envControl e)
                            , "controller" .= hexT (ctlController (envControl e))
                            , "lovelace" .= let Coin c = o ^. coinTxOutL in c
                            ]
                    Left why ->
                        object
                            [ "absent" .= T.pack why
                            , "holdings" .= map (txInText . fst . fst) holdings
                            ]
                labels =
                    [ ("key", toJSON (hexT key))
                    , ("chainPoint", toJSON chainPoint)
                    , ("mechanism", toJSON ("node-to-client local state query" :: Text))
                    ,
                        ( "freshness"
                        , toJSON ("read at the chain point above, in this process" :: Text)
                        )
                    , ("root", toJSON (hexT root))
                    , ("applicationOutput", application)
                    , ("recovery", recoveryJson recovered)
                    , ("mirrorAdvanced", toJSON advanced)
                    , ("observed", toJSON observedNow)
                    ]
                agrees = \case
                    Active -> length holdings == 1
                    _ -> null holdings
            pure $ case (pending, leaf) of
                (Just e, _) ->
                    receipt
                        "inspect"
                        Partial
                        ( labels
                            <> [
                                   ( "unresolved"
                                   , object
                                        [ "tx" .= journalTxId e
                                        , "step" .= journalStep e
                                        , "lastPhase" .= journalEvent e
                                        , "status" .= ("uncertain" :: Text)
                                        ]
                                   )
                               ]
                        )
                (Nothing, Left err@(RootMismatch _ _)) ->
                    receipt
                        "inspect"
                        StaleState
                        (labels <> [("refusal", toJSON (renderAuthError err))])
                (Nothing, Left err) ->
                    receipt
                        "inspect"
                        ProofInconsistent
                        (labels <> [("refusal", toJSON (renderAuthError err))])
                (Nothing, Right l)
                    | agrees l ->
                        receipt "inspect" Success (labels <> [("leaf", toJSON (leafName l))])
                    | otherwise ->
                        receipt
                            "inspect"
                            ProofInconsistent
                            ( labels
                                <> [
                                       ( "refusal"
                                       , toJSON
                                            ( "the proven leaf and this registry's holdings of the key disagree: "
                                                <> leafName l
                                                <> " with "
                                                <> T.pack (show (length holdings))
                                                <> " holding(s)"
                                            )
                                       )
                                   ]
                            )
    case reached of
        Right v -> pure v
        Left (e :: SomeException) -> case fromException e of
            Just (failure :: CommandFailure) -> throwIO failure
            Nothing ->
                failWith
                    NodeUnavailable
                    ("the node at " <> sock <> " could not be read: " <> show e)

-- ---------------------------------------------------------
-- 1. Inclusion
-- ---------------------------------------------------------

-- | What recovery found for one unresolved transaction.
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

{- | Positive inclusion evidence for each unresolved transaction, from its
saved body bound to its @prepared@ line; journals @confirmed@ for an
included one that lacked it.
-}
recoverInclusion :: FilePath -> Cage.View IO -> IO [Recovery]
recoverInclusion dir view = do
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
                [ p | p <- entries, journalTxId p == txid, journalEvent p == "prepared"
                ]
            base =
                Recovery
                    { recTx = txid
                    , recStep = journalStep e
                    , recIncluded = False
                    , recNote = ""
                    , recPrepared = case prepared of
                        (p : _) -> Just p
                        [] -> Nothing
                    , recFirstOutput = Nothing
                    , recLast = e
                    }
            miss why = pure base{recNote = why}
        case prepared of
            (p : _)
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
                                                            when (journalEvent e /= "confirmed") $
                                                                appendJournal
                                                                    dir
                                                                    ( recoveryLine
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
-- 2. Mirror
-- ---------------------------------------------------------

{- | Apply an included fold's journalled edge to the mirror when its
journalled roots authenticate the change, and require the result to be
the ledger's root. Returns the folds applied.
-}
advanceMirror
    :: Saved -> Mirror -> ByteString -> [Recovery] -> IO [Text]
advanceMirror saved mirror root recovered = fmap concat . forM recovered $ \r ->
    case recPrepared r of
        Just p
            | recIncluded r
            , Just keyHex <- journalKey p
            , Just edge <- journalEdge p
            , Just before <- journalRootBefore p
            , Just after <- journalRootAfter p
            , after == hexT root
            , Right key <- B16.decode (BC.pack (T.unpack keyHex)) -> do
                local <- mirrorRoot saved mirror
                if hexT local /= before
                    then pure []
                    else do
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
                                writeLocalState
                                    (savedDir saved)
                                    LocalState
                                        { localVersion = 1
                                        , localToken =
                                            let TokenId (AssetName n) = savedToken saved
                                            in  hexT (SBS.fromShort n)
                                        , localRoot = hexT now
                                        , localLastTx = Just (recTx r)
                                        , localLastSlot = Nothing
                                        }
                                pure [recTx r]
        _ -> pure []

-- ---------------------------------------------------------
-- 3. Observation
-- ---------------------------------------------------------

{- | Journal @observed@ for each included transaction whose prepared
after-state is read back in this run. Key-bound after-states are read
only for the inspected key.
-}
observe
    :: FilePath
    -> ByteString
    -> ByteString
    -> Either AuthError Leaf
    -> Either String ((TxIn, TxOut ConwayEra), Envelope)
    -> [Recovery]
    -> IO [Text]
observe dir key root leaf keyOutput recovered = do
    let found =
            mapMaybe
                ( \r -> case (recIncluded r, recPrepared r, recFirstOutput r) of
                    (True, Just p, Just out0) -> (,) r <$> holds p out0
                    _ -> Nothing
                )
                recovered
    forM_ found $ \(r, what) -> appendJournal dir (recoveryLine (recLast r) "observed" what)
    pure (map (recTx . fst) found)
  where
    forKey p = journalKey p == Just (hexT key)
    holds p out0 = case T.breakOn ":" <$> journalExpect p of
        Just ("reference", h)
            | SJust sc <- out0 ^. referenceScriptTxOutL
            , ":" <> hexT (scriptHashBytes (hashScript sc)) == h ->
                Just "inspect: the reference output is live carrying its script"
        Just ("state", _)
            | Just (StateDatum _) <- extractCageDatum out0 ->
                Just "inspect: the state output is live"
        Just ("request", _)
            | Just (RequestDatum _) <- extractCageDatum out0 ->
                Just "inspect: the request output is live"
        Just ("active", h)
            | forKey p
            , Right Active <- leaf
            , Right (_, e) <- keyOutput
            , ":" <> hexT (envelopeHash e) == h ->
                Just
                    ( "inspect: key Active against root 0x"
                        <> hexT root
                        <> " and its one holding carries the envelope"
                    )
        Just ("payload", h)
            | forKey p
            , Right Active <- leaf
            , Right (_, e) <- keyOutput
            , ":" <> hexT (envelopeHash e) == h ->
                Just "inspect: the key's one holding carries the updated envelope"
        Just ("terminal", _)
            | forKey p
            , Right Terminal <- leaf
            , Left _ <- keyOutput ->
                Just
                    ( "inspect: key Terminal against root 0x"
                        <> hexT root
                        <> " and no holding of it is live"
                    )
        _ -> Nothing

-- | A journal line inspect appends for a recovered transaction.
recoveryLine :: JournalEntry -> Text -> Text -> JournalEntry
recoveryLine e event detail =
    e
        { journalCommand = "inspect"
        , journalEvent = event
        , journalDetail = Just detail
        , journalInputs = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalChainPoint = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        }

txIdHexOf :: ConwayTx -> Text
txIdHexOf tx = let TxId h = txIdTx tx in hexT (hashToBytes (extractHash h))
