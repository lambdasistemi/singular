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
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.FilePath ((</>))

import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Crypto.Hash.SHA256 (SHA256)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (ConwayEra)

import Conformance.Cli.Controls
    ( ProcessEvidence (..)
    , Receipt (..)
    , Resolved (..)
    , Submission (..)
    , rejectionEvidence
    )

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
admit work r
    | "run " `T.isPrefixOf` rcAction r = admitCommand work r
    | "provoke " `T.isPrefixOf` rcAction r = admitProcess work r
    | otherwise = admitTransaction work r

-- | A hand-built transaction, booking or fold: its body and rejection.
admitTransaction :: FilePath -> Receipt -> IO Receipt
admitTransaction work r = case rcTxId r of
    Nothing -> pure r{rcAdmission = Just []}
    Just txid -> do
        bodyProblems <- body txid
        (rejectionProblems, derived) <-
            if rcOutcome r == "ledger-refused"
                then rejection
                else pure ([], Nothing)
        let fromBytes = case derived of
                Just (phaseWords, failed) ->
                    r{rcPhaseWords = phaseWords, rcRefusingScripts = failed}
                Nothing -> r
        pure fromBytes{rcAdmission = Just (bodyProblems <> rejectionProblems)}
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
            Left problems -> problems
            Right hexBytes -> case B16.decode (BC.filter (not . isSpace) hexBytes) of
                Left _ -> ["the retained body is not hex"]
                Right raw -> case decodeFullAnnotator
                    (eraProtVerHigh @ConwayEra)
                    "transaction"
                    decCBOR
                    (BL.fromStrict raw) of
                    Left _ -> ["the retained body does not decode as a transaction"]
                    Right (tx :: ConwayTx)
                        | txIdHexOf tx /= txid ->
                            [ "the retained body is transaction "
                                <> txIdHexOf tx
                                <> ", not the receipt's "
                                <> txid
                            ]
                        | otherwise -> []

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

{- | An ordinary command: every submission its journal recorded must be the
digested body of that very transaction; every transaction the command's own
receipt names must be one of them, or a live output its journal read back
without submitting it, which the receipt names among its references; a
command that submitted must have recorded submissions, and one that submits
nothing must have none.
-}
admitCommand :: FilePath -> Receipt -> IO Receipt
admitCommand work r = do
    bodies <- mapM (submissionProblems work) (rcSubmissions r)
    let references = referenceTxIds r
        readBack = [reTxId x | x <- rcResolved r, reTxId x `elem` references]
        known = map suTxId (rcSubmissions r) <> readBack
        unbound =
            [ "the command names transaction "
                <> t
                <> ", but no retained body of it was journalled"
            | t <- namedTxIds r
            , t `notElem` known
            ]
        submits =
            rcAction r
                `elem` ["run create", "run insert", "run update", "run terminate"]
        shape
            | not submits && not (null (rcSubmissions r)) =
                [ rcAction r <> " submits nothing, yet submissions are recorded for it"
                ]
            | submits
            , rcOutcome r `elem` ["success", "partial"]
            , null (rcSubmissions r) =
                ["the command submitted, but no journalled submission is recorded"]
            | otherwise = []
    pure r{rcAdmission = Just (concat bodies <> unbound <> shape)}

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
admitProcess :: FilePath -> Receipt -> IO Receipt
admitProcess work r = do
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
        journal <- readRetained (peJournal p)
        files <- mapM digestProblem (peFilesBefore p <> peFilesAfter p)
        probe <- maybe (pure []) probeProblems (peSeedProbe p)
        pure
            ( either pure (journalProblems p . BC.lines) journal
                <> concat files
                <> probe
            )

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
        pure $ case bytes of
            Left problem -> [problem]
            Right b -> case Aeson.decodeStrict b of
                Just (Aeson.Object o)
                    | Just (Aeson.String "success") <- KeyMap.lookup "outcome" o -> []
                _ ->
                    [ "the seed's probe "
                        <> file
                        <> " did not succeed: the seed is spent or was not read"
                    ]

-- | @step/event@ of one journal line.
lastEventOf :: ByteString -> Text
lastEventOf l = case Aeson.decodeStrict l of
    Just (Aeson.Object o)
        | Just (Aeson.String s) <- KeyMap.lookup "journalStep" o
        , Just (Aeson.String e) <- KeyMap.lookup "journalEvent" o ->
            s <> "/" <> e
    _ -> ""

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
