{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.Criterion3Spec
Description : Criterion 3 — every fold effect observed at the fresh-blueprint boundary
License     : Apache-2.0

One connected devnet scenario that exercises all seven admissible edges
and observes, for each fold, the effects the issue's third acceptance
criterion names: request order, keyed mints, approvals, holder
selection, destinations, custody refunds and the unsigned body's empty
required-signer set.

Expected values are derived from the accepted Lean model's tables
(@Singular.Model.delta@ through 'modelDelta', @route@, @obligations@,
@requiredSigners@ — accepted tree @f1e6a0edcaf9edce7369fd42add8b3677ddabeb2@)
applied to OBSERVED chain state: the request datums and UTxOs, the
custody and holder UTxOs, the policy pins of the booted config and the
observed request deposits. Nothing here reads 'registryDuties' or the
builder's own decisions.

The ordering stage is deterministic. Two real requests are booked
and captured through the real provider; a test-local provider
override — a record update that changes only the request address's
@queryUTxOs@ — returns those same real outputs to the one public fold
in descending input order, while every other address and provider
function forwards unchanged. The fold's canonical sort must therefore
associate each request with its own proof in ascending order despite
the reversed enumeration, and the spec derives that expected
association independently from the observed request datums. A setup
that cannot present exactly two distinct real requests, a genuinely
reversed enumeration, or two distinguishable proofs fails
@ORDER-WITNESS-NONDISCRIMINATING@ before submission, and is a setup
failure, never an intended RED. This witnesses canonicalisation of a
test-controlled enumeration of real outputs; real cage acceptance
separately supports proof correctness.

Each of the seven comparison classes runs once on the live captured
observation and immediately again on a single field-mutated copy
inside this same E2E invocation: the live call must pass and the
mutant must fail with its own stable @C3-…@ token.
-}
module Singular.Registry.E2E.Criterion3Spec (spec) where

import Control.Monad (forM_, unless, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.List (isPrefixOf, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))
import Test.Hspec (
    Expectation,
    Spec,
    describe,
    expectationFailure,
    it,
 )

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Api.Scripts.Data (
    Data (..),
    Datum (..),
    binaryDataToData,
 )
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body (
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    reqSignerHashesTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    valueTxOutL,
 )
import Cardano.Ledger.Api.Tx.Wits (Redeemers (..), rdmrsTxWitsL)
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (extractHash)
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MaryValue (..),
    MultiAsset (..),
    PolicyID,
 )
import Cardano.Ledger.Plutus.Data (getPlutusData, hashData)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import PlutusTx.Builtins (fromBuiltin)
import PlutusTx.Builtins.Internal (BuiltinData (..))
import PlutusTx.IsData.Class (FromData (..))

import Cardano.Node.Client.E2E.Setup (
    genesisAddr,
 )
import Cardano.Node.Client.Submitter (
    Submitter,
 )
import Singular.Registry.Blueprint (
    Blueprint,
    NamingCodes,
    extractCompiledCode,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Config (
    CageConfig (..),
 )
import Singular.Registry.Driver qualified as Driver
import Singular.Registry.E2E.CageSpec (
    publishCageRefs,
    submitWithGenesis,
    withBootedCage,
 )
import Singular.Registry.Ledger (
    ConwayEra,
    Root (..),
    TokenId,
 )
import Singular.Registry.Provider (
    Provider (..),
 )
import Singular.Registry.Provider qualified as Cage
import Singular.Registry.Trie (
    Trie (getRoot),
    TrieManager (..),
 )
import Singular.Registry.TxBuilder.ConnectedFold (
    syncFoldedRequests,
 )
import Singular.Registry.TxBuilder.Edges qualified as Edges
import Singular.Registry.TxBuilder.Internal (
    addrFromBytes,
    addrFromKeyHashBytes,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    extractCageDatum,
    findStateUtxo,
    policyIdFromPin,
    requestAddrFromCfg,
    toPlcData,
    walkEdge,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext (..),
    updateTokenWithDuties,
 )
import Singular.Registry.Types (
    CageDatum (..),
    Edge,
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenState (stateRoot),
    ProofStep,
    RequestAction (..),
    UpdateRedeemer (..),
    edgeDeleteAbsent,
    edgeDeleteActive,
    edgeInsertAbsent,
    edgeInsertActive,
    edgeUpdateActive,
    edgeUpdateTerminal,
    edgeWitnessTerminal,
 )

-- ---------------------------------------------------------
-- The model table this witness derives its mints from
-- ---------------------------------------------------------

{- | @Singular.Model.delta@ on the accepted tree: the mint each edge
owes, keyed by token kind — 0 absent, 1 active, 2 terminal — under the
registry's pinned policy for that kind. Stated from the model, never
read from the builder under test.
-}
modelDelta :: Edge -> [(Integer, Integer)]
modelDelta edge
    | edge == edgeInsertAbsent = [(0, 1)]
    | edge == edgeInsertActive = [(1, 1)]
    | edge == edgeUpdateActive = [(0, -1), (1, 1)]
    | edge == edgeUpdateTerminal = [(1, -1)]
    | edge == edgeDeleteAbsent = [(0, -1)]
    | edge == edgeDeleteActive = [(1, -1)]
    | edge == edgeWitnessTerminal = [(2, 1)]
    | otherwise = []

-- | The pinned policy of a kind, as the model's @tx@ row names it.
kindPolicy :: CageConfig -> Integer -> PolicyID
kindPolicy cfg kind
    | kind == 0 = policyIdFromPin (cfgAbsentPolicy cfg)
    | kind == 1 = policyIdFromPin (cfgActivePolicy cfg)
    | otherwise = policyIdFromPin (cfgTerminalPolicy cfg)

{- | Expected nonzero mint for observed requests: the model's delta
over each observed edge, keyed by the observed policy pins and each
observed request key.
-}
expectedMintOf :: CageConfig -> [OnChainRequest] -> Map.Map (PolicyID, AssetName) Integer
expectedMintOf cfg requests =
    Map.fromList
        [ ((kindPolicy cfg kind, keyAssetName (requestKey req)), quantity)
        | req <- requests
        , (kind, quantity) <- modelDelta (requestEdge req)
        ]

keyAssetName :: ByteString -> AssetName
keyAssetName = AssetName . SBS.toShort

-- ---------------------------------------------------------
-- The destination preimages this scenario books
-- ---------------------------------------------------------

{- | The distinct nonempty destination-datum preimages the scenario
books, named by stage. Distinct preimages make an absent or swapped
inline datum detectable.
-}
orderDatumA, deliverDatumB, deliverDatumA, deliverDatumD, witnessDatumD :: Data ConwayEra
orderDatumA = ledgerData 1
deliverDatumB = ledgerData 2
deliverDatumA = ledgerData 3
deliverDatumD = ledgerData 4
witnessDatumD = ledgerData 5

{- | The ledger datum wrapper over an integer preimage, so nothing here
names the Plutus core data type.
-}
ledgerData :: Integer -> Data ConwayEra
ledgerData n = Data (toPlcData n)

scenarioDatumPreimages :: [Data ConwayEra]
scenarioDatumPreimages =
    [orderDatumA, deliverDatumB, deliverDatumA, deliverDatumD, witnessDatumD]

{- | The hash a request's destination field carries for a preimage: the
same ledger encoding the cage itself compares (@destinationMatches@
hashes the inline datum with BLAKE2b-256; @Edges.edgeRecordDatumHash@
uses this exact expression), so a literal label could never match.
-}
datumHashOf :: Data ConwayEra -> ByteString
datumHashOf d = hashToBytes (extractHash (hashData d))

{- | The preimage for a hash the request carries, when this scenario
booked it.
-}
preimageOf :: ByteString -> Maybe (Data ConwayEra)
preimageOf h = lookup h [(datumHashOf d, d) | d <- scenarioDatumPreimages]

{- | A delivering destination at the funding wallet carrying a booked
preimage's real hash.
-}
deliverDest :: Data ConwayEra -> (ByteString, ByteString)
deliverDest d = (serialiseAddr genesisAddr, datumHashOf d)

{- | The refund address the absent-insert stages book: a distinct key
address that is not the fold wallet, so the only ada-only outputs
that ever land there are the custody refunds owed to it (receiving
needs no witness).
-}
stageRefundAddr :: CageConfig -> Addr
stageRefundAddr cfg = addrFromKeyHashBytes (network cfg) (BS.replicate 28 0xab)

-- | A decodable address nothing pays, for the custody mutant's divert.
absentAddress :: CageConfig -> Addr
absentAddress cfg = addrFromKeyHashBytes (network cfg) (BS.replicate 28 0x99)

-- ---------------------------------------------------------
-- Scenario
-- ---------------------------------------------------------

spec :: Blueprint -> Spec
spec bp =
    describe "Criterion 3: seven edges, every fold effect at the fresh-blueprint boundary" $
        case (extractCompiledCode "state.state" bp, extractCompiledCode "request.request" bp) of
            (Just stateBytes, Just requestBytes) ->
                it "observes order, approvals, mints, holders, destinations, custody refunds and body signers" $
                    withBootedCage id stateBytes requestBytes $ \cfg prov submit tm reg -> do
                        let tokenId = Driver.registryTokenId reg
                            requestAddr = requestAddrFromCfg cfg tokenId (network cfg)
                        codes <- loadRegistryCodesFromEnv
                        refs <- publishCageRefs cfg prov submit tokenId
                        orderingStage cfg codes prov submit tm tokenId requestAddr refs
                        connectedStages cfg codes prov submit tm tokenId requestAddr refs
            _ ->
                it "no compiled code" $
                    expectationFailure "state or request script not found in blueprint"

-- ---------------------------------------------------------
-- Stage O: deterministic two-request ordering
-- ---------------------------------------------------------

{- | The criterion-3 ordering witness, per A-014's v2 selection: two
REAL booked requests, captured through the real provider, enumerated to
the one public fold in DESCENDING input order through a test-local
provider override that changes no output and no other query.

'Update.Context.queryContext' sorts its request list ascending, so the
fold's proof association must follow ascending order despite the
reversed enumeration. The expected association is derived independently
from the observed request datums walked over a fresh speculative
session of the committed trie; the actual association is decoded from
the unsigned body's state redeemer. A setup that cannot present
exactly two distinct real requests, a genuinely reversed enumeration
or two distinguishable proofs fails @ORDER-WITNESS-NONDISCRIMINATING@
before submission.

L-ORD1: this witnesses canonicalisation of a test-controlled
enumeration of real outputs; L-ORD2: the association is observed
against proof content — real cage acceptance separately supports proof
correctness.
-}
orderingStage ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    Addr ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ()
orderingStage cfg codes prov submit tm tokenId requestAddr refs = do
    -- Two real, independent bookings: distinct keys, distinct edges,
    -- both folded together below.
    let keyA = "c3-order-a"
        keyB = "c3-order-b"
        destA = deliverDest orderDatumA
    refB <-
        Edges.bookEdgeTo
            cfg
            codes
            prov
            (submitWithGenesis submit)
            genesisAddr
            tokenId
            keyB
            edgeInsertAbsent
            (serialiseAddr genesisAddr, BS.empty)
    refA <-
        Edges.bookEdgeTo cfg codes prov (submitWithGenesis submit) genesisAddr tokenId keyA edgeInsertActive destA
    -- The booking sequence, written beside the calls in their order;
    -- a future reordering of the calls must edit this list to match.
    let bookingSequence = [(keyB, refB), (keyA, refA)]
    -- The real provider's own observations, before anything is wrapped.
    pending <- Cage.queryUTxOs prov requestAddr
    unless (length pending == 2 && sort (map fst pending) == sort [refA, refB]) $
        fail "ORDER-WITNESS-NONDISCRIMINATING: the request address does not hold exactly the two booked requests"
    (outA, reqA) <- observedRequestAt refA pending
    (outB, reqB) <- observedRequestAt refB pending
    let ascending = sortOn fst pending
        descending = reverse ascending
        sortedRefs = map fst ascending
        sortedRequests = map (requestOf (zip [refA, refB] [reqA, reqB])) sortedRefs
    unless (map fst descending /= map fst ascending) $
        fail "ORDER-WITNESS-NONDISCRIMINATING: reversed enumeration equals ascending order"
    -- Scenario receipt, from captured values only: the booking
    -- sequence in call order, the raw test-controlled provider
    -- enumeration the fold saw, the real provider's own order, and the
    -- canonical ascending order it must commit to.
    putStrLn $
        "[c3-receipt] ordering booking-order="
            <> show (map fst bookingSequence)
            <> " booked-request-txins="
            <> show (map snd bookingSequence)
            <> " real-provider-order="
            <> show (map fst pending)
            <> " raw-provider-order-descending="
            <> show (map fst descending)
            <> " canonical-order-ascending="
            <> show sortedRefs
    -- The test-local provider override: the request address's REAL
    -- outputs, returned descending; every other address and provider
    -- function forwards to the real provider unchanged.
    let wrapped =
            prov
                { queryUTxOs = \addr ->
                    if addr == requestAddr
                        then pure descending
                        else Cage.queryUTxOs prov addr
                }
    -- Expected association: observed datums, ascending order, fresh
    -- speculative session of the committed trie.
    expectedActions <-
        withSpeculativeTrie tm tokenId $ \trie ->
            mapM (\req -> walkEdge trie (requestKey req) (requestEdge req)) sortedRequests
    case expectedActions of
        [proofOne, proofTwo]
            | proofOne /= proofTwo -> pure ()
        _ -> fail "ORDER-WITNESS-NONDISCRIMINATING: the two requests do not produce distinguishable proofs"
    ctx <- contextFor cfg codes prov refs
    unsigned <- updateTokenWithDuties cfg wrapped tm tokenId genesisAddr ctx
    decoded <- modifyActionsOf unsigned
    let orderObs = OrderObservation{ooActions = decoded, ooExpected = expectedActions}
    livePass "ordering: request association" (cmpOrder orderObs)
    mutantFails "ordering: request association" "C3-ORDER-REDEEMER" (cmpOrder orderObs{ooExpected = reverse expectedActions})
    let mintObs = mintObservationOf cfg unsigned sortedRequests
    livePass "ordering fold: keyed mint" (cmpMint mintObs)
    mutantFails "ordering fold: keyed mint" "C3-MINT-KEYED" (cmpMint mintObs{moExpected = bumpOne cfg (moExpected mintObs)})
    forM_ [(refA, outA, reqA), (refB, outB, reqB)] $ \(_, out, req) -> do
        approvalName <- observedApprovalName cfg out
        let approvalObs = approvalObservationOf cfg unsigned req approvalName
        livePass ("ordering fold: approval for " <> show (requestKey req)) (cmpApproval approvalObs)
        mutantFails
            ("ordering fold: approval for " <> show (requestKey req))
            "C3-APPROVAL-ASSET"
            (cmpApproval approvalObs{aoName = AssetName "c3-mutant"})
    let signerObs = signerObservationOf unsigned
    livePass "ordering fold: body signers" (cmpBodySigner signerObs)
    mutantFails "ordering fold: body signers" "C3-BODY-SIGNER" (cmpBodySigner (insertSigner signerObs))
    rootBefore <- withTrie tm tokenId getRoot
    signedFold <- submitWithGenesis submit unsigned
    syncFoldedRequests tm tokenId ascending
    rootAfter <- withTrie tm tokenId getRoot
    when (unRoot rootBefore == unRoot rootAfter) $
        expectationFailure "wrong effect: mirror root did not move across the ordering fold"
    assertChainRootMatches cfg prov tokenId rootAfter "ordering fold"
    putStrLn $
        "[c3-receipt] ordering fold-txid="
            <> show (txIdTx signedFold)
            <> " mirror-root-before="
            <> show (unRoot rootBefore)
            <> " mirror-root-after="
            <> show (unRoot rootAfter)
    -- Receipts through the REAL provider: both requests consumed.
    after <- Cage.queryUTxOs prov requestAddr
    forM_ sortedRefs $ \ref ->
        when (lookup ref after /= Nothing) $
            expectationFailure
                ("wrong effect: ordering-fold request " <> show ref <> " still pending after submission")
  where
    requestOf pairs ref = case lookup ref pairs of
        Just req -> req
        Nothing -> error "orderingStage: booked request not in observation list"

-- ---------------------------------------------------------
-- Stages A–D: the seven edges, connected
-- ---------------------------------------------------------

{- | Stage order matters for holder availability: B.1 leaves a second
active token in the funding wallet so A's retirement sees two
distinguishable holder candidates.
-}
connectedStages ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    Addr ->
    [(TxIn, TxOut ConwayEra)] ->
    IO ()
connectedStages cfg codes prov submit tm tokenId requestAddr refs = do
    -- Stage B.1: deliver keyB's active token and leave it held.
    stage keyB edgeInsertActive deliverDatumB
    -- Stage A: absent custody, then the active life, then retirement.
    -- The absent inserts book a refund address away from the fold
    -- wallet, so refund crediting is unambiguous. The no-token-delivery
    -- edges book a plain destination: nothing is delivered to it and
    -- the booking's approval only binds the pair.
    let refundDest = (serialiseAddr (stageRefundAddr cfg), BS.empty)
        plainDest = (serialiseAddr genesisAddr, BS.empty)
    stageTo keyA edgeInsertAbsent refundDest
    stage keyA edgeUpdateActive deliverDatumA
    stageTo keyA edgeUpdateTerminal plainDest
    -- Stage B.2: burn keyB's active token.
    stageTo keyB edgeDeleteActive plainDest
    -- Stage C: absent custody then deletion, same refund address.
    stageTo keyC edgeInsertAbsent refundDest
    stageTo keyC edgeDeleteAbsent plainDest
    -- Stage D: active, terminal, witnessed.
    stage keyD edgeInsertActive deliverDatumD
    stageTo keyD edgeUpdateTerminal plainDest
    stage keyD edgeWitnessTerminal witnessDatumD
  where
    keyA = "c3-key-a"
    keyB = "c3-key-b"
    keyC = "c3-key-c"
    keyD = "c3-key-d"
    stage key edge datum =
        bookFoldObserve
            cfg
            codes
            prov
            submit
            tm
            tokenId
            requestAddr
            refs
            key
            edge
            (deliverDest datum)
    stageTo key edge dest =
        bookFoldObserve cfg codes prov submit tm tokenId requestAddr refs key edge dest

-- ---------------------------------------------------------
-- One booking, one fold, every control it feeds
-- ---------------------------------------------------------

bookFoldObserve ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    Submitter IO ->
    TrieManager IO ->
    TokenId ->
    Addr ->
    [(TxIn, TxOut ConwayEra)] ->
    ByteString ->
    Edge ->
    (ByteString, ByteString) ->
    IO ()
bookFoldObserve cfg codes prov submit tm tokenId requestAddr refs key edge dest = do
    requestTxIn <-
        Edges.bookEdgeTo cfg codes prov (submitWithGenesis submit) genesisAddr tokenId key edge dest
    pending <- Cage.queryUTxOs prov requestAddr
    (reqOut, req) <- observedRequestAt requestTxIn pending
    cageUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    walletUtxos <- Cage.queryUTxOs prov genesisAddr
    rootBefore <- withTrie tm tokenId getRoot
    ctx <- contextFor cfg codes prov refs
    unsigned <- updateTokenWithDuties cfg prov tm tokenId genesisAddr ctx
    let body = unsigned ^. bodyTxL
        requests = [req]
        outputs = toList (body ^. outputsTxBodyL)
        label = "edge " <> show edge
        mintObs = mintObservationOf cfg unsigned requests
    livePass (label <> ": keyed mint") (cmpMint mintObs)
    mutantFails (label <> ": keyed mint") "C3-MINT-KEYED" (cmpMint mintObs{moExpected = bumpOne cfg (moExpected mintObs)})
    -- Approval: every edge but witnessTerminal carries one, and the
    -- owner's return output also carries at least the deposit floor.
    when (edge /= edgeWitnessTerminal) $ do
        approvalName <- observedApprovalName cfg reqOut
        let approvalObs = approvalObservationOf cfg unsigned req approvalName
        livePass (label <> ": approval") (cmpApproval approvalObs)
        mutantFails (label <> ": approval") "C3-APPROVAL-ASSET" (cmpApproval approvalObs{aoName = AssetName "c3-mutant"})
    let signerObs = signerObservationOf unsigned
    livePass (label <> ": body signers") (cmpBodySigner signerObs)
    mutantFails (label <> ": body signers") "C3-BODY-SIGNER" (cmpBodySigner (insertSigner signerObs))
    -- Destination: the delivering shapes, including the custody
    -- creation of an absent insert, whose output sits at the cage.
    case destinationShapeOf cfg edge key req of
        Just DestinationShape{dsAddress, dsDatum, dsAsset} -> do
            let destObs =
                    DestinationObservation
                        { doAddress = dsAddress
                        , doDatum = dsDatum
                        , doAsset = dsAsset
                        , doFloor = requestDeposit req
                        , doOutputs = outputs
                        }
            livePass (label <> ": destination") (cmpDestination destObs)
            mutantFails (label <> ": destination") "C3-DESTINATION" (cmpDestination destObs{doDatum = ledgerData (-1)})
            -- The destination shape also names the body's delivery
            -- output for the post-state landing check below.
            pure ()
        Nothing -> pure ()
    -- Custody refund: the two edges that consume absent custody.
    when (edge == edgeUpdateActive || edge == edgeDeleteAbsent) $
        case findKeyedCustody cfg key cageUtxos of
            Just (custodyIn, custodyCoin, refundBytes) -> do
                refundAddr <- decodeRefund refundBytes
                let custodyObs =
                        CustodyObservation
                            { cuInput = custodyIn
                            , cuRefundAddr = refundAddr
                            , cuOwed = custodyCoin
                            , cuPolicies = witnessPolicies cfg
                            , cuInputs = body ^. inputsTxBodyL
                            , cuOutputs = outputs
                            }
                livePass (label <> ": custody refund") (cmpCustodyRefund custodyObs)
                mutantFails
                    (label <> ": custody refund")
                    "C3-CUSTODY-REFUND"
                    ( cmpCustodyRefund
                        custodyObs
                            { cuRefundAddr = absentAddress cfg
                            }
                    )
            Nothing ->
                expectationFailure ("setup: no keyed custody UTxO observed for key " <> show key)
    -- Holder: the two edges that burn an active token.
    when (edge == edgeUpdateTerminal || edge == edgeDeleteActive) $
        case [i | (i, o) <- walletUtxos, quantityInValue (activePin cfg) (keyAssetName key) (o ^. valueTxOutL) == 1] of
            [] -> expectationFailure ("setup: no single-quantity holder observed for key " <> show key)
            (holderIn : _) -> do
                let otherHolders =
                        [ i
                        | (i, o) <- walletUtxos
                        , i /= holderIn
                        , holdsAnyActive cfg o
                        , quantityInValue (activePin cfg) (keyAssetName key) (o ^. valueTxOutL) == 0
                        ]
                    holderObs =
                        HolderObservation
                            { hoExpectedTxIn = holderIn
                            , hoOtherCandidates = otherHolders
                            , hoInputs = body ^. inputsTxBodyL
                            }
                livePass (label <> ": holder") (cmpHolder holderObs)
                case otherHolders of
                    [] ->
                        expectationFailure
                            ("setup: no second distinguishable holder candidate for key " <> show key)
                    (other : _) ->
                        mutantFails
                            (label <> ": holder")
                            "C3-HOLDER-TXIN"
                            (cmpHolder holderObs{hoExpectedTxIn = other})
    signed <- submitWithGenesis submit unsigned
    syncFoldedRequests tm tokenId [(requestTxIn, reqOut)]
    -- Post-state, through the REAL provider: the mirror root moved
    -- across every connected stage's landed fold.
    rootAfter <- withTrie tm tokenId getRoot
    when (unRoot rootBefore == unRoot rootAfter) $
        expectationFailure
            ("wrong effect: mirror root did not move across the fold of edge " <> show edge)
    assertChainRootMatches cfg prov tokenId rootAfter ("fold of edge " <> show edge)
    putStrLn $
        "[c3-receipt] edge="
            <> show edge
            <> " key="
            <> show key
            <> " request-txin="
            <> show requestTxIn
            <> " fold-txid="
            <> show (txIdTx signed)
            <> " mirror-root-before="
            <> show (unRoot rootBefore)
            <> " mirror-root-after="
            <> show (unRoot rootAfter)
    -- A delivering stage's built destination output lands at its
    -- address exactly as the body built it.
    case destinationShapeOf cfg edge key req of
        Just DestinationShape{dsAddress, dsDatum, dsAsset = (policy, asset)} ->
            case [ (ix, out)
                 | (ix, out) <- zip [0 :: Int ..] outputs
                 , out ^. addrTxOutL == dsAddress
                 , quantityInValue policy asset (out ^. valueTxOutL) >= 1
                 , inlineDatumData out == dsDatum
                 ] of
                [(ix, built)] -> do
                    landed <- Cage.queryUTxOs prov dsAddress
                    case lookup (TxIn (txIdTx signed) (TxIx (fromIntegral ix))) landed of
                        Just observed ->
                            unless (observed `sameOutputAs` built) $
                                expectationFailure
                                    ( "wrong effect: landed destination output at index "
                                        <> show ix
                                        <> " differs from the body's built output"
                                    )
                        Nothing ->
                            expectationFailure
                                ("wrong effect: destination output at index " <> show ix <> " not found after inclusion")
                _ ->
                    expectationFailure
                        ("setup: destination output not uniquely identified in the body of edge " <> show edge)
        Nothing -> pure ()
    -- A custody-consuming stage's built refund output lands at the
    -- recorded refund address exactly as the body built it.
    when (edge == edgeUpdateActive || edge == edgeDeleteAbsent) $
        case findKeyedCustody cfg key cageUtxos of
            Just (_, _, refundBytes) -> do
                refundAddr <- decodeRefund refundBytes
                case [ (ix, out)
                     | (ix, out) <- zip [0 :: Int ..] outputs
                     , out ^. addrTxOutL == refundAddr
                     , not (any (\p -> carriesPolicyAsset p out) (witnessPolicies cfg))
                     ] of
                    [(ix, built)] -> do
                        landed <- Cage.queryUTxOs prov refundAddr
                        case lookup (TxIn (txIdTx signed) (TxIx (fromIntegral ix))) landed of
                            Just observed ->
                                unless (observed `sameOutputAs` built) $
                                    expectationFailure
                                        "wrong effect: landed custody refund differs from the body's built output"
                            Nothing ->
                                expectationFailure "wrong effect: custody refund output not found after inclusion"
                    _ ->
                        expectationFailure
                            ("setup: custody refund output not uniquely identified in the body of edge " <> show edge)
            Nothing -> pure ()
    -- The request is spent; a burned asset is gone.
    after <- Cage.queryUTxOs prov requestAddr
    when (lookup requestTxIn after /= Nothing) $
        expectationFailure ("wrong effect: request " <> show requestTxIn <> " still pending after fold")
    when (edge == edgeUpdateTerminal || edge == edgeDeleteActive) $ do
        walletAfter <- Cage.queryUTxOs prov genesisAddr
        let remaining = length [() | (_, o) <- walletAfter, quantityInValue (activePin cfg) (keyAssetName key) (o ^. valueTxOutL) > 0]
        unless (remaining == 0) $
            expectationFailure
                ("wrong effect: active asset for key " <> show key <> " still held after burn")

-- ---------------------------------------------------------
-- The seven comparison classes
-- ---------------------------------------------------------

data OrderObservation = OrderObservation
    { ooActions :: [[ProofStep]]
    , ooExpected :: [[ProofStep]]
    }

{- | @C3-ORDER-REDEEMER@: the decoded proof actions of the body's state
redeemer associate each request with its own proof, in canonical
sorted-input order.
-}
cmpOrder :: OrderObservation -> Either String ()
cmpOrder OrderObservation{ooActions, ooExpected}
    | ooActions == ooExpected = Right ()
    | otherwise =
        Left
            "C3-ORDER-REDEEMER: decoded proof actions do not associate each request with its own proof in canonical order"

data MintObservation = MintObservation
    { moExpected :: Map.Map (PolicyID, AssetName) Integer
    , moActual :: Map.Map (PolicyID, AssetName) Integer
    }

-- | @C3-MINT-KEYED@: the body's nonzero mint is exactly the model's delta.
cmpMint :: MintObservation -> Either String ()
cmpMint MintObservation{moExpected, moActual}
    | moActual == moExpected = Right ()
    | otherwise =
        Left
            ( "C3-MINT-KEYED: body mint "
                <> show moActual
                <> " is not the model's keyed delta "
                <> show moExpected
            )

data ApprovalObservation = ApprovalObservation
    { aoPolicy :: PolicyID
    , aoName :: AssetName
    , aoQuantity :: Integer
    , aoMint :: MultiAsset
    , aoOwnerAddress :: Addr
    , aoDeposit :: Integer
    , aoOutputs :: [TxOut ConwayEra]
    }

{- | @C3-APPROVAL-ASSET@: the fold does not mint or burn the approval,
and exactly one owner output returns it, carrying at least the observed
deposit floor.
-}
cmpApproval :: ApprovalObservation -> Either String ()
cmpApproval ApprovalObservation{aoPolicy, aoName, aoQuantity, aoMint, aoOwnerAddress, aoDeposit, aoOutputs}
    | quantityInMultiAsset aoPolicy aoName aoMint /= 0 =
        Left "C3-APPROVAL-ASSET: the fold minted or burned the approval asset"
    | length returns == 1 = Right ()
    | otherwise =
        Left
            ( "C3-APPROVAL-ASSET: expected exactly one owner output returning the approval with its deposit, observed "
                <> show (length returns)
            )
  where
    returns =
        [ ()
        | out <- aoOutputs
        , out ^. addrTxOutL == aoOwnerAddress
        , quantityInValue aoPolicy aoName (out ^. valueTxOutL) == aoQuantity
        , let Coin c = out ^. coinTxOutL
        , c >= aoDeposit
        ]

data HolderObservation = HolderObservation
    { hoExpectedTxIn :: TxIn
    , hoOtherCandidates :: [TxIn]
    , hoInputs :: Set.Set TxIn
    }

{- | @C3-HOLDER-TXIN@: the exact keyed holder input is spent and no
wrong-key holder candidate is.
-}
cmpHolder :: HolderObservation -> Either String ()
cmpHolder HolderObservation{hoExpectedTxIn, hoOtherCandidates, hoInputs}
    | not (Set.member hoExpectedTxIn hoInputs) =
        Left "C3-HOLDER-TXIN: the exact keyed holder input is not spent by the body"
    | any (`Set.member` hoInputs) hoOtherCandidates =
        Left "C3-HOLDER-TXIN: a wrong-key holder input is spent by the body"
    | otherwise = Right ()

data DestinationObservation = DestinationObservation
    { doAddress :: Addr
    , doDatum :: Data ConwayEra
    , doAsset :: (PolicyID, AssetName)
    , doFloor :: Integer
    , doOutputs :: [TxOut ConwayEra]
    }

{- | @C3-DESTINATION@: some output pays the observed destination address
with the keyed asset, the booked inline datum and at least the floor.
-}
cmpDestination :: DestinationObservation -> Either String ()
cmpDestination DestinationObservation{doAddress, doDatum, doAsset = (policy, asset), doFloor, doOutputs}
    | not (null matching) = Right ()
    | otherwise = Left "C3-DESTINATION: no output pays the named address with the keyed asset, datum and floor"
  where
    matching =
        [ ()
        | out <- doOutputs
        , out ^. addrTxOutL == doAddress
        , quantityInValue policy asset (out ^. valueTxOutL) >= 1
        , let Coin c = out ^. coinTxOutL
        , c >= doFloor
        , inlineDatumData out == doDatum
        ]

data CustodyObservation = CustodyObservation
    { cuInput :: TxIn
    , cuRefundAddr :: Addr
    , cuOwed :: Integer
    , cuPolicies :: [PolicyID]
    , cuInputs :: Set.Set TxIn
    , cuOutputs :: [TxOut ConwayEra]
    }

{- | @C3-CUSTODY-REFUND@: the exact observed custody input is consumed,
and the outputs at its recorded refund address that carry no delivered
token sum to at least the observed coin — a token carrier or an
approval/change output at the same address is not custody refund
value, matching the constitution's realization of a custody refund.
-}
cmpCustodyRefund :: CustodyObservation -> Either String ()
cmpCustodyRefund CustodyObservation{cuInput, cuRefundAddr, cuOwed, cuPolicies, cuInputs, cuOutputs}
    | not (Set.member cuInput cuInputs) =
        Left "C3-CUSTODY-REFUND: the exact observed custody input is not consumed"
    | credited >= cuOwed = Right ()
    | otherwise =
        Left
            ( "C3-CUSTODY-REFUND: the token-free refund credited at the recorded address ("
                <> show credited
                <> ") falls short of the observed custody coin ("
                <> show cuOwed
                <> ")"
            )
  where
    credited =
        sum
            [ c
            | out <- cuOutputs
            , out ^. addrTxOutL == cuRefundAddr
            , not (any (`carriesPolicyAsset` out) cuPolicies)
            , let Coin c = out ^. coinTxOutL
            ]

{- | Whether an output carries any asset under a policy column, used
to keep token carriers out of a custody refund's credited value and
to identify the refund output in the post-state landing check.
-}
carriesPolicyAsset :: PolicyID -> TxOut ConwayEra -> Bool
carriesPolicyAsset policy out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) ->
        maybe False (not . Map.null) (Map.lookup policy m)

{- | Semantic output equality for the landing checks: address, value
-- and inline datum compared directly, without depending on the
-- ledger output type's own equality over its compact representation.
-}
sameOutputAs :: TxOut ConwayEra -> TxOut ConwayEra -> Bool
sameOutputAs a b =
    a ^. addrTxOutL == b ^. addrTxOutL
        && a ^. valueTxOutL == b ^. valueTxOutL
        && inlineDatumData a == inlineDatumData b

{- | The chain's state root, read from the state UTxO's inline datum
-- through the real provider, must equal the mirror's root after a
-- landed fold: a moving mirror alone does not show the trie the chain
-- committed.
-}
assertChainRootMatches ::
    CageConfig ->
    Cage.Provider IO ->
    TokenId ->
    Root ->
    String ->
    IO ()
assertChainRootMatches cfg prov tokenId mirrorRoot what = do
    cageUtxos <- Cage.queryUTxOs prov (cageAddrFromCfg cfg (network cfg))
    case findStateUtxo (cagePolicyIdFromCfg cfg) tokenId cageUtxos of
        Just (_, stateOut) -> case extractCageDatum stateOut of
            Just (StateDatum st)
                | stateRoot st == OnChainRoot (unRoot mirrorRoot) -> pure ()
                | otherwise ->
                    expectationFailure
                        ( "wrong effect: chain state root after the "
                            <> what
                            <> " differs from the mirror root"
                        )
            _ -> expectationFailure ("setup: state UTxO carries no state datum after the " <> what)
        Nothing ->
            expectationFailure ("setup: state UTxO not found after the " <> what)

{- | The fold's required-signer set, reduced to its size class: the
set must be empty, so any member is a defect.
-}
newtype SignerObservation = SignerObservation
    { soSigners :: Set.Set ()
    }

-- | @C3-BODY-SIGNER@: the unsigned fold body requires no signature.
cmpBodySigner :: SignerObservation -> Either String ()
cmpBodySigner SignerObservation{soSigners}
    | Set.null soSigners = Right ()
    | otherwise = Left "C3-BODY-SIGNER: the unsigned fold body requires a signature"

insertSigner :: SignerObservation -> SignerObservation
insertSigner obs = obs{soSigners = Set.insert () (soSigners obs)}

-- ---------------------------------------------------------
-- Observation builders over captured state
-- ---------------------------------------------------------

mintObservationOf :: CageConfig -> ConwayTx -> [OnChainRequest] -> MintObservation
mintObservationOf cfg tx requests =
    MintObservation
        { moExpected = expectedMintOf cfg requests
        , moActual = nonzeroMint (tx ^. bodyTxL . mintTxBodyL)
        }

approvalObservationOf ::
    CageConfig ->
    ConwayTx ->
    OnChainRequest ->
    AssetName ->
    ApprovalObservation
approvalObservationOf cfg tx req approvalName =
    ApprovalObservation
        { aoPolicy = policyIdFromPin (cfgApplicationPolicy cfg)
        , aoName = approvalName
        , aoQuantity = 1
        , aoMint = tx ^. bodyTxL . mintTxBodyL
        , aoOwnerAddress = ownerAddressOf cfg req
        , aoDeposit = approvalFloorOf (requestEdge req) req
        , aoOutputs = toList (tx ^. bodyTxL . outputsTxBodyL)
        }

{- | The approval-return output's ADA floor, by edge, from the accepted
obligations: a delivering edge returns the approval alone at the
ledger's minimum (the minimum itself is unmodeled, so the floor here is
zero) while its deposit goes to the destination or custody; the
no-token-delivery edges group the deposit with the returned approval
at the owner, where the deposit floor does apply.
-}
approvalFloorOf :: Edge -> OnChainRequest -> Integer
approvalFloorOf edge req
    | edge == edgeUpdateTerminal || edge == edgeDeleteAbsent || edge == edgeDeleteActive =
        requestDeposit req
    | otherwise = 0

signerObservationOf :: ConwayTx -> SignerObservation
signerObservationOf tx =
    SignerObservation{soSigners = Set.map (const ()) (tx ^. bodyTxL . reqSignerHashesTxBodyL)}

data DestinationShape = DestinationShape
    { dsAddress :: Addr
    , dsDatum :: Data ConwayEra
    , dsAsset :: (PolicyID, AssetName)
    }

{- | The observed destination shape per edge: the three delivering
kinds pay the request's named address with the booked datum; an absent
insert pays the cage a custody output whose datum records the request's
own destination address as the refund.
-}
destinationShapeOf ::
    CageConfig ->
    Edge ->
    ByteString ->
    OnChainRequest ->
    Maybe DestinationShape
destinationShapeOf cfg edge key req
    | edge == edgeInsertActive || edge == edgeUpdateActive =
        delivering (cfgActivePolicy cfg)
    | edge == edgeWitnessTerminal =
        delivering (cfgTerminalPolicy cfg)
    | edge == edgeInsertAbsent =
        DestinationShape
            <$> Just (cageAddrFromCfg cfg (network cfg))
            <*> Just (Data (toPlcData (AbsentCustody (fst (requestDestination req)))))
            <*> Just (policyIdFromPin (cfgAbsentPolicy cfg), keyAssetName key)
    | otherwise = Nothing
  where
    delivering pin = do
        addr <- addrFromBytes (fst (requestDestination req))
        datum <- preimageOf (snd (requestDestination req))
        pure DestinationShape{dsAddress = addr, dsDatum = datum, dsAsset = (policyIdFromPin pin, keyAssetName key)}

observedRequestAt :: TxIn -> [(TxIn, TxOut ConwayEra)] -> IO (TxOut ConwayEra, OnChainRequest)
observedRequestAt ref utxos = case lookup ref utxos of
    Just out -> case extractCageDatum out of
        Just (RequestDatum request) -> pure (out, request)
        _ -> fail "observed request carries no inline request datum"
    Nothing -> fail "observed request UTxO not found at the request address"

-- | The single application-policy asset the observed request UTxO carries.
observedApprovalName :: CageConfig -> TxOut ConwayEra -> IO AssetName
observedApprovalName cfg out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) -> case Map.lookup (policyIdFromPin (cfgApplicationPolicy cfg)) m of
        Just names
            | [(name, 1)] <- Map.toList names -> pure name
        _ -> fail "observed request does not carry exactly one approval asset of quantity 1"

ownerAddressOf :: CageConfig -> OnChainRequest -> Addr
ownerAddressOf cfg req =
    addrFromKeyHashBytes (network cfg) (fromBuiltin (requestOwner req))

-- | The keyed absent-custody UTxO: policy and key exact, quantity one.
findKeyedCustody ::
    CageConfig ->
    ByteString ->
    [(TxIn, TxOut ConwayEra)] ->
    Maybe (TxIn, Integer, ByteString)
findKeyedCustody cfg key utxos =
    case [ (i, coin, refund)
         | (i, o) <- utxos
         , quantityInValue (policyIdFromPin (cfgAbsentPolicy cfg)) (keyAssetName key) (o ^. valueTxOutL) == 1
         , Just (AbsentCustody refund) <- [extractCageDatum o]
         , let Coin coin = o ^. coinTxOutL
         ] of
        [(found, coin, refund)] -> Just (found, coin, refund)
        _ -> Nothing

decodeRefund :: ByteString -> IO Addr
decodeRefund bytes = case addrFromBytes bytes of
    Just addr -> pure addr
    Nothing -> fail "custody datum records an undecodable refund address"

{- | The fold's context: the registry's own, plus this scenario's
distinct destination-datum preimages.
-}
contextFor ::
    CageConfig ->
    NamingCodes ->
    Cage.Provider IO ->
    [(TxIn, TxOut ConwayEra)] ->
    IO RegistryContext
contextFor cfg codes prov refs = do
    base <- Edges.registryContextFor cfg codes prov refs
    pure
        base
            { rcDatums =
                [(datumHashOf d, getPlutusData d) | d <- scenarioDatumPreimages]
                    ++ rcDatums base
            }

-- | Decode the body's state redeemer into its per-request actions.
modifyActionsOf :: ConwayTx -> IO [[ProofStep]]
modifyActionsOf tx =
    case [ actions
         | (_, (d, _)) <- Map.toList rdmrs
         , Just (Modify actions) <- [fromBuiltinData (BuiltinData (getPlutusData d))]
         ] of
        [actions] -> pure (map stepsOf actions)
        _ -> fail "state redeemer did not decode to exactly one Modify action list"
  where
    Redeemers rdmrs = tx ^. witsTxL . rdmrsTxWitsL
    stepsOf (Update steps) = steps
    stepsOf Rejected =
        error "modifyActionsOf: a fold state redeemer carried a Rejected action"

-- ---------------------------------------------------------
-- Value helpers
-- ---------------------------------------------------------

activePin :: CageConfig -> PolicyID
activePin cfg = policyIdFromPin (cfgActivePolicy cfg)

{- | The three witness policies of this registry: the token columns a
delivered asset can arrive under, used to keep token carriers out
of a custody refund's credited value.
-}
witnessPolicies :: CageConfig -> [PolicyID]
witnessPolicies cfg =
    [ policyIdFromPin (cfgAbsentPolicy cfg)
    , activePin cfg
    , policyIdFromPin (cfgTerminalPolicy cfg)
    ]

quantityInValue :: PolicyID -> AssetName -> MaryValue -> Integer
quantityInValue policy name (MaryValue _ (MultiAsset m)) =
    maybe 0 (Map.findWithDefault 0 name) (Map.lookup policy m)

quantityInMultiAsset :: PolicyID -> AssetName -> MultiAsset -> Integer
quantityInMultiAsset policy name (MultiAsset m) =
    maybe 0 (Map.findWithDefault 0 name) (Map.lookup policy m)

nonzeroMint :: MultiAsset -> Map.Map (PolicyID, AssetName) Integer
nonzeroMint (MultiAsset m) =
    Map.fromList
        [ ((policy, name), quantity)
        | (policy, names) <- Map.toList m
        , (name, quantity) <- Map.toList names
        , quantity /= 0
        ]

holdsAnyActive :: CageConfig -> TxOut ConwayEra -> Bool
holdsAnyActive cfg out = case out ^. valueTxOutL of
    MaryValue _ (MultiAsset m) ->
        maybe False (not . Map.null) (Map.lookup (activePin cfg) m)

inlineDatumData :: TxOut ConwayEra -> Data ConwayEra
inlineDatumData out = case out ^. datumTxOutL of
    Datum bd -> binaryDataToData bd
    _ -> ledgerData (-1)

{- | Bump one entry of a nonzero expectation map, or add one under the
application policy when the map is empty: the mint mutant's
single-field change.
-}
bumpOne :: CageConfig -> Map.Map (PolicyID, AssetName) Integer -> Map.Map (PolicyID, AssetName) Integer
bumpOne cfg m = case Map.toList m of
    [] -> Map.singleton (policyIdFromPin (cfgApplicationPolicy cfg), AssetName "c3-mutant") 1
    ((k, v) : _) -> Map.insert k (v + 1) m

-- ---------------------------------------------------------
-- Live and mutant runners (in-run controls)
-- ---------------------------------------------------------

{- | The live observation must pass. Runs inside the same E2E
invocation as the capture.
-}
livePass :: String -> Either String () -> Expectation
livePass _ (Right ()) = pure ()
livePass label (Left err) =
    expectationFailure ("live observation failed: " <> label <> ": " <> err)

{- | The single-field mutant must fail with its own C3 token, proving
the live comparison discriminates that class in this same invocation.
-}
mutantFails :: String -> String -> Either String () -> Expectation
mutantFails label token result = case result of
    Right () -> expectationFailure ("mutant unexpectedly passed: " <> label)
    Left err ->
        unless (token `isPrefixOf` err) $
            expectationFailure
                ("mutant failed with the wrong token: " <> label <> ": expected " <> token <> " at the start of " <> err)
