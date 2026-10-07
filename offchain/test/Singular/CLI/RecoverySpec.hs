{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.RecoverySpec
Description : Offline recovery over recorded preprod answers
License     : Apache-2.0

A submission can die between any two journal phases: the node's answer
never arrives, the process stops after a confirmation, its validity
expires, or an inclusion is rolled back. The next command reconciles
the journal against the chain ("Singular.CLI.Reconcile"), submitting
nothing. These stories exercise that production composition offline,
against recorded answers.

Provider provenance: every chain read comes from the recorded preprod
Koios fixture set @test/fixtures/koios/preprod@ — raw status, headers
and body recorded read-only from @https://preprod.koios.rest/api/v1@ by
the @koios-http@ recorder on 4 October 2026, replayed through the
recorded transport ("Singular.Provider.Koios.Recorded") and the
shipping Koios provider constructor. No node runs and no block is
waited for.

Saved bodies come from two producers, both bound to their @prepared@
line by byte hash and derived id through the production
"Singular.CLI.ReceiptBody" reader:

- recorded transactions, served by the same fixture set: a real
  preprod transaction whose first output the recorded snapshot shows
  live. These stand in for one of our own submissions that the chain
  did include; nothing here claims we signed them.
- transactions this suite builds and signs through the production
  'submitBuilt' seam with a deterministic test key, spending inputs the
  recorded snapshot shows live. These are never sent anywhere: the
  injected submitter either loses the answer or reports an acceptance,
  and the recorded transport cannot submit at all.

Every compared value is obtained at run time from the producer: the
candidate transactions are discovered from the fixture set, their ids,
inputs, outputs, addresses, script hashes and validity bounds are read
from the decoded bodies, and the live inputs come from the recorded
address answers. Journals, receipts, refusal classes and exit codes
are read back from the production composition; none is supplied by the
provider.

What this establishes: client recovery over recorded answers. It does
not establish ledger acceptance of any transaction here, chain
finality, a node rollback, or a connected registry lifecycle; the
recorded snapshot is a replay of one moment, not a ledger. The
saved-registry 'Singular.CLI.Reconcile.reconcile' variant is not
exercised by these stories (its deployment attach needs a recorded
booted registry the fixture set does not hold); the create-interrupted
'reconcileIncomplete' composition is.
-}
module Singular.CLI.RecoverySpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM, forM_)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import Lens.Micro ((&), (.~), (^.))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (decCBOR, decodeFullAnnotator)
import Cardano.Ledger.Core (eraProtVerHigh, hashScript)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Sequence.Strict qualified as StrictSeq

import Singular.CLI.Live (txInText)
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , OutcomeClass (..)
    , appendJournal
    , bodiesDir
    , durableWrite
    , exitCodeOf
    , readJournal
    )
import Singular.CLI.Reconcile
    ( Reconciliation (..)
    , Recovery (..)
    , reconcileIncomplete
    , reconciledJson
    , refuseUnreconciled
    )
import Singular.CLI.Registry (hexT)
import Singular.CLI.Session
    ( CommandFailure (..)
    , WriteContext (..)
    , expecting
    , submitBuilt
    , txIdHex
    )
import Singular.Provider.Koios.Client
    ( Answer (..)
    , RawRequest (..)
    , Transport (..)
    )
import Singular.Provider.Koios.Provider (koiosProvider)
import Singular.Provider.Koios.Recorded
    ( Fixture (..)
    , FixtureRequest (..)
    , FixtureSet (..)
    , loadFixtureSet
    , recordedTransport
    )
import Singular.Provider.Koios.Runtime (newIORuntime)
import Singular.Provider.Koios.Scripted (koiosWith)
import Singular.Provider.Koios.Wire (Body (..))
import Singular.Provider.Koios.Wire qualified as Wire
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( Addr
    , Coin (..)
    , ConwayEra
    , SlotNo (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.PhaseLog (noPhaseLog)
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signedTx)
import Singular.Registry.TimeSource (TimeSource)
import Singular.Registry.TxBuilder.Internal (scriptHashBytes)
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec = describe "offline recovery over recorded answers" $ do
    boundaryRows
    lostAcknowledgementRows
    confirmedInterruptionRows
    expiryRows
    rollbackRows
    repeatedRows

-- ---------------------------------------------------------
-- The recorded boundary
-- ---------------------------------------------------------

boundaryRows :: Spec
boundaryRows = describe "the recorded recovery boundary" $ do
    it
        "loads the preprod fixture set through the existing provider decoder"
        $ do
            set <- fixtureSet
            setRevision set `shouldNotBe` ""
            length (setFixtures set) `shouldSatisfy` (> 0)
    it
        "discovers recorded transactions whose live first output can \
        \settle an uncertain submission"
        $ withRecordedStory
        $ \r -> do
            let candidates = recordedCandidates r
            length candidates `shouldSatisfy` (>= 2)
            forM_ candidates $ \tx -> do
                live <- liveAt (recordedView r) (firstAddress tx)
                TxIn (txIdTx tx) (TxIx 0) `shouldSatisfy` (`Set.member` live)

-- ---------------------------------------------------------
-- A lost acknowledgement resolves from positive evidence
-- ---------------------------------------------------------

lostAcknowledgementRows :: Spec
lostAcknowledgementRows =
    describe "a lost acknowledgement reconciles offline"
        $ it
            "records one confirmed and observed for each included \
            \transaction, preserving the evidence"
        $ withRecordedStory
        $ \r -> do
            let candidates = recordedCandidates r
            length candidates `shouldSatisfy` (>= 2)
            forM_ (take 2 candidates) $ \tx ->
                withSystemTempDirectory "singular-recovery" $ \dir -> do
                    (bytes, txid) <- prepareRecorded dir tx
                    journalBefore <- journalBytes dir
                    result <- reconcileIncomplete "inspect" dir (recordedView r)
                    recIncluded (recoveryOf txid result) `shouldBe` True
                    recExcluded (recoveryOf txid result) `shouldBe` False
                    rcObserved result `shouldBe` [txid]
                    eventsOf txid dir
                        `shouldReturn` [ "prepared"
                                       , "submit-unknown"
                                       , "confirmed"
                                       , "observed"
                                       ]
                    journalAfter <- journalBytes dir
                    BS.isPrefixOf journalBefore journalAfter `shouldBe` True
                    savedBody dir txid `shouldReturn` B16.encode bytes
                    preparedLines dir `shouldReturn` 1
                    jsonField (reconciledJson result) "observed"
                        `shouldBe` Just (Aeson.toJSON [txid])
                    refuseUnreconciled result -- settled: writing proceeds

-- ---------------------------------------------------------
-- An interruption after confirmation observes once
-- ---------------------------------------------------------

confirmedInterruptionRows :: Spec
confirmedInterruptionRows =
    describe "an interruption after confirmation reconciles offline" $ do
        it
            "observes the durable after-state once, appending no second \
            \confirmation"
            $ twoCandidates
            $ \r tx _ ->
                withSystemTempDirectory "singular-recovery" $ \dir -> do
                    (_, txid) <- prepareConfirmedRecorded dir tx
                    journalBefore <- journalBytes dir
                    result <- reconcileIncomplete "inspect" dir (recordedView r)
                    rcObserved result `shouldBe` [txid]
                    eventsOf txid dir
                        `shouldReturn` ["prepared", "submitted", "confirmed", "observed"]
                    journalAfter <- journalBytes dir
                    BS.isPrefixOf journalBefore journalAfter `shouldBe` True
                    preparedLines dir `shouldReturn` 1
                    refuseUnreconciled result
        it
            "keeps an expectation the evidence does not match unresolved, \
            \as stale state"
            $ twoCandidates
            $ \r tx other ->
                withSystemTempDirectory "singular-recovery" $ \dir -> do
                    (_, txid) <-
                        prepareConfirmedRecordedWith
                            dir
                            tx
                            (referenceExpectationOf other)
                    result <- reconcileIncomplete "inspect" dir (recordedView r)
                    rcObserved result `shouldBe` []
                    eventsOf txid dir
                        `shouldReturn` ["prepared", "submitted", "confirmed"]
                    failure <- refusalOf result
                    outcomeClass failure `shouldBe` StaleState
                    exitCodeOf (outcomeClass failure)
                        `shouldBe` exitCodeOf StaleState
                    unresolvedField failure "case"
                        `shouldBe` Aeson.String "included"

-- ---------------------------------------------------------
-- Expiry needs a live spent input and a reached finite bound
-- ---------------------------------------------------------

expiryRows :: Spec
expiryRows =
    describe "an expired submission reconciles offline" $ do
        it
            "excludes one whose spent inputs are live and whose finite \
            \upper bound the recorded tip has reached"
            $ withRecordedStory
            $ \r ->
                withRecordedWrite r PastBound LostAnswer $ \dir txid saved -> do
                    upperBoundOf saved `shouldSatisfy` isJust
                    journalBefore <- journalBytes dir
                    result <- reconcileIncomplete "inspect" dir (recordedView r)
                    recExcluded (recoveryOf txid result) `shouldBe` True
                    recIncluded (recoveryOf txid result) `shouldBe` False
                    rcExcluded result `shouldBe` [txid]
                    eventsOf txid dir
                        `shouldReturn` ["prepared", "submit-unknown", "excluded"]
                    journalAfter <- journalBytes dir
                    BS.isPrefixOf journalBefore journalAfter `shouldBe` True
                    jsonField (reconciledJson result) "excluded"
                        `shouldBe` Just (Aeson.toJSON [txid])
                    refuseUnreconciled result -- settled: writing proceeds
        it "keeps an unreached bound unresolved though its inputs are live" $
            withRecordedStory $ \r ->
                withRecordedWrite r FutureBound LostAnswer $ \dir txid saved -> do
                    upperBoundOf saved `shouldSatisfy` isJust
                    result <- reconcileIncomplete "inspect" dir (recordedView r)
                    recExcluded (recoveryOf txid result) `shouldBe` False
                    recIncluded (recoveryOf txid result) `shouldBe` False
                    eventsOf txid dir
                        `shouldReturn` ["prepared", "submit-unknown"]
                    failure <- refusalOf result
                    outcomeClass failure `shouldBe` Partial
        it "keeps an unbounded one unresolved though its inputs are live" $
            withRecordedStory $ \r ->
                withRecordedWrite r LiveInputsNoBound LostAnswer $ \dir txid saved -> do
                    upperBoundOf saved `shouldBe` Nothing
                    result <- reconcileIncomplete "inspect" dir (recordedView r)
                    recExcluded (recoveryOf txid result) `shouldBe` False
                    recIncluded (recoveryOf txid result) `shouldBe` False
                    eventsOf txid dir
                        `shouldReturn` ["prepared", "submit-unknown"]
                    failure <- refusalOf result
                    outcomeClass failure `shouldBe` Partial
        it "keeps an undetermined one unresolved: no live evidence at all" $
            withRecordedStory $ \r ->
                withRecordedWrite r SpentInputsNoBound LostAnswer $ \dir txid _ -> do
                    result <- reconcileIncomplete "inspect" dir (recordedView r)
                    recExcluded (recoveryOf txid result) `shouldBe` False
                    recIncluded (recoveryOf txid result) `shouldBe` False
                    eventsOf txid dir
                        `shouldReturn` ["prepared", "submit-unknown"]
                    failure <- refusalOf result
                    outcomeClass failure `shouldBe` Partial
                    unresolvedField failure "case" `shouldBe` Aeson.String "unknown"

-- ---------------------------------------------------------
-- A rolled-back inclusion preserves identity and blocks resend
-- ---------------------------------------------------------

rollbackRows :: Spec
rollbackRows =
    describe "a rolled-back inclusion reconciles offline" $ do
        it
            "records one rolled-back from live spent inputs, keeping the \
            \identity and refusing the next write"
            $ withRecordedStory
            $ \r ->
                withRecordedWrite
                    r
                    LiveInputsNoBound
                    AnsweredAndConfirmed
                    $ \dir txid _ -> do
                        journalBefore <- journalBytes dir
                        result <- reconcileIncomplete "inspect" dir (recordedView r)
                        rcRolledBack result `shouldBe` [txid]
                        recExcluded (recoveryOf txid result) `shouldBe` False
                        recIncluded (recoveryOf txid result) `shouldBe` False
                        eventsOf txid dir
                            `shouldReturn` [ "prepared"
                                           , "submitted"
                                           , "confirmed"
                                           , "rolled-back"
                                           ]
                        jsonField (reconciledJson result) "rolledBack"
                            `shouldBe` Just (Aeson.toJSON [txid])
                        journalAfter <- journalBytes dir
                        BS.isPrefixOf journalBefore journalAfter `shouldBe` True
                        preparedLines dir `shouldReturn` 1
                        failure <- refusalOf result
                        outcomeClass failure `shouldBe` Partial
                        unresolvedField failure "case"
                            `shouldBe` Aeson.String "rolled-back"
        it "journals no rollback without live spent inputs" $
            withRecordedStory $ \r ->
                withRecordedWrite
                    r
                    SpentInputsNoBound
                    AnsweredAndConfirmed
                    $ \dir txid _ -> do
                        result <- reconcileIncomplete "inspect" dir (recordedView r)
                        rcRolledBack result `shouldBe` []
                        eventsOf txid dir
                            `shouldReturn` ["prepared", "submitted", "confirmed"]
                        failure <- refusalOf result
                        outcomeClass failure `shouldBe` StaleState

-- ---------------------------------------------------------
-- Repeated recovery records each effect once
-- ---------------------------------------------------------

repeatedRows :: Spec
repeatedRows =
    describe "a repeated reconciliation is idempotent"
        $ it
            "appends nothing the second time, over the same journal and \
            \the same bytes"
        $ withRecordedStory
        $ \r -> do
            let candidates = recordedCandidates r
            length candidates `shouldSatisfy` (>= 2)
            forM_ (take 2 candidates) $ \tx ->
                withSystemTempDirectory "singular-recovery" $ \dir -> do
                    _ <- prepareRecorded dir tx
                    first <- reconcileIncomplete "inspect" dir (recordedView r)
                    afterFirst <- journalBytes dir
                    second <- reconcileIncomplete "inspect" dir (recordedView r)
                    map recTx (rcRecovered second) `shouldBe` []
                    rcObserved second `shouldBe` []
                    rcRolledBack second `shouldBe` []
                    rcExcluded second `shouldBe` []
                    journalBytes dir `shouldReturn` afterFirst
                    preparedLines dir `shouldReturn` 1
                    -- a settled reconciliation refuses nothing, again
                    again <- try (refuseUnreconciled first)
                    case again of
                        Left failure ->
                            expectationFailure
                                ("a settled recovery refused: " <> show (outcomeClass failure))
                        Right () -> pure ()

-- ---------------------------------------------------------
-- The recorded view
-- ---------------------------------------------------------

-- | Everything a story needs from the recorded set.
data Recorded = Recorded
    { recordedView :: Cage.Session NoWitness IO
    , recordedProvider :: (Cage.Network, Cage.LedgerProvider NoWitness IO)
    , recordedCandidates :: [ConwayTx]
    }

fixtureSet :: IO FixtureSet
fixtureSet = do
    loaded <- loadFixtureSet "test/fixtures/koios/preprod"
    either
        (fail . ("the recorded preprod set does not load: " <>) . show)
        pure
        loaded

{- | Run one story over a provider served only by the recorded set, and
require at the end that only recorded reads reached the transport.
-}
withRecordedStory :: (Recorded -> IO a) -> IO a
withRecordedStory story = do
    (transport, calls) <- countedRecordedTransport
    runtime <- newIORuntime noPhaseLog (\_ -> pure ())
    let client = koiosWith 20 10 transport
        provider = koiosProvider runtime (Cage.Network 1) noTimeSource client
    Cage.withLatest (Cage.Network 1, provider) $ \view -> do
        candidates <- inclusionCandidates view
        result <-
            story
                Recorded
                    { recordedView = view
                    , recordedProvider = (Cage.Network 1, provider)
                    , recordedCandidates = candidates
                    }
        seen <- calls
        seen `shouldSatisfy` all (`elem` ["tip", "address_utxos"])
        seen `shouldNotSatisfy` elem ("submittx" :: Text)
        pure result

-- | The recorded set has no time source; recovery reads none.
noTimeSource :: IO (Either Cage.ReadFailure TimeSource)
noTimeSource =
    pure
        ( Left
            (Cage.BackendReadFailure "the recorded set records no time source")
        )

-- | The recorded transport, counting every raw request it is handed.
countedRecordedTransport :: IO (Transport IO, IO [Text])
countedRecordedTransport = do
    set <- fixtureSet
    seen <- newIORef []
    let Transport answer = recordedTransport set
    pure
        ( Transport $ \raw -> do
            modifyIORef' seen (<> [Wire.callName (rawCall raw)])
            answer raw
        , readIORef seen
        )

-- | Run a story needing two distinct recorded candidates.
twoCandidates :: (Recorded -> ConwayTx -> ConwayTx -> IO a) -> IO a
twoCandidates story = withRecordedStory $ \r -> case recordedCandidates r of
    (tx : other : _) -> story r tx other
    _ -> fail "the recorded set holds too few candidates"

-- ---------------------------------------------------------
-- Recorded transactions as saved bodies
-- ---------------------------------------------------------

{- | Every recorded transaction whose outputs pay exactly one address,
whose first output carries a reference script, and whose first
output the recorded snapshot shows live at that address.
-}
inclusionCandidates :: Cage.Session NoWitness IO -> IO [ConwayTx]
inclusionCandidates view = do
    set <- fixtureSet
    decoded <- traverse tryRecordedTx (txCborFixtures set)
    let shaped =
            [ tx
            | Just tx <- decoded
            , (out0 : more) <- [toList (tx ^. bodyTxL . outputsTxBodyL)]
            , all ((== out0 ^. addrTxOutL) . (^. addrTxOutL)) more
            , SJust _ <- [out0 ^. referenceScriptTxOutL]
            ]
    fmap concat . forM shaped $ \tx -> do
        live <- liveAt view (firstAddress tx)
        pure [tx | TxIn (txIdTx tx) (TxIx 0) `Set.member` live]

{- | One fixture's transaction when the ledger decodes it as Conway:
a recording of another era is not a candidate, and the extent stays
fail-closed through the stories' candidate-count assertions.
-}
tryRecordedTx :: Fixture -> IO (Maybe ConwayTx)
tryRecordedTx fixture = do
    outcome <- try (decodeRecordedTx fixture)
    pure $ case outcome of
        Left (_ :: IOError) -> Nothing
        Right tx -> Just tx

-- | The outputs live at an address, as the recorded answers show them.
liveAt :: Cage.Session NoWitness IO -> Addr -> IO (Set.Set TxIn)
liveAt view addr = Set.fromList . map fst <$> Cage.outputsAt view addr

-- | The first output's address of a recorded transaction.
firstAddress :: ConwayTx -> Addr
firstAddress tx = case toList (tx ^. bodyTxL . outputsTxBodyL) of
    (o : _) -> o ^. addrTxOutL
    [] -> error "a recorded transaction with no outputs"

-- | Every @tx_cbor@ fixture of the set.
txCborFixtures :: FixtureSet -> [Fixture]
txCborFixtures set =
    [ f
    | f <- setFixtures set
    , fixtureCall (fixtureRequest f) == Wire.CallTxCbor
    ]

{- | One fixture's recorded transaction, decoded by the ledger from its
own recorded bytes.
-}
decodeRecordedTx :: Fixture -> IO ConwayTx
decodeRecordedTx fixture = do
    bytes <- recordedBytesOf fixture
    either
        (fail . ("a recorded transaction does not decode: " <>) . show)
        pure
        ( decodeFullAnnotator
            (eraProtVerHigh @ConwayEra)
            "transaction"
            decCBOR
            (BSL.fromStrict bytes)
        )

-- | The raw bytes a @tx_cbor@ fixture's single row carries.
recordedBytesOf :: Fixture -> IO ByteString
recordedBytesOf fixture = do
    rows <-
        either
            (fail . ("a recorded tx_cbor body does not decode: " <>))
            pure
            ( Aeson.eitherDecodeStrict'
                (answerBody (fixtureAnswer fixture))
                :: Either String [Aeson.Value]
            )
    case rows of
        [row] -> do
            hex <-
                either
                    (fail . ("a recorded tx_cbor row carries no cbor: " <>))
                    pure
                    (parseEither (Aeson.withObject "row" (.: "cbor")) row)
            either
                (fail . ("recorded cbor is not hex: " <>))
                pure
                (B16.decode (TE.encodeUtf8 hex))
        _ -> fail "a recorded tx_cbor answer does not hold exactly one row"

{- | The bytes the fixture set recorded for this transaction, whose
request names exactly its id.
-}
recordedBytes :: ConwayTx -> IO ByteString
recordedBytes tx = do
    set <- fixtureSet
    let wanted = txIdHex tx
        namesThis f = case fixtureBody (fixtureRequest f) of
            JsonBody value -> hashNamed value == Just wanted
            _ -> False
    case [f | f <- txCborFixtures set, namesThis f] of
        [one] -> recordedBytesOf one
        _ ->
            fail "the recorded set does not hold exactly one cbor per candidate"
  where
    hashNamed value = case value of
        Aeson.Object o -> case KeyMap.lookup "_tx_hashes" o of
            Just (Aeson.Array named) -> case toList named of
                [Aeson.String h] -> Just h
                _ -> Nothing
            _ -> Nothing
        _ -> Nothing

{- | The expectation a reference-publishing transaction's readback must
find: its first output's script hash.
-}
referenceExpectationOf :: ConwayTx -> Text
referenceExpectationOf tx =
    case toList (tx ^. bodyTxL . outputsTxBodyL) of
        (o : _)
            | SJust script <- o ^. referenceScriptTxOutL ->
                "reference:" <> hexT (scriptHashBytes (hashScript script))
        _ -> "state"

-- ---------------------------------------------------------
-- Journals and saved bodies
-- ---------------------------------------------------------

{- | Save a recorded transaction's own bytes as the saved body of a
@prepared@ line naming its derived id, as an interrupted write left
them, with the node's answer never arriving.
-}
prepareRecorded :: FilePath -> ConwayTx -> IO (ByteString, Text)
prepareRecorded dir tx =
    prepareRecordedWith
        dir
        tx
        (referenceExpectationOf tx)
        "submit-unknown"

prepareConfirmedRecorded
    :: FilePath -> ConwayTx -> IO (ByteString, Text)
prepareConfirmedRecorded dir tx =
    prepareConfirmedRecordedWith dir tx (referenceExpectationOf tx)

prepareConfirmedRecordedWith
    :: FilePath -> ConwayTx -> Text -> IO (ByteString, Text)
prepareConfirmedRecordedWith dir tx expect = do
    prepared <- prepareRecordedWith dir tx expect "submitted"
    appendJournal
        dir
        (recoveryBase (snd prepared)){journalEvent = "confirmed"}
    pure prepared

prepareRecordedWith
    :: FilePath -> ConwayTx -> Text -> Text -> IO (ByteString, Text)
prepareRecordedWith dir tx expect answerEvent = do
    bytes <- recordedBytes tx
    let txid = txIdHex tx
        bodyPath = bodiesDir dir </> T.unpack txid <> ".cbor.hex"
    createDirectoryIfMissing True (bodiesDir dir)
    durableWrite bodyPath (B16.encode bytes)
    appendJournal
        dir
        (recoveryBase txid)
            { journalEvent = "prepared"
            , journalDetail = Just "an interrupted write, replayed offline"
            , journalInputs =
                Just (map txInText (toList (tx ^. bodyTxL . inputsTxBodyL)))
            , journalBody = Just bodyPath
            , journalBodyHash =
                Just (hexT (hashToBytes (hashWith @Blake2b_256 id bytes)))
            , journalNetwork = Just 1
            , journalEra = Just "Conway"
            , journalExpect = Just expect
            }
    appendJournal dir (recoveryBase txid){journalEvent = answerEvent}
    pure (bytes, txid)

recoveryBase :: Text -> JournalEntry
recoveryBase txid =
    JournalEntry
        { journalCommand = "insert"
        , journalStep = "fold"
        , journalTxId = txid
        , journalEvent = "prepared"
        , journalDetail = Nothing
        , journalInputs = Nothing
        , journalBody = Nothing
        , journalBodyHash = Nothing
        , journalNetwork = Nothing
        , journalEra = Nothing
        , journalChainPoint = Nothing
        , journalSession = Nothing
        , journalObservedTip = Nothing
        , journalKey = Nothing
        , journalExpect = Nothing
        , journalEdge = Nothing
        , journalRootBefore = Nothing
        , journalRootAfter = Nothing
        , journalTime = Nothing
        }

journalBytes :: FilePath -> IO ByteString
journalBytes dir = BS.readFile (dir </> "journal.jsonl")

savedBody :: FilePath -> Text -> IO ByteString
savedBody dir txid =
    BS.readFile (bodiesDir dir </> T.unpack txid <> ".cbor.hex")

eventsOf :: Text -> FilePath -> IO [Text]
eventsOf txid dir =
    map journalEvent . filter ((== txid) . journalTxId)
        <$> readJournal dir

preparedLines :: FilePath -> IO Int
preparedLines dir =
    length . filter ((== "prepared") . journalEvent) <$> readJournal dir

-- ---------------------------------------------------------
-- Writes over recorded inputs
-- ---------------------------------------------------------

-- | The chain evidence a body this suite builds carries.
data BodyEvidence
    = {- | Its inputs are live at the recorded address and its finite
      upper bound the recorded tip has passed: exclusion evidence.
      -}
      PastBound
    | {- | Its inputs are live and its finite upper bound lies beyond
      the recorded tip: the bound is not reached, so no exclusion.
      -}
      FutureBound
    | {- | Its inputs are live and it names no upper bound: it may
      still be included.
      -}
      LiveInputsNoBound
    | {- | It spends inputs a recorded transaction already spent: no
      evidence in either direction.
      -}
      SpentInputsNoBound

-- | Whether the injected submitter's answer ever arrives.
data WriteAnswer = LostAnswer | AnsweredAndConfirmed

{- | One write through the production 'submitBuilt' seam over the
recorded view: build from a live recorded read, sign with a
deterministic test key, save the body, journal @prepared@, and then
either lose the node's answer or hear an acceptance and its
confirmation. Returns the registry directory, the journalled
transaction's id, and the saved body read back from disk.
-}
withRecordedWrite
    :: Recorded
    -> BodyEvidence
    -> WriteAnswer
    -> (FilePath -> Text -> ConwayTx -> IO a)
    -> IO a
withRecordedWrite r evidence answer story =
    case recordedCandidates r of
        [] -> fail "the recorded set holds no candidate transaction"
        (producer : _) -> writeWith producer
  where
    writeWith producer =
        withSystemTempDirectory "singular-recovery" $ \dir -> do
            wallet <- storyWallet dir
            let registry = dir </> "registry"
                ctx = storyContext registry wallet (recordedProvider r) answer
            outcome <-
                try @CommandFailure
                    ( submitBuilt
                        ctx
                        "fold"
                        (const (expecting "state"))
                        ( \v -> do
                            SlotNo tip <- Cage.observedSlot <$> Cage.tip v
                            live <- liveAt v (firstAddress producer)
                            pure
                                ( spendingBody
                                    (inputsFor evidence producer live)
                                    (firstAddress producer)
                                    (upperFor evidence tip)
                                , ()
                                )
                        )
                    )
            txid <- case outcome of
                Left _ -> preparedTxId registry
                Right (signed, _) -> pure (txIdHex signed)
            (_, saved) <- savedTx registry txid
            story registry txid saved

-- | The inputs a body spends for its evidence.
inputsFor
    :: BodyEvidence -> ConwayTx -> Set.Set TxIn -> [TxIn]
inputsFor = \case
    SpentInputsNoBound ->
        \producer _ -> toList (producer ^. bodyTxL . inputsTxBodyL)
    _ -> \_ live -> take 2 (Set.toAscList live)

-- | The validity upper bound a body carries for its evidence.
upperFor :: BodyEvidence -> Word64 -> StrictMaybe SlotNo
upperFor PastBound tip = SJust (SlotNo (tip - 1))
upperFor FutureBound tip = SJust (SlotNo (tip + 100))
upperFor _ _ = SNothing

storyWallet :: FilePath -> IO Wallet
storyWallet dir = do
    let keyPath = dir </> "payment.skey"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    loadWallet 1 keyPath

storyContext
    :: FilePath
    -> Wallet
    -> (Cage.Network, Cage.LedgerProvider NoWitness IO)
    -> WriteAnswer
    -> WriteContext
storyContext dir wallet recordedReads = \case
    LostAnswer ->
        base{wcCapabilities = capabilities{capSubmit = loseTheAnswer}}
    AnsweredAndConfirmed ->
        base{wcCapabilities = capabilities{capSubmit = acceptAndConfirm}}
  where
    capabilities = wcCapabilities base
    base =
        WriteContext
            { wcDir = dir
            , wcCommand = "insert"
            , wcWallet = wallet
            , wcCapabilities =
                Capabilities
                    { capReads = recordedReads
                    , capSubmit = loseTheAnswer
                    , capConfirm = \_ -> pure ()
                    , capFacts = pure []
                    , capTrace = pure []
                    }
            , wcTimeout = Just 5
            }
    loseTheAnswer _ = throwIO (userError "the submission connection was lost")
    acceptAndConfirm sealed = pure (Cage.SubmitAccepted (txIdTx (signedTx sealed)))

-- | The transaction the journal's one @prepared@ line names.
preparedTxId :: FilePath -> IO Text
preparedTxId dir = do
    entries <- readJournal dir
    case [journalTxId e | e <- entries, journalEvent e == "prepared"] of
        [txid] -> pure txid
        _ -> fail "the journal does not hold exactly one prepared line"

-- | The transaction a @prepared@ line saved, read back and decoded.
savedTx :: FilePath -> Text -> IO (Maybe JournalEntry, ConwayTx)
savedTx dir txid = do
    entries <- readJournal dir
    case [ e | e <- entries, journalTxId e == txid, journalEvent e == "prepared"
         ] of
        [e] -> case journalBody e of
            Just path -> do
                hexBytes <- BS.readFile path
                bytes <-
                    either
                        (fail . ("the saved body is not hex: " <>))
                        pure
                        (B16.decode (BC.filter (not . isSpace) hexBytes))
                either
                    (fail . ("the saved body does not decode: " <>) . show)
                    (\tx -> pure (Just e, tx))
                    ( decodeFullAnnotator
                        (eraProtVerHigh @ConwayEra)
                        "transaction"
                        decCBOR
                        (BSL.fromStrict bytes)
                    )
            Nothing -> fail "the prepared line names no saved body"
        _ -> fail "the journal does not hold exactly one prepared line"

{- | A body spending inputs back to the recorded address it pays, with
the validity upper bound its evidence calls for.
-}
spendingBody :: [TxIn] -> Addr -> StrictMaybe SlotNo -> ConwayTx
spendingBody spent addr upper =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList spent
            & outputsTxBodyL
                .~ StrictSeq.fromList
                    [ mkBasicTxOut addr (MaryValue (Coin 5_000_000) mempty)
                    , mkBasicTxOut addr (MaryValue (Coin 4_000_000) mempty)
                    ]
            & vldtTxBodyL .~ ValidityInterval SNothing upper
        )

-- | A body's validity upper bound, as the production reader takes it.
upperBoundOf :: ConwayTx -> Maybe SlotNo
upperBoundOf tx = case tx ^. bodyTxL . vldtTxBodyL of
    ValidityInterval _ (SJust upper) -> Just upper
    ValidityInterval _ SNothing -> Nothing

-- ---------------------------------------------------------
-- Reading the production result
-- ---------------------------------------------------------

recoveryOf :: Text -> Reconciliation -> Recovery
recoveryOf txid r = case [rec | rec <- rcRecovered r, recTx rec == txid] of
    [one] -> one
    _ -> error "the reconciliation does not report exactly one recovery"

refusalOf :: Reconciliation -> IO CommandFailure
refusalOf r = do
    outcome <- try (refuseUnreconciled r)
    case outcome of
        Left failure -> pure failure
        Right () -> error "an unresolved recovery did not refuse the next write"

outcomeClass :: CommandFailure -> OutcomeClass
outcomeClass (CommandFailure cls _ _) = cls

-- | One field of the unresolved object a refusal carries.
unresolvedField :: CommandFailure -> Text -> Aeson.Value
unresolvedField (CommandFailure _ _ fields) key =
    case lookup "unresolved" fields of
        Just (Aeson.Object o) -> case KeyMap.lookup (Key.fromText key) o of
            Just v -> v
            Nothing -> error "the unresolved object carries no such key"
        _ -> error "the refusal carries no unresolved object"

-- | One field of the production reconciliation receipt.
jsonField :: Aeson.Value -> Text -> Maybe Aeson.Value
jsonField value key = case value of
    Aeson.Object o -> KeyMap.lookup (Key.fromText key) o
    _ -> Nothing
