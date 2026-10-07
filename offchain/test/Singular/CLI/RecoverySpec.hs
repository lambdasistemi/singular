{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.RecoverySpec
Description : Offline recovery: a recorded-answer core and a labelled synthetic supplement
License     : Apache-2.0

A submission can die between any two journal phases: the node's answer
never arrives, the process stops after a confirmation, its validity
expires, or an inclusion is rolled back. The next command reconciles
the journal against the chain ("Singular.CLI.Reconcile"), submitting
nothing. This module holds two groups, kept distinct by name and by
provenance:

- the __recovery core on recorded answers (incomplete create)__, which
  exercises the production 'reconcileIncomplete' composition against
  recorded answers; and
- a __synthetic saved-registry supplement__ (its own describe group,
  labelled "not recorded answers"), which exercises the production
  'reconcile' composition over a stub provider this suite builds. A
  synthetic read is never a recorded one: nothing in that group is
  served by the recorded fixture set.

Provider provenance of the recorded core: every chain read it makes
comes from the recorded preprod Koios fixture set
@test/fixtures/koios/preprod@ — raw status, headers and body recorded
read-only from @https://preprod.koios.rest/api/v1@ by the @koios-http@
recorder on 4 October 2026, replayed through the recorded transport
("Singular.Provider.Koios.Recorded") and the shipping Koios provider
constructor. No node runs and no block is waited for in either group.

Provider provenance of the synthetic supplement: a stub session over
the repository's own fixture facilities serves a booted registry and
its public history; see the group's own documentation below. No
recorded fixture set holds a booted registry.

Saved bodies in the recorded core come from two producers, both bound
to their @prepared@ line by byte hash and derived id through the
production "Singular.CLI.ReceiptBody" reader:

- recorded transactions, served by the same fixture set: a real
  preprod transaction whose first output the recorded snapshot shows
  live. These stand in for one of our own submissions that the chain
  did include; nothing here claims we signed them.
- transactions this suite builds and signs through the production
  'submitBuilt' seam with a deterministic test key, spending inputs the
  recorded snapshot shows live. These are never sent anywhere: the
  injected submitter either loses the answer or reports an acceptance,
  and the recorded transport cannot submit at all.

Every compared value in the recorded core is obtained at run time from
the producer: the candidate transactions are discovered from the
fixture set, their ids, inputs, outputs, addresses, script hashes and
validity bounds are read from the decoded bodies, and the live inputs
come from the recorded address answers. Journals, receipts, refusal
classes and exit codes are read back from the production composition;
none is supplied by the provider.

What the recorded core establishes: client recovery over recorded
answers for a create interrupted before its registry was saved. It
does not establish ledger acceptance of any transaction here, chain
finality, a node rollback, or a connected registry lifecycle; the
recorded snapshot is a replay of one moment, not a ledger. Saved-registry
reconciliation on recorded chain answers is not exercised anywhere in
this module and remains uncovered: the recorded fixture set holds no
booted registry, and the saved-registry 'Singular.CLI.Reconcile.reconcile'
variant runs only in the synthetic supplement, whose provider and
history are synthetic.
-}
module Singular.CLI.RecoverySpec (spec) where

import Control.Exception (throwIO, try)
import Control.Monad (forM, forM_, when)
import Control.Monad.State.Strict (evalState)
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
import Data.ByteString.Short qualified as SBS
import Data.Char (isSpace)
import Data.Foldable (toList)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
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
import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Alonzo.Scripts (AsIx (..))
import Cardano.Ledger.Alonzo.TxWits (Redeemers (..))
import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Api.Tx (bodyTxL, mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , inputsTxBodyL
    , mintTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.Api.Tx.Wits (rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Binary
    ( decCBOR
    , decodeFullAnnotator
    , serialize'
    )
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose (..))
import Cardano.Ledger.Core (eraProtVerHigh, hashScript)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Data.Sequence.Strict qualified as StrictSeq
import MPF.Backend.Pure (emptyMPFInMemoryDB)
import PlutusCore.Data qualified as PLC

import Control.Tracer (nullTracer)
import Singular.Application.OpenDatum.Envelope
    ( Control (..)
    , Envelope (..)
    , StateAsset (..)
    , envelopeHash
    , envelopeToData
    , envelopeVersion
    )
import Singular.Application.OpenDatum.Release (liveEnvelope)
import Singular.CLI.Live
    ( Saved (..)
    , applicationAddr
    , txInText
    )
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
    , reconcile
    , reconcileIncomplete
    , reconciledJson
    , refuseUnreconciled
    )
import Singular.CLI.Registry (hexT, mkRegistryConfig, pinsOf)
import Singular.CLI.Session
    ( CommandFailure (..)
    , Expectation (..)
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
import Singular.Registry.AssetName (deriveAssetName)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Config
    ( CageConfig (..)
    , bootStateFromCfg
    , defaultProcessTime
    , defaultRetractTime
    )
import Singular.Registry.Deployment (Deployment (..), parseOutRef)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger
    ( Addr
    , Coin (..)
    , ConwayEra
    , Root (..)
    , SlotNo (..)
    , TokenId (..)
    )
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.SessionIO qualified as Cage
import Singular.Registry.Signing (signedTx)
import Singular.Registry.StubSession
    ( servingSession
    , stubSession
    , withAddressOutputs
    , withTip
    )
import Singular.Registry.TimeSource (TimeSource)
import Singular.Registry.Trie (Trie (getRoot))
import Singular.Registry.Trie.Pure (stateTrie)
import Singular.Registry.TxBuilder.BookingFixture qualified as Booking
import Singular.Registry.TxBuilder.Internal
    ( addrKeyHashBytes
    , cageAddrFromCfg
    , cagePolicyIdFromCfg
    , extractCageDatum
    , mkInlineDatum
    , mkRequestDatumWith
    , policyIdFromPin
    , requestAddrFromCfg
    , scriptHashBytes
    , toPlcData
    , txInToRef
    , walkEdge
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , MintRedeemer (..)
    , OnChainRequest (..)
    , OnChainRoot (..)
    , RequestAction (..)
    , UpdateRedeemer (..)
    , edgeInsertActive
    )
import Singular.Registry.Wallet (Wallet (..), loadWallet)

spec :: Spec
spec = do
    describe "offline recovery over recorded answers" $ do
        boundaryRows
        lostAcknowledgementRows
        confirmedInterruptionRows
        expiryRows
        rollbackRows
        repeatedRows
    syntheticRows

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
            \upper bound the recorded tip has exactly reached"
            $ withRecordedStory
            $ \r ->
                withRecordedWrite r PastBound LostAnswer $ \dir txid saved -> do
                    upperBoundOf saved `shouldSatisfy` isJust
                    -- the boundary itself: the bound equals the recorded tip
                    upperBoundOf saved `shouldBe` Just (recordedTip r)
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
        it "keeps a bound one slot ahead of the recorded tip unresolved" $
            withRecordedStory $ \r ->
                withRecordedWrite r FutureBound LostAnswer $ \dir txid saved -> do
                    upperBoundOf saved `shouldSatisfy` isJust
                    upperBoundOf saved `shouldBe` Just (beyondBy 1 (recordedTip r))
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
    describe "a repeated reconciliation is idempotent" $ do
        it
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
        it
            "repeats a rolled-back, an excluded and an unresolved outcome \
            \without new effects, over the same bytes"
            $ withRecordedStory
            $ \r ->
                forM_
                    [ (LiveInputsNoBound, AnsweredAndConfirmed)
                    , (PastBound, LostAnswer)
                    , (SpentInputsNoBound, LostAnswer)
                    ]
                    $ \(evidence, answer) ->
                        withRecordedWrite r evidence answer $ \dir txid _ -> do
                            bodyPath <- preparedBody dir txid
                            bodyBefore <- BS.readFile bodyPath
                            first <- reconcileIncomplete "inspect" dir (recordedView r)
                            afterFirst <- journalBytes dir
                            second <- reconcileIncomplete "inspect" dir (recordedView r)
                            -- an excluded outcome settles; a rolled-back or
                            -- unresolved one stays open and is re-reported
                            -- without journalling anything new
                            let staysOpen = case evidence of PastBound -> False; _ -> True
                            map recTx (rcRecovered second) `shouldBe` [txid | staysOpen]
                            rcObserved second `shouldBe` []
                            rcRolledBack second `shouldBe` []
                            rcExcluded second `shouldBe` []
                            journalBytes dir `shouldReturn` afterFirst
                            preparedLines dir `shouldReturn` 1
                            BS.readFile bodyPath `shouldReturn` bodyBefore
                            -- the repeated refusal keeps the first's class
                            let classOf = either (Left . outcomeClass) Right
                            firstClass <- classOf <$> try (refuseUnreconciled first)
                            secondClass <- classOf <$> try (refuseUnreconciled second)
                            firstClass `shouldBe` secondClass

-- ---------------------------------------------------------
-- The recorded view
-- ---------------------------------------------------------

-- | Everything a story needs from the recorded set.
data Recorded = Recorded
    { recordedView :: Cage.Session NoWitness IO
    , recordedProvider :: (Cage.Network, Cage.LedgerProvider NoWitness IO)
    , recordedCandidates :: [ConwayTx]
    , recordedTip :: SlotNo
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
    runtime <- newIORuntime nullTracer (\_ -> pure ())
    let client = koiosWith 20 10 transport
        provider = koiosProvider runtime (Cage.Network 1) noTimeSource client
    Cage.withLatest (Cage.Network 1, provider) $ \view -> do
        candidates <- inclusionCandidates view
        tip <- Cage.tip view
        result <-
            story
                Recorded
                    { recordedView = view
                    , recordedProvider = (Cage.Network 1, provider)
                    , recordedCandidates = candidates
                    , recordedTip = Cage.observedSlot tip
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

-- | A slot the given number beyond another.
beyondBy :: Word64 -> SlotNo -> SlotNo
beyondBy n (SlotNo slot) = SlotNo (slot + n)

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

-- | The saved-body path the one prepared line of a transaction names.
preparedBody :: FilePath -> Text -> IO FilePath
preparedBody dir txid = do
    entries <- readJournal dir
    case [ p
         | e <- entries
         , journalTxId e == txid
         , journalEvent e == "prepared"
         , Just p <- [journalBody e]
         ] of
        [path] -> pure path
        _ -> fail "the journal does not hold exactly one prepared body"

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
            ctx <- storyContext registry wallet (recordedProvider r) answer
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
upperFor PastBound tip = SJust (SlotNo tip)
upperFor FutureBound tip = SJust (SlotNo (tip + 1))
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
    -> IO WriteContext
storyContext dir wallet recordedReads answer = do
    confirmed <- newIORef Map.empty
    placed <- newIORef Map.empty
    let submit = case answer of
            LostAnswer -> const (throwIO (userError "the submission connection was lost"))
            AnsweredAndConfirmed -> pure . Cage.SubmitAccepted . txIdTx . signedTx
    pure
        WriteContext
            { wcDir = dir
            , wcCommand = "insert"
            , wcWallet = wallet
            , wcCapabilities =
                Capabilities
                    { capReads = recordedReads
                    , capSubmit = submit
                    , capConfirm = \_ -> pure ()
                    , capFacts = pure []
                    , capTrace = pure []
                    }
            , wcTimeout = Just 5
            , wcTracer = nullTracer
            , wcSource = "recorded"
            , wcConfirmed = confirmed
            , wcPlaced = placed
            }

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

-- ---------------------------------------------------------
-- The synthetic saved-registry supplement (not recorded answers)
-- ---------------------------------------------------------

{- | A saved registry this suite synthesizes from the repository's own
fixture facilities, labelled synthetic wherever it is named. Its
provider is a stub session: a booted registry whose state output and
application holding are live at their addresses, and whose public
history serves the boot and one insert-active fold as one recorded
block. It stands in for a recorded booted registry, which no recorded
fixture set holds; nothing here is a recorded chain answer, and no
ledger ever accepted these transactions.
-}
data Synthetic = Synthetic
    { syntheticDir :: FilePath
    , syntheticSaved :: Saved
    , syntheticView :: Cage.Session NoWitness IO
    , syntheticTxId :: Text
    , syntheticKey :: ByteString
    , syntheticExpectation :: Text
    }

{- | Build, sign, journal and confirm one insert-active fold through the
production 'submitBuilt' seam over the synthetic provider, then run
the story with the fold's history published or withheld.
-}
withSyntheticSavedRegistry :: Bool -> (Synthetic -> IO a) -> IO a
withSyntheticSavedRegistry publishHistory story =
    withSystemTempDirectory "singular-synthetic" $ \dir -> do
        wallet <- storyWallet dir
        historyRef <- newIORef emptyHistory
        confirmed <- newIORef Map.empty
        placed <- newIORef Map.empty
        let cfg = Booking.cfg
            seed =
                either
                    (error . ("synthetic fixture: " <>))
                    id
                    (parseOutRef (T.pack (replicate 64 '7' <> "#0")))
            seedOut =
                mkBasicTxOut (walletAddr wallet) (MaryValue (Coin 10_000_000) mempty)
            tid@(TokenId (AssetName name)) =
                TokenId (AssetName (SBS.toShort (deriveAssetName (txInToRef seed))))
            policy = cagePolicyIdFromCfg cfg
            key = "synthetic-key"
            bootRoot = BS.replicate 32 0
            activeRoot =
                evalState
                    (walkEdge stateTrie key edgeInsertActive >> getRoot stateTrie)
                    emptyMPFInMemoryDB
            stateOutAt root =
                mkBasicTxOut
                    (cageAddrFromCfg cfg Testnet)
                    ( MaryValue
                        (Coin 2_000_000)
                        (MultiAsset (Map.singleton policy (Map.singleton (AssetName name) 1)))
                    )
                    & datumTxOutL
                        .~ mkInlineDatum
                            (toPlcData (StateDatum (bootStateFromCfg cfg (OnChainRoot root))))
            bootStateOut = stateOutAt bootRoot
            foldStateOut = stateOutAt (unRoot activeRoot)
            -- The delivered envelope is the datum the request itself
            -- carries (#419): the fold's receiving output presents
            -- exactly what the request names, inline.
            envelopeData = envelopeToData envelope
            destination = (serialiseAddr (applicationAddr saved), Just envelopeData)
            requestOut =
                mkBasicTxOut
                    (requestAddrFromCfg cfg tid Testnet)
                    (MaryValue (Coin 2_000_000) mempty)
                    & datumTxOutL
                        .~ mkInlineDatum
                            ( mkRequestDatumWith
                                tid
                                (walletAddr wallet)
                                key
                                edgeInsertActive
                                2_000_000
                                0
                                destination
                            )
            boot :: ConwayTx
            boot =
                mkBasicTx
                    ( mkBasicTxBody
                        & inputsTxBodyL .~ Set.singleton seed
                        & outputsTxBodyL
                            .~ StrictSeq.fromList [bootStateOut, requestOut]
                        & mintTxBodyL
                            .~ MultiAsset (Map.singleton policy (Map.singleton (AssetName name) 1))
                    )
                    & witsTxL . rdmrsTxWitsL
                        .~ Redeemers
                            ( Map.singleton
                                (ConwayMinting (AsIx 0))
                                (Data (toPlcData (Minting (txInToRef seed))), ExUnits 0 0)
                            )
            bootId = txIdTx boot
            bootStateIn = TxIn bootId (TxIx 0)
            bootRequestIn = TxIn bootId (TxIx 1)
            -- The fold's id is its body's hash: signing changes no
            -- identifier, so the live references are known before the
            -- signed body exists.
            foldStateIn = TxIn (txIdTx unsigned) (TxIx 0)
            foldHoldingIn = TxIn (txIdTx unsigned) (TxIx 1)
            envelope =
                Envelope
                    { envControl =
                        Control
                            { ctlVersion = envelopeVersion
                            , ctlRegistry =
                                StateAsset
                                    (scriptHashBytes (cfgScriptHash cfg))
                                    (SBS.fromShort name)
                            , ctlActivePolicy = SBS.fromShort (cfgActivePolicy cfg)
                            , ctlKey = key
                            , ctlController = addrKeyHashBytes (walletAddr wallet)
                            , ctlDeposit = 2_000_000
                            }
                    , envPayload = PLC.Constr 0 []
                    }
            holding =
                mkBasicTxOut
                    (applicationAddr saved)
                    ( MaryValue
                        (Coin 2_000_000)
                        ( MultiAsset
                            ( Map.singleton
                                (policyIdFromPin (cfgActivePolicy cfg))
                                (Map.singleton (AssetName (SBS.toShort key)) 1)
                            )
                        )
                    )
                    & datumTxOutL .~ mkInlineDatum (envelopeToData envelope)
            unsigned :: ConwayTx
            unsigned =
                mkBasicTx
                    ( mkBasicTxBody
                        & inputsTxBodyL .~ Set.fromList [bootStateIn, bootRequestIn]
                        & outputsTxBodyL .~ StrictSeq.fromList [foldStateOut, holding]
                    )
                    & witsTxL . rdmrsTxWitsL
                        .~ Redeemers
                            ( Map.singleton
                                (ConwaySpending (AsIx 0))
                                (Data (toPlcData (Modify [Update []])), ExUnits 0 0)
                            )
            deployment =
                Deployment
                    { depRelease = "synthetic-saved-registry-supplement"
                    , depLeanRevision = "no-ledger-admission-claim"
                    , depNetworkMagic = 1
                    , depSeedOutRef = T.pack (replicate 64 '7' <> "#0")
                    , depCageToken = hexT (SBS.fromShort name)
                    , depStatePolicy = hexT (scriptHashBytes (cfgScriptHash cfg))
                    , depRequestHash = ""
                    , depApplicationHash = hexT (SBS.fromShort (cfgApplicationPolicy cfg))
                    , depRepresentativePolicy = hexT (SBS.fromShort (cfgActivePolicy cfg))
                    , depProcessTime = defaultProcessTime cfg
                    , depRetractTime = defaultRetractTime cfg
                    , depTip = 1_000
                    , depReferenceScripts = []
                    , depBootstrapTxs = []
                    }
            saved =
                Saved
                    (dir </> "registry")
                    (mkRegistryConfig 1 (walletAddr wallet) (pinsOf cfg) deployment)
                    cfg
                    Booking.codes
                    tid
            expectation = "active:" <> hexT (envelopeHash envelope)
            serve addr
                | addr == cageAddrFromCfg cfg Testnet =
                    pure [(foldStateIn, foldStateOut)]
                | addr == applicationAddr saved = pure [(foldHoldingIn, holding)]
                | otherwise =
                    fail "the synthetic registry serves no other address"
            session =
                ( withTip
                    (Cage.TipObservation (SlotNo 7) (BS.replicate 32 3) 7 0)
                    (withAddressOutputs serve stubSession)
                )
                    { Cage.history = \_ _ -> Right <$> readIORef historyRef
                    }
            provider = servingSession session
            ctx =
                WriteContext
                    { wcDir = dir </> "registry"
                    , wcCommand = "insert"
                    , wcWallet = wallet
                    , wcCapabilities =
                        Capabilities
                            { capReads = provider
                            , capSubmit =
                                pure . Cage.SubmitAccepted . txIdTx . signedTx
                            , capConfirm = \_ -> pure ()
                            , capFacts = pure []
                            , capTrace = pure []
                            }
                    , wcTimeout = Just 5
                    , wcTracer = nullTracer
                    , wcSource = "fixture"
                    , wcConfirmed = confirmed
                    , wcPlaced = placed
                    }
        -- Permanent computed guard over the actual constructed request
        -- and holding: absent or foreign carried datum cannot regress
        -- silently while the replay still succeeds.
        case extractCageDatum requestOut of
            Just (RequestDatum request) -> do
                let carried = snd (requestDestination request)
                    delivered =
                        either
                            (const Nothing)
                            (Just . envelopeToData)
                            (liveEnvelope holding)
                when (carried /= delivered) $
                    fail
                        "the synthetic request does not carry the datum \
                        \its delivered holding presents"
            _ ->
                fail
                    "the synthetic request output carries no request datum"
        (signed, _) <-
            submitBuilt
                ctx
                "fold"
                ( \(key', wanted) -> Expectation (Just key') wanted Nothing Nothing Nothing
                )
                (\_ -> pure (unsigned, (key, expectation)))
        when publishHistory $
            writeIORef
                historyRef
                ( syntheticHistory
                    boot
                    [(seed, seedOut)]
                    [(bootStateIn, bootStateOut), (bootRequestIn, requestOut)]
                    signed
                )
        story
            Synthetic
                { syntheticDir = dir </> "registry"
                , syntheticSaved = saved
                , syntheticView = session
                , syntheticTxId = txIdHex signed
                , syntheticKey = key
                , syntheticExpectation = expectation
                }

-- | An empty stream: history that answers nothing.
emptyHistory :: Cage.HistoryStream IO
emptyHistory = Cage.HistoryStream (pure (Right Nothing))

{- | The registry's public history as one recorded block: the boot
creates the state and the request, and the fold spends both.
-}
syntheticHistory
    :: ConwayTx
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> ConwayTx
    -> Cage.HistoryStream IO
syntheticHistory boot bootSpent foldSpent signed =
    Cage.HistoryStream
        ( pure
            ( Right
                ( Just
                    ( Cage.HistoryBlock
                        7
                        (record boot bootSpent :| [record signed foldSpent])
                    , emptyHistory
                    )
                )
            )
        )
  where
    record tx spent =
        Cage.HistoricalTransaction
            { Cage.historicalId = txIdTx tx
            , Cage.historicalCbor = serialize' (eraProtVerHigh @ConwayEra) tx
            , Cage.historicalTx = tx
            , Cage.spentOutputs = spent
            , Cage.referenceOutputs = []
            , Cage.createdOutputs =
                [ (TxIn (txIdTx tx) (TxIx (fromIntegral index)), out)
                | (index, out) <-
                    zip [0 :: Int ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
                ]
            , Cage.scriptValid = True
            }

syntheticRows :: Spec
syntheticRows =
    describe
        "a synthetic saved-registry reconciliation (not recorded answers)"
        $ do
            it "observes the keyed after-state through replayed public history" $
                withSyntheticSavedRegistry True $ \s -> do
                    entries <- readJournal (syntheticDir s)
                    case [e | e <- entries, journalEvent e == "prepared"] of
                        [prepared] -> do
                            journalKey prepared `shouldBe` Just (hexT (syntheticKey s))
                            journalExpect prepared `shouldBe` Just (syntheticExpectation s)
                        _ -> fail "the synthetic journal holds no single prepared line"
                    journalBefore <- journalBytes (syntheticDir s)
                    bodyBefore <- case [journalBody e | e <- entries, journalEvent e == "prepared"] of
                        [Just path] -> BS.readFile path
                        _ -> fail "the prepared line names no saved body"
                    result <-
                        reconcile
                            "inspect"
                            (syntheticDir s)
                            (syntheticSaved s)
                            (syntheticView s)
                    rcObserved result `shouldBe` [syntheticTxId s]
                    recIncluded (recoveryOf (syntheticTxId s) result) `shouldBe` True
                    eventsOf (syntheticTxId s) (syntheticDir s)
                        `shouldReturn` ["prepared", "submitted", "confirmed", "observed"]
                    journalAfter <- journalBytes (syntheticDir s)
                    BS.isPrefixOf journalBefore journalAfter `shouldBe` True
                    entriesAfter <- readJournal (syntheticDir s)
                    case [journalBody e | e <- entriesAfter, journalEvent e == "prepared"] of
                        [Just path] -> BS.readFile path `shouldReturn` bodyBefore
                        _ -> fail "the prepared line names no saved body"
                    jsonField (reconciledJson result) "observed"
                        `shouldBe` Just (Aeson.toJSON [syntheticTxId s])
                    refuseUnreconciled result -- settled: writing proceeds
            it "refuses without history rather than serving an unreplayed trie" $
                withSyntheticSavedRegistry False $ \s -> do
                    journalBefore <- journalBytes (syntheticDir s)
                    outcome <-
                        try @CommandFailure
                            ( reconcile
                                "inspect"
                                (syntheticDir s)
                                (syntheticSaved s)
                                (syntheticView s)
                            )
                    case outcome of
                        Right _ -> expectationFailure "an unreplayed trie reconciled"
                        Left failure -> do
                            outcomeClass failure `shouldBe` StaleState
                            fieldsOf failure "trieRefusal" `shouldSatisfy` isJust
                            journalBytes (syntheticDir s) `shouldReturn` journalBefore
                            eventsOf (syntheticTxId s) (syntheticDir s)
                                `shouldReturn` ["prepared", "submitted", "confirmed"]
  where
    fieldsOf (CommandFailure _ _ fields) key = lookup key fields
