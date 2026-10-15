{- |
Module      : Singular.CLI.FoldRulesSpec
Description : The command-line rules for a fold that takes a selection (#518)
License     : Apache-2.0

Pull request 1 settles one request per fold, chosen by the pure selection
and built by the builder entry point. This suite pins the pure
command-line rules around that choice: the named-request guard, the
refusal that names every exclusion, the rule that several pending requests
never refuse on count, and the check that a built fold spends exactly the
selection. Every expected refusal text is rendered from the same exclusion
values the selection produced, never typed.
-}
module Singular.CLI.FoldRulesSpec (spec) where

import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Short qualified as SBS
import Data.Either (rights)
import Data.List (isInfixOf, nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec
import Test.QuickCheck

import Cardano.Ledger.Address (serialiseAddr)
import Cardano.Ledger.Api.Tx (mkBasicTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out
    ( datumTxOutL
    , mkBasicTxOut
    )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Aeson (Value, object, toJSON, (.=))
import Lens.Micro ((&), (.~))
import PlutusCore.Data qualified as PLC
import PlutusTx.Builtins.Internal (BuiltinByteString (..))

import Singular.CLI.Fold
    ( Deadline (..)
    , Delivery (..)
    , Folded (..)
    , SettledEntry (..)
    , foldDeadline
    , foldedFields
    , settledEntryFor
    )
import Singular.CLI.FoldRules
    ( FoldKind (..)
    , FoldRequestsRefusal (..)
    , KeptReceipt (..)
    , SettledForReceipt (..)
    , SpendsRefusal (..)
    , appVerdictOf
    , approvalCheckOf
    , assignKeyInts
    , assignRefPairing
    , buildLiveFacts
    , buildPendingRequests
    , combineWindowClosedMessage
    , foldReceiptLists
    , foldRequests
    , keptReceiptFields
    , neutralAppExecutable
    , pendingDeadlineOf
    , pendingRequestOf
    , refuseNamedEdgeEarly
    , renderFoldRequestsRefusal
    , renderSpendsRefusal
    , requestEdgeKind
    , requestOwnerText
    , spendsSelection
    )
import Singular.Registry.Application
    ( Application (..)
    , HoldingRules (..)
    , neutralApplication
    )
import Singular.Registry.Config (CageConfig (..), defaultProcessTime)
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.FoldSelection
    ( AppVerdict (..)
    , ApprovalCheck (..)
    , EdgeKind (..)
    , Exclusion (..)
    , Leaf (..)
    , PendingRequest (..)
    , Reason (..)
    , SelectedRequest (..)
    , Selection (..)
    , exclusionName
    , exclusionSource
    , selectFold
    )
import Singular.Registry.TxBuilder.BookingFixture qualified as Fixture
import Singular.Registry.TxBuilder.Internal.Edges
    ( approvalDestination
    , approvalName
    )
import Singular.Registry.TxBuilder.Internal.Identity
    ( addrFromKeyHashBytes
    , extractCageDatum
    , mkInlineDatum
    , mkRequestDatumWith
    , policyIdFromPin
    , requestAddrFromCfg
    )
import Singular.Registry.Types
    ( CageDatum (..)
    , OnChainRequest (..)
    , edgeInsertActive
    , edgeName
    , edgeUpdateTerminal
    )

-- ---------------------------------------------------------
-- Clock and request builders
-- ---------------------------------------------------------

nowMs :: Integer
nowMs = 1000000

marginMs :: Integer
marginMs = 30000

farDeadline :: Integer
farDeadline = nowMs + 1000000

nearDeadline :: Integer
nearDeadline = nowMs + 10000

-- | A distinct output reference numbered by its hex tail.
txRef :: Int -> TxIn
txRef n =
    either error id $
        parseOutRef (T.pack (replicate 62 'a' <> hex2 n <> "#0"))
  where
    hex2 k = [digit (k `div` 16), digit (k `mod` 16)]
    digit d = "0123456789abcdef" !! (d `mod` 16)

mkInsert :: Int -> Int -> T.Text -> Integer -> PendingRequest
mkInsert ref key owner deadline =
    PendingRequest
        { prRef = ref
        , prKey = key
        , prOwner = owner
        , prEdge = EdgeInsertActive
        , prDeadline = deadline
        , prDecodeOk = True
        , prApproval = ApprovalOk
        , prApp = AppReady
        }

-- | Look an exclusion up by the selection's own reference.
exclusionFor :: Int -> Selection -> Exclusion
exclusionFor r sel =
    case [exc | (q, exc) <- selectionExcluded sel, prRef q == r] of
        (exc : _) -> exc
        [] -> error ("exclusionFor: no exclusion for " <> show r)

-- | Translate a selection's settled references through the pairing.
settledTxIns :: [(TxIn, Int)] -> Selection -> [TxIn]
settledTxIns pairing sel =
    [ tx
    | s <- selectionSettled sel
    , tx <- [txFor (selRef s)]
    ]
  where
    intToTx = [(r, tx) | (tx, r) <- pairing]
    txFor r = case lookup r intToTx of
        Just tx -> tx
        Nothing -> error ("settledTxIns: no output reference for " <> show r)

-- | Translate a selection's exclusions through the pairing, in order.
excludedTxIns :: [(TxIn, Int)] -> Selection -> [(TxIn, Exclusion)]
excludedTxIns pairing sel =
    [(txFor (prRef q), exc) | (q, exc) <- selectionExcluded sel]
  where
    intToTx = [(r, tx) | (tx, r) <- pairing]
    txFor r = case lookup r intToTx of
        Just tx -> tx
        Nothing -> error ("excludedTxIns: no output reference for " <> show r)

-- ---------------------------------------------------------
-- Fixtures: three pending, one settles
-- ---------------------------------------------------------

t1 :: TxIn
t1 = txRef 1

t2 :: TxIn
t2 = txRef 2

t3 :: TxIn
t3 = txRef 3

p1 :: PendingRequest
p1 = mkInsert 1 50 "Alice" farDeadline

p2 :: PendingRequest
p2 = mkInsert 2 51 "Bob" farDeadline

p3 :: PendingRequest
p3 = mkInsert 3 52 "Carol" nearDeadline

threeFacts :: Map.Map Int (Leaf, Bool)
threeFacts =
    Map.fromList
        [ (50, (LeafUnknown, False))
        , (51, (LeafActive, True))
        , (52, (LeafUnknown, False))
        ]

threePending :: [PendingRequest]
threePending = [p1, p2, p3]

threePairing :: [(TxIn, Int)]
threePairing = [(t1, 1), (t2, 2), (t3, 3)]

threeSelection :: Selection
threeSelection = selectFold 1 nowMs marginMs threeFacts threePending

-- ---------------------------------------------------------
-- Fixtures: three pending, none settleable, three reasons
-- ---------------------------------------------------------

u1 :: TxIn
u1 = txRef 11

u2 :: TxIn
u2 = txRef 12

u3 :: TxIn
u3 = txRef 13

q1 :: PendingRequest
q1 = (mkInsert 11 60 "Quinn" farDeadline){prDecodeOk = False}

q2 :: PendingRequest
q2 = mkInsert 12 61 "Ruth" farDeadline

q3 :: PendingRequest
q3 = mkInsert 13 62 "Sam" nearDeadline

noneFacts :: Map.Map Int (Leaf, Bool)
noneFacts =
    Map.fromList
        [ (60, (LeafUnknown, False))
        , (61, (LeafActive, True))
        , (62, (LeafUnknown, False))
        ]

nonePending :: [PendingRequest]
nonePending = [q1, q2, q3]

nonePairing :: [(TxIn, Int)]
nonePairing = [(u1, 11), (u2, 12), (u3, 13)]

noneSelection :: Selection
noneSelection = selectFold 1 nowMs marginMs noneFacts nonePending

-- ---------------------------------------------------------
-- Fixtures: two settle under a wide bound
-- ---------------------------------------------------------

v1 :: TxIn
v1 = txRef 21

v2 :: TxIn
v2 = txRef 22

v3 :: TxIn
v3 = txRef 23

s1 :: PendingRequest
s1 = mkInsert 21 70 "Tess" farDeadline

s2 :: PendingRequest
s2 = mkInsert 22 71 "Uma" farDeadline

s3 :: PendingRequest
s3 = mkInsert 23 72 "Vera" farDeadline

wideFacts :: Map.Map Int (Leaf, Bool)
wideFacts =
    Map.fromList
        [ (70, (LeafUnknown, False))
        , (71, (LeafUnknown, False))
        , (72, (LeafActive, True))
        ]

widePending :: [PendingRequest]
widePending = [s1, s2, s3]

widePairing :: [(TxIn, Int)]
widePairing = [(v1, 21), (v2, 22), (v3, 23)]

wideSelection :: Selection
wideSelection = selectFold 9 nowMs marginMs wideFacts widePending

-- ---------------------------------------------------------
-- Fixtures: the spend check, three pending
-- ---------------------------------------------------------

stateTx :: TxIn
stateTx = txRef 90

aTx :: TxIn
aTx = txRef 91

bTx :: TxIn
bTx = txRef 92

cTx :: TxIn
cTx = txRef 93

fundTx :: TxIn
fundTx = txRef 94

pendingTxIns :: [TxIn]
pendingTxIns = [aTx, bTx, cTx]

spec :: Spec
spec = describe "registry fold takes the selection" $ do
    namedRequestMustBeSettled
    nothingToFoldNamesEveryExclusion
    severalPendingNeverRefusesOnCount
    builtFoldSpendsExactlyTheSelection
    mismatchedInputsRefuseAsInconsistent
    namedWithNothingSettledStatesCause
    earlyNamedEdgeRefusal
    requestFieldsAreReadFromTheOutput
    sameKeySameInteger
    approvalCheckFollowsTheModel
    applicationVerdictFollowsTheValue
    liveFactsReadLeafAndToken
    assembledApplicationVerdictReachesTheSelection
    assembledApprovalCheckReachesTheSelection
    oldRuleUntouched
    receiptListsSettledAndExcluded
    foldReceiptOmitsEarlierFields
    windowClosedKeepsOthers
    oldRuleContrastReference
    foldResultListsItsSettledRequests
    settledEntryLookup

-- ---------------------------------------------------------
-- A named request must be among the settled
-- ---------------------------------------------------------

namedRequestMustBeSettled :: Spec
namedRequestMustBeSettled = describe "a named request is among the settled" $ do
    it "returns exactly the settled list when the named request settled" $ do
        let got = foldRequests (Just t1) threePairing threeSelection
        got `shouldBe` Right (t1 :| [])
        got `shouldBe` case settledTxIns threePairing threeSelection of
            (x : xs) -> Right (x :| xs)
            [] -> Left FoldNothingPending
    it
        "refuses a named request the model refused, naming reason and source"
        $ do
            let exc = exclusionFor 2 threeSelection
            exclusionSource exc `shouldBe` "model-refusal"
            foldRequests (Just t2) threePairing threeSelection
                `shouldBe` Left (FoldNamedExcluded t2 exc)
            let said = renderFoldRequestsRefusal (FoldNamedExcluded t2 exc)
            T.unpack (renderOutRef t2) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionName exc) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionSource exc) `isInfixOf` said `shouldBe` True
            T.unpack (excDetail exc) `isInfixOf` said `shouldBe` True
    it
        "refuses a named request the policy left out, naming reason and source"
        $ do
            let exc = exclusionFor 3 threeSelection
            exclusionSource exc `shouldBe` "selection-policy"
            foldRequests (Just t3) threePairing threeSelection
                `shouldBe` Left (FoldNamedExcluded t3 exc)
            let said = renderFoldRequestsRefusal (FoldNamedExcluded t3 exc)
            T.unpack (renderOutRef t3) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionName exc) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionSource exc) `isInfixOf` said `shouldBe` True
            T.unpack (excDetail exc) `isInfixOf` said `shouldBe` True
    it
        "refuses a named request that was never pending with the not-pending wording"
        $ do
            let fresh = txRef 9
                said = renderFoldRequestsRefusal (FoldNamedNotPending fresh)
            foldRequests (Just fresh) threePairing threeSelection
                `shouldBe` Left (FoldNamedNotPending fresh)
            T.unpack (renderOutRef fresh) `isInfixOf` said `shouldBe` True
            "is not pending" `isInfixOf` said `shouldBe` True

-- ---------------------------------------------------------
-- Nothing settleable names every exclusion
-- ---------------------------------------------------------

nothingToFoldNamesEveryExclusion :: Spec
nothingToFoldNamesEveryExclusion = describe "nothing settleable names every exclusion" $ do
    it "lists all three exclusions in ledger input order" $ do
        let expected = excludedTxIns nonePairing noneSelection
        length expected `shouldBe` 3
        length (nub (map (T.unpack . exclusionName . snd) expected))
            `shouldBe` 3
        map fst expected `shouldBe` [u1, u2, u3]
        foldRequests Nothing nonePairing noneSelection
            `shouldBe` Left (FoldNothingToFold expected)
        let said = renderFoldRequestsRefusal (FoldNothingToFold expected)
        mapM_
            ( \(tx, exc) -> do
                T.unpack (renderOutRef tx) `isInfixOf` said `shouldBe` True
                T.unpack (exclusionName exc) `isInfixOf` said `shouldBe` True
                T.unpack (exclusionSource exc) `isInfixOf` said `shouldBe` True
                T.unpack (excDetail exc) `isInfixOf` said `shouldBe` True
            )
            expected
    it "fails a version that names only the first exclusion" $ do
        let expected = excludedTxIns nonePairing noneSelection
            firstOnly = take 1 expected
            actual = foldRequests Nothing nonePairing noneSelection
        actual `shouldBe` Left (FoldNothingToFold expected)
        actual `shouldNotBe` Left (FoldNothingToFold firstOnly)
        renderFoldRequestsRefusal (FoldNothingToFold expected)
            `shouldNotBe` renderFoldRequestsRefusal (FoldNothingToFold firstOnly)
    it "says nothing is pending when nothing is pending" $ do
        let emptySel = selectFold 1 nowMs marginMs Map.empty []
            said = renderFoldRequestsRefusal FoldNothingPending
        foldRequests Nothing [] emptySel `shouldBe` Left FoldNothingPending
        "nothing is pending" `isInfixOf` said `shouldBe` True

-- ---------------------------------------------------------
-- Several pending never refuses on count
-- ---------------------------------------------------------

severalPendingNeverRefusesOnCount :: Spec
severalPendingNeverRefusesOnCount = describe "several pending never refuses on count" $ do
    it "takes the one settled request when two are pending" $ do
        let pending2 = [p1, p2]
            pairing2 = [(t1, 1), (t2, 2)]
            facts2 = Map.delete 52 threeFacts
            sel2 = selectFold 1 nowMs marginMs facts2 pending2
        foldRequests Nothing pairing2 sel2 `shouldBe` Right (t1 :| [])
        refuseWhenSeveralArePending Nothing [t1, t2]
            `shouldBe` Left "several pending"
    it "takes the one settled request when three are pending" $ do
        foldRequests Nothing threePairing threeSelection
            `shouldBe` Right (t1 :| [])
        refuseWhenSeveralArePending Nothing [t1, t2, t3]
            `shouldBe` Left "several pending"
    it "returns every settled request under a wide bound" $ do
        let expected = settledTxIns widePairing wideSelection
        expected `shouldBe` [v1, v2]
        foldRequests Nothing widePairing wideSelection
            `shouldBe` Right (v1 :| [v2])

-- ---------------------------------------------------------
-- A built fold spends exactly the selection
-- ---------------------------------------------------------

builtFoldSpendsExactlyTheSelection :: Spec
builtFoldSpendsExactlyTheSelection = describe "a built fold spends exactly the selection" $ do
    it "is ok for the state plus the selected plus unrelated funding" $ do
        spendsSelection stateTx [aTx] pendingTxIns [stateTx, aTx, fundTx]
            `shouldBe` Right ()
        spendsSelection
            stateTx
            [aTx, bTx]
            pendingTxIns
            [stateTx, bTx, aTx, fundTx]
            `shouldBe` Right ()
    it "refuses naming the missing state output" $ do
        let got = spendsSelection stateTx [aTx] pendingTxIns [aTx, fundTx]
        got `shouldBe` Left (SpendsMissingState stateTx)
        case got of
            Left why ->
                T.unpack (renderOutRef stateTx)
                    `isInfixOf` renderSpendsRefusal why
                    `shouldBe` True
            Right _ -> expectationFailure "the missing state output is ok"
    it "refuses naming a missing selected reference" $ do
        let got = spendsSelection stateTx [aTx] pendingTxIns [stateTx, fundTx]
        got `shouldBe` Left (SpendsMissingSelected [aTx])
        case got of
            Left why ->
                T.unpack (renderOutRef aTx)
                    `isInfixOf` renderSpendsRefusal why
                    `shouldBe` True
            Right _ -> expectationFailure "the missing selected reference is ok"
    it "refuses naming another pending reference that is spent" $ do
        let got =
                spendsSelection stateTx [aTx] pendingTxIns [stateTx, aTx, bTx, fundTx]
        got `shouldBe` Left (SpendsExtraPending [bTx])
        case got of
            Left why ->
                T.unpack (renderOutRef bTx)
                    `isInfixOf` renderSpendsRefusal why
                    `shouldBe` True
            Right _ -> expectationFailure "the extra pending spend is ok"
    it
        "refuses when the second of two selected references is not spent, naming it"
        $ do
            let got =
                    spendsSelection stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
            got `shouldBe` Left (SpendsMissingSelected [bTx])
            case got of
                Left why ->
                    T.unpack (renderOutRef bTx)
                        `isInfixOf` renderSpendsRefusal why
                        `shouldBe` True
                Right _ -> expectationFailure "the missing second reference is ok"
    it
        "refuses when the last of three selected references is not spent, naming it"
        $ do
            let got =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, bTx, fundTx]
            got `shouldBe` Left (SpendsMissingSelected [cTx])
            case got of
                Left why ->
                    T.unpack (renderOutRef cTx)
                        `isInfixOf` renderSpendsRefusal why
                        `shouldBe` True
                Right _ -> expectationFailure "the missing last reference is ok"
    it
        "refuses when the middle of three selected references is not spent, naming it"
        $ do
            let got =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, cTx, fundTx]
            got `shouldBe` Left (SpendsMissingSelected [bTx])
            case got of
                Left why ->
                    T.unpack (renderOutRef bTx)
                        `isInfixOf` renderSpendsRefusal why
                        `shouldBe` True
                Right _ -> expectationFailure "the missing middle reference is ok"
    it
        "fails the new rows for a variant that checks only the first selected reference"
        $ do
            let firstOnly state selected _ spent = case selected of
                    [] -> Right ()
                    (x : _) | x `notElem` spent -> Left (SpendsMissingSelected [x])
                    _ | state `notElem` spent -> Left (SpendsMissingState state)
                    _ -> Right ()
                secondMissing =
                    spendsSelection stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
                lastMissing =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, bTx, fundTx]
                middleMissing =
                    spendsSelection
                        stateTx
                        [aTx, bTx, cTx]
                        pendingTxIns
                        [stateTx, aTx, cTx, fundTx]
            firstOnly stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
                `shouldBe` Right ()
            ( firstOnly stateTx [aTx, bTx] pendingTxIns [stateTx, aTx, fundTx]
                    == secondMissing
                )
                `shouldBe` False
            ( firstOnly
                    stateTx
                    [aTx, bTx, cTx]
                    pendingTxIns
                    [stateTx, aTx, bTx, fundTx]
                    == lastMissing
                )
                `shouldBe` False
            ( firstOnly
                    stateTx
                    [aTx, bTx, cTx]
                    pendingTxIns
                    [stateTx, aTx, cTx, fundTx]
                    == middleMissing
                )
                `shouldBe` False
    it "leaves funding and collateral free for any non-pending reference" $
        property $
            forAll (choose (100, 200)) $ \n ->
                let extra = txRef n
                in  extra `notElem` (stateTx : pendingTxIns) ==>
                        spendsSelection
                            stateTx
                            [aTx]
                            pendingTxIns
                            [stateTx, aTx, fundTx, extra]
                            === Right ()

-- ---------------------------------------------------------
-- Mismatched selection and pairing refuse as inconsistent
-- ---------------------------------------------------------

mismatchedInputsRefuseAsInconsistent :: Spec
mismatchedInputsRefuseAsInconsistent =
    describe "mismatched selection and pairing refuse as inconsistent" $ do
        it
            "refuses when a settled reference has no pairing, never shortening the list"
            $ do
                let pairingMissingSettled = [(t2, 2), (t3, 3)]
                    listed =
                        map selRef (selectionSettled threeSelection)
                            ++ map (prRef . fst) (selectionExcluded threeSelection)
                    paired = map snd pairingMissingSettled
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingMissingSettled, r `notElem` listed]
                    got = foldRequests Nothing pairingMissingSettled threeSelection
                missing `shouldNotBe` []
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                got `shouldNotBe` Left FoldNothingPending
                case got of
                    Left why -> do
                        let said = renderFoldRequestsRefusal why
                        mapM_ (\r -> show r `isInfixOf` said `shouldBe` True) missing
                        said `shouldNotBe` renderFoldRequestsRefusal FoldNothingPending
                    Right _ -> expectationFailure "the inconsistent pairing returned a list"
        it
            "refuses when a paired output is listed nowhere, never as not-pending"
            $ do
                let tX = txRef 4
                    pairingWithExtra = threePairing ++ [(tX, 99)]
                    listed =
                        map selRef (selectionSettled threeSelection)
                            ++ map (prRef . fst) (selectionExcluded threeSelection)
                    paired = map snd pairingWithExtra
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingWithExtra, r `notElem` listed]
                    got = foldRequests Nothing pairingWithExtra threeSelection
                    gotNamed = foldRequests (Just tX) pairingWithExtra threeSelection
                extraTxs `shouldBe` [tX]
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                gotNamed `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                gotNamed `shouldNotBe` Left (FoldNamedNotPending tX)
                case gotNamed of
                    Left why ->
                        T.unpack (renderOutRef tX)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ -> expectationFailure "the unlisted pairing returned a list"
        it
            "refuses when the pairing is non-empty while both lists are empty, never as nothing pending"
            $ do
                let emptySel = selectFold 1 nowMs marginMs Map.empty []
                    pairingNonEmpty = [(t1, 1)]
                    got = foldRequests Nothing pairingNonEmpty emptySel
                got `shouldBe` Left (FoldInconsistentInput [] [t1])
                got `shouldNotBe` Left FoldNothingPending
                case got of
                    Left why ->
                        T.unpack (renderOutRef t1)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ ->
                        expectationFailure "the empty selection with pairing returned a list"
        it
            "refuses when the first selected maps and a later one does not, naming the unpaired"
            $ do
                let pairingFirstMaps = [(v1, 21), (v3, 23)]
                    listed =
                        map selRef (selectionSettled wideSelection)
                            ++ map (prRef . fst) (selectionExcluded wideSelection)
                    paired = map snd pairingFirstMaps
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingFirstMaps, r `notElem` listed]
                    got = foldRequests Nothing pairingFirstMaps wideSelection
                missing `shouldBe` [22]
                extraTxs `shouldBe` []
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                case got of
                    Left why ->
                        show (22 :: Int)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ -> expectationFailure "the partial pairing returned a list"
        it
            "refuses when the last selected maps and an earlier one does not, naming the unpaired"
            $ do
                let pairingLastMaps = [(v2, 22), (v3, 23)]
                    listed =
                        map selRef (selectionSettled wideSelection)
                            ++ map (prRef . fst) (selectionExcluded wideSelection)
                    paired = map snd pairingLastMaps
                    missing = [r | r <- listed, r `notElem` paired]
                    extraTxs = [tx | (tx, r) <- pairingLastMaps, r `notElem` listed]
                    got = foldRequests Nothing pairingLastMaps wideSelection
                missing `shouldBe` [21]
                extraTxs `shouldBe` []
                got `shouldBe` Left (FoldInconsistentInput missing extraTxs)
                case got of
                    Left why ->
                        show (21 :: Int)
                            `isInfixOf` renderFoldRequestsRefusal why
                            `shouldBe` True
                    Right _ -> expectationFailure "the partial pairing returned a list"
        it
            "fails partial rows for a shortening translation that returns the shorter list"
            $ do
                let shortenFold pairing sel =
                        let intToTx = [(r, tx) | (tx, r) <- pairing]
                            mapped =
                                [ tx
                                | s <- selectionSettled sel
                                , Just tx <- [lookup (selRef s) intToTx]
                                ]
                        in  case mapped of
                                [] -> Left FoldNothingPending
                                (x : xs) -> Right (x :| xs)
                    shortFirst = shortenFold [(v1, 21), (v3, 23)] wideSelection
                    shortLast = shortenFold [(v2, 22), (v3, 23)] wideSelection
                shortFirst `shouldBe` Right (v1 :| [])
                shortLast `shouldBe` Right (v2 :| [])
                shortFirst
                    `shouldNotBe` Left (FoldInconsistentInput [22] [] :: FoldRequestsRefusal)
                shortLast
                    `shouldNotBe` Left (FoldInconsistentInput [21] [] :: FoldRequestsRefusal)

-- ---------------------------------------------------------
-- A named request with nothing settled states its cause
-- ---------------------------------------------------------

namedWithNothingSettledStatesCause :: Spec
namedWithNothingSettledStatesCause =
    describe "a named request with nothing settled states its cause" $ do
        it "states a not-pending named cause and lists every other exclusion" $ do
            let fresh = txRef 9
                allOthers = excludedTxIns nonePairing noneSelection
                got = foldRequests (Just fresh) nonePairing noneSelection
                expected = FoldNamedNothingSettled fresh Nothing allOthers
            got `shouldBe` Left expected
            got `shouldNotBe` Left (FoldNothingToFold allOthers)
            case got of
                Left why -> do
                    let said = renderFoldRequestsRefusal why
                    renderFoldRequestsRefusal (FoldNamedNotPending fresh)
                        `isInfixOf` said
                        `shouldBe` True
                    renderFoldRequestsRefusal (FoldNothingToFold allOthers)
                        `isInfixOf` said
                        `shouldBe` True
                Right _ -> expectationFailure "the named empty fold returned a list"
        it "states an excluded named cause and lists every other exclusion" $ do
            let exc2 = exclusionFor 12 noneSelection
                allExclusions = excludedTxIns nonePairing noneSelection
                others = [x | x@(tx, _) <- allExclusions, tx /= u2]
                got = foldRequests (Just u2) nonePairing noneSelection
                expected = FoldNamedNothingSettled u2 (Just exc2) others
            map fst others `shouldBe` [u1, u3]
            got `shouldBe` Left expected
            got `shouldNotBe` Left (FoldNamedExcluded u2 exc2)
            got `shouldNotBe` Left (FoldNothingToFold allExclusions)
            case got of
                Left why -> do
                    let said = renderFoldRequestsRefusal why
                    renderFoldRequestsRefusal (FoldNamedExcluded u2 exc2)
                        `isInfixOf` said
                        `shouldBe` True
                    renderFoldRequestsRefusal (FoldNothingToFold others)
                        `isInfixOf` said
                        `shouldBe` True
                Right _ -> expectationFailure "the named empty fold returned a list"
        it
            "states both not-pending and nothing pending when nothing is pending"
            $ do
                let fresh = txRef 9
                    emptySel = selectFold 1 nowMs marginMs Map.empty []
                    got = foldRequests (Just fresh) [] emptySel
                    expected = FoldNamedNothingSettled fresh Nothing []
                got `shouldBe` Left expected
                got `shouldNotBe` Left (FoldNamedNotPending fresh)
                got `shouldNotBe` Left FoldNothingPending
                case got of
                    Left why -> do
                        let said = renderFoldRequestsRefusal why
                        renderFoldRequestsRefusal (FoldNamedNotPending fresh)
                            `isInfixOf` said
                            `shouldBe` True
                        renderFoldRequestsRefusal FoldNothingPending
                            `isInfixOf` said
                            `shouldBe` True
                    Right _ -> expectationFailure "the named empty fold returned a list"

-- ---------------------------------------------------------
-- The old rule stays in place
-- ---------------------------------------------------------

oldRuleUntouched :: Spec
oldRuleUntouched = describe "the old one-pending rule is deleted" $ do
    it "refuses several pending by the private reference" $
        refuseWhenSeveralArePending Nothing [t1, t2]
            `shouldBe` Left "several pending"
    it "keeps the not-pending wording for the new refusals" $ do
        let saidNothing = renderFoldRequestsRefusal FoldNothingPending
            saidNotPending = renderFoldRequestsRefusal (FoldNamedNotPending t1)
        "nothing is pending" `isInfixOf` saidNothing `shouldBe` True
        T.unpack (renderOutRef t1) `isInfixOf` saidNotPending `shouldBe` True
        "is not pending" `isInfixOf` saidNotPending `shouldBe` True

-- ---------------------------------------------------------
-- The additive receipt lists beside the earlier fields (invariant 7)
-- ---------------------------------------------------------

receiptListsSettledAndExcluded :: Spec
receiptListsSettledAndExcluded = describe
    "receipt lists settled and excluded beside the earlier fields"
    $ do
        it "lists two settled requests with distinct payloads in ledger order" $ do
            let provenance =
                    "recovery reads one transition until the multi-request recovery ships"
                        :: T.Text
                settlement1 = object ["liveOutput" .= renderOutRef v1]
                deadline1 = object ["posixMs" .= (farDeadline :: Integer)]
                settlement2 =
                    object
                        ["released" .= renderOutRef v2, "deposit" .= (2000000 :: Integer)]
                deadline2 = object ["posixMs" .= (nearDeadline :: Integer)]
                settled =
                    [ SettledForReceipt
                        v1
                        "6b31"
                        "insertActive"
                        "6f776e657231"
                        settlement1
                        deadline1
                    , SettledForReceipt
                        v2
                        "6b32"
                        "updateTerminal"
                        "6f776e657232"
                        settlement2
                        deadline2
                    ]
                got = foldReceiptLists settled [] 1 provenance
            map fst got `shouldBe` ["settled", "excluded", "capacity"]
            lookup "settled" got
                `shouldBe` Just
                    ( toJSON
                        [ object
                            [ "request" .= renderOutRef v1
                            , "key" .= ("6b31" :: T.Text)
                            , "edge" .= ("insertActive" :: T.Text)
                            , "owner" .= ("6f776e657231" :: T.Text)
                            , "settlement" .= settlement1
                            , "deadline" .= deadline1
                            ]
                        , object
                            [ "request" .= renderOutRef v2
                            , "key" .= ("6b32" :: T.Text)
                            , "edge" .= ("updateTerminal" :: T.Text)
                            , "owner" .= ("6f776e657232" :: T.Text)
                            , "settlement" .= settlement2
                            , "deadline" .= deadline2
                            ]
                        ]
                    )
            lookup "settled" got
                `shouldNotBe` Just
                    ( toJSON
                        [ object
                            [ "request" .= renderOutRef v2
                            , "key" .= ("6b32" :: T.Text)
                            , "edge" .= ("updateTerminal" :: T.Text)
                            , "owner" .= ("6f776e657232" :: T.Text)
                            , "settlement" .= settlement2
                            , "deadline" .= deadline2
                            ]
                        , object
                            [ "request" .= renderOutRef v1
                            , "key" .= ("6b31" :: T.Text)
                            , "edge" .= ("insertActive" :: T.Text)
                            , "owner" .= ("6f776e657231" :: T.Text)
                            , "settlement" .= settlement1
                            , "deadline" .= deadline1
                            ]
                        ]
                    )
            lookup "excluded" got `shouldBe` Just (toJSON ([] :: [Value]))
        it
            "lists every exclusion with reason, source and detail in ledger order, both vocabularies"
            $ do
                let provenance =
                        "recovery reads one transition until the multi-request recovery ships"
                            :: T.Text
                    expected = excludedTxIns nonePairing noneSelection
                    got = foldReceiptLists [] expected 1 provenance
                map fst got `shouldBe` ["settled", "excluded", "capacity"]
                length expected `shouldBe` 3
                let sources = map (exclusionSource . snd) expected
                sources `shouldSatisfy` elem "model-refusal"
                sources `shouldSatisfy` elem "selection-policy"
                lookup "settled" got `shouldBe` Just (toJSON ([] :: [Value]))
                lookup "excluded" got
                    `shouldBe` Just
                        ( toJSON
                            [ object
                                [ "request" .= renderOutRef tx
                                , "reason" .= exclusionName exc
                                , "source" .= exclusionSource exc
                                , "detail" .= excDetail exc
                                ]
                            | (tx, exc) <- expected
                            ]
                        )
                lookup "excluded" got
                    `shouldNotBe` Just
                        ( toJSON
                            [ object
                                [ "request" .= renderOutRef tx
                                , "reason" .= exclusionName exc
                                , "source" .= exclusionSource exc
                                , "detail" .= excDetail exc
                                ]
                            | (tx, exc) <- reverse expected
                            ]
                        )
                map fst expected `shouldBe` [u1, u2, u3]
        it
            "carries the bound with its provenance text, and a second bound differs"
            $ do
                let provenance1 =
                        "recovery reads one transition until the multi-request recovery ships"
                            :: T.Text
                    provenance9 =
                        "preprod execution budget of 14 million memory units, bound by trie-proof verification, unmeasured"
                            :: T.Text
                    got1 = foldReceiptLists [] [] 1 provenance1
                    got9 = foldReceiptLists [] [] 9 provenance9
                map fst got1 `shouldBe` ["settled", "excluded", "capacity"]
                lookup "capacity" got1
                    `shouldBe` Just (object ["bound" .= (1 :: Int), "provenance" .= provenance1])
                lookup "capacity" got9
                    `shouldBe` Just (object ["bound" .= (9 :: Int), "provenance" .= provenance9])
                lookup "capacity" got1 `shouldNotBe` lookup "capacity" got9

-- ---------------------------------------------------------
-- The fold receipt omits the earlier single-request fields
-- ---------------------------------------------------------

{- | The earlier top-level single-request fields the removal slice deletes:
@request@, @key@, @edge@, and the delivery fields of every branch
(@liveOutput@ with @envelope@, @liveOutput@ with @datumHash@ and @datumCbor@,
@released@ with @deposit@).
-}
removedEarlierFields :: [T.Text]
removedEarlierFields =
    [ "request"
    , "key"
    , "edge"
    , "liveOutput"
    , "envelope"
    , "released"
    , "deposit"
    , "datumHash"
    , "datumCbor"
    ]

{- | The top-level fields that stay: the transaction facts, the host clock
facts and the three lists, in the order a reader meets them.
-}
keptFieldNames :: [T.Text]
keptFieldNames =
    [ "folder"
    , "fold"
    , "root"
    , "foldDeadline"
    , "validUntilSlot"
    , "postBuild"
    , "hostClockMs"
    , "remainingMs"
    , "settled"
    , "excluded"
    , "capacity"
    ]

{- | Every retained top-level pair, spelled literally from the fixture
components (not projected through the production function), so that a
corrupted retained value fails the rows below. The eight pairs are the
transaction and clock facts the receipt keeps, in order, before the lists.
-}
expectedKeptPairs :: [(T.Text, Value)]
expectedKeptPairs =
    [ ("folder", toJSON ("666f6c646572" :: T.Text))
    , ("fold", toJSON ("aa11" :: T.Text))
    , ("root", toJSON ("726f6f74" :: T.Text))
    , ("foldDeadline", object ["posixMs" .= farDeadline])
    , ("validUntilSlot", toJSON (Just 42 :: Maybe Integer))
    , ("postBuild", object ["check" .= ("admitted" :: T.Text)])
    , ("hostClockMs", toJSON nowMs)
    , ("remainingMs", toJSON (900000 :: Integer))
    ]

foldReceiptOmitsEarlierFields :: Spec
foldReceiptOmitsEarlierFields =
    describe "the fold receipt omits the earlier single-request fields" $ do
        it
            "a delivered holding receipt has none of the earlier fields and keeps the list"
            $ do
                let liveOut = renderOutRef (txRef 111)
                    envelope = toJSON ("656e76656c6f7065" :: T.Text)
                    settled =
                        [ SettledForReceipt
                            (txRef 111)
                            "6b31"
                            "insertActive"
                            "6f776e657231"
                            (object ["liveOutput" .= liveOut, "envelope" .= envelope])
                            (object ["posixMs" .= farDeadline])
                        ]
                    got =
                        keptReceiptFields baseKeptComps
                            <> foldReceiptLists settled [] 1 "prov-1"
                mapM_
                    (\name -> lookup name got `shouldBe` Nothing)
                    removedEarlierFields
                map fst got `shouldBe` keptFieldNames
                take (length expectedKeptPairs) got `shouldBe` expectedKeptPairs
                lookup "settled" got
                    `shouldBe` Just
                        ( toJSON
                            [ object
                                [ "request" .= liveOut
                                , "key" .= ("6b31" :: T.Text)
                                , "edge" .= ("insertActive" :: T.Text)
                                , "owner" .= ("6f776e657231" :: T.Text)
                                , "settlement"
                                    .= object ["liveOutput" .= liveOut, "envelope" .= envelope]
                                , "deadline" .= object ["posixMs" .= farDeadline]
                                ]
                            ]
                        )
        it
            "a delivered datum receipt has none of the earlier fields and keeps the list"
            $ do
                let liveOut = renderOutRef t2
                    dHash = "6861736832" :: T.Text
                    dCbor = "63626f7232" :: T.Text
                    settled =
                        [ SettledForReceipt
                            t2
                            "6b31"
                            "insertActive"
                            "6f776e657231"
                            ( object
                                [ "liveOutput" .= liveOut
                                , "datumHash" .= dHash
                                , "datumCbor" .= dCbor
                                ]
                            )
                            (object ["posixMs" .= farDeadline])
                        ]
                    got =
                        keptReceiptFields baseKeptComps
                            <> foldReceiptLists settled [] 1 "prov-1"
                mapM_
                    (\name -> lookup name got `shouldBe` Nothing)
                    removedEarlierFields
                map fst got `shouldBe` keptFieldNames
                take (length expectedKeptPairs) got `shouldBe` expectedKeptPairs
                lookup "settled" got
                    `shouldBe` Just
                        ( toJSON
                            [ object
                                [ "request" .= liveOut
                                , "key" .= ("6b31" :: T.Text)
                                , "edge" .= ("insertActive" :: T.Text)
                                , "owner" .= ("6f776e657231" :: T.Text)
                                , "settlement"
                                    .= object
                                        [ "liveOutput" .= liveOut
                                        , "datumHash" .= dHash
                                        , "datumCbor" .= dCbor
                                        ]
                                , "deadline" .= object ["posixMs" .= farDeadline]
                                ]
                            ]
                        )
        it
            "a released holding receipt has none of the earlier fields and keeps the list"
            $ do
                let releasedOut = renderOutRef t3
                    deposit = 2000000 :: Integer
                    settled =
                        [ SettledForReceipt
                            t3
                            "6b32"
                            "updateTerminal"
                            "6f776e657232"
                            ( object
                                [ "released" .= releasedOut
                                , "deposit" .= deposit
                                ]
                            )
                            (object ["posixMs" .= farDeadline])
                        ]
                    got =
                        keptReceiptFields baseKeptComps
                            <> foldReceiptLists settled [] 1 "prov-1"
                mapM_
                    (\name -> lookup name got `shouldBe` Nothing)
                    removedEarlierFields
                map fst got `shouldBe` keptFieldNames
                take (length expectedKeptPairs) got `shouldBe` expectedKeptPairs
                lookup "settled" got
                    `shouldBe` Just
                        ( toJSON
                            [ object
                                [ "request" .= releasedOut
                                , "key" .= ("6b32" :: T.Text)
                                , "edge" .= ("updateTerminal" :: T.Text)
                                , "owner" .= ("6f776e657232" :: T.Text)
                                , "settlement"
                                    .= object
                                        [ "released" .= releasedOut
                                        , "deposit" .= deposit
                                        ]
                                , "deadline" .= object ["posixMs" .= farDeadline]
                                ]
                            ]
                        )

-- ---------------------------------------------------------
-- The old-rule contrast as a private reference (invariant 9)
-- ---------------------------------------------------------

{- | A private reference implementation of "refuse when several are pending":
the contrast the deletion keeps, failing the same inputs the old rule failed.
-}
refuseWhenSeveralArePending
    :: Maybe TxIn -> [TxIn] -> Either String TxIn
refuseWhenSeveralArePending _ [] = Left "nothing is pending"
refuseWhenSeveralArePending (Just r) pend
    | r `notElem` pend = Left "not pending"
refuseWhenSeveralArePending _ [one] = Right one
refuseWhenSeveralArePending _ _ = Left "several pending"

-- ---------------------------------------------------------
-- A window-closed named cause keeps every other exclusion
-- ---------------------------------------------------------

windowClosedKeepsOthers :: Spec
windowClosedKeepsOthers = describe "a window-closed named cause keeps every other exclusion" $ do
    it "leaves a sole window-closed message unchanged" $ do
        let legacy = "the request's processing deadline, 123 ms: no fold is built"
        combineWindowClosedMessage legacy [] `shouldBe` legacy
    it "lists an undecodable other exclusion after the legacy wording" $ do
        let legacy = "the request's processing deadline, 123 ms: no fold is built"
            undecodableExc =
                Exclusion ReasonUndecodable "the output does not decode as a request"
            others = [(u1, undecodableExc)]
            got = combineWindowClosedMessage legacy others
        legacy `isInfixOf` got `shouldBe` True
        T.unpack (renderOutRef u1) `isInfixOf` got `shouldBe` True
        "undecodable" `isInfixOf` got `shouldBe` True
        "selection-policy" `isInfixOf` got `shouldBe` True
        got `shouldNotBe` legacy

oldRuleContrastReference :: Spec
oldRuleContrastReference = describe "the old-rule contrast refuses the same inputs" $ do
    it "takes the one pending request" $
        refuseWhenSeveralArePending Nothing [t1] `shouldBe` Right t1
    it "refuses several pending" $ do
        refuseWhenSeveralArePending Nothing [t1, t2]
            `shouldBe` Left "several pending"
        refuseWhenSeveralArePending (Just t1) [t1, t2]
            `shouldBe` Left "several pending"
    it "refuses nothing pending" $ do
        refuseWhenSeveralArePending Nothing []
            `shouldBe` Left "nothing is pending"
        refuseWhenSeveralArePending (Just t1) []
            `shouldBe` Left "nothing is pending"

-- ---------------------------------------------------------
-- An early refusal for a named request keeps every other exclusion
-- ---------------------------------------------------------

{- | The fixtures of the early-refusal row: one pending request whose edge the
fold does not take (named) and one pending output that does not decode, both
read from real request datums through the production adapters.
-}
earlyRefusalFixtures
    :: ( [(TxIn, Either String OnChainRequest)]
       , [(TxIn, Int)]
       , [PendingRequest]
       , Selection
       )
earlyRefusalFixtures =
    let addrR = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'R'))
        keyR = BC.pack "early-refusal-inadmissible"
        destR = (serialiseAddr addrR, Just (PLC.I 1))
        datumR =
            mkRequestDatumWith
                Fixture.tokenId
                addrR
                keyR
                2
                2000000
                1000
                destR
        reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
        outR =
            mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                & datumTxOutL .~ mkInlineDatum datumR
        outU = mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
        decR = case extractCageDatum outR of
            Just (RequestDatum r) -> Right r
            _ -> Left "no request datum"
        decU = Left "no datum" :: Either String OnChainRequest
        rTx = txRef 101
        uTx = txRef 102
        (pendings, pairing) =
            buildPendingRequests
                [(rTx, outR, decR), (uTx, outU, decU)]
                gPinned
                neutralApplication
                gProcess
        facts = Map.fromList [(prKey p, (LeafUnknown, False)) | p <- pendings]
        sel = selectFold 1 nowMs marginMs facts pendings
    in  ([(rTx, decR), (uTx, decU)], pairing, pendings, sel)

earlyNamedEdgeRefusal :: Spec
earlyNamedEdgeRefusal = describe "an early refusal for a named untakeable edge" $ do
    it "refuses at once when the named request is the only one pending" $
        refuseNamedEdgeEarly (Just t1) [t1] `shouldBe` True
    it "does not refuse at once when another request is also pending" $
        refuseNamedEdgeEarly (Just t1) [t1, t2] `shouldBe` False
    it
        "does not refuse at once a named request that is not the sole pending one"
        $ refuseNamedEdgeEarly (Just t1) [t2, t3] `shouldBe` False
    it "decides nothing without a named request" $
        refuseNamedEdgeEarly Nothing [t1] `shouldBe` False
    it
        "a named inadmissible edge beside an undecodable request is refused by the selection, naming both"
        $ do
            let (_, pairing, pendings, sel) = earlyRefusalFixtures
                (rTx, uTx) = (txRef 101, txRef 102)
                excluded = excludedTxIns pairing sel
                excOf tx = case [exc | (t, exc) <- excluded, t == tx] of
                    (e : _) -> e
                    [] -> error ("early-refusal row: no exclusion for " <> show tx)
                excR = excOf rTx
                excU = excOf uTx
            map fst pairing `shouldBe` [rTx, uTx]
            selectionSettled sel `shouldBe` []
            map fst excluded `shouldBe` [rTx, uTx]
            exclusionName excR `shouldBe` "edge-inadmissible"
            exclusionSource excR `shouldBe` "model-refusal"
            exclusionName excU `shouldBe` "undecodable"
            exclusionSource excU `shouldBe` "selection-policy"
            length pendings `shouldBe` 2
            -- the decision: with another request pending, no early refusal
            refuseNamedEdgeEarly (Just rTx) (map fst pairing) `shouldBe` False
            -- so the selection's refusal names the named cause and every other exclusion
            foldRequests (Just rTx) pairing sel
                `shouldBe` Left (FoldNamedNothingSettled rTx (Just excR) [(uTx, excU)])
            let said =
                    renderFoldRequestsRefusal
                        (FoldNamedNothingSettled rTx (Just excR) [(uTx, excU)])
            T.unpack (renderOutRef rTx) `isInfixOf` said `shouldBe` True
            T.unpack (renderOutRef uTx) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionName excR) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionName excU) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionSource excR) `isInfixOf` said `shouldBe` True
            T.unpack (exclusionSource excU) `isInfixOf` said `shouldBe` True
            T.unpack (excDetail excR) `isInfixOf` said `shouldBe` True
            T.unpack (excDetail excU) `isInfixOf` said `shouldBe` True

-- ---------------------------------------------------------
-- The kept fields' shared fixture components
-- ---------------------------------------------------------

{- | The kept fields' fixture components, shared by every delivery branch:
each value is spelled once and both the projection and its expected pairs
read the same fields.
-}
baseKeptComps :: KeptReceipt
baseKeptComps =
    KeptReceipt
        { keptFolder = "666f6c646572"
        , keptFold = "aa11"
        , keptRoot = "726f6f74"
        , keptDeadline = object ["posixMs" .= farDeadline]
        , keptUpperSlot = Just 42
        , keptPostBuild = object ["check" .= ("admitted" :: T.Text)]
        , keptHostClockMs = nowMs
        , keptRemainingMs = 900000
        }

-- ---------------------------------------------------------
-- Selection inputs: output-derived fixtures (invariants 1-5)
-- ---------------------------------------------------------

-- | The pinned policy of the test registry, read from its config.
gPinned :: SBS.ShortByteString
gPinned = cfgApplicationPolicy Fixture.cfg

-- | The processing time of the test registry, read from its config.
gProcess :: Integer
gProcess = defaultProcessTime Fixture.cfg

requestFieldsAreReadFromTheOutput :: Spec
requestFieldsAreReadFromTheOutput = describe "request fields are read from the output" $ do
    it "maps admitted edges to their kinds" $ do
        requestEdgeKind edgeInsertActive `shouldBe` EdgeInsertActive
        requestEdgeKind edgeUpdateTerminal `shouldBe` EdgeUpdateTerminal
    it "maps another edge to other carrying the model name" $
        requestEdgeKind 5 `shouldBe` EdgeOther (T.pack (edgeName 5))
    it "hexes the owner bytes" $ do
        let raw = BC.pack "k1-owner"
            want = T.pack (BC.unpack (B16.encode raw))
        requestOwnerText raw `shouldBe` want
    it "adds submission and processing time" $ do
        let s = 1000
            p = 30000
        pendingDeadlineOf s p `shouldBe` (s + p)
    it "assembles pending requests field by field from real datums" $ do
        let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
            addrB = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'B'))
            keyA = BC.pack "green-key-1"
            keyB = BC.pack "green-key-2"
            subA = 1000
            subB = 2000
            destA = (serialiseAddr addrA, Just (PLC.I 1))
            destB = (serialiseAddr addrB, Nothing)
            datumA =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrA
                    keyA
                    edgeInsertActive
                    2000000
                    subA
                    destA
            datumB =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrB
                    keyB
                    edgeUpdateTerminal
                    2000000
                    subB
                    destB
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            outA =
                mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                    & datumTxOutL .~ mkInlineDatum datumA
            outB =
                mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                    & datumTxOutL .~ mkInlineDatum datumB
            decA = case extractCageDatum outA of
                Just (RequestDatum r) -> Right r
                _ -> Left "no request datum"
            decB = case extractCageDatum outB of
                Just (RequestDatum r) -> Right r
                _ -> Left "no request datum"
            txA = txRef 41
            txB = txRef 42
            app = neutralApplication
            (pendings, pairing) =
                buildPendingRequests
                    [(txA, outA, decA), (txB, outB, decB)]
                    gPinned
                    app
                    gProcess
        length pendings `shouldBe` 2
        pairing `shouldBe` [(txA, 1), (txB, 2)]
        case (decA, decB, pendings) of
            (Right reqA, Right reqB, [pA, pB]) -> do
                prDecodeOk pA `shouldBe` True
                prDecodeOk pB `shouldBe` True
                prEdge pA `shouldBe` EdgeInsertActive
                prEdge pB `shouldBe` EdgeUpdateTerminal
                prDeadline pA `shouldBe` (requestSubmittedAt reqA + gProcess)
                prDeadline pB `shouldBe` (requestSubmittedAt reqB + gProcess)
                requestKey reqA `shouldBe` keyA
                requestKey reqB `shouldBe` keyB
                requestEdge reqA `shouldBe` edgeInsertActive
                requestEdge reqB `shouldBe` edgeUpdateTerminal
                let BuiltinByteString obsA = requestOwner reqA
                    BuiltinByteString obsB = requestOwner reqB
                prOwner pA `shouldBe` T.pack (BC.unpack (B16.encode obsA))
                prOwner pB `shouldBe` T.pack (BC.unpack (B16.encode obsB))
                prRef pA `shouldBe` 1
                prRef pB `shouldBe` 2
                prKey pA `shouldNotBe` prKey pB
            _ -> expectationFailure "fixtures did not decode"
    it "a non-decoding output yields an undecodable pending request" $ do
        let reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            out = mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
            got =
                pendingRequestOf
                    1
                    1
                    (Left "no datum" :: Either String OnChainRequest)
                    out
                    gPinned
                    AppReady
                    gProcess
        prDecodeOk got `shouldBe` False

sameKeySameInteger :: Spec
sameKeySameInteger = describe "same key shares one integer" $ do
    it "shares one integer among requests on the same key bytes" $ do
        let keys = [BC.pack "same-key", BC.pack "same-key", BC.pack "other-key"]
            ints = assignKeyInts keys
        length ints `shouldBe` 3
        case ints of
            (i0 : _) -> do
                i0 `shouldBe` (ints !! 1)
                i0 `shouldNotBe` (ints !! 2)
            [] -> expectationFailure "assignKeyInts returned no integers"
    it "keeps references distinct and pairs each with its own output" $ do
        let txs = [txRef 31, txRef 32, txRef 33]
            pairing = assignRefPairing txs
        map snd pairing `shouldBe` nub (map snd pairing)
        pairing `shouldBe` zip txs (map snd pairing)
    it "fails the spec for a mapping that numbers keys by position" $ do
        let keys = [BC.pack "dup-key", BC.pack "dup-key"]
            byPosition = [1 .. length keys]
        case byPosition of
            (b0 : _) -> b0 `shouldNotBe` (byPosition !! 1)
            [] -> expectationFailure "position numbering is empty"
    it
        "the selection excludes the later same-key request under shared integers"
        $ do
            let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
                addrB = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'B'))
                key = BC.pack "shared-key"
                reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
                mkOut addr sub =
                    let dest = (serialiseAddr addr, Just (PLC.I 1))
                        datum =
                            mkRequestDatumWith
                                Fixture.tokenId
                                addr
                                key
                                edgeInsertActive
                                2000000
                                sub
                                dest
                        base =
                            mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                                & datumTxOutL .~ mkInlineDatum datum
                    in  case extractCageDatum base of
                            Just (RequestDatum r) ->
                                let BuiltinByteString obs = requestOwner r
                                    good =
                                        approvalName
                                            (requestEdge r)
                                            (requestKey r)
                                            obs
                                            (approvalDestination (requestDestination r))
                                    assets =
                                        MultiAsset
                                            ( Map.singleton
                                                (policyIdFromPin gPinned)
                                                (Map.singleton (AssetName (SBS.toShort good)) 1)
                                            )
                                    out =
                                        mkBasicTxOut reqAddr (MaryValue (Coin 10000000) assets)
                                            & datumTxOutL .~ mkInlineDatum datum
                                in  (out, Right r)
                            _ -> (base, Left "no datum" :: Either String OnChainRequest)
                (outA, decA) = mkOut addrA 1000
                (outB, decB) = mkOut addrB 2000
                txA = txRef 51
                txB = txRef 52
                app = neutralApplication
                (pendings, _) =
                    buildPendingRequests
                        [(txA, outA, decA), (txB, outB, decB)]
                        gPinned
                        app
                        10000000
            length pendings `shouldBe` 2
            case pendings of
                (p0 : _) -> do
                    prKey p0 `shouldBe` prKey (pendings !! 1)
                    let facts = Map.fromList [(prKey p0, (LeafUnknown, False))]
                        sel = selectFold 9 0 0 facts pendings
                    map selRef (selectionSettled sel) `shouldBe` [prRef p0]
                    map (exclusionName . snd) (selectionExcluded sel)
                        `shouldBe` ["key-in-batch"]
                [] -> expectationFailure "pending assembly is empty"
    it "a position-numbered control would settle both same-key requests" $ do
        let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
            addrB = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'B'))
            key = BC.pack "shared-key"
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            mkP addr sub refInt keyInt =
                let dest = (serialiseAddr addr, Just (PLC.I 1))
                    datum =
                        mkRequestDatumWith
                            Fixture.tokenId
                            addr
                            key
                            edgeInsertActive
                            2000000
                            sub
                            dest
                    base =
                        mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                            & datumTxOutL .~ mkInlineDatum datum
                in  case extractCageDatum base of
                        Just (RequestDatum r) ->
                            let BuiltinByteString obs = requestOwner r
                                ownerT = T.pack (BC.unpack (B16.encode obs))
                            in  PendingRequest
                                    refInt
                                    keyInt
                                    ownerT
                                    EdgeInsertActive
                                    (requestSubmittedAt r + 10000000)
                                    True
                                    ApprovalOk
                                    AppReady
                        _ -> error "control datum did not decode"
            pA = mkP addrA 1000 1 1
            pB = mkP addrB 2000 2 2
            facts = Map.fromList [(1, (LeafUnknown, False)), (2, (LeafUnknown, False))]
            sel = selectFold 9 0 0 facts [pA, pB]
        length (selectionSettled sel) `shouldBe` 2
        selectionExcluded sel `shouldBe` []

approvalCheckFollowsTheModel :: Spec
approvalCheckFollowsTheModel = describe "approval check follows the model" $ do
    it "no approval asset is missing" $ do
        let pinned = SBS.toShort (BC.pack "pinned-policy")
            good = BC.pack "good-name"
        approvalCheckOf [] pinned good `shouldBe` ApprovalMissing
    it "an approval under another policy is a policy mismatch" $ do
        let pinned = SBS.toShort (BC.pack "pinned-policy")
            other = SBS.toShort (BC.pack "other-policy")
            good = BC.pack "good-name"
        approvalCheckOf [(other, good)] pinned good
            `shouldBe` ApprovalPolicyMismatch
    it "a pinned approval with the wrong name is a tuple mismatch" $ do
        let pinned = SBS.toShort (BC.pack "pinned-policy")
            good = BC.pack "good-name"
            bad = BC.pack "bad-name"
        approvalCheckOf [(pinned, bad)] pinned good
            `shouldBe` ApprovalTupleMismatch
    it "a matching approval is ok" $ do
        let pinned = SBS.toShort (BC.pack "pinned-policy")
            good = BC.pack "good-name"
        approvalCheckOf [(pinned, good)] pinned good `shouldBe` ApprovalOk
    it "the matching commitment is the name the builders mint" $ do
        let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
            key = BC.pack "approval-key"
            dest = (serialiseAddr addrA, Just (PLC.I 1))
            datum =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrA
                    key
                    edgeInsertActive
                    2000000
                    1000
                    dest
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            out =
                mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                    & datumTxOutL .~ mkInlineDatum datum
        case extractCageDatum out of
            Just (RequestDatum r) -> do
                let BuiltinByteString obs = requestOwner r
                    good =
                        approvalName
                            (requestEdge r)
                            (requestKey r)
                            obs
                            (approvalDestination (requestDestination r))
                approvalCheckOf [(gPinned, good)] gPinned good `shouldBe` ApprovalOk
            _ -> expectationFailure "base datum did not decode"
    it "altering only the edge breaks the commitment" $ do
        checkAltered (\r -> r{requestEdge = edgeUpdateTerminal})
    it "altering only the key breaks the commitment" $ do
        checkAltered (\r -> r{requestKey = requestKey r <> BC.pack "x"})
    it "altering only the owner breaks the commitment" $ do
        checkAltered
            ( \r ->
                r{requestOwner = BuiltinByteString (BC.pack (replicate 28 'Z'))}
            )
    it "altering only the destination address breaks the commitment" $ do
        let addrZ = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'Z'))
        checkAltered
            ( \r ->
                r
                    { requestDestination = (serialiseAddr addrZ, snd (requestDestination r))
                    }
            )
    it "altering only the destination datum breaks the commitment" $ do
        checkAltered
            ( \r ->
                r
                    { requestDestination = (fst (requestDestination r), Just (PLC.I 999))
                    }
            )
    it "a hand-altered name breaks the commitment" $ do
        let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
            key = BC.pack "approval-key"
            dest = (serialiseAddr addrA, Just (PLC.I 1))
            datum =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrA
                    key
                    edgeInsertActive
                    2000000
                    1000
                    dest
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            out =
                mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                    & datumTxOutL .~ mkInlineDatum datum
        case extractCageDatum out of
            Just (RequestDatum r) -> do
                let BuiltinByteString obs = requestOwner r
                    good =
                        approvalName
                            (requestEdge r)
                            (requestKey r)
                            obs
                            (approvalDestination (requestDestination r))
                    bad = good <> BC.pack "extra"
                approvalCheckOf [(gPinned, bad)] gPinned good
                    `shouldBe` ApprovalTupleMismatch
            _ -> expectationFailure "base datum did not decode"
  where
    checkAltered alter = do
        let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
            key = BC.pack "approval-key"
            dest = (serialiseAddr addrA, Just (PLC.I 1))
            datum =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrA
                    key
                    edgeInsertActive
                    2000000
                    1000
                    dest
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            out =
                mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                    & datumTxOutL .~ mkInlineDatum datum
        case extractCageDatum out of
            Just (RequestDatum r) -> do
                let BuiltinByteString obs = requestOwner r
                    good =
                        approvalName
                            (requestEdge r)
                            (requestKey r)
                            obs
                            (approvalDestination (requestDestination r))
                    r2 = alter r
                    BuiltinByteString obs2 = requestOwner r2
                    altered =
                        approvalName
                            (requestEdge r2)
                            (requestKey r2)
                            obs2
                            (approvalDestination (requestDestination r2))
                altered `shouldNotBe` good
                approvalCheckOf [(gPinned, altered)] gPinned good
                    `shouldBe` ApprovalTupleMismatch
            _ -> expectationFailure "base datum did not decode"

applicationVerdictFollowsTheValue :: Spec
applicationVerdictFollowsTheValue = describe "application verdict follows the value" $ do
    it "a readable insertion is ready" $ do
        let req = mkReq edgeInsertActive (Just (PLC.I 1))
        appVerdictOf neutralApplication req `shouldBe` AppReady
    it "an unreadable insertion is unreadable" $ do
        let req = mkReq edgeInsertActive Nothing
        appVerdictOf neutralApplication req `shouldBe` AppDatumUnreadable
    it "an insertion follows the value holding rules" $ do
        let req = mkReq edgeInsertActive (Just (PLC.I 1))
            badRules = dummyRules (Left "cannot read")
            goodRules = dummyRules (Right (PLC.I 1))
            badApp = neutralApplication{appHolding = Just badRules}
            goodApp = neutralApplication{appHolding = Just goodRules}
        appVerdictOf badApp req `shouldBe` AppDatumUnreadable
        appVerdictOf goodApp req `shouldBe` AppReady
    it "a termination without holding rules names the value executable" $ do
        let exe = T.pack "fixture-exe-1"
            app = neutralApplication{appExecutable = Just exe}
            req = mkReq edgeUpdateTerminal Nothing
        appVerdictOf app req `shouldBe` AppRequired exe
    it
        "a termination without holding rules or executable names the generic wording"
        $ do
            let req = mkReq edgeUpdateTerminal Nothing
            appVerdictOf neutralApplication req
                `shouldBe` AppRequired neutralAppExecutable
    it
        "a termination with holding rules is ready with and without an executable"
        $ do
            let exe = T.pack "fixture-exe-9"
                noExe =
                    neutralApplication
                        { appHolding = Just (dummyRules (Right (PLC.I 0)))
                        }
                withExe = noExe{appExecutable = Just exe}
                req = mkReq edgeUpdateTerminal Nothing
            appVerdictOf noExe req `shouldBe` AppReady
            appVerdictOf withExe req `shouldBe` AppReady
    it "the executable in the verdict is the value's own" $ do
        let exe = T.pack "fixture-exe-2"
            other = T.pack "fixture-exe-other"
            app = neutralApplication{appExecutable = Just exe}
            req = mkReq edgeUpdateTerminal Nothing
            owned = case appExecutable app of
                Just e -> e
                Nothing -> error "verdict fixture names no executable"
        owned `shouldBe` exe
        appVerdictOf app req `shouldBe` AppRequired owned
        appVerdictOf app req `shouldNotBe` AppRequired other
  where
    mkReq edge destDatum =
        let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
            key = BC.pack "verdict-key"
            dest = (serialiseAddr addrA, destDatum)
            datum = mkRequestDatumWith Fixture.tokenId addrA key edge 2000000 1000 dest
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            out =
                mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                    & datumTxOutL .~ mkInlineDatum datum
        in  case extractCageDatum out of
                Just (RequestDatum r) -> r
                _ -> error "verdict fixture did not decode"
    dummyRules check =
        HoldingRules
            { hrCheckCarried = const check
            , hrFindHoldings = \_ _ _ _ -> []
            , hrLiveOutputFor = \_ _ _ _ -> Left "unused"
            , hrReleaseOf = \_ _ -> Left "unused"
            , hrWithApplication = \_ _ _ _ -> Left "unused"
            }

liveFactsReadLeafAndToken :: Spec
liveFactsReadLeafAndToken = describe "live facts read leaf and token" $ do
    it "yields matching facts under the shared integers" $ do
        let k1 = BC.pack "leaf-key-1"
            k2 = BC.pack "leaf-key-2"
            leaves = Map.fromList [(k1, LeafActive), (k2, LeafTerminal)]
            present = Map.fromList [(k1, True), (k2, False)]
            keys = Map.fromList [(k1, 1), (k2, 2)]
            want = Map.fromList [(1, (LeafActive, True)), (2, (LeafTerminal, False))]
        buildLiveFacts leaves present keys `shouldBe` want
    it "covers all four leaf states with and without a token output" $ do
        let ks = [BC.pack "u", BC.pack "a", BC.pack "c", BC.pack "t"]
            leaves =
                Map.fromList
                    (zip ks [LeafUnknown, LeafAbsent, LeafActive, LeafTerminal])
            present =
                Map.fromList (zip ks [False, False, True, False])
            keys = Map.fromList (zip ks [1 ..])
            want =
                Map.fromList
                    [ (1, (LeafUnknown, False))
                    , (2, (LeafAbsent, False))
                    , (3, (LeafActive, True))
                    , (4, (LeafTerminal, False))
                    ]
        buildLiveFacts leaves present keys `shouldBe` want
    it "a key never mentioned is unknown" $ do
        let k = BC.pack "missing-key"
            keys = Map.fromList [(k, 7)]
        buildLiveFacts Map.empty Map.empty keys
            `shouldBe` Map.fromList [(7, (LeafUnknown, False))]
    it "uses the same integers as the pending assembly" $ do
        let addrA = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'A'))
            addrB = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'B'))
            keyA = BC.pack "shared-facts-1"
            keyB = BC.pack "shared-facts-2"
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            mkOut addr key sub =
                let dest = (serialiseAddr addr, Just (PLC.I 1))
                    datum =
                        mkRequestDatumWith
                            Fixture.tokenId
                            addr
                            key
                            edgeInsertActive
                            2000000
                            sub
                            dest
                    out =
                        mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                            & datumTxOutL .~ mkInlineDatum datum
                in  case extractCageDatum out of
                        Just (RequestDatum r) -> (out, Right r)
                        _ -> (out, Left "no datum" :: Either String OnChainRequest)
            (outA, decA) = mkOut addrA keyA 1000
            (outB, decB) = mkOut addrB keyB 2000
            txA = txRef 61
            txB = txRef 62
            (pendings, _) =
                buildPendingRequests
                    [(txA, outA, decA), (txB, outB, decB)]
                    gPinned
                    neutralApplication
                    gProcess
        case pendings of
            (p0 : _) -> do
                let keyMap =
                        Map.fromList
                            [ (keyA, prKey p0)
                            , (keyB, prKey (pendings !! 1))
                            ]
                    leaves =
                        Map.fromList [(keyA, LeafUnknown), (keyB, LeafActive)]
                    present = Map.fromList [(keyA, False), (keyB, True)]
                    got = buildLiveFacts leaves present keyMap
                Map.lookup (prKey p0) got
                    `shouldBe` Just (LeafUnknown, False)
                Map.lookup (prKey (pendings !! 1)) got
                    `shouldBe` Just (LeafActive, True)
            [] -> expectationFailure "pending assembly is empty"

-- ---------------------------------------------------------
-- Assembly: the application verdict reaches the selection
-- ---------------------------------------------------------

assembledApplicationVerdictReachesTheSelection :: Spec
assembledApplicationVerdictReachesTheSelection = describe "assembled application verdict reaches the selection" $ do
    it "carries each request's application verdict into the selection" $ do
        let exe = T.pack "fixture-exe-assembled-1"
            app = neutralApplication{appExecutable = Just exe}
            addrR = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'R'))
            addrS = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'S'))
            addrT = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'T'))
            keyR = BC.pack "assembled-app-ready"
            keyS = BC.pack "assembled-app-required"
            keyT = BC.pack "assembled-app-unreadable"
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            destR = (serialiseAddr addrR, Just (PLC.I 1))
            destS = (serialiseAddr addrS, Just (PLC.I 2))
            destT = (serialiseAddr addrT, Nothing)
            datumR =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrR
                    keyR
                    edgeInsertActive
                    2000000
                    1000
                    destR
            datumS =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrS
                    keyS
                    edgeUpdateTerminal
                    2000000
                    2000
                    destS
            datumT =
                mkRequestDatumWith
                    Fixture.tokenId
                    addrT
                    keyT
                    edgeInsertActive
                    2000000
                    3000
                    destT
            mkApproved datum =
                let base =
                        mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                            & datumTxOutL .~ mkInlineDatum datum
                in  case extractCageDatum base of
                        Just (RequestDatum r) ->
                            let BuiltinByteString obs = requestOwner r
                                good =
                                    approvalName
                                        (requestEdge r)
                                        (requestKey r)
                                        obs
                                        (approvalDestination (requestDestination r))
                                assets =
                                    MultiAsset
                                        ( Map.singleton
                                            (policyIdFromPin gPinned)
                                            (Map.singleton (AssetName (SBS.toShort good)) 1)
                                        )
                                out =
                                    mkBasicTxOut reqAddr (MaryValue (Coin 10000000) assets)
                                        & datumTxOutL .~ mkInlineDatum datum
                            in  (out, Right r :: Either String OnChainRequest)
                        _ -> (base, Left "no datum" :: Either String OnChainRequest)
            (outR, decR) = mkApproved datumR
            (outS, decS) = mkApproved datumS
            (outT, decT) = mkApproved datumT
            txR = txRef 71
            txS = txRef 72
            txT = txRef 73
            (pendings, _) =
                buildPendingRequests
                    [(txR, outR, decR), (txS, outS, decS), (txT, outT, decT)]
                    gPinned
                    app
                    gProcess
            decoded = rights [decR, decS, decT]
            expected = map (appVerdictOf app) decoded
        length pendings `shouldBe` 3
        length decoded `shouldBe` 3
        (length (nub expected) >= 2) `shouldBe` True
        map prApp pendings `shouldBe` expected
        map prApproval pendings
            `shouldBe` [ApprovalOk, ApprovalOk, ApprovalOk]
        case pendings of
            [pR, pS, pT] -> do
                let facts =
                        Map.fromList
                            [ (prKey pR, (LeafUnknown, False))
                            , (prKey pS, (LeafActive, True))
                            , (prKey pT, (LeafUnknown, False))
                            ]
                    sel = selectFold 9 0 0 facts pendings
                map selRef (selectionSettled sel) `shouldBe` [prRef pR]
                map (T.unpack . exclusionName . snd) (selectionExcluded sel)
                    `shouldBe` ["application-required", "application-datum-unreadable"]
                case selectionExcluded sel of
                    [(_, excS), (_, excT)] -> do
                        T.unpack exe `isInfixOf` T.unpack (excDetail excS)
                            `shouldBe` True
                        T.unpack (excDetail excT) `shouldNotBe` ""
                    _ ->
                        expectationFailure
                            "the application exclusions are not the two expected"
            _ -> expectationFailure "pending assembly is not the three expected"

-- ---------------------------------------------------------
-- Assembly: the approval check reaches the selection
-- ---------------------------------------------------------

assembledApprovalCheckReachesTheSelection :: Spec
assembledApprovalCheckReachesTheSelection = describe "assembled approval check reaches the selection" $ do
    it "carries each request's approval check into the selection" $ do
        let addrC = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'C'))
            addrD = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'D'))
            addrE = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'E'))
            addrF = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'F'))
            addrG = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'G'))
            addrH = addrFromKeyHashBytes Testnet (BC.pack (replicate 28 'H'))
            keyC = BC.pack "assembled-approval-ok"
            keyD = BC.pack "assembled-approval-policy"
            keyE = BC.pack "assembled-approval-missing"
            keyF = BC.pack "assembled-approval-edge"
            keyG = BC.pack "assembled-approval-key"
            keyH = BC.pack "assembled-approval-owner"
            reqAddr = requestAddrFromCfg Fixture.cfg Fixture.tokenId Testnet
            otherPin = SBS.toShort (BC.pack (replicate 28 'Q'))
            otherOwner = BC.pack (replicate 28 'Z')
            mkDatum addr key sub =
                mkRequestDatumWith
                    Fixture.tokenId
                    addr
                    key
                    edgeInsertActive
                    2000000
                    sub
                    (serialiseAddr addr, Just (PLC.I 1))
            datumC = mkDatum addrC keyC 1000
            datumD = mkDatum addrD keyD 2000
            datumE = mkDatum addrE keyE 3000
            datumF = mkDatum addrF keyF 4000
            datumG = mkDatum addrG keyG 5000
            datumH = mkDatum addrH keyH 6000
            decode datum =
                let base =
                        mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                            & datumTxOutL .~ mkInlineDatum datum
                in  case extractCageDatum base of
                        Just (RequestDatum r) -> (base, Right r :: Either String OnChainRequest)
                        _ -> (base, Left "no datum" :: Either String OnChainRequest)
            (_, decC) = decode datumC
            (_, decD) = decode datumD
            (_, decE) = decode datumE
            (_, decF) = decode datumF
            (_, decG) = decode datumG
            (_, decH) = decode datumH
            goodOf dec = case dec of
                Right r ->
                    let BuiltinByteString obs = requestOwner r
                    in  approvalName
                            (requestEdge r)
                            (requestKey r)
                            obs
                            (approvalDestination (requestDestination r))
                Left _ -> error "approval fixture did not decode"
            goodC = goodOf decC
            goodD = goodOf decD
            alteredF = case decF of
                Right r ->
                    let BuiltinByteString obs = requestOwner r
                    in  approvalName
                            edgeUpdateTerminal
                            (requestKey r)
                            obs
                            (approvalDestination (requestDestination r))
                Left _ -> error "approval fixture did not decode"
            alteredG = case decG of
                Right r ->
                    let BuiltinByteString obs = requestOwner r
                    in  approvalName
                            (requestEdge r)
                            (requestKey r <> BC.pack "x")
                            obs
                            (approvalDestination (requestDestination r))
                Left _ -> error "approval fixture did not decode"
            alteredH = case decH of
                Right r ->
                    approvalName
                        (requestEdge r)
                        (requestKey r)
                        otherOwner
                        (approvalDestination (requestDestination r))
                Left _ -> error "approval fixture did not decode"
            mkAssets pin name =
                MultiAsset
                    ( Map.singleton
                        (policyIdFromPin pin)
                        (Map.singleton (AssetName (SBS.toShort name)) 1)
                    )
            outC =
                mkBasicTxOut
                    reqAddr
                    (MaryValue (Coin 10000000) (mkAssets gPinned goodC))
                    & datumTxOutL .~ mkInlineDatum datumC
            outD =
                mkBasicTxOut
                    reqAddr
                    (MaryValue (Coin 10000000) (mkAssets otherPin goodD))
                    & datumTxOutL .~ mkInlineDatum datumD
            outE =
                mkBasicTxOut reqAddr (MaryValue (Coin 10000000) mempty)
                    & datumTxOutL .~ mkInlineDatum datumE
            outF =
                mkBasicTxOut
                    reqAddr
                    (MaryValue (Coin 10000000) (mkAssets gPinned alteredF))
                    & datumTxOutL .~ mkInlineDatum datumF
            outG =
                mkBasicTxOut
                    reqAddr
                    (MaryValue (Coin 10000000) (mkAssets gPinned alteredG))
                    & datumTxOutL .~ mkInlineDatum datumG
            outH =
                mkBasicTxOut
                    reqAddr
                    (MaryValue (Coin 10000000) (mkAssets gPinned alteredH))
                    & datumTxOutL .~ mkInlineDatum datumH
            txC = txRef 81
            txD = txRef 82
            txE = txRef 83
            txF = txRef 84
            txG = txRef 85
            txH = txRef 86
            app = neutralApplication
            (pendings, _) =
                buildPendingRequests
                    [ (txC, outC, decC)
                    , (txD, outD, decD)
                    , (txE, outE, decE)
                    , (txF, outF, decF)
                    , (txG, outG, decG)
                    , (txH, outH, decH)
                    ]
                    gPinned
                    app
                    gProcess
            -- Expected checks from how each fixture was built: matching, other policy, missing, then edge, key and owner altered.
            expected =
                [ ApprovalOk
                , ApprovalPolicyMismatch
                , ApprovalMissing
                , ApprovalTupleMismatch
                , ApprovalTupleMismatch
                , ApprovalTupleMismatch
                ]
        length pendings `shouldBe` 6
        map prApproval pendings `shouldBe` expected
        let facts = Map.fromList [(prKey p, (LeafUnknown, False)) | p <- pendings]
            sel = selectFold 9 0 0 facts pendings
        case pendings of
            (pC : _) ->
                map selRef (selectionSettled sel) `shouldBe` [prRef pC]
            [] -> expectationFailure "pending assembly is empty"
        map (T.unpack . exclusionName . snd) (selectionExcluded sel)
            `shouldBe` [ "no-approval"
                       , "no-approval"
                       , "approval-mismatch"
                       , "approval-mismatch"
                       , "approval-mismatch"
                       ]

-- ---------------------------------------------------------
-- The fold result lists its settled requests
-- ---------------------------------------------------------

twoEntryFolded :: Folded
twoEntryFolded =
    Folded
        { fdSettled = entry1 :| [entry2]
        , fdFolder = "666f6c646572"
        , fdTx = mkBasicTx mkBasicTxBody
        , fdRoot = "726f6f74"
        , fdUpperSlot = Nothing
        , fdPostBuild = object ["check" .= ("admitted" :: T.Text)]
        , fdDecidedAt = nowMs
        , fdRemaining = 900000
        , fdExcluded = []
        , fdCapacityBound = 1
        , fdCapacityProvenance = "prov-1"
        , fdPreparation = Nothing
        }
  where
    entry1 =
        SettledEntry
            { seRequest = v1
            , seKey = BC.pack "k1"
            , seEdge = edgeInsertActive
            , seOwner = "6f776e657231"
            , seKind = FoldInsertion
            , seDelivery = Released v1 2000000
            , seDeadline = Deadline farDeadline (Just (SlotNo 42))
            }
    entry2 =
        SettledEntry
            { seRequest = v2
            , seKey = BC.pack "k2"
            , seEdge = edgeUpdateTerminal
            , seOwner = "6f776e657232"
            , seKind = FoldTermination
            , seDelivery = Released v2 2000000
            , seDeadline = Deadline nearDeadline (Just (SlotNo 43))
            }

foldResultListsItsSettledRequests :: Spec
foldResultListsItsSettledRequests = describe "the fold result lists its settled requests" $ do
    it
        "the settled list of a receipt built from two entries holds both, in order"
        $ do
            let fields = foldedFields twoEntryFolded
                settled = case lookup "settled" fields of
                    Just v -> v
                    Nothing -> error "no settled list"
            settled
                `shouldBe` toJSON
                    [ object
                        [ "request" .= renderOutRef v1
                        , "key" .= ("6b31" :: T.Text)
                        , "edge" .= ("insertActive" :: T.Text)
                        , "owner" .= ("6f776e657231" :: T.Text)
                        , "settlement"
                            .= object
                                [ "released" .= renderOutRef v1
                                , "deposit" .= (2000000 :: Integer)
                                ]
                        , "deadline"
                            .= object
                                [ "posixMs" .= farDeadline
                                , "slot" .= (42 :: Integer)
                                ]
                        ]
                    , object
                        [ "request" .= renderOutRef v2
                        , "key" .= ("6b32" :: T.Text)
                        , "edge" .= ("updateTerminal" :: T.Text)
                        , "owner" .= ("6f776e657232" :: T.Text)
                        , "settlement"
                            .= object
                                [ "released" .= renderOutRef v2
                                , "deposit" .= (2000000 :: Integer)
                                ]
                        , "deadline"
                            .= object
                                [ "posixMs" .= nearDeadline
                                , "slot" .= (43 :: Integer)
                                ]
                        ]
                    ]
    it "the fold deadline is the earliest among the entries" $ do
        deadlineMs (foldDeadline twoEntryFolded) `shouldBe` nearDeadline

settledEntryLookup :: Spec
settledEntryLookup = describe "settledEntryFor finds the entry for a request" $ do
    it "returns the right entry among two" $ do
        settledEntryFor twoEntryFolded v1
            `shouldBe` Just (case fdSettled twoEntryFolded of e :| _ -> e)
        case fdSettled twoEntryFolded of
            _ :| [e2] -> settledEntryFor twoEntryFolded v2 `shouldBe` Just e2
            _ -> expectationFailure "two entries expected"
    it "returns nothing for a request not among them" $ do
        settledEntryFor twoEntryFolded (txRef 9) `shouldBe` Nothing
