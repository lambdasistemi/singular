{-# LANGUAGE TypeApplications #-}

{- | Admit a receipt's retained evidence before any verdict is computed from
it.

A receipt that names a submitted transaction names the files kept beside
it: the transaction's body and, when the node refused it, the node's
rejection. Admission reads both back from the run's directory. The body
must be the digested bytes and decode to the very transaction the receipt
names. The rejection must be the digested bytes. The node's words for a
failed script, and the hashes of the scripts that failed, are then taken
from those bytes — not from the receipt's summary of them — and a summary
that differs is itself a problem. What admission finds wrong is what the
verdict reports; a receipt read without admission is never credited.
-}
module Conformance.Cli.Admission
    ( admit
    , newReplayAdmission
    , blake2b256Hex
    , lastEventOf
    , lastMaybe
    , sha256Hex
    , submittedIn
    , txIdHexOf
    ) where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Crypto.Hash.SHA256 (SHA256)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , totalCollateralTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (coinTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Ledger (ConwayEra)

import Conformance.Cli.Controls
    ( Account (..)
    , IndexerRead (..)
    , JournalSpan (..)
    , ProcessEvidence (..)
    , Receipt (..)
    , Resolved (..)
    , Submission (..)
    , decodeIndexerRead
    , rejectionEvidence
    )

{- | The blake2b-256 of hex bytes, as the ledger hashes a datum, in lowercase
hex; nothing when the text is not hex.
-}
blake2b256Hex :: Text -> Maybe Text
blake2b256Hex t = case B16.decode (TE.encodeUtf8 t) of
    Right raw ->
        Just
            ( TE.decodeUtf8
                (B16.encode (hashToBytes (hashWith @Blake2b_256 id raw)))
            )
    Left _ -> Nothing

-- | The lowercase hex SHA-256 of bytes.
sha256Hex :: ByteString -> Text
sha256Hex = TE.decodeUtf8 . B16.encode . hashToBytes . hashWith @SHA256 id

-- | A transaction's id, as receipts print it.
txIdHexOf :: ConwayTx -> Text
txIdHexOf tx =
    let TxId h = txIdTx tx
    in  TE.decodeUtf8 (B16.encode (hashToBytes (extractHash h)))

{- | Read back what the receipt names, from the run's directory, and record
what is wrong with it. A receipt that names no transaction has nothing to
admit.
-}
admit :: FilePath -> Receipt -> IO Receipt
admit = admitWithJournalReader (fmap BC.lines . BS.readFile)

{- | Admit a completed replay using journal lines read once per file. Allocate
this reader separately for every replay; never reuse it across live writes or
mutation cases. Every receipt still checks its own span, digest and evidence.
-}
newReplayAdmission :: FilePath -> IO (Receipt -> IO Receipt)
newReplayAdmission work = do
    cache <- newIORef Map.empty
    let readJournal path = do
            saved <- readIORef cache
            case Map.lookup path saved of
                Just rows -> pure rows
                Nothing -> do
                    rows <- BC.lines <$> BS.readFile path
                    modifyIORef' cache (Map.insert path rows)
                    pure rows
    pure (admitWithJournalReader readJournal work)

admitWithJournalReader
    :: (FilePath -> IO [ByteString])
    -> FilePath
    -> Receipt
    -> IO Receipt
admitWithJournalReader readJournal work r
    | "run " `T.isPrefixOf` rcAction r = admitCommand readJournal work r
    | "provoke " `T.isPrefixOf` rcAction r =
        admitProcess readJournal work r
    | "read-indexer " `T.isPrefixOf` rcAction r = admitReadback work r
    | otherwise = admitTransaction work r

{- | An indexer's read: the readback record it kept, read back from the run's
directory. The record must be the digested bytes and decode to the fields the
verdict reads; what the verdict reports about the indexer is taken from those
bytes, never from the receipt's own words.
-}
admitReadback :: FilePath -> Receipt -> IO Receipt
admitReadback work r = case (rcReadbackFile r, rcReadbackSha256 r) of
    (Just f, Just d) -> do
        read' <- try (BS.readFile (work </> T.unpack f))
        pure $ case read' of
            Left (_ :: IOException) ->
                r
                    { rcAdmission =
                        Just ["the retained readback record " <> f <> " is missing"]
                    }
            Right bytes
                | sha256Hex bytes /= d ->
                    r
                        { rcAdmission =
                            Just
                                [ "the retained readback record "
                                    <> f
                                    <> " is not the bytes the receipt digests"
                                ]
                        }
                | otherwise -> case Aeson.decodeStrict bytes >>= decodeIndexerRead of
                    Nothing ->
                        r
                            { rcAdmission =
                                Just
                                    [ "the retained readback record does not carry the fields a readback records"
                                    ]
                            }
                    Just ir ->
                        r
                            { rcAdmission = Just []
                            , rcIndexer =
                                Just
                                    ir{irIndexerDatumHashComputed = blake2b256Hex (irIndexerDatumCbor ir)}
                            }
    _ ->
        pure
            r
                { rcAdmission =
                    Just ["no retained readback record is named with its digest"]
                }

-- | A hand-built transaction, booking or fold: its body and rejection.
admitTransaction :: FilePath -> Receipt -> IO Receipt
admitTransaction work r = case rcTxId r of
    Nothing -> pure r{rcAdmission = Just []}
    Just txid -> do
        (bodyProblems, account) <- body txid
        (rejectionProblems, derived) <-
            if rcOutcome r == "ledger-refused"
                then rejection
                else pure ([], Nothing)
        let fromBytes = case derived of
                Just (phaseWords, failed) ->
                    r{rcPhaseWords = phaseWords, rcRefusingScripts = failed}
                Nothing -> r
        pure
            fromBytes
                { rcAdmission = Just (bodyProblems <> rejectionProblems)
                , rcAccount = account
                }
  where
    retained
        :: Text -> Maybe Text -> Maybe Text -> IO (Either [Text] ByteString)
    retained what file digest = case (file, digest) of
        (Just f, Just d) -> do
            read' <- try (BS.readFile (work </> T.unpack f))
            pure $ case read' of
                Left (_ :: IOException) ->
                    Left ["the retained " <> what <> " " <> f <> " is missing"]
                Right bytes
                    | sha256Hex bytes /= d ->
                        Left
                            [ "the retained "
                                <> what
                                <> " "
                                <> f
                                <> " is not the bytes the receipt digests"
                            ]
                    | otherwise -> Right bytes
        _ ->
            pure (Left ["no retained " <> what <> " is named with its digest"])

    body txid = do
        bytes <- retained "body" (rcBodyFile r) (rcBodySha256 r)
        pure $ case bytes of
            Left problems -> (problems, Nothing)
            Right hexBytes -> case B16.decode (BC.filter (not . isSpace) hexBytes) of
                Left _ -> (["the retained body is not hex"], Nothing)
                Right raw -> case decodeFullAnnotator
                    (eraProtVerHigh @ConwayEra)
                    "transaction"
                    decCBOR
                    (BL.fromStrict raw) of
                    Left _ ->
                        (["the retained body does not decode as a transaction"], Nothing)
                    Right (tx :: ConwayTx)
                        | txIdHexOf tx /= txid ->
                            (
                                [ "the retained body is transaction "
                                    <> txIdHexOf tx
                                    <> ", not the receipt's "
                                    <> txid
                                ]
                            , Nothing
                            )
                        | otherwise -> ([], Just (accountOf tx))

    rejection = do
        bytes <-
            retained "rejection" (rcRejectionFile r) (rcRejectionSha256 r)
        pure $ case bytes of
            Left problems -> (problems, Nothing)
            Right text ->
                let derived = rejectionEvidence (BC.unpack text)
                in  ( [ "the receipt's summary of the rejection differs from the retained rejection"
                      | derived /= (rcPhaseWords r, rcRefusingScripts r)
                      ]
                    , Just derived
                    )

{- | What a transaction states about its fee and collateral, read from its
body: the fee, the collateral inputs, the total collateral it declares and
the lovelace of the collateral return it declares.
-}
accountOf :: ConwayTx -> Account
accountOf tx =
    Account
        { acFee = let Coin f = body ^. feeTxBodyL in f
        , acCollateralInputs =
            map renderOutRef (Set.toList (body ^. collateralInputsTxBodyL))
        , acCollateralTotal = case body ^. totalCollateralTxBodyL of
            SJust (Coin c) -> Just c
            SNothing -> Nothing
        , acCollateralReturn = case body ^. collateralReturnTxBodyL of
            SJust o -> Just (let Coin c = o ^. coinTxOutL in c)
            SNothing -> Nothing
        , acSpends = map renderOutRef (Set.toList (body ^. inputsTxBodyL))
        }
  where
    body = tx ^. bodyTxL

{- | An ordinary command, admitted from its registry's journal. The lines the
journal gained while the command ran are read back from the run's files and
must be the bytes the receipt digests. From them alone come what the command
submitted (each @prepared@ line: step, transaction, kept body) and what it
only read back (an @observed@ line for a transaction it never prepared). The
receipt's submissions must be exactly the prepared ones, each the digested
body of that very transaction, and its read-backs exactly the observed-only
ones; every transaction the receipt names must be one it submitted, or one it
read back that the receipt names among its references. A command that
submitted must have prepared something, and one that submits nothing must
have prepared nothing.
-}
admitCommand
    :: (FilePath -> IO [ByteString]) -> FilePath -> Receipt -> IO Receipt
admitCommand readJournal work r = do
    bodies <- mapM (submissionProblems work) (rcSubmissions r)
    gained <- journalSpan readJournal work r
    let problems = case gained of
            Left spanProblems -> spanProblems
            Right ls -> reconcile ls
    pure r{rcAdmission = Just (concat bodies <> problems)}
  where
    reconcile ls =
        let events =
                [ (event, step, txid, body)
                | l <- ls
                , Just (Aeson.Object o) <- [Aeson.decodeStrict l]
                , let body = case KeyMap.lookup "journalBody" o of
                        Just (Aeson.String b) -> b
                        _ -> ""
                , Just (Aeson.String event) <- [KeyMap.lookup "journalEvent" o]
                , Just (Aeson.String step) <- [KeyMap.lookup "journalStep" o]
                , Just (Aeson.String txid) <- [KeyMap.lookup "journalTxId" o]
                ]
            prepared = [(step, txid, body) | ("prepared", step, txid, body) <- events]
            preparedIds = [txid | (_, txid, _) <- prepared]
            observedOnly =
                nub
                    [ (step, txid)
                    | ("observed", step, txid, _) <- events
                    , txid `notElem` preparedIds
                    ]
            recorded = [(suStep s, suTxId s) | s <- rcSubmissions r]
            references = referenceTxIds r
            known =
                preparedIds
                    <> [txid | (_, txid) <- observedOnly, txid `elem` references]
            submits =
                rcAction r
                    `elem` [ "run create"
                           , "run insert"
                           , "run update"
                           , "run terminate"
                           , "run fold"
                           , "run fold by token"
                           ]
        in  [ "the journal prepared "
                <> listed [(s, t) | (s, t, _) <- prepared]
                <> " while the command ran, but the receipt records the submissions "
                <> listed recorded
            | recorded /= [(s, t) | (s, t, _) <- prepared]
            ]
                <> [ "the journal keeps the body of "
                        <> suTxId s
                        <> " elsewhere than the receipt's "
                        <> suBodyFile s
                   | s <- rcSubmissions r
                   , (_, t, body) <- prepared
                   , t == suTxId s
                   , not (suBodyFile s `T.isSuffixOf` body)
                   ]
                <> [ "the journal read back "
                        <> listed observedOnly
                        <> " without submitting it, but the receipt records the read-backs "
                        <> listed [(reStep x, reTxId x) | x <- rcResolved r]
                   | [(reStep x, reTxId x) | x <- rcResolved r] /= observedOnly
                   ]
                <> [ "the command names transaction "
                        <> t
                        <> ", but no retained body of it was journalled"
                   | t <- namedTxIds r
                   , t `notElem` known
                   ]
                <> shape submits preparedIds
    listed xs = "[" <> T.intercalate ", " [s <> " " <> t | (s, t) <- xs] <> "]"
    shape submits preparedIds
        | not submits && not (null preparedIds)
            || not submits && not (null (rcSubmissions r)) =
            [ rcAction r <> " submits nothing, yet submissions are recorded for it"
            ]
        | submits
        , rcOutcome r `elem` ["success", "partial"]
        , null preparedIds || null (rcSubmissions r) =
            ["the command submitted, but no journalled submission is recorded"]
        | otherwise = []

{- | The lines a command's journal gained while it ran, read back from the
run's files and checked against the receipt's digest. A journal that does not
exist is empty, which an empty span may be.
-}
journalSpan
    :: (FilePath -> IO [ByteString])
    -> FilePath
    -> Receipt
    -> IO (Either [Text] [ByteString])
journalSpan readJournal work r = case rcJournal r of
    Nothing -> pure (Left ["no journal span of the command is recorded"])
    Just j -> do
        read' <- try (readJournal (work </> T.unpack (jsFile j)))
        pure $ case read' of
            Left (_ :: IOException)
                | jsBefore j == 0 && jsAfter j == 0 -> Right []
                | otherwise ->
                    Left ["the command's journal " <> jsFile j <> " is missing"]
            Right ls ->
                let gained = take (jsAfter j - jsBefore j) (drop (jsBefore j) ls)
                in  if jsBefore j < 0 || jsAfter j < jsBefore j || jsAfter j > length ls
                        then
                            Left
                                [ "the journal "
                                    <> jsFile j
                                    <> " has "
                                    <> T.pack (show (length ls))
                                    <> " lines, not the "
                                    <> T.pack (show (jsBefore j))
                                    <> " to "
                                    <> T.pack (show (jsAfter j))
                                    <> " the receipt records"
                                ]
                        else
                            if sha256Hex (BC.unlines gained) /= jsSha256 j
                                then
                                    Left
                                        [ "the lines the journal "
                                            <> jsFile j
                                            <> " gained while the command ran are not the bytes the receipt digests"
                                        ]
                                else Right gained

-- | What is wrong with one journalled submission's kept body.
submissionProblems :: FilePath -> Submission -> IO [Text]
submissionProblems work s = do
    read' <- try (BS.readFile (work </> T.unpack (suBodyFile s)))
    pure $ case read' of
        Left (_ :: IOException) ->
            ["the journalled body " <> suBodyFile s <> " is missing"]
        Right bytes
            | sha256Hex bytes /= suBodySha256 s ->
                [ "the journalled body "
                    <> suBodyFile s
                    <> " is not the bytes the receipt digests"
                ]
            | otherwise -> case B16.decode (BC.filter (not . isSpace) bytes) of
                Left _ -> ["the journalled body " <> suBodyFile s <> " is not hex"]
                Right raw -> case decodeFullAnnotator
                    (eraProtVerHigh @ConwayEra)
                    "transaction"
                    decCBOR
                    (BL.fromStrict raw) of
                    Left _ ->
                        [ "the journalled body "
                            <> suBodyFile s
                            <> " does not decode as a transaction"
                        ]
                    Right (tx :: ConwayTx)
                        | txIdHexOf tx /= suTxId s ->
                            [ "the journalled body "
                                <> suBodyFile s
                                <> " is transaction "
                                <> txIdHexOf tx
                                <> ", not "
                                <> suTxId s
                            ]
                        | otherwise -> []

-- | The transactions a command's own receipt names.
namedTxIds :: Receipt -> [Text]
namedTxIds r = case rcCommand r of
    Just (Aeson.Object o) ->
        [ t
        | k <- ["booking", "fold", "update", "boot"]
        , Just (Aeson.String t) <- [KeyMap.lookup k o]
        ]
            <> [ t
               | Just (Aeson.Array ts) <- [KeyMap.lookup "transactions" o]
               , Aeson.String t <- toList ts
               ]
            <> [ T.takeWhile (/= '#') t
               | Just (Aeson.String t) <- [KeyMap.lookup "pendingRequest" o]
               ]
    _ -> []

-- | The transactions whose outputs the command's receipt names as references.
referenceTxIds :: Receipt -> [Text]
referenceTxIds r = case rcCommand r of
    Just (Aeson.Object o)
        | Just (Aeson.Array refs) <- KeyMap.lookup "references" o ->
            [ T.takeWhile (/= '#') t
            | Aeson.Object ref <- toList refs
            , Just (Aeson.String t) <- [KeyMap.lookup "output" ref]
            ]
    _ -> []

{- | A provoked command: its kept bodies as an ordinary command's, its
printed receipt read back as the receipt carries it, and what its process
left read back from the run's files — the registry's journal, the copies of
a registry's saved files and the files themselves, and a seed's probe. A
recorded part that differs from those files is a problem.
-}
admitProcess
    :: (FilePath -> IO [ByteString]) -> FilePath -> Receipt -> IO Receipt
admitProcess readJournal work r = do
    bodies <- mapM (submissionProblems work) (rcSubmissions r)
    printedProblems <- printed
    processProblems <-
        maybe
            (pure ["what the command's process left is not recorded"])
            process
            (rcProcess r)
    pure
        r
            { rcAdmission =
                Just (concat bodies <> printedProblems <> processProblems)
            }
  where
    readRetained :: Text -> IO (Either Text ByteString)
    readRetained file = do
        read' <- try (BS.readFile (work </> T.unpack file))
        pure $ case read' of
            Left (_ :: IOException) -> Left ("the retained " <> file <> " is missing")
            Right bytes -> Right bytes

    printed = case rcEvidence r of
        [] -> pure ["no printed receipt of the command is kept"]
        (file : _) -> do
            bytes <- readRetained file
            pure $ case bytes of
                Left problem -> [problem]
                Right b ->
                    let value = Aeson.decodeStrict b :: Maybe Aeson.Value
                        outcome = case value of
                            Just (Aeson.Object o)
                                | Just (Aeson.String s) <- KeyMap.lookup "outcome" o -> s
                            _ -> "no-receipt"
                    in  [ "the receipt's copy of what the command printed differs from " <> file
                        | value /= rcCommand r
                        ]
                            <> [ "the receipt's outcome differs from the one " <> file <> " prints"
                               | outcome /= rcOutcome r
                               ]

    process p = do
        journal <- try (readJournal (work </> T.unpack (peJournal p)))
        files <- mapM digestProblem (peFilesBefore p <> peFilesAfter p)
        probe <- maybe (pure []) probeProblems (peSeedProbe p)
        pure
            ( either (absentJournal p) (journalProblems p) journal
                <> concat files
                <> probe
            )

    -- A journal the command never wrote is the empty span it claims, but
    -- only then: no claimed span, no last event, no submission and no kept
    -- body. Any other absence, and any journal the run cannot read, stays
    -- a problem.
    absentJournal :: ProcessEvidence -> IOException -> [Text]
    absentJournal p e
        | isDoesNotExistError e
        , peJournalBefore p == 0
        , peJournalAfter p == 0
        , T.null (peLastEvent p)
        , null (peSubmitted p)
        , null (rcSubmissions r) =
            []
        | isDoesNotExistError e =
            ["the retained " <> peJournal p <> " is missing"]
        | otherwise =
            [ "the retained "
                <> peJournal p
                <> " could not be read: "
                <> T.pack (show e)
            ]

    journalProblems p ls =
        let before = peJournalBefore p
            after = peJournalAfter p
            delta = take (after - before) (drop before ls)
            prepared =
                [ t
                | l <- delta
                , Just (Aeson.Object o) <- [Aeson.decodeStrict l]
                , Just (Aeson.String "prepared") <- [KeyMap.lookup "journalEvent" o]
                , Just (Aeson.String t) <- [KeyMap.lookup "journalTxId" o]
                ]
        in  if before < 0 || after < before || after > length ls
                then
                    [ "the journal has "
                        <> T.pack (show (length ls))
                        <> " lines, not the "
                        <> T.pack (show before)
                        <> " to "
                        <> T.pack (show after)
                        <> " the receipt records"
                    ]
                else
                    [ "the journal's last line when the command stopped is not the one recorded"
                    | maybe "" lastEventOf (lastMaybe (take after ls)) /= peLastEvent p
                    ]
                        <> [ "the journal's submissions while the command ran are not the ones recorded"
                           | submittedIn delta /= peSubmitted p
                           ]
                        <> [ "the journal's prepared bodies while the command ran are not the kept ones"
                           | prepared /= map suTxId (rcSubmissions r)
                           ]
                        <> [ "the journal's line "
                                <> T.pack (show n)
                                <> " while the command ran is not a journal record"
                           | (n, l) <- zip [before + 1 ..] delta
                           , not (isJournalRecord l)
                           ]

    digestProblem (file, digest) = do
        bytes <- readRetained file
        pure $ case bytes of
            Left problem -> [problem]
            Right b ->
                [ "the retained " <> file <> " is not the bytes the receipt digests"
                | sha256Hex b /= digest
                ]

    probeProblems file = do
        bytes <- readRetained file
        case bytes of
            Left problem -> pure [problem]
            Right b -> case Aeson.decodeStrict b of
                Just (Aeson.Object o)
                    | Just (Aeson.String "spent") <- KeyMap.lookup "expectation" o ->
                        probeSpent file o
                    | Just (Aeson.String "success") <- KeyMap.lookup "outcome" o ->
                        pure []
                _ ->
                    pure
                        [ "the seed's probe "
                            <> file
                            <> " did not succeed: the seed is spent or was not read"
                        ]

    -- A spent-by wrapper for a raced seed: the file names the expectation,
    -- the probe receipt, the seed, the one boot transaction that spent it,
    -- and the journal that shows it. Anything else is a problem with it.
    probeSpent :: Text -> KeyMap.KeyMap Aeson.Value -> IO [Text]
    probeSpent file o = case ( KeyMap.lookup "receipt" o
                             , KeyMap.lookup "seed" o
                             , KeyMap.lookup "spentBy" o
                             , KeyMap.lookup "journal" o
                             ) of
        ( Just (Aeson.String receipt)
            , Just (Aeson.String seed)
            , Just (Aeson.String spentBy)
            , Just (Aeson.String journalRel)
            )
                | T.length spentBy == 64 -> do
                    refused <- readRetained (T.pack (work </> T.unpack receipt))
                    case refused of
                        Left problem -> pure [problem]
                        Right b -> case Aeson.decodeStrict b of
                            Just (Aeson.Object rr)
                                | Just (Aeson.String "client-refusal") <- KeyMap.lookup "outcome" rr ->
                                    checkBinding seed spentBy journalRel
                            _ ->
                                pure
                                    [ "the raced seed's probe "
                                        <> receipt
                                        <> " does not refuse a spent seed"
                                    ]
        _ ->
            pure
                [ "the seed-spend binding "
                    <> file
                    <> " names no receipt, seed, spender and journal"
                ]
      where
        checkBinding seed spentBy journalRel = do
            entries <- try (BS.readFile (work </> T.unpack journalRel))
            case entries of
                Left (e :: IOException) ->
                    pure
                        [ "the bound journal "
                            <> journalRel
                            <> " cannot be read: "
                            <> T.pack (show e)
                        ]
                Right ls ->
                    let spenders =
                            [ txid
                            | l <- BC.lines ls
                            , Just (Aeson.Object m) <- [Aeson.decodeStrict l]
                            , Just (Aeson.String txid) <- [KeyMap.lookup "journalTxId" m]
                            , Just (Aeson.String event) <- [KeyMap.lookup "journalEvent" m]
                            , event == "prepared"
                            , Just (Aeson.Array ins) <- [KeyMap.lookup "journalInputs" m]
                            , Aeson.String seed `elem` foldr (:) [] ins
                            ]
                    in  pure
                            [ "the seed-spend binding "
                                <> file
                                <> " is not spent once by its boot transaction"
                            | nub spenders /= [spentBy]
                            ]

-- | @step/event@ of one journal line.
lastEventOf :: ByteString -> Text
lastEventOf l = case Aeson.decodeStrict l of
    Just (Aeson.Object o)
        | Just (Aeson.String s) <- KeyMap.lookup "journalStep" o
        , Just (Aeson.String e) <- KeyMap.lookup "journalEvent" o ->
            s <> "/" <> e
    _ -> ""

{- | Whether a journal line is a journal record: an object carrying the
three fields the verdict reads — the step, the event and the
transaction — as text, as the producer's 'JournalEntry' writes them.
Anything else in the claimed span is corruption, even when the
comparisons that skip undecodable lines would agree.
-}
isJournalRecord :: ByteString -> Bool
isJournalRecord l = case Aeson.decodeStrict l of
    Just (Aeson.Object o) -> all isTextField ["journalStep", "journalEvent", "journalTxId"]
      where
        isTextField k = case KeyMap.lookup k o of
            Just (Aeson.String _) -> True
            _ -> False
    _ -> False

-- | The transactions a journal slice records as submitted, in order.
submittedIn :: [ByteString] -> [Text]
submittedIn ls =
    [ t
    | l <- ls
    , Just (Aeson.Object o) <- [Aeson.decodeStrict l]
    , Just (Aeson.String "submitted") <- [KeyMap.lookup "journalEvent" o]
    , Just (Aeson.String t) <- [KeyMap.lookup "journalTxId" o]
    ]

lastMaybe :: [a] -> Maybe a
lastMaybe = foldl (\_ x -> Just x) Nothing
