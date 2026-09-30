{-# LANGUAGE TypeApplications #-}

-- | A refusal counts only on its retained body and rejection, read back.
module Conformance.Support.CliAdmission (spec) where

import Conformance.Cli.Admission (admit, sha256Hex, txIdHexOf)
import Conformance.Cli.Controls
    ( JournalSpan (..)
    , ProcessEvidence (..)
    , Receipt (..)
    , Resolved (..)
    , Submission (..)
    , emptyReceipt
    , rejectionEvidence
    )
import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BL
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((&), (.~))
import System.Directory (createDirectoryIfMissing, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body (feeTxBodyL, mkBasicTxBody)
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (eraProtVerHigh)
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (ConwayEra)

-- | Two distinct transactions.
txOf :: Integer -> ConwayTx
txOf fee = mkBasicTx (mkBasicTxBody & feeTxBodyL .~ Coin fee)

bodyBytes :: ConwayTx -> ByteString
bodyBytes = B16.encode . serialize' (eraProtVerHigh @ConwayEra)

-- | A refused receipt, its body and the node's rejection written as the backend writes them.
refusedIn :: FilePath -> ByteString -> IO Receipt
refusedIn work rejectionText = do
    createDirectoryIfMissing True (work </> "evidence")
    let tx = txOf 1
        body = bodyBytes tx
        (phaseWords, failed) = rejectionEvidence (BC.unpack rejectionText)
    BS.writeFile (work </> "evidence/body.cbor.hex") body
    BS.writeFile (work </> "evidence/rejection.txt") rejectionText
    pure
        (emptyReceipt 8 "fold-unevaluated" "duplicate" "held")
            { rcOutcome = "ledger-refused"
            , rcTxId = Just (txIdHexOf tx)
            , rcBodyFile = Just "evidence/body.cbor.hex"
            , rcBodySha256 = Just (sha256Hex body)
            , rcRejectionFile = Just "evidence/rejection.txt"
            , rcRejectionSha256 = Just (sha256Hex rejectionText)
            , rcPhaseWords = phaseWords
            , rcRefusingScripts = failed
            }

problems :: Receipt -> [String]
problems r = maybe ["not admitted"] (map T.unpack) (rcAdmission r)

mentions :: String -> Receipt -> Bool
mentions phrase r = any (phrase `isInfixOf`) (problems r)

spec :: Spec
spec = commandSpec >> refusalSpec >> processSpec

refusalSpec :: Spec
refusalSpec = describe
    "A refusal counts only on its retained body and rejection, read back"
    $ do
        let phase1 hash =
                BC.pack
                    ( "ConwayUtxowFailure (MissingScriptWitnessesUTXOW (fromList [ScriptHash \""
                        <> hash
                        <> "\"]))"
                    )
        it
            "admits the genuine body and phase-2 rejection, attributing from the retained bytes"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                budget <- BS.readFile "test/fixtures/node-refusals/budget.txt"
                r <- refusedIn work budget
                a <- admit work r
                problems a `shouldBe` []
                rcPhaseWords a `shouldSatisfy` elem "PlutusFailure"
        it
            "admits a genuine phase-1 rejection as the bytes say, with no phase-2 words"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <-
                    refusedIn
                        work
                        (phase1 "5c00128af8900fdc387758c62f8467934e4b41c6995cb2750548a153")
                a <- admit work r
                problems a `shouldBe` []
                rcPhaseWords a `shouldBe` []
                rcRefusingScripts a
                    `shouldBe` ["5c00128af8900fdc387758c62f8467934e4b41c6995cb2750548a153"]
        it
            "reports a missing rejection, changed rejection bytes and a changed digest"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                budget <- BS.readFile "test/fixtures/node-refusals/budget.txt"
                r <- refusedIn work budget
                BS.appendFile (work </> "evidence/rejection.txt") "tampered"
                changed <- admit work r
                changed
                    `shouldSatisfy` mentions "is not the bytes the receipt digests"
                BS.writeFile (work </> "evidence/rejection.txt") budget
                redigested <- admit work r{rcRejectionSha256 = Just "00"}
                redigested
                    `shouldSatisfy` mentions "is not the bytes the receipt digests"
                removeFile (work </> "evidence/rejection.txt")
                missing <- admit work r
                missing `shouldSatisfy` mentions "is missing"
        it
            "attributes from the retained phase-1 rejection when the summary still claims phase 2"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                budget <- BS.readFile "test/fixtures/node-refusals/budget.txt"
                r <- refusedIn work budget
                let (_, failed) = rejectionEvidence (BC.unpack budget)
                    swapped = phase1 (concatMap T.unpack (take 1 failed))
                BS.writeFile (work </> "evidence/rejection.txt") swapped
                a <- admit work r{rcRejectionSha256 = Just (sha256Hex swapped)}
                a `shouldSatisfy` mentions "summary of the rejection differs"
                rcPhaseWords a `shouldBe` []
        it "reports a missing body and a body that is another transaction" $
            withSystemTempDirectory "admission" $ \work -> do
                budget <- BS.readFile "test/fixtures/node-refusals/budget.txt"
                r <- refusedIn work budget
                let other = bodyBytes (txOf 2)
                BS.writeFile (work </> "evidence/body.cbor.hex") other
                another <- admit work r{rcBodySha256 = Just (sha256Hex other)}
                another `shouldSatisfy` mentions "not the receipt's"
                removeFile (work </> "evidence/body.cbor.hex")
                missing <- admit work r
                missing `shouldSatisfy` mentions "is missing"
        it "never credits a receipt that was not admitted" $ do
            let r = (emptyReceipt 0 "book" "t" "k"){rcTxId = Just "00"}
            problems r `shouldBe` ["not admitted"]

-- | An ordinary insert that journalled its booking and fold, as the backend records it.
commandIn :: FilePath -> IO Receipt
commandIn work = commandWith work []

{- | The same, its journal first reading back, without submitting, the
outputs of the transactions given, as a create reading a reused reference.
-}
commandWith :: FilePath -> [Text] -> IO Receipt
commandWith work readBacks = do
    createDirectoryIfMissing True (work </> "targets/t/submissions")
    let booking = txOf 10
        fold = txOf 11
        keep (step, tx) = do
            let name = "targets/t/submissions/" <> T.unpack (txIdHexOf tx) <> ".cbor.hex"
                bytes = bodyBytes tx
            BS.writeFile (work </> name) bytes
            pure
                Submission
                    { suStep = step
                    , suTxId = txIdHexOf tx
                    , suBodyFile = T.pack name
                    , suBodySha256 = sha256Hex bytes
                    }
    submissions <- mapM keep [("booking", booking), ("fold", fold)]
    let event step name txid extra =
            BL.toStrict
                ( Aeson.encode
                    ( object
                        ( [ "journalStep" .= step
                          , "journalEvent" .= (name :: Text)
                          , "journalTxId" .= txid
                          ]
                            <> extra
                        )
                    )
                )
        earlier = [event ("create" :: Text) "observed" ("00" :: Text) []]
        gained =
            [event ("publish-state" :: Text) "observed" t [] | t <- readBacks]
                <> concat
                    [ [ event
                            (suStep s)
                            "prepared"
                            (suTxId s)
                            ["journalBody" .= (T.pack work <> "/" <> suBodyFile s)]
                      , event (suStep s) "submitted" (suTxId s) []
                      ]
                    | s <- submissions
                    ]
    BS.writeFile
        (work </> "targets/t/journal.jsonl")
        (BC.unlines (earlier <> gained))
    pure
        (emptyReceipt 1 "run insert" "t" "k")
            { rcOutcome = "success"
            , rcCommand =
                Just
                    ( object
                        [ "booking" .= txIdHexOf booking
                        , "fold" .= txIdHexOf fold
                        , "outcome" .= ("success" :: String)
                        ]
                    )
            , rcSubmissions = submissions
            , rcResolved =
                [Resolved{reStep = "publish-state", reTxId = t} | t <- readBacks]
            , rcJournal =
                Just
                    JournalSpan
                        { jsFile = "targets/t/journal.jsonl"
                        , jsBefore = 1
                        , jsAfter = 1 + length gained
                        , jsSha256 = sha256Hex (BC.unlines gained)
                        }
            }

commandSpec :: Spec
commandSpec = describe
    "An ordinary command counts only on the bodies its journal kept"
    $ do
        it
            "admits an insert whose booking and fold bodies are the transactions it names"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <- commandIn work
                a <- admit work r
                problems a `shouldBe` []
        it "reports a missing, a changed and a mis-identified journalled body" $
            withSystemTempDirectory "admission" $ \work -> do
                r <- commandIn work
                case rcSubmissions r of
                    (first : second : _) -> do
                        BS.appendFile (work </> T.unpack (suBodyFile first)) "changed"
                        changed <- admit work r
                        changed
                            `shouldSatisfy` mentions "is not the bytes the receipt digests"
                        let swapped = r{rcSubmissions = [first{suTxId = suTxId second}, second]}
                        BS.writeFile
                            (work </> T.unpack (suBodyFile first))
                            (bodyBytes (txOf 10))
                        misnamed <- admit work swapped
                        misnamed `shouldSatisfy` mentions ", not "
                        removeFile (work </> T.unpack (suBodyFile second))
                        missing <- admit work r
                        missing `shouldSatisfy` mentions "is missing"
                    _ -> fail "the fixture journals two submissions"
        it
            "reports a named transaction never journalled, and a submitting command with none"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <- commandIn work
                dropped <- admit work r{rcSubmissions = take 1 (rcSubmissions r)}
                dropped `shouldSatisfy` mentions "the journal prepared"
                stranger <-
                    admit
                        work
                        r
                            { rcCommand =
                                Just
                                    ( object
                                        ["fold" .= txIdHexOf (txOf 13), "outcome" .= ("success" :: String)]
                                    )
                            }
                stranger
                    `shouldSatisfy` mentions "no retained body of it was journalled"
                none <- admit work r{rcSubmissions = []}
                none `shouldSatisfy` mentions "no journalled submission is recorded"
        it
            "binds a reference the command read back without submitting only when it names that reference"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                let reused = txIdHexOf (txOf 12)
                r <- commandWith work [reused]
                let create refs =
                        r
                            { rcAction = "run create"
                            , rcCommand =
                                Just
                                    ( object
                                        [ "boot" .= txIdHexOf (txOf 10)
                                        , "transactions"
                                            .= [reused, txIdHexOf (txOf 10), txIdHexOf (txOf 11)]
                                        , "references"
                                            .= [object ["role" .= ("state" :: String), "output" .= o] | o <- refs]
                                        ]
                                    )
                            }
                clean <- admit work (create [reused <> "#0"])
                problems clean `shouldBe` []
                unnamed <- admit work (create ([] :: [Text]))
                unnamed
                    `shouldSatisfy` mentions "no retained body of it was journalled"
                unread <- admit work (create [reused <> "#0"]){rcResolved = []}
                unread `shouldSatisfy` mentions "the journal read back"
        it
            "refuses a fresh submission relabelled as a read-back, its body gone, whichever it is"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                let reused = txIdHexOf (txOf 12)
                r <- commandWith work [reused]
                let named =
                        r
                            { rcAction = "run create"
                            , rcCommand =
                                Just
                                    ( object
                                        [ "boot" .= txIdHexOf (txOf 10)
                                        , "transactions"
                                            .= (reused : map suTxId (rcSubmissions r))
                                        , "references"
                                            .= [ object ["output" .= (t <> "#0")]
                                               | t <- reused : map suTxId (rcSubmissions r)
                                               ]
                                        ]
                                    )
                            }
                honest <- admit work named
                problems honest `shouldBe` []
                mapM_
                    ( \s -> do
                        let relabelled =
                                named
                                    { rcSubmissions = filter (/= s) (rcSubmissions named)
                                    , rcResolved =
                                        rcResolved named <> [Resolved (suStep s) (suTxId s)]
                                    }
                        BS.writeFile (work </> T.unpack (suBodyFile s) <> ".aside") ""
                        removeFile (work </> T.unpack (suBodyFile s))
                        a <- admit work relabelled
                        a `shouldSatisfy` mentions "the journal prepared"
                        a `shouldSatisfy` mentions "the journal read back"
                        BS.writeFile
                            (work </> T.unpack (suBodyFile s))
                            (bodyBytes (txOf (if suStep s == "booking" then 10 else 11)))
                    )
                    (rcSubmissions named)
        it
            "refuses a journal span whose lines are not the digested bytes, or none recorded"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <- commandIn work
                journal <- BS.readFile (work </> "targets/t/journal.jsonl")
                BS.writeFile
                    (work </> "targets/t/journal.jsonl")
                    ( BC.unlines
                        (map (BC.map (\c -> if c == 'b' then 'B' else c)) (BC.lines journal))
                    )
                changed <- admit work r
                changed
                    `shouldSatisfy` mentions "are not the bytes the receipt digests"
                unrecorded <- admit work r{rcJournal = Nothing}
                unrecorded
                    `shouldSatisfy` mentions "no journal span of the command is recorded"
        it
            "keeps inspect apart: it admits with no submissions and refuses any recorded"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <- commandIn work
                let inspect = r{rcAction = "run inspect", rcCommand = Nothing}
                    unchanged =
                        JournalSpan
                            { jsFile = "targets/t/journal.jsonl"
                            , jsBefore = 5
                            , jsAfter = 5
                            , jsSha256 = sha256Hex ""
                            }
                clean <-
                    admit work inspect{rcSubmissions = [], rcJournal = Just unchanged}
                problems clean `shouldBe` []
                dirty <- admit work inspect
                dirty `shouldSatisfy` mentions "submits nothing"

-- | A killed terminate as the backend records it: journal, printed receipt, kept body.
processIn :: FilePath -> IO Receipt
processIn work = do
    createDirectoryIfMissing True (work </> "targets/t/submissions")
    createDirectoryIfMissing True (work </> "evidence")
    let fold = txOf 21
        tx = txIdHexOf fold
        name = "targets/t/submissions/" <> T.unpack tx <> ".cbor.hex"
        bytes = bodyBytes fold
        line event =
            "{\"journalStep\":\"fold\",\"journalEvent\":\""
                <> event
                <> "\",\"journalTxId\":\""
                <> TE.encodeUtf8 tx
                <> "\"}"
    BS.writeFile (work </> name) bytes
    BS.writeFile
        (work </> "targets/t/journal.jsonl")
        ( BC.unlines
            [ "{\"journalStep\":\"boot\",\"journalEvent\":\"observed\",\"journalTxId\":\"00\"}"
            , line "prepared"
            , line "submitted"
            ]
        )
    BS.writeFile (work </> "evidence/printed.json") ""
    BS.writeFile
        (work </> "evidence/probe.json")
        "{\"outcome\":\"success\"}"
    BS.writeFile (work </> "evidence/before.json") "saved"
    pure
        (emptyReceipt 3 "provoke terminate-killed" "t" "k")
            { rcOutcome = "no-receipt"
            , rcEvidence = ["evidence/printed.json"]
            , rcSubmissions = [Submission "fold" tx (T.pack name) (sha256Hex bytes)]
            , rcProcess =
                Just
                    ProcessEvidence
                        { peJournal = "targets/t/journal.jsonl"
                        , peJournalBefore = 1
                        , peJournalAfter = 3
                        , peLastEvent = "fold/submitted"
                        , peSubmitted = [tx]
                        , peExit = -9
                        , peWaited = Nothing
                        , peFilesBefore = [("evidence/before.json", sha256Hex "saved")]
                        , peFilesAfter = []
                        , peSeedProbe = Just "evidence/probe.json"
                        }
            }

processSpec :: Spec
processSpec = describe
    "A provoked command counts only on what its process left, read back"
    $ do
        it "admits the journal, printed receipt, copies and probe as recorded" $
            withSystemTempDirectory "admission" $ \work -> do
                r <- processIn work
                a <- admit work r
                problems a `shouldBe` []
        it
            "reports a recorded journal line, submission or file the run's files contradict"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <- processIn work
                let with f = r{rcProcess = f <$> rcProcess r}
                lastLine <-
                    admit work (with (\p -> p{peLastEvent = "fold/confirmed"}))
                lastLine `shouldSatisfy` mentions "last line when the command stopped"
                submissions <- admit work (with (\p -> p{peSubmitted = []}))
                submissions
                    `shouldSatisfy` mentions "submissions while the command ran"
                range <- admit work (with (\p -> p{peJournalAfter = 9}))
                range `shouldSatisfy` mentions "the journal has 3 lines"
                BS.writeFile (work </> "evidence/before.json") "changed"
                copy <- admit work r
                copy `shouldSatisfy` mentions "is not the bytes the receipt digests"
        it
            "reports a failed seed probe, a changed printed receipt and a missing record"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <- processIn work
                BS.writeFile
                    (work </> "evidence/probe.json")
                    "{\"outcome\":\"client-refusal\"}"
                probe <- admit work r
                probe `shouldSatisfy` mentions "the seed is spent"
                BS.writeFile
                    (work </> "evidence/printed.json")
                    "{\"outcome\":\"success\"}"
                printed <- admit work r
                printed `shouldSatisfy` mentions "differs from evidence/printed.json"
                unrecorded <- admit work r{rcProcess = Nothing}
                unrecorded `shouldSatisfy` mentions "is not recorded"
