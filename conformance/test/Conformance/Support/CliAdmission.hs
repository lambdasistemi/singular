{-# LANGUAGE TypeApplications #-}

-- | A refusal counts only on its retained body and rejection, read back.
module Conformance.Support.CliAdmission (spec) where

import Conformance.Cli.Admission (admit, sha256Hex, txIdHexOf)
import Conformance.Cli.Controls
    ( Receipt (..)
    , Submission (..)
    , emptyReceipt
    , rejectionEvidence
    )
import Data.Aeson (object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.List (isInfixOf)
import Data.Text qualified as T
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
spec = commandSpec >> refusalSpec

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
commandIn work = do
    createDirectoryIfMissing True (work </> "targets/t/submissions")
    let booking = txOf 10
        fold = txOf 11
        keep tx = do
            let name = "targets/t/submissions/" <> T.unpack (txIdHexOf tx) <> ".cbor.hex"
                bytes = bodyBytes tx
            BS.writeFile (work </> name) bytes
            pure
                Submission
                    { suStep = "step"
                    , suTxId = txIdHexOf tx
                    , suBodyFile = T.pack name
                    , suBodySha256 = sha256Hex bytes
                    }
    submissions <- mapM keep [booking, fold]
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
                dropped
                    `shouldSatisfy` mentions "no retained body of it was journalled"
                none <- admit work r{rcSubmissions = []}
                none `shouldSatisfy` mentions "no journalled submission is recorded"
        it
            "keeps inspect apart: it admits with no submissions and refuses any recorded"
            $ withSystemTempDirectory "admission"
            $ \work -> do
                r <- commandIn work
                let inspect = r{rcAction = "run inspect", rcCommand = Nothing}
                clean <- admit work inspect{rcSubmissions = []}
                problems clean `shouldBe` []
                dirty <- admit work inspect
                dirty `shouldSatisfy` mentions "submits nothing"
